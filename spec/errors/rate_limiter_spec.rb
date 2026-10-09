# frozen_string_literal: true

require "spec_helper"
require "estate/monitor/errors/rate_limiter"

RSpec.describe Estate::Monitor::Errors::RateLimiter do
  let(:now) { [0.0] }
  subject(:limiter) { described_class.new(limit: 30, period: 60, max_keys: 3, clock: -> { now[0] }) }

  it "lets thirty events a minute through from one address" do
    expect(limiter.allow("1.1.1.1", 25)).to eq(25)
    expect(limiter.allow("1.1.1.1", 10)).to eq(5)
    expect(limiter.allow("1.1.1.1", 1)).to eq(0)
  end

  it "counts each address on its own" do
    limiter.allow("1.1.1.1", 30)
    expect(limiter.allow("2.2.2.2", 10)).to eq(10)
  end

  it "starts again the next minute" do
    limiter.allow("1.1.1.1", 30)
    now[0] = 61.0
    expect(limiter.allow("1.1.1.1", 10)).to eq(10)
  end

  # The bound that matters: memory is how many addresses one minute saw,
  # never how many the process has seen since boot.
  it "forgets every address at the rollover" do
    3.times { |i| limiter.allow("10.0.0.#{i}") }
    now[0] = 120.0
    limiter.allow("10.0.0.9")
    expect(limiter.size).to eq(1)
  end

  it "refuses a new address once the table is full, rather than growing it" do
    3.times { |i| limiter.allow("10.0.0.#{i}") }
    expect(limiter.allow("10.0.0.99")).to eq(0)
    expect(limiter.allow("10.0.0.1")).to eq(1)
  end

  it "holds the limit under concurrent callers" do
    threads = Array.new(8) { Thread.new { 10.times.sum { limiter.allow("1.1.1.1") } } }
    expect(threads.sum(&:value)).to eq(30)
  end
end
