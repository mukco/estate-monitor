# frozen_string_literal: true

require_relative "lib/estate/monitor/version"

Gem::Specification.new do |spec|
  spec.name          = "estate-monitor"
  spec.version       = Estate::Monitor::VERSION
  spec.authors       = ["Devoun Edwards"]
  spec.summary       = "Per-app monitoring reporter for the estate: runtime, Solid Queue, and custom sources."
  spec.description   = "Mount a token-gated /internal/metrics endpoint reporting runtime facts, " \
                       "Solid Queue processes/queues/recurring/failures, and any custom " \
                       "sources the app registers. Includes a client for aggregators."
  spec.homepage      = "https://github.com/mukco/estate-monitor"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "app/**/*.rb", "config/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "railties", ">= 7.1"
  spec.metadata["rubygems_mfa_required"] = "true"
end
