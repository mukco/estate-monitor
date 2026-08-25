# frozen_string_literal: true

module Estate
  module Monitor
    module RuntimeSource
      BOOTED_AT = Time.now

      module_function

      def snapshot
        {
          sha: git_sha, booted_at: BOOTED_AT.utc.iso8601,
          uptime_seconds: (Time.now - BOOTED_AT).to_i,
          ruby: RUBY_DESCRIPTION[/ruby \d+\.\d+\.\d+/].to_s,
          rails: (defined?(Rails::VERSION) ? "rails #{Rails::VERSION::STRING}" : nil),
          environment: (Rails.env.to_s if defined?(Rails.env)),
          db_ping: db_ping
        }.compact
      rescue StandardError => e
        { unavailable: "#{e.class}: #{e.message}" }
      end

      def git_sha
        ENV["SOURCE_VERSION"].presence ||
          ENV["KAMAL_VERSION"].presence ||
          (File.exist?("/rails/.git-sha") ? File.read("/rails/.git-sha").strip : nil)
      end

      def db_ping
        return { status: "no activerecord" } unless defined?(ActiveRecord::Base)

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        ActiveRecord::Base.connection.select_value("SELECT 1")
        { status: "ok", ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1) }
      rescue StandardError => e
        { status: "down", error: e.class.to_s }
      end
    end
  end
end
