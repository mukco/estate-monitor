# frozen_string_literal: true

require "rack/mock"
require "support/solid_queue"

# The error reporter, wired into the spec application the way an app wires it:
# the browser endpoint mounted, the metrics engine mounted, and one controller
# and one job that fail on purpose.
#
# Delivery is the real class with its HTTP replaced by a recorder, and with no
# background thread, so each spec decides when a flush happens and can see
# exactly what would have been sent.

class BoomController < ActionController::API
  def show
    raise ArgumentError, "boom #{params[:id]}"
  end

  def missing
    raise ActiveRecord::RecordNotFound, "gone"
  end

  def manual
    Estate::Monitor.report(:warning, "Lidarr refused import", context: { album: "Blue" })
    head :ok
  end
end

class BoomJob < ActiveJob::Base
  def perform
    raise IOError, "feed went away"
  end
end

Rails.application.routes.draw do
  mount Estate::Monitor::ErrorsApp => "/internal/errors"
  mount Estate::Monitor::Engine => "/internal/metrics"
  get "/boom/:id" => "boom#show"
  get "/missing" => "boom#missing"
  get "/manual" => "boom#manual"
end

class RecordingTransport
  attr_reader :calls
  attr_accessor :status

  def initialize(status: 202)
    @status = status
    @calls = []
  end

  def call(url, token, body)
    @calls << { url: url, token: token, body: JSON.parse(body) }
    status.is_a?(Exception) ? raise(status) : [status, nil]
  end

  def events
    calls.flat_map { |call| call[:body]["events"] }
  end
end

module ErrorReportingHelpers
  def transport
    @transport ||= RecordingTransport.new
  end

  def delivery
    Estate::Monitor::Errors.delivery
  end

  def sent_events
    delivery.flush(force: true)
    transport.events
  end

  def app_request(method, path, **opts)
    Rack::MockRequest.new(Rails.application).request(method, path, opts)
  end
end

RSpec.configure do |config|
  config.include ErrorReportingHelpers, :errors

  config.before(:each, :errors) do
    Estate::Monitor.token = "spec-token"
    Estate::Monitor.app_name = "Spec"
    Estate::Monitor.enabled = true
    Estate::Monitor.current_user_id = nil
    Estate::Monitor.release = "abc123"
    Estate::Monitor::Errors.delivery = Estate::Monitor::Errors::Delivery.new(transport: transport, threaded: false)
    Estate::Monitor::Errors.limiter = Estate::Monitor::Errors::RateLimiter.new
  end

  config.after(:each, :errors) do
    Estate::Monitor.token = nil
    Estate::Monitor.enabled = nil
    Estate::Monitor.release = nil
    Estate::Monitor.current_user_id = nil
  end
end
