# frozen_string_literal: true

module Estate
  module Monitor
    module Errors
      # Rails.error, forwarded.
      #
      # 2026-10-09: Rails 7.1+ already routes every unhandled request error
      # (ActionDispatch::Executor) and every job failure (the app executor
      # Solid Queue wraps each job in) through Rails.error, and stamps each
      # with the controller or job it happened in. Subscribing is the whole of
      # server-side capture — no middleware of our own, no ActiveJob callback,
      # nothing that has to be ordered against the app's own.
      #
      # Rails marks an exception once it has been reported, so the executor and
      # Solid Queue both seeing the same job failure still makes one event.
      class Subscriber
        SEVERITY = { error: "error", warning: "warning", info: "info" }.freeze

        def report(error, handled:, severity:, context:, source: nil)
          return unless Monitor.reporting?
          return if Errors.ignored?(error)

          described, request = Errors.describe(context)
          job = context.is_a?(Hash) && context[:job] || source.to_s.match?(/active_job|solid_queue/)
          described["handled"] = handled

          Errors.capture_exception(
            error,
            level: SEVERITY.fetch(severity, "error"),
            source: job ? "job" : "server",
            kind: job ? "job" : "exception",
            context: described,
            request: request,
            user_id: (context[:user_id] if context.is_a?(Hash))
          )
        rescue StandardError
          # Rails would log a raising subscriber at FATAL on every error the app
          # has. Better to lose this one report than to add a second failure.
          nil
        end
      end
    end
  end
end
