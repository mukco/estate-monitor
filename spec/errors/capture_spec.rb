# frozen_string_literal: true

require "spec_helper"
require "support/errors"

RSpec.describe "Server-side capture", :errors do
  describe "an unhandled request error" do
    it "is reported as a server error with the route, action and app frames" do
      app_request("GET", "/boom/7")
      event = sent_events.first

      expect(event).to include(
        "level" => "error", "source" => "server", "error_class" => "ArgumentError",
        "message" => "boom 7", "app" => "Spec", "release" => "abc123"
      )
      expect(event["context"]).to include(
        "kind" => "exception", "route" => "/boom/7", "method" => "GET", "action" => "boom#show",
        "handled" => false
      )
      expect(event["stack"].lines.size).to be <= 40
    end

    it "asks the app who was signed in" do
      Estate::Monitor.current_user_id = ->(request) { request.path == "/boom/8" ? 99 : nil }
      app_request("GET", "/boom/8")
      expect(sent_events.first["user_id"]).to eq(99)
    end

    it "skips the ignore list" do
      app_request("GET", "/missing")
      expect(sent_events).to be_empty
    end

    it "honours an app's own ignore list" do
      Estate::Monitor.ignored_exceptions = %w[ArgumentError]
      app_request("GET", "/boom/1")
      expect(sent_events).to be_empty
    ensure
      Estate::Monitor.ignored_exceptions = nil
    end
  end

  describe "a failed job" do
    it "is reported as a job error with the job's name" do
      expect { Rails.application.executor.wrap { BoomJob.perform_now } }.to raise_error(IOError)
      event = sent_events.first
      expect(event).to include("level" => "error", "source" => "job", "error_class" => "IOError")
      expect(event["context"]).to include("kind" => "job", "job" => "BoomJob", "queue" => "default")
    end
  end

  describe "severity" do
    it "maps Rails.error severities onto levels" do
      Rails.error.report(RuntimeError.new("w"), handled: true, severity: :warning)
      Rails.error.report(RuntimeError.new("i"), handled: true, severity: :info)
      Rails.error.report(RuntimeError.new("e"), handled: true, severity: :error)
      expect(sent_events.to_h { |e| [e["message"], e["level"]] }).to eq("w" => "warning", "i" => "info", "e" => "error")
    end

    it "gives a handled error Rails' default of warning" do
      Rails.error.handle { raise "swallowed" }
      expect(sent_events.first).to include("message" => "swallowed", "level" => "warning")
    end
  end

  it "reports one exception once, however many reporters saw it" do
    error = RuntimeError.new("twice")
    Rails.error.report(error)
    Rails.error.report(error)
    expect(sent_events.size).to eq(1)
  end

  it "puts the app's frames first" do
    error = RuntimeError.new("x")
    error.set_backtrace([
      "/usr/local/bundle/gems/activerecord/lib/x.rb:1:in `y'",
      "#{Rails.root}/app/models/feed.rb:12:in `fetch'"
    ])
    Rails.error.report(error)
    expect(sent_events.first["stack"].lines.first.strip).to eq("app/models/feed.rb:12:in `fetch'")
  end

  it "records the cause" do
    begin
      begin
        raise IOError, "socket closed"
      rescue IOError
        raise "import failed"
      end
    rescue RuntimeError => e
      Rails.error.report(e)
    end
    expect(sent_events.first["context"]["cause"]).to eq("IOError: socket closed")
  end

  it "reports nothing in the test environment unless turned on" do
    Estate::Monitor.enabled = nil
    Rails.error.report(RuntimeError.new("quiet"))
    expect(sent_events).to be_empty
  end

  describe "Estate::Monitor.report" do
    it "sends a deliberate warning with context" do
      id = Estate::Monitor.report(:warning, "Lidarr refused import", context: { album: "Blue" })

      event = sent_events.first
      expect(event["event_id"]).to eq(id)
      expect(event).to include("level" => "warning", "source" => "server", "message" => "Lidarr refused import")
      expect(event["context"]).to include("kind" => "manual", "album" => "Blue")
    end

    it "sends an exception with its class and stack" do
      error = begin
        raise KeyError, "no such feed"
      rescue KeyError => e
        e
      end
      Estate::Monitor.report(:error, error, context: { feed: 3 })

      expect(sent_events.first).to include("level" => "error", "error_class" => "KeyError", "message" => "no such feed")
      expect(sent_events.first["stack"]).to be_present
      expect(sent_events.first["context"]).to include("kind" => "exception", "feed" => 3)
    end

    it "picks up the request it was called in" do
      app_request("GET", "/manual")
      expect(sent_events.first["context"]).to include("route" => "/manual", "action" => "boom#manual", "album" => "Blue")
    end

    it "reports even an exception on the ignore list, because it was asked to" do
      Estate::Monitor.report(:info, ActiveRecord::RecordNotFound.new("on purpose"))
      expect(sent_events.size).to eq(1)
    end

    it "returns nil and sends nothing when reporting is off" do
      Estate::Monitor.token = nil
      expect(Estate::Monitor.report(:error, "x")).to be_nil
      expect(delivery.pending).to eq(0)
    end

    it "never raises" do
      allow(Estate::Monitor::Errors).to receive(:capture_message).and_raise("reporter bug")
      expect { Estate::Monitor.report(:error, "x") }.not_to raise_error
    end
  end

  describe "the metrics `errors` section" do
    def metrics
      response = app_request("GET", "/internal/metrics", "HTTP_AUTHORIZATION" => "Bearer spec-token")
      JSON.parse(response.body)
    end

    it "exposes undelivered events for the scrape" do
      transport.status = 503
      id = Estate::Monitor.report(:error, "estate unreachable")
      delivery.flush(force: true)

      body = metrics
      expect(body["version"]).to eq(5)
      section = body["sections"]["errors"]
      expect(section).to include("pending" => 1, "consecutive_failures" => 1, "last_error" => "HTTP 503")
      expect(section["events"].map { |e| e["event_id"] }).to eq([id])
      expect(section["events"].first).to include("app" => "Spec", "release" => "abc123")
    end

    it "is empty once delivered" do
      Estate::Monitor.report(:error, "fine")
      delivery.flush(force: true)
      expect(metrics["sections"]["errors"]).to include("pending" => 0, "delivered" => 1, "events" => [])
    end
  end
end
