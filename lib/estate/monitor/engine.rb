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
    end
  end
end
