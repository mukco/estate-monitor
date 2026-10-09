# frozen_string_literal: true

require "digest"
require "socket"
require "time"
require_relative "errors/event"
require_relative "errors/rate_limiter"
require_relative "errors/delivery"

module Estate
  module Monitor
    # Errors and deliberate log lines, from this app to the estate.
    #
    # 2026-10-09: the estate already scraped each app every five minutes for
    # numbers; this is the other half of watching an app — what went wrong, in
    # which release, for whom. Rolled here rather than bought because every app
    # already carries this gem and already shares a token with the estate, so
    # a Rollbar-shaped reporter is a few files rather than a new service.
    #
    # Three ways in, one way out:
    #   ErrorsApp       — browsers and the TV, POST /internal/errors
    #   Subscriber      — Rails.error: unhandled request and job failures
    #   Monitor.report  — an app saying something on purpose
    # all become an Event, are stamped here with who/where/which release, and
    # go to Delivery, which owns getting them to the estate.
    module Errors
      # Noise, not faults: a bot probing /wp-login.php, a stale link to a
      # deleted row, a form left open over a deploy. Each is an ordinary day on
      # the internet, and an error feed full of them is one nobody reads.
      DEFAULT_IGNORED = %w[
        ActionController::RoutingError
        ActiveRecord::RecordNotFound
        ActionController::InvalidAuthenticityToken
        ActionController::UnknownFormat
      ].freeze

      BACKTRACE_LINES = 40
      HOST = (Socket.gethostname rescue nil)

      # Created at load, not lazily: two Puma threads reporting the first error
      # of a boot at the same moment must not build two of them.
      @delivery = Delivery.new
      @limiter = RateLimiter.new

      class << self
        attr_accessor :delivery, :limiter

        # Stamps a normalized event and hands it to delivery. Returns the
        # event_id, or nil when nothing was recorded.
        def record(event, request: nil, user_id: nil)
          return nil if event.nil? || !Monitor.reporting?

          delivery.push(stamp(event, request: request, user_id: user_id))
        rescue StandardError
          nil
        end

        # What the server knows that the sender does not, or should not be
        # trusted to say: which app and release, who was signed in, roughly
        # where from, and when it actually arrived.
        def stamp(event, request: nil, user_id: nil)
          event.merge(
            "app" => Monitor.resolved_app_name,
            "release" => Monitor.resolved_release,
            "user_id" => user_id.nil? ? user_id_for(request) : user_id,
            "ip_hash" => ip_hash(ip_for(request)),
            "received_at" => Time.now.utc.iso8601(3),
            "host" => HOST
          )
        end

        # Each app keeps its session differently — a signed cookie, a Devise
        # warden, a Google sign-in id in the session — so the gem asks the app.
        # A lambda that raises (no session yet, a cookie it cannot read) means
        # "nobody", never a lost report.
        def user_id_for(request)
          finder = Monitor.current_user_id
          return nil if finder.nil? || request.nil?

          id = finder.call(request)
          id.is_a?(Integer) || id.nil? ? id : id.to_s
        rescue StandardError
          nil
        end

        # Cloudflare's header first: behind its proxy, `remote_ip` is a
        # Cloudflare edge, which would put a whole region in one rate-limit
        # bucket and give every user the same ip_hash.
        def ip_for(request)
          return nil if request.nil?

          cf = request.get_header("HTTP_CF_CONNECTING_IP") if request.respond_to?(:get_header)
          return cf if cf && !cf.empty?

          request.respond_to?(:remote_ip) ? request.remote_ip : request.ip
        rescue StandardError
          nil
        end

        # Enough to say "these five reports are one person" on one day, and not
        # enough to say who. The salt changes daily and is derived from the
        # token, so a hash cannot be reversed by trying the IPv4 space unless
        # you also hold the token, and cannot be followed from one day to the
        # next by anyone.
        def ip_hash(ip)
          return nil if ip.nil? || ip.to_s.empty?

          salt = Digest::SHA256.hexdigest("estate-monitor:#{Monitor.token}:#{Time.now.utc.strftime('%Y-%m-%d')}")
          Digest::SHA256.hexdigest("#{ip}#{salt}")[0, 12]
        end

        def ignored?(exception)
          names = exception.class.ancestors.map(&:name)
          Array(Monitor.ignored_exceptions).any? { |name| names.include?(name.to_s) }
        rescue StandardError
          false
        end

        # An exception, from Rails.error or from Monitor.report.
        def capture_exception(exception, level:, source:, kind:, context: {}, request: nil,
                              user_id: nil, fingerprint: nil)
          event = Event.normalize(
            {
              "level" => level, "source" => source,
              "message" => exception.message.to_s.empty? ? exception.class.name : exception.message,
              "error_class" => exception.class.name,
              "stack" => backtrace(exception),
              "fingerprint" => fingerprint,
              "context" => { "kind" => kind }.merge(stringify(context)).merge(cause(exception))
            },
            default_source: "server"
          )
          record(event, request: request, user_id: user_id)
        end

        # A sentence, from Monitor.report.
        def capture_message(message, level:, source:, kind:, context: {}, request: nil,
                            user_id: nil, fingerprint: nil)
          event = Event.normalize(
            {
              "level" => level, "source" => source, "message" => message.to_s,
              "fingerprint" => fingerprint,
              "context" => { "kind" => kind }.merge(stringify(context))
            },
            default_source: "server"
          )
          record(event, request: request, user_id: user_id)
        end

        # The app's own frames first, then everything else, forty in all,
        # relative to the app root.
        #
        # The estate groups on the top in-app frame, and a Rails backtrace
        # starts deep inside whichever gem raised — ActiveRecord for a bad
        # query, Net::HTTP for a timeout. Put in order, the line that names
        # *our* code is the first one a person reads and the one the grouping
        # keys on; the gem frames are still there underneath, for when the gem
        # is the story.
        def backtrace(exception)
          lines = exception.backtrace || []
          root = Monitor.app_root
          return lines.first(BACKTRACE_LINES).join("\n") if root.nil?

          prefix = root.end_with?("/") ? root : "#{root}/"
          ours, theirs = lines.partition do |line|
            line.start_with?(prefix) && !line.include?("/vendor/") && !line.include?("/gems/")
          end
          (ours + theirs).first(BACKTRACE_LINES).map { |line| line.delete_prefix(prefix) }.join("\n")
        rescue StandardError
          nil
        end

        # A wrapped error says what failed; its cause usually says why.
        def cause(exception)
          cause = exception.cause
          return {} if cause.nil?

          { "cause" => "#{cause.class}: #{cause.message}"[0, 500] }
        rescue StandardError
          {}
        end

        # What Rails knew about the request or job when it failed.
        #
        # Rails puts the live controller and job objects in the error context
        # (ActiveSupport::ExecutionContext). They become the few facts that
        # find the failure again — route, action, job class, attempt — and are
        # dropped as objects, since serialising a controller would ship the
        # whole request.
        def describe(rails_context)
          rails_context ||= {}
          controller = rails_context[:controller]
          job = rails_context[:job]
          out = {}
          request = controller.request if controller.respond_to?(:request)
          if request
            out["route"] = request.path
            out["method"] = request.request_method
          end
          if controller.respond_to?(:controller_path) && controller.respond_to?(:action_name)
            out["action"] = "#{controller.controller_path}##{controller.action_name}"
          end
          if job
            out["job"] = job.class.name
            out["queue"] = job.queue_name if job.respond_to?(:queue_name)
            out["job_id"] = job.job_id if job.respond_to?(:job_id)
            out["executions"] = job.executions if job.respond_to?(:executions)
          end
          rest = rails_context.reject { |key, _| %i[controller job].include?(key.to_sym) }
          [out.merge(stringify(rest)), request]
        rescue StandardError
          [{}, nil]
        end

        def execution_context
          defined?(ActiveSupport::ExecutionContext) ? ActiveSupport::ExecutionContext.to_h : {}
        rescue StandardError
          {}
        end

        def stringify(hash)
          hash.is_a?(Hash) ? hash.transform_keys(&:to_s) : {}
        end
      end
    end
  end
end

require_relative "errors/subscriber"
