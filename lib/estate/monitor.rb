# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/integer/time"
require "active_support/core_ext/module/attribute_accessors"
require_relative "monitor/version"
require_relative "monitor/sources/runtime"
require_relative "monitor/sources/solid_queue"
require_relative "monitor/sources/latency"

module Estate
  module Monitor
    mattr_accessor :token, :app_name

    # 3 adds the `latency` section. Additive: a v2 reader that has never heard
    # of it keeps working on the sections it does know.
    CONTRACT_VERSION = 3

    def self.sources
      @sources ||= [
        [:runtime, -> { RuntimeSource.snapshot }],
        [:solid_queue, -> { SolidQueueSource.snapshot }],
        [:latency, -> { LatencySource.snapshot }]
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
