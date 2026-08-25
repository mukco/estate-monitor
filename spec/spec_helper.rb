# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/object/blank"
require "estate/monitor/sources/latency"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
end
