# frozen_string_literal: true

require_relative "../../../lib/estate/monitor"

module Estate
  module Monitor
    class MetricsController < ApplicationController
      before_action :authorize!

      def show
        render json: {
          app: Monitor.app_name || Rails.application.class.module_parent_name.to_s,
          version: CONTRACT_VERSION,
          generated_at: Time.current.utc.iso8601,
          sections: Monitor.sections
        }
      end

      private

      def authorize!
        render json: { error: "unauthorized" }, status: :unauthorized unless
          Monitor.authorized?(request.headers["Authorization"].to_s, Monitor.token)
      end
    end
  end
end
