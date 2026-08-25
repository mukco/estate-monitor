# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/integer/time"
require "active_support/core_ext/module/attribute_accessors"
require_relative "monitor/version"
require_relative "monitor/sources/runtime"
require_relative "monitor/sources/solid_queue"

module Estate
  module Monitor
    mattr_accessor :token, :app_name

    CONTRACT_VERSION = 2

    def self.sources
      @sources ||= [
        [:runtime, -> { RuntimeSource.snapshot }],
        [:solid_queue, -> { SolidQueueSource.snapshot }]
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
