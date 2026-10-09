# frozen_string_literal: true

require "rails"

module Estate
  module Monitor
    class Engine < ::Rails::Engine
      isolate_namespace Estate::Monitor

      # Subscribing here rather than at require time keeps the gem loadable
      # outside Rails — the specs drive the collector directly, with no
      # ActionController anywhere — and `subscribe!` is idempotent, so however
      # many times this file is required there is one subscription per boot.
      initializer "estate_monitor.subscribe_latency" do
        ActiveSupport.on_load(:action_controller) do
          Estate::Monitor::LatencySource.subscribe!
        end
      end

      # 2026-10-09: server-side error capture. Always subscribed — it costs a
      # method call per reported error — and the subscriber checks
      # `reporting?` each time, so a token set later in boot, or a spec that
      # turns reporting on, takes effect without re-subscribing.
      initializer "estate_monitor.subscribe_errors" do
        Estate::Monitor::Engine.subscribe_errors!
      end

      # 2026-10-09: stale pages. Just below ActionDispatch::Static, so a file
      # that exists never reaches it and the 404 it sees for one that does not
      # is the app's final answer; at the very top for an app that serves no
      # files itself. Always inserted — it reads its settings per request, so
      # turning it off is `report_stale_assets = false`, not a middleware edit.
      initializer "estate_monitor.stale_assets" do |app|
        if app.config.public_file_server.enabled
          app.config.middleware.insert_after ::ActionDispatch::Static, Estate::Monitor::StaleAssets
        else
          app.config.middleware.insert_before 0, Estate::Monitor::StaleAssets
        end
      end

      def self.subscribe_errors!
        return if @errors_subscribed
        return unless defined?(::Rails.error) && ::Rails.error.respond_to?(:subscribe)

        ::Rails.error.subscribe(Estate::Monitor::Errors::Subscriber.new)
        @errors_subscribed = true
      end
    end
  end
end
