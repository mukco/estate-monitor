# frozen_string_literal: true

require "spec_helper"
require "securerandom"
require "socket"
require "estate/monitor/errors/delivery"

RSpec.describe Estate::Monitor::Errors::Delivery do
  let(:now) { [100.0] }
  let(:responses) { [] }
  let(:posts) { [] }
  let(:transport) do
    lambda do |url, token, body|
      posts << { url: url, token: token, body: JSON.parse(body) }
      status = responses.empty? ? 202 : responses.shift
      status.is_a?(Exception) ? raise(status) : [status, (status.nil? ? "Errno::ECONNREFUSED: refused" : nil)]
    end
  end
  let(:token) { ["spec-token"] }

  subject(:delivery) do
    described_class.new(url: -> { "https://estate.test" }, token: -> { token[0] }, app: -> { "Spec" },
                        transport: transport, threaded: false, clock: -> { now[0] })
  end

  def event(message = "boom", **extra)
    { "event_id" => SecureRandom.uuid, "level" => "error", "message" => message }.merge(extra)
  end

  def ids(list) = list.map { |e| e["event_id"] }

  describe "#flush" do
    it "posts the app and its events, then forgets them" do
      pushed = [event, event]
      pushed.each { |e| delivery.push(e) }

      expect(delivery.flush).to eq(2)
      expect(posts.size).to eq(1)
      expect(posts[0]).to include(url: "https://estate.test", token: "spec-token")
      expect(posts[0][:body]).to eq("app" => "Spec", "events" => pushed)
      expect(delivery.pending).to eq(0)
      expect(delivery.snapshot[:delivered]).to eq(2)
    end

    it "sends at most fifty events a request" do
      120.times { delivery.push(event) }
      delivery.flush
      expect(posts.map { |p| p[:body]["events"].size }).to eq([50, 50, 20])
    end

    it "keeps a request under the estate's 512 KB" do
      12.times { delivery.push(event("x" * 60_000)) }
      delivery.flush
      expect(posts.map { |p| JSON.generate(p[:body]).bytesize }).to all(be < 512 * 1024)
      expect(posts.sum { |p| p[:body]["events"].size }).to eq(12)
    end

    it "keeps the events when the estate cannot be reached, and backs off" do
      responses.push(nil)
      delivery.push(event)

      expect(delivery.flush).to eq(0)
      expect(delivery.pending).to eq(1)
      expect(delivery.snapshot[:last_error]).to include("ECONNREFUSED")

      # Backing off: not retried until the delay has passed.
      expect(delivery.flush).to eq(0)
      expect(posts.size).to eq(1)

      now[0] += 3
      expect(delivery.flush).to eq(1)
      expect(delivery.snapshot).to include(pending: 0, consecutive_failures: 0)
    end

    it "doubles the wait after each failure, to five minutes at most" do
      delivery.push(event)
      responses.push(503, 503, 503)
      waits = 3.times.map do
        delivery.flush(force: true)
        delivery.instance_variable_get(:@next_attempt) - now[0]
      end
      expect(waits).to eq([2, 4, 8])

      delivery.instance_variable_set(:@failures, 20)
      responses.push(503)
      delivery.flush(force: true)
      expect(delivery.instance_variable_get(:@next_attempt) - now[0]).to eq(300)
    end

    it "keeps the events on a bad token, which a corrected token can still send" do
      responses.push(401)
      delivery.push(event)
      delivery.flush
      expect(delivery.pending).to eq(1)
    end

    # 429: the estate already counted these against the app's budget and
    # dropped them. Sending them again only spends more of it.
    it "lets go of a batch the estate refused for volume or size" do
      responses.push(429)
      delivery.push(event)
      delivery.flush
      expect(delivery.pending).to eq(0)
      expect(delivery.snapshot[:rejected]).to eq(1)
    end

    it "does nothing without a token" do
      token[0] = nil
      delivery.push(event)
      expect(delivery.flush).to eq(0)
      expect(posts).to be_empty
    end

    it "never raises, even when the transport does" do
      responses.push(RuntimeError.new("kaboom"))
      delivery.push(event)
      expect { delivery.flush }.not_to raise_error
    end
  end

  describe "the buffer" do
    it "holds five hundred and then drops the oldest" do
      first = event("first")
      delivery.push(first)
      500.times { delivery.push(event) }

      snapshot = delivery.snapshot
      expect(snapshot[:pending]).to eq(500)
      expect(snapshot[:dropped]).to eq(1)
      expect(ids(snapshot[:events])).not_to include(first["event_id"])
    end

    it "is safe to fill from many threads at once" do
      threads = Array.new(10) { Thread.new { 40.times { delivery.push(event) } } }
      threads.each(&:join)
      expect(delivery.pending).to eq(400)
    end

    # Puma's workers and Solid Queue's supervisor are forks. The parent's
    # buffer is the parent's to send; a child that also sent it would double
    # every event that happened before the fork.
    it "starts empty in a forked child" do
      delivery.push(event)
      allow(Process).to receive(:pid).and_return(Process.pid + 1)
      expect(delivery.snapshot[:pending]).to eq(0)
    end
  end

  describe "#snapshot (the metrics `errors` section)" do
    it "shows what has not been delivered" do
      responses.push(503)
      pushed = [event, event]
      pushed.each { |e| delivery.push(e) }
      delivery.flush

      snapshot = delivery.snapshot
      expect(ids(snapshot[:events])).to eq(ids(pushed))
      expect(snapshot).to include(pending: 2, consecutive_failures: 1, last_error: "HTTP 503")
    end

    # Once is enough when the estate stored it; twice covers a scrape whose
    # response was lost. Never more, or a dead push path serves the same
    # events to every scrape for ever.
    it "shows each event to two scrapes and then forgets it" do
      delivery.push(event)
      expect(delivery.snapshot[:events].size).to eq(1)
      expect(delivery.snapshot[:events].size).to eq(1)
      expect(delivery.snapshot[:events].size).to eq(0)
    end

    it "keeps a scrape to a hundred events, oldest first" do
      pushed = Array.new(150) { event }
      pushed.each { |e| delivery.push(e) }
      shown = delivery.snapshot[:events]
      expect(ids(shown)).to eq(ids(pushed.first(100)))
    end

    it "keeps a scrape under 256 KB" do
      20.times { delivery.push(event("y" * 30_000)) }
      expect(JSON.generate(delivery.snapshot[:events]).bytesize).to be <= 256 * 1024
    end
  end

  describe "the real transport" do
    it "posts JSON to /api/ingest/events with the bearer token" do
      server = TCPServer.new("127.0.0.1", 0)
      received = Thread.new do
        client = server.accept
        head = +""
        head << client.gets until head.end_with?("\r\n\r\n")
        length = head[/content-length: (\d+)/i, 1].to_i
        body = client.read(length)
        client.write("HTTP/1.1 202 Accepted\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        client.close
        [head, body]
      end

      real = described_class.new(url: -> { "http://127.0.0.1:#{server.addr[1]}" }, token: -> { "tok" },
                                 app: -> { "Spec" }, threaded: false)
      real.push(event("over the wire"))

      expect(real.flush).to eq(1)
      head, body = received.value
      expect(head).to start_with("POST /api/ingest/events HTTP/1.1")
      expect(head).to include("Authorization: Bearer tok")
      expect(JSON.parse(body)["events"].first["message"]).to eq("over the wire")
    ensure
      server&.close
    end
  end

  describe "the background thread" do
    subject(:delivery) do
      described_class.new(url: -> { "https://estate.test" }, token: -> { "t" }, app: -> { "Spec" },
                          transport: transport, interval: 0.05)
    end

    after { delivery.stop }

    it "sends without being asked" do
      delivery.push(event)
      deadline = Time.now + 2
      sleep 0.01 until posts.any? || Time.now > deadline
      expect(posts.size).to eq(1)
    end

    it "wakes at once when twenty are waiting" do
      slow = described_class.new(url: -> { "https://estate.test" }, token: -> { "t" }, app: -> { "Spec" },
                                 transport: transport, interval: 60)
      20.times { slow.push(event) }
      deadline = Time.now + 2
      sleep 0.01 until posts.any? || Time.now > deadline
      expect(posts.sum { |p| p[:body]["events"].size }).to eq(20)
    ensure
      slow.stop
    end

    it "waits out the backoff with a full buffer instead of spinning" do
      responses.push(*Array.new(50, 503))
      slow = described_class.new(url: -> { "https://estate.test" }, token: -> { "t" }, app: -> { "Spec" },
                                 transport: transport, interval: 60)
      25.times { slow.push(event) }
      sleep 0.3
      expect(posts.size).to eq(1)
    ensure
      slow.stop
    end
  end
end
