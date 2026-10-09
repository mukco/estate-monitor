# frozen_string_literal: true

require "spec_helper"
require "support/errors"

# The 2026-10-09 white screen, replayed: a phone with an old index.html asks
# for the JS and CSS that page was built with, after a deploy deleted them.
RSpec.describe Estate::Monitor::StaleAssets, :errors do
  IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 " \
           "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

  let(:now) { [100.0] }
  let(:coalescer) { described_class::Coalescer.new(threaded: false, clock: -> { now[0] }) }

  around do |example|
    original = described_class.coalescer
    described_class.coalescer = coalescer
    example.run
  ensure
    described_class.coalescer = original
    Estate::Monitor.report_stale_assets = true
    Estate::Monitor.stale_asset_paths = nil
  end

  def asset(path, ua: IPHONE, ip: "203.0.113.7", method: "GET", headers: {})
    app_request(method, path, "HTTP_USER_AGENT" => ua, "REMOTE_ADDR" => ip,
                              "HTTP_REFERER" => "https://football.edwardsfamily.app/",
                              "HTTP_ACCEPT" => "*/*", **headers)
  end

  # Closes every open window, then flushes delivery.
  def stale_events
    coalescer.flush(force: true)
    sent_events
  end

  it "reports a browser's 404 for a built asset as one client error" do
    response = asset("/assets/index-wQ90q-cT.js")
    expect(response.status).to eq(404)

    event = stale_events.sole
    expect(event).to include(
      "level" => "error", "source" => "client", "fingerprint" => "stale-asset",
      "message" => "A phone asked for /assets/index-wQ90q-cT.js, which this deploy no longer has",
      "app" => "Spec", "release" => "abc123", "user_id" => nil
    )
    expect(event["context"]).to include(
      "kind" => "stale_asset", "path" => "/assets/index-wQ90q-cT.js", "paths" => ["/assets/index-wQ90q-cT.js"],
      "ua" => IPHONE, "referer" => "https://football.edwardsfamily.app/", "accept" => "*/*", "release" => "abc123"
    )
    expect(event["context"]["ip_hash"]).to match(/\A\h{12}\z/).and eq(event["ip_hash"])
    expect(JSON.generate(event)).not_to include("203.0.113.7")
  end

  it "makes one event of one page load's files, listing them all" do
    asset("/assets/index-wQ90q-cT.js")
    asset("/assets/index-BXpUa--r.css")
    asset("/assets/vendor-x1.mjs")
    asset("/assets/index-BXpUa--r.css")

    event = stale_events.sole
    expect(event["context"]["paths"]).to eq(%w[/assets/index-wQ90q-cT.js /assets/index-BXpUa--r.css /assets/vendor-x1.mjs])
    expect(event["message"]).to include("/assets/index-wQ90q-cT.js")
  end

  it "holds the window open five seconds, then reports without being asked" do
    asset("/assets/index-wQ90q-cT.js")
    now[0] += 4
    asset("/assets/index-BXpUa--r.css")
    expect(coalescer.flush).to eq(0)

    now[0] += 1
    expect(coalescer.flush).to eq(1)
    expect(sent_events.sole["context"]["paths"].size).to eq(2)
  end

  it "reports the next page load from the same phone as another event in the same group" do
    asset("/assets/index-wQ90q-cT.js")
    now[0] += 6
    coalescer.flush
    asset("/assets/index-wQ90q-cT.js")

    expect(stale_events.map { |e| e["fingerprint"] }).to eq(%w[stale-asset stale-asset])
  end

  it "keeps phones apart" do
    asset("/assets/index-wQ90q-cT.js", ip: "198.51.100.1")
    asset("/assets/index-wQ90q-cT.js", ip: "198.51.100.2")
    expect(stale_events.size).to eq(2)
  end

  it "lists at most twenty paths" do
    25.times { |i| asset("/assets/chunk-#{i}.js") }
    expect(stale_events.sole["context"]["paths"].size).to eq(20)
  end

  it "says nothing about a file that is there" do
    response = asset("/assets/index-live.js")
    expect(response.status).to eq(200)
    expect(stale_events).to be_empty
  end

  it "says nothing about a 404 that is not an asset" do
    asset("/missing.js")
    asset("/nope")
    expect(stale_events).to be_empty
  end

  it "takes only scripts and stylesheets" do
    %w[/assets/logo.png /assets/index.js.map /assets/font.woff2 /assets/].each { |path| asset(path) }
    expect(stale_events).to be_empty
    asset("/assets/INDEX.CSS")
    expect(stale_events.size).to eq(1)
  end

  it "takes only the configured prefixes" do
    asset("/wp-content/x.js")
    asset("/packs/app.js")
    expect(stale_events).to be_empty

    Estate::Monitor.stale_asset_paths = ["/assets/", "/packs/"]
    asset("/packs/app.js")
    expect(stale_events.sole["context"]["path"]).to eq("/packs/app.js")
  end

  it "ignores anything that does not look like a person's browser" do
    [
      "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
      "Mozilla/5.0 (compatible; AhrefsBot/7.0)",
      "Mozilla/5.0 SomeCrawler", "Mozilla/5.0 spider",
      "curl/8.5.0", "python-requests/2.32", "Go-http-client/2.0", ""
    ].each_with_index { |ua, i| asset("/assets/index-wQ90q-cT.js", ua: ua, ip: "192.0.2.#{i}") }
    expect(stale_events).to be_empty
  end

  it "ignores anything but GET and HEAD" do
    asset("/assets/index-wQ90q-cT.js", method: "POST")
    expect(stale_events).to be_empty
    asset("/assets/index-wQ90q-cT.js", method: "HEAD")
    expect(stale_events.size).to eq(1)
  end

  it "asks the app who was signed in" do
    Estate::Monitor.current_user_id = ->(request) { request.get_header("HTTP_X_SPEC_USER")&.to_i }
    asset("/assets/index-wQ90q-cT.js", headers: { "HTTP_X_SPEC_USER" => "7" })
    expect(stale_events.sole["user_id"]).to eq(7)
  end

  it "keys on Cloudflare's client address" do
    asset("/assets/a.js", headers: { "HTTP_CF_CONNECTING_IP" => "192.0.2.1" })
    asset("/assets/b.js", headers: { "HTTP_CF_CONNECTING_IP" => "192.0.2.2" })
    expect(stale_events.size).to eq(2)
  end

  it "shares the browser endpoint's rate limit" do
    Estate::Monitor::Errors.limiter.allow("203.0.113.7", 30)
    asset("/assets/index-wQ90q-cT.js")
    expect(stale_events).to be_empty
  end

  it "is off when report_stale_assets is false" do
    Estate::Monitor.report_stale_assets = false
    asset("/assets/index-wQ90q-cT.js")
    expect(coalescer.pending).to eq(0)
  end

  it "is off when reporting is" do
    Estate::Monitor.token = nil
    asset("/assets/index-wQ90q-cT.js")
    expect(coalescer.pending).to eq(0)
  end

  it "never turns a 404 into anything else" do
    allow(coalescer).to receive(:add).and_raise("reporter bug")
    expect(asset("/assets/index-wQ90q-cT.js").status).to eq(404)
  end

  it "reports and re-raises a RoutingError that nothing turned into a 404" do
    raising = ->(env) { raise ActionController::RoutingError, "No route matches [GET] \"#{env['PATH_INFO']}\"" }
    middleware = described_class.new(raising)
    env = Rack::MockRequest.env_for("/assets/index-wQ90q-cT.js", "HTTP_USER_AGENT" => IPHONE, "REMOTE_ADDR" => "203.0.113.7")

    expect { middleware.call(env) }.to raise_error(ActionController::RoutingError)
    expect(stale_events.size).to eq(1)
  end

  it "is in the stack just below ActionDispatch::Static" do
    stack = Rails.application.middleware.map(&:klass)
    expect(stack.index(described_class)).to eq(stack.index(ActionDispatch::Static) + 1)
  end

  it "closes windows on its own thread" do
    threaded = described_class::Coalescer.new(window: 0.05, tick: 0.05)
    described_class.coalescer = threaded
    asset("/assets/index-wQ90q-cT.js")

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.02 while threaded.pending.positive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    expect(sent_events.size).to eq(1)
  end
end
