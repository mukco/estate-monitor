# frozen_string_literal: true

require "json"
require "securerandom"
require "time"

module Estate
  module Monitor
    module Errors
      # One occurrence, shaped to the estate's contract (§1) whatever it came
      # from — a browser that sent us anything at all, a Rails.error report, or
      # an app calling Estate::Monitor.report on purpose.
      #
      # 2026-10-09: everything here is defensive because half the input is a
      # stranger's JSON. The endpoint takes reports before sign-in (a white
      # screen on the login page must still be heard), so the body is whatever
      # anybody on the internet chose to POST. Nothing here raises on bad
      # input: an unusable field is dropped or replaced, and only an event with
      # no message at all is thrown away, because there is nothing to group.
      module Event
        LEVELS = %w[error warning info].freeze
        SOURCES = %w[client server job tv].freeze

        # The contract's ceilings. Message, class and fingerprint are counted
        # in characters — they are titles a person reads. The stack and the
        # context are counted in bytes, because what they cost is space.
        MESSAGE_CHARS = 1000
        ERROR_CLASS_CHARS = 200
        FINGERPRINT_CHARS = 200
        STACK_BYTES = 16 * 1024
        CONTEXT_BYTES = 8 * 1024
        BREADCRUMBS = 20

        # A single context value is cut well before the whole budget, so one
        # enormous `component_stack` cannot crowd out the route and the build id
        # that make the event findable.
        CONTEXT_VALUE_CHARS = 2000
        CONTEXT_DEPTH = 3

        UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

        module_function

        # `raw` is a Hash with string or symbol keys. Returns the event as a
        # string-keyed Hash, or nil when there is nothing worth keeping.
        #
        # `sources` is what this caller is allowed to claim. A browser may say
        # it is the TV, but it may not say it is the server: the estate treats
        # server errors as ours, and a page should not be able to forge one.
        def normalize(raw, default_source:, sources: SOURCES, now: Time.now.utc)
          return nil unless raw.is_a?(Hash)

          raw = raw.transform_keys(&:to_s)
          message = text(raw["message"], MESSAGE_CHARS)
          return nil if message.nil? || message.strip.empty?

          source = raw["source"].to_s
          {
            "event_id" => event_id(raw["event_id"]),
            "level" => level(raw["level"]),
            "source" => sources.include?(source) ? source : default_source,
            "message" => message,
            "error_class" => text(raw["error_class"], ERROR_CLASS_CHARS),
            "stack" => bytes(raw["stack"], STACK_BYTES),
            "fingerprint" => text(raw["fingerprint"], FINGERPRINT_CHARS),
            "occurred_at" => occurred_at(raw["occurred_at"], now),
            "context" => context(raw["context"])
          }.compact
        end

        # An id the sender chose is kept, so a browser that retried a beacon is
        # recognised as the same event. Anything that is not a UUID is not
        # trusted to be unique and gets a fresh one.
        def event_id(value)
          value.is_a?(String) && value.match?(UUID) ? value.downcase : SecureRandom.uuid
        end

        # An unknown level is an error rather than a drop: something reported
        # it, and "we do not know how bad" is closer to bad than to fine.
        def level(value)
          name = value.to_s.downcase
          name = "warning" if name == "warn"
          LEVELS.include?(name) ? name : "error"
        end

        def occurred_at(value, now)
          time = value.is_a?(String) ? Time.iso8601(value) : nil
          (time || now).utc.iso8601(3)
        rescue ArgumentError
          now.utc.iso8601(3)
        end

        def text(value, chars)
          return nil if value.nil?

          string = value.is_a?(String) ? value : value.to_s
          string = string.scrub("?")
          string.length > chars ? string[0, chars] : string
        end

        def bytes(value, limit)
          return nil if value.nil?

          string = (value.is_a?(String) ? value : value.to_s).b
          string = string.byteslice(0, limit) if string.bytesize > limit
          # Cutting by bytes can split a multi-byte character; scrub turns the
          # stub into nothing rather than shipping invalid UTF-8 that would
          # fail JSON.generate at the far end of the pipeline.
          string.force_encoding(Encoding::UTF_8).scrub("")
        end

        # Plain JSON in, plain JSON out, within budget.
        #
        # Keys are added in the order they came until the next one would not
        # fit; the rest are dropped and `_truncated` says so. Order matters
        # because the reporters put the identifying keys (kind, route, build)
        # first and the bulky ones (component_stack, breadcrumbs) last.
        def context(value)
          return {} unless value.is_a?(Hash)

          out = {}
          size = 2
          value.each do |key, val|
            key = text(key, 100)
            val = key == "breadcrumbs" ? breadcrumbs(val) : plain(val, 0)
            piece = JSON.generate(key => val).bytesize - 1
            if size + piece > CONTEXT_BYTES - 32
              out["_truncated"] = true
              break
            end
            out[key] = val
            size += piece
          end
          out
        rescue StandardError
          {}
        end

        # The last twenty: the steps nearest the failure are the ones that
        # explain it.
        def breadcrumbs(value)
          return plain(value, 0) unless value.is_a?(Array)

          value.last(BREADCRUMBS).map { |crumb| plain(crumb, CONTEXT_DEPTH - 1) }
        end

        # Anything that is not already JSON becomes a short string. A server
        # context can carry live objects — a model, a job, a request — and
        # `as_json` on those would serialise every attribute they hold.
        def plain(value, depth)
          case value
          when nil, true, false, Integer then value
          when Float then value.finite? ? value : value.to_s
          when String then text(value, CONTEXT_VALUE_CHARS)
          when Symbol then value.to_s
          when Time then value.utc.iso8601(3)
          when Hash
            return text(value.inspect, 200) if depth >= CONTEXT_DEPTH

            value.first(50).to_h { |k, v| [text(k, 100), plain(v, depth + 1)] }
          when Array
            return text(value.inspect, 200) if depth >= CONTEXT_DEPTH

            value.first(50).map { |v| plain(v, depth + 1) }
          else
            text(value.inspect, 200)
          end
        rescue StandardError
          nil
        end
      end
    end
  end
end
