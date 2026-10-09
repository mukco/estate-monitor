# frozen_string_literal: true

require "spec_helper"
require "support/errors"

RSpec.describe Estate::Monitor::ErrorsApp, :errors do
  # Positional options: the bodies are string-keyed hashes, which Ruby would
  # otherwise take for keyword arguments.
  def post_errors(body, options = {})
    app_request("POST", "/internal/errors",
                input: body.is_a?(String) ? body : JSON.generate(body),
                "CONTENT_TYPE" => options.fetch(:content_type, "application/json"),
                "REMOTE_ADDR" => options.fetch(:ip, "203.0.113.7"), **options.fetch(:headers, {}))
  end

  let(:browser_event) do
    { "level" => "error", "source" => "client", "message" => "Cannot read properties of undefined",
      "error_class" => "TypeError", "stack" => "TypeError: …\n    at x (app.js:1:2)",
      "context" => { "kind" => "onerror", "route" => "/game/1", "build" => "b1" } }
  end

  it "accepts the contract's body and answers 202 {}" do
    response = post_errors("events" => [browser_event])

    expect(response.status).to eq(202)
    expect(response.body).to eq("{}")
    expect(sent_events.size).to eq(1)
  end

  it "stamps what the server knows" do
    post_errors("events" => [browser_event])
    event = sent_events.first

    expect(event).to include(
      "app" => "Spec", "release" => "abc123", "user_id" => nil, "level" => "error",
      "source" => "client", "message" => "Cannot read properties of undefined", "error_class" => "TypeError"
    )
    expect(event["ip_hash"]).to match(/\A\h{12}\z/)
    expect(event["received_at"]).to be_present
    expect(event["host"]).to eq(Socket.gethostname)
    expect(event["event_id"]).to match(Estate::Monitor::Errors::Event::UUID)
  end

  it "accepts a sendBeacon body, which arrives as text/plain" do
    response = post_errors(JSON.generate("events" => [browser_event]), content_type: "text/plain;charset=UTF-8")
    expect(response.status).to eq(202)
    expect(sent_events.size).to eq(1)
  end

  it "needs no session, token or CSRF token" do
    response = post_errors({ "events" => [browser_event] }, headers: { "HTTP_COOKIE" => "" })
    expect(response.status).to eq(202)
  end

  it "answers 400 only for a body that is not JSON" do
    expect(post_errors("{nope").status).to eq(400)
    expect(sent_events).to be_empty
  end

  it "answers 405 to anything but POST" do
    expect(app_request("GET", "/internal/errors").status).to eq(405)
  end

  it "drops an oversized body but still answers 202" do
    huge = { "events" => [browser_event.merge("stack" => "s" * 70_000)] }
    response = post_errors(huge)
    expect(response.status).to eq(202)
    expect(sent_events).to be_empty
  end

  it "takes at most ten events from one request" do
    post_errors("events" => Array.new(15) { browser_event })
    expect(sent_events.size).to eq(10)
  end

  it "will not let a browser claim to be the server" do
    post_errors("events" => [browser_event.merge("source" => "server"), browser_event.merge("source" => "tv")])
    expect(sent_events.map { |e| e["source"] }).to eq(%w[client tv])
  end

  it "accepts a bare event, and a bare array, from a hand-written fetch" do
    post_errors(browser_event)
    post_errors([browser_event])
    expect(sent_events.size).to eq(2)
  end

  it "keeps a client's event_id so a retried beacon is one event" do
    id = SecureRandom.uuid
    post_errors("events" => [browser_event.merge("event_id" => id)])
    expect(sent_events.first["event_id"]).to eq(id)
  end

  describe "rate limit" do
    it "lets thirty events a minute through from one address, and still answers 202" do
      statuses = 4.times.map { post_errors("events" => Array.new(10) { browser_event }).status }
      expect(statuses).to all(eq(202))
      expect(sent_events.size).to eq(30)
    end

    it "counts addresses separately" do
      3.times { post_errors({ "events" => Array.new(10) { browser_event } }, ip: "198.51.100.1") }
      post_errors({ "events" => [browser_event] }, ip: "198.51.100.2")
      expect(sent_events.size).to eq(31)
    end

    it "keys on Cloudflare's client address when it is there" do
      3.times do |i|
        post_errors({ "events" => Array.new(10) { browser_event } },
                    headers: { "HTTP_CF_CONNECTING_IP" => "192.0.2.#{i}" })
      end
      expect(sent_events.size).to eq(30)
      expect(sent_events.map { |e| e["ip_hash"] }.uniq.size).to eq(3)
    end
  end

  describe "user_id" do
    it "asks the app's lambda, with the request" do
      Estate::Monitor.current_user_id = ->(request) { request.get_header("HTTP_X_SPEC_USER")&.to_i }
      post_errors({ "events" => [browser_event] }, headers: { "HTTP_X_SPEC_USER" => "42" })
      expect(sent_events.first["user_id"]).to eq(42)
    end

    it "is nobody when the lambda raises" do
      Estate::Monitor.current_user_id = ->(_request) { raise "no session" }
      post_errors("events" => [browser_event])
      expect(sent_events.first["user_id"]).to be_nil
    end
  end

  describe "ip_hash" do
    it "is stable for one address in one day and never the address itself" do
      post_errors({ "events" => [browser_event, browser_event] }, ip: "203.0.113.9")
      hashes = sent_events.map { |e| e["ip_hash"] }
      expect(hashes.uniq.size).to eq(1)
      expect(JSON.generate(sent_events)).not_to include("203.0.113.9")
    end
  end

  it "accepts and discards when reporting is off" do
    Estate::Monitor.enabled = false
    expect(post_errors("events" => [browser_event]).status).to eq(202)
    expect(sent_events).to be_empty
  end

  it "accepts and discards when there is no token" do
    Estate::Monitor.token = nil
    expect(post_errors("events" => [browser_event]).status).to eq(202)
    expect(delivery.pending).to eq(0)
  end
end
