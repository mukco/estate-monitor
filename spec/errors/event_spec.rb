# frozen_string_literal: true

require "spec_helper"
require "estate/monitor/errors/event"

RSpec.describe Estate::Monitor::Errors::Event do
  def normalize(raw, opts = {})
    described_class.normalize(raw, default_source: "client", **opts)
  end

  it "keeps a well-formed event as sent" do
    event = normalize(
      "event_id" => "0F8FAD5B-D9CB-469F-A165-70867728950E", "level" => "warning", "source" => "tv",
      "message" => "stalled", "error_class" => "Watchdog", "stack" => "at x", "fingerprint" => "fp",
      "occurred_at" => "2026-10-09T13:02:14Z", "context" => { "kind" => "watchdog", "route" => "/" }
    )

    expect(event).to include(
      "event_id" => "0f8fad5b-d9cb-469f-a165-70867728950e", "level" => "warning", "source" => "tv",
      "message" => "stalled", "error_class" => "Watchdog", "stack" => "at x", "fingerprint" => "fp",
      "occurred_at" => "2026-10-09T13:02:14.000Z", "context" => { "kind" => "watchdog", "route" => "/" }
    )
  end

  it "drops an event with nothing to say" do
    expect(normalize("level" => "error")).to be_nil
    expect(normalize("message" => "   ")).to be_nil
    expect(normalize("not a hash")).to be_nil
  end

  it "accepts symbol keys" do
    expect(normalize(message: "hi")["message"]).to eq("hi")
  end

  describe "level" do
    it "treats an unknown level as an error rather than dropping it" do
      expect(normalize("message" => "x", "level" => "fatal")["level"]).to eq("error")
      expect(normalize("message" => "x")["level"]).to eq("error")
    end

    it "understands warn" do
      expect(normalize("message" => "x", "level" => "WARN")["level"]).to eq("warning")
    end
  end

  describe "source" do
    it "will not let a caller claim a source it is not allowed" do
      event = normalize({ "message" => "x", "source" => "server" }, sources: %w[client tv])
      expect(event["source"]).to eq("client")
    end
  end

  describe "event_id" do
    it "replaces anything that is not a UUID" do
      id = normalize("message" => "x", "event_id" => "1; drop table")["event_id"]
      expect(id).to match(described_class::UUID)
    end
  end

  describe "occurred_at" do
    let(:now) { Time.utc(2026, 10, 9, 12) }

    it "fills a missing or unreadable time with now" do
      expect(normalize({ "message" => "x" }, now: now)["occurred_at"]).to eq("2026-10-09T12:00:00.000Z")
      expect(normalize({ "message" => "x", "occurred_at" => "yesterday" }, now: now)["occurred_at"])
        .to eq("2026-10-09T12:00:00.000Z")
    end
  end

  describe "limits" do
    it "cuts each field to its contract size" do
      event = normalize(
        "message" => "m" * 5000, "error_class" => "C" * 500, "fingerprint" => "f" * 500,
        "stack" => "s" * 40_000
      )
      expect(event["message"].length).to eq(1000)
      expect(event["error_class"].length).to eq(200)
      expect(event["fingerprint"].length).to eq(200)
      expect(event["stack"].bytesize).to eq(16 * 1024)
    end

    it "never cuts a stack in the middle of a character" do
      stack = "é" * 10_000
      expect(normalize("message" => "x", "stack" => stack)["stack"]).to be_valid_encoding
    end

    it "keeps the context under 8 KB, dropping the later keys and saying so" do
      context = { "kind" => "boundary", "route" => "/x" }
      10.times { |i| context["blob#{i}"] = "z" * 1500 }
      out = normalize("message" => "x", "context" => context)["context"]

      expect(JSON.generate(out).bytesize).to be <= 8 * 1024
      expect(out).to include("kind" => "boundary", "route" => "/x", "_truncated" => true)
    end

    it "keeps the last twenty breadcrumbs" do
      crumbs = (1..30).map { |i| "step #{i}" }
      out = normalize("message" => "x", "context" => { "breadcrumbs" => crumbs })["context"]
      expect(out["breadcrumbs"]).to eq(crumbs.last(20))
    end

    it "turns live objects into short strings instead of serialising them" do
      object = Object.new
      out = normalize("message" => "x", "context" => { "thing" => object, "at" => Time.utc(2026) })["context"]
      expect(out["thing"]).to start_with("#<Object")
      expect(out["at"]).to eq("2026-01-01T00:00:00.000Z")
    end

    it "ignores a context that is not an object" do
      expect(normalize("message" => "x", "context" => "nope")["context"]).to eq({})
    end
  end
end
