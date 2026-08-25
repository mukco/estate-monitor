# frozen_string_literal: true

require "net/http"

module Estate
  module Monitor
    module Client
      TIMEOUT = 5

      module_function

      def fetch(url, token:, timeout: TIMEOUT)
        uri = URI(url)
        response = Net::HTTP.start(uri.host, uri.port,
                                   use_ssl: uri.scheme == "https",
                                   open_timeout: timeout, read_timeout: timeout) do |http|
          http.get(uri.request_uri, { "Authorization" => "Bearer #{token}",
                                      "Accept" => "application/json" })
        end
        return { ok: false, error: "HTTP #{response.code}" } unless response.is_a?(Net::HTTPSuccess)

        { ok: true, payload: JSON.parse(response.body, symbolize_names: true) }
      rescue StandardError => e
        { ok: false, error: "#{e.class}: #{e.message}" }
      end
    end
  end
end
