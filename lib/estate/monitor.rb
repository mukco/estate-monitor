# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/integer/time"
require "active_support/core_ext/module/attribute_accessors"
require_relative "monitor/version"
require_relative "monitor/sources/runtime"
require_relative "monitor/sources/solid_queue"
require_relative "monitor/sources/latency"
require_relative "monitor/errors"
require_relative "monitor/errors_app"
require_relative "monitor/stale_assets"

module Estate
  module Monitor
    mattr_accessor :token, :app_name

    # 2026-10-09, error reporting (see Errors). Each has a default that is
    # right for an app that sets nothing but the token:
    #
    #   estate_url         — where events go; ENV["ESTATE_URL"] or the estate.
    #   enabled            — nil means "when there is a token, outside test".
    #                        true/false overrides; a spec that wants to see
    #                        events sets true.
    #   current_user_id    — ->(request) { … } returning the signed-in user's
    #                        id, or nil. Each app's session is its own, so the
    #                        gem cannot guess; unset, every event says nobody.
    #   ignored_exceptions — class names (strings, so an app without
    #                        ActiveRecord can still name its errors) whose
    #                        exceptions, and subclasses, are never reported.
    #   release            — ->{ … } or a string; defaults to the runtime sha
    #                        the metrics already report, so an error and the
    #                        deploy that caused it share a name.
    mattr_accessor :enabled, :current_user_id, :release
    mattr_writer :estate_url, :ignored_exceptions

    # 2026-10-09, stale pages (see StaleAssets):
    #
    #   report_stale_assets — a browser 404ing on one of the app's own built
    #                         JS/CSS files is reported as a client error.
    #   stale_asset_paths   — the prefixes that are the app's own build
    #                         output. Vite's is /assets/; anything outside the
    #                         list is a stranger's guess, not a stale page.
    mattr_accessor :report_stale_assets, default: true
    mattr_writer :stale_asset_paths

    # The README has always shown this block; until now it raised NoMethodError,
    # which is why every app sets the accessors one by one instead.
    def self.configure
      yield self
    end

    def self.estate_url
      class_variable_get(:@@estate_url).presence || ENV["ESTATE_URL"].presence || "https://estate.edwardsfamily.app"
    end

    def self.stale_asset_paths
      class_variable_get(:@@stale_asset_paths) || StaleAssets::DEFAULT_PATHS
    end

    def self.ignored_exceptions
      class_variable_get(:@@ignored_exceptions) || Errors::DEFAULT_IGNORED
    end

    # Reporting is off without a token — there is nobody to send to, and an
    # app in development should not need one — and off in tests unless a spec
    # turns it on, so a suite does not post its deliberate failures to the
    # estate.
    def self.reporting?
      return false if token.blank?
      return enabled unless enabled.nil?

      !(defined?(Rails.env) && Rails.env.test?)
    end

    def self.resolved_app_name
      return app_name if app_name.present?

      Rails.application.class.module_parent_name.to_s if defined?(Rails.application) && Rails.application
    end

    def self.resolved_release
      value = release.respond_to?(:call) ? release.call : release
      value.presence || RuntimeSource.git_sha
    rescue StandardError
      nil
    end

    def self.app_root
      defined?(Rails.root) && Rails.root ? Rails.root.to_s : nil
    end

    # Say something to the estate on purpose.
    #
    #   Estate::Monitor.report(:warning, "Lidarr refused import", context: { album: "…" })
    #   Estate::Monitor.report(:error, exception, context: { feed: feed.id })
    #
    # Returns the event_id, or nil when reporting is off. Never raises: a call
    # in a rescue block must not become the next exception. Inside a request
    # or a job it picks up the route, the job and the signed-in user from
    # Rails' execution context, as an unhandled error would. The ignore list
    # does not apply — reporting one deliberately is the opposite of noise.
    def self.report(level, message_or_exception, context: {}, source: nil, fingerprint: nil)
      return nil unless reporting?

      described, request = Errors.describe(Errors.execution_context)
      source ||= described.key?("job") ? "job" : "server"
      options = { level: level.to_s, source: source.to_s, request: request, fingerprint: fingerprint,
                  context: described.merge(Errors.stringify(context)) }

      if message_or_exception.is_a?(Exception)
        Errors.capture_exception(message_or_exception, kind: "exception", **options)
      else
        Errors.capture_message(message_or_exception, kind: "manual", **options)
      end
    rescue StandardError
      nil
    end

    # 5 adds the `errors` section: events this process has not yet delivered
    # to the estate, for the scrape to collect when pushes are failing.
    # Additive, like 4.
    #
    # 4 adds `recent`, `failure_counts` and `retention` to the solid_queue
    # section, and starts answering two things v3 only pretended to: every
    # `recurring[].last_enqueued_at` was null and `timing` was a NameError.
    # Additive: a v3 reader that has never heard of the new keys keeps working
    # on the sections it does know.
    CONTRACT_VERSION = 5

    def self.sources
      @sources ||= [
        [:runtime, -> { RuntimeSource.snapshot }],
        [:solid_queue, -> { SolidQueueSource.snapshot }],
        [:latency, -> { LatencySource.snapshot }],
        [:errors, -> { Errors.delivery.snapshot }]
      ]
    end

    def self.sources=(array)
      @sources = array
    end

    def self.source(name, &block)
      sources.reject! { |(n, _)| n == name }
      sources << [name.to_sym, block]
    end

    def self.exclude(name)
      sources.reject! { |(n, _)| n == name }
    end

    def self.sections
      sources.each_with_object({}) do |(name, callable), out|
        begin
          out[name] = callable.call
        rescue StandardError => e
          out[name] = { unavailable: "#{e.class}: #{e.message}" }
        end
      end
    end

    # The name apps call at their one gateway call site. Delegated so the
    # caller never has to know which source is counting, or that one is.
    def self.external(&block)
      LatencySource.external(&block)
    end

    def self.authorized?(authorization_header, configured)
      return false if configured.blank?

      provided = authorization_header.to_s.delete_prefix("Bearer ")
      ActiveSupport::SecurityUtils.secure_compare(
        Digest::SHA256.hexdigest(provided), Digest::SHA256.hexdigest(configured)
      )
    end
  end
end

require_relative "monitor/client"

require_relative "monitor/engine"
