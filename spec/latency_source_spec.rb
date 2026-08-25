# frozen_string_literal: true

require "spec_helper"

RSpec.describe Estate::Monitor::LatencySource do
  subject(:collector) { described_class::Collector.new }

  def record(ms, route: "GET things#index", **rest)
    collector.record(route: route, duration_ms: ms, **rest)
  end

  describe "bucket boundaries" do
    it "puts a duration in the first bucket at or under its boundary" do
      record(5)
      expect(collector.snapshot[:requests][:buckets]["5"]).to eq(1)
    end

    it "treats the boundary as inclusive, so 10ms is not in the 5ms bucket" do
      record(10)
      buckets = collector.snapshot[:requests][:buckets]
      expect(buckets["5"]).to eq(0)
      expect(buckets["10"]).to eq(1)
    end

    it "counts anything past the last boundary without dropping it" do
      record(45_000)
      buckets = collector.snapshot[:requests][:buckets]
      expect(buckets["30000"]).to eq(0)
      expect(buckets["+Inf"]).to eq(1)
    end

    # The reason the last boundary is the apps' rack-timeout budget: a request
    # at or beyond it is one the timeout is about to kill.
    it "separates a request killed at the timeout from one just under it" do
      record(29_999)
      record(30_001)
      buckets = collector.snapshot[:requests][:buckets]
      expect(buckets["30000"]).to eq(1)
      expect(buckets["+Inf"]).to eq(2)
    end
  end

  describe "cumulative counts" do
    it "each bucket includes everything below it" do
      [ 3, 8, 40, 900 ].each { |ms| record(ms) }
      buckets = collector.snapshot[:requests][:buckets]

      expect(buckets["5"]).to eq(1)
      expect(buckets["10"]).to eq(2)
      expect(buckets["50"]).to eq(3)
      expect(buckets["1000"]).to eq(4)
      expect(buckets["+Inf"]).to eq(4)
    end

    it "never decreases as the boundary grows" do
      [ 1, 7, 60, 300, 4000, 26_000, 31_000 ].each { |ms| record(ms) }
      counts = collector.snapshot[:requests][:buckets].values
      expect(counts).to eq(counts.sort)
    end

    it "ends at the total number of requests" do
      [ 2, 2000, 90_000 ].each { |ms| record(ms) }
      snapshot = collector.snapshot
      expect(snapshot[:requests][:buckets]["+Inf"]).to eq(snapshot[:requests][:total])
    end
  end

  describe "counters" do
    it "accumulates rather than windowing, so nothing is lost between scrapes" do
      record(10)
      first = collector.snapshot[:requests][:total]
      record(10)
      second = collector.snapshot[:requests][:total]

      expect(first).to eq(1)
      expect(second).to eq(2)
    end

    it "sums duration, db and view time" do
      collector.record(route: "GET a#b", duration_ms: 100, db_ms: 40, view_ms: 5, queries: 7)
      collector.record(route: "GET a#b", duration_ms: 50,  db_ms: 10, view_ms: 1, queries: 3)

      requests = collector.snapshot[:requests]
      expect(requests[:duration_ms_total]).to eq(150)
      expect(requests[:db_ms_total]).to eq(50)
      expect(requests[:view_ms_total]).to eq(6)
      expect(requests[:query_count_total]).to eq(10)
    end

    it "groups statuses by class" do
      record(1, status: 200)
      record(1, status: 201)
      record(1, status: 404)
      record(1, status: 500)

      expect(collector.snapshot[:requests][:by_status]).to eq("2xx" => 2, "4xx" => 1, "5xx" => 1)
    end

    it "records a request that raised as an error rather than guessing a status" do
      record(1, status: nil, exception: true)
      snapshot = collector.snapshot
      expect(snapshot[:requests][:exceptions]).to eq(1)
      expect(snapshot[:requests][:by_status]).to eq("error" => 1)
    end

    it "reports since, so an aggregator can tell a restart from a negative delta" do
      expect(collector.snapshot[:since]).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end
  end

  describe "routes" do
    it "ranks by total time, not by slowest single call" do
      # Slow and rare against fast and constant: both spend a budget, and the
      # second is the one a max-based ranking would hide.
      collector.record(route: "GET rare#slow",   duration_ms: 2_000)
      40.times { collector.record(route: "GET common#fast", duration_ms: 100) }

      routes = collector.snapshot[:routes]
      expect(routes.first[:route]).to eq("GET common#fast")
      expect(routes.first[:ms_total]).to eq(4_000)
    end

    it "keeps only the top N" do
      (described_class::TOP_ROUTES + 8).times { |i| collector.record(route: "GET r#{i}#show", duration_ms: i + 1) }
      expect(collector.snapshot[:routes].length).to eq(described_class::TOP_ROUTES)
    end

    it "tracks the worst single call and how many hit the limit" do
      collector.record(route: "GET games#factoids", duration_ms: 12_000)
      collector.record(route: "GET games#factoids", duration_ms: 30_003)
      collector.record(route: "GET games#factoids", duration_ms: 30_000)

      route = collector.snapshot[:routes].first
      expect(route[:count]).to eq(3)
      expect(route[:max_ms]).to eq(30_003)
      expect(route[:over_limit]).to eq(2)
    end
  end

  describe "naming a route" do
    # /api/games/824962/factoids and /api/games/401873291/factoids are one
    # route wearing two ids. Keying on the path hides that and lets an
    # unbounded set of ids into memory.
    it "collapses ids by keying on controller#action" do
      expect(described_class.route_for({ method: "GET", controller: "Api::GamesController", action: "factoids" }))
        .to eq("GET api/games#factoids")
    end

    # The notification carries a class name; Rails writes the same thing as a
    # path everywhere else, and that is what a routes file looks like.
    it "reads the class name back as the path Rails itself uses" do
      expect(described_class.controller_path("Api::NotificationsController")).to eq("api/notifications")
      expect(described_class.controller_path("Dinner::RecipeIngredientsController")).to eq("dinner/recipe_ingredients")
    end

    it "does not raise on a payload missing its controller" do
      expect(described_class.route_for({})).to eq("? unknown#unknown")
    end
  end

  describe "what it refuses to count" do
    around do |example|
      previous = described_class.ignore
      example.run
      described_class.ignore = previous
    end

    # kamal-proxy probing /up on a timer is not what anybody means by "how long
    # do our requests take". It always answers in a millisecond or two, and on a
    # quiet app it is most of the traffic — 8 of 19 requests when this was
    # measured on the hub. Left in, the median describes /up, not the app.
    it "ignores the health endpoint the proxy polls" do
      event = instance_double(ActiveSupport::Notifications::Event,
                              payload: { controller: "Rails::HealthController", action: "show", method: "GET", status: 200 },
                              duration: 2.0)
      expect { described_class.record_event(event) }
        .not_to change { described_class.collector.snapshot[:requests][:total] }
    end

    it "ignores its own endpoint, so reading the counters does not inflate them" do
      event = instance_double(ActiveSupport::Notifications::Event,
                              payload: { controller: "Estate::Monitor::MetricsController", action: "show", method: "GET", status: 200 },
                              duration: 3.0)
      expect { described_class.record_event(event) }
        .not_to change { described_class.collector.snapshot[:requests][:total] }
    end

    it "counts an ordinary controller" do
      event = instance_double(ActiveSupport::Notifications::Event,
                              payload: { controller: "Api::WordController", action: "standings", method: "GET", status: 200 },
                              duration: 12.0)
      expect { described_class.record_event(event) }
        .to change { described_class.collector.snapshot[:requests][:total] }.by(1)
    end

    it "lets an app name its own" do
      described_class.ignore = [ "Api::WebhooksController" ]
      event = instance_double(ActiveSupport::Notifications::Event,
                              payload: { controller: "Api::WebhooksController", action: "create", method: "POST", status: 204 },
                              duration: 9.0)
      expect { described_class.record_event(event) }
        .not_to change { described_class.collector.snapshot[:requests][:total] }
    end
  end

  describe "not being the reason a request fails" do
    it "swallows a collector failure rather than raising into the controller" do
      allow(described_class).to receive(:collector).and_raise(RuntimeError, "boom")
      event = instance_double(ActiveSupport::Notifications::Event, payload: {}, duration: 1.0)

      expect { described_class.record_event(event) }.not_to raise_error
    end

    it "reports itself unavailable rather than breaking the whole snapshot" do
      allow(described_class).to receive(:collector).and_raise(RuntimeError, "boom")
      expect(described_class.snapshot).to eq(unavailable: "RuntimeError: boom")
    end
  end

  describe "thread safety" do
    it "counts every request when several threads record at once" do
      threads = 8.times.map do
        Thread.new { 100.times { collector.record(route: "GET a#b", duration_ms: 5) } }
      end
      threads.each(&:join)

      expect(collector.snapshot[:requests][:total]).to eq(800)
    end
  end
end
