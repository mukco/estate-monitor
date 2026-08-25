# frozen_string_literal: true

# Time#iso8601. Rails happens to load this, but the collector is deliberately
# usable — and tested — with no Rails in the process, so it asks for its own.
require "time"

module Estate
  module Monitor
    # How long this app takes to answer, counted in the process that answers.
    #
    # Everything here is a counter since boot, never a rolling window. A window
    # would mean the aggregator sees only the slice that happens to be in it:
    # report "p95 over the last five minutes", scrape every ten, and half the
    # requests are never represented anywhere. Counters plus `since` let the
    # aggregator take the difference between two scrapes and lose nothing in
    # between — and when the process restarts, `since` moves and it knows to
    # start a new run rather than record a negative delta.
    #
    # Durations are histogram buckets rather than percentiles for the same class
    # of reason: percentiles cannot be added up. Averaging 288 daily p95 values
    # does not give you the day's p95, so an app that reports one has thrown the
    # information away before anybody could ask the question. Bucket counts are
    # additive, so any window can be merged and the percentile taken at the end.
    #
    # This says how long things took. It does not say whether that is bad —
    # thresholds belong to whoever watches the estate, the same bargain the
    # `sources` section makes.
    module LatencySource
      # Logarithmic, because the estate's own spread is four orders of
      # magnitude: a push request answers in 1 ms and a football one that waits
      # on the gateway takes 30 seconds. Linear buckets would put almost
      # everything in the first one and tell you nothing.
      #
      # The last boundary is deliberately the apps' rack-timeout budget. A
      # request at or beyond it is one the timeout is about to kill, so that
      # count is the interesting number rather than an arbitrary tail.
      BUCKETS = [ 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10_000, 30_000 ].freeze

      # Serialised per scrape, not held: the collector aggregates every route it
      # sees (bounded by the app's routing table, so a few dozen) and only the
      # worst offenders travel. Ranked by total time rather than by slowest
      # call, which is what surfaces "fast but constant" alongside "slow and
      # rare" — both are ways to spend a budget.
      TOP_ROUTES = 15

      # Infrastructure talking to the app, which is not what anybody means by
      # "how long do our requests take".
      #
      # The health endpoint is the biggest offender: kamal-proxy probes it on a
      # timer, it always answers in a millisecond or two, and on a quiet app it
      # is most of the traffic — measured at 8 of 19 requests on the hub. Left
      # in, the median stops describing the app and starts describing /up.
      #
      # The reporter's own endpoint goes too. Counting the scrape that reads the
      # counters means every aggregator visit inflates the thing it came to read.
      DEFAULT_IGNORE = [
        "Rails::HealthController",
        "Estate::Monitor::MetricsController"
      ].freeze

      BOOTED_AT = Time.now

      # Where a request's time went while it was not this app's fault.
      #
      # An app that calls the gateway spends most of a slow request waiting: the
      # gateway's own numbers put the mean completion at fourteen seconds. Left
      # undivided, the p90 of any app that talks to it stops being a statement
      # about the app and becomes "did an LLM call happen", which is already
      # visible from the route name and tells nobody whether the app regressed.
      #
      # Per thread because Puma gives a request a thread and this is read at the
      # end of one. Reset at the start rather than only after: a job on the same
      # thread also calls the gateway, and its waiting is not the next request's.
      THREAD_KEY = :estate_monitor_external_ms

      class << self
        # Apps can add their own — an internal callback endpoint, a webhook
        # receiver that is somebody else's traffic. Replaces rather than
        # appends, so a caller that wants the defaults keeps them explicitly.
        attr_writer :ignore

        def ignore
          @ignore ||= DEFAULT_IGNORE.dup
        end
      end

      class Collector
        def initialize
          @mutex = Mutex.new
          reset!
        end

        def reset!
          @mutex.synchronize do
            @total = 0
            @duration_ms = 0.0
            @db_ms = 0.0
            @view_ms = 0.0
            @queries = 0
            @exceptions = 0
            # One slot per boundary plus a final slot for everything above the
            # last one, so a 45-second request still lands somewhere.
            @histogram = Array.new(BUCKETS.length + 1, 0)
            # The same requests, timed without whatever they were waiting on.
            # Kept beside the first rather than replacing it: one answers "how
            # long did the family wait", the other "was that us".
            @own_histogram = Array.new(BUCKETS.length + 1, 0)
            @external_ms = 0.0
            @status = Hash.new(0)
            @routes = Hash.new do |h, k|
              h[k] = { count: 0, ms_total: 0.0, db_ms_total: 0.0, external_ms_total: 0.0, max_ms: 0.0, over_limit: 0 }
            end
          end
        end

        # Called once per request, off the notification. Kept to arithmetic on
        # purpose: it runs inside the request's own thread, so anything slow
        # here is added to the very number it is trying to measure.
        def record(route:, duration_ms:, db_ms: 0.0, view_ms: 0.0, queries: 0, status: nil,
                   exception: false, external_ms: 0.0)
          slot = bucket_for(duration_ms)
          # Never negative: a clock is not a ledger, and a rounding difference
          # between two monotonic reads should not invent a faster request.
          own_slot = bucket_for([ duration_ms - external_ms, 0.0 ].max)

          @mutex.synchronize do
            @total += 1
            @duration_ms += duration_ms
            @db_ms += db_ms
            @view_ms += view_ms
            @queries += queries
            @exceptions += 1 if exception
            @histogram[slot] += 1
            @own_histogram[own_slot] += 1
            @external_ms += external_ms
            @status[status_class(status)] += 1

            r = @routes[route]
            r[:count] += 1
            r[:ms_total] += duration_ms
            r[:db_ms_total] += db_ms
            r[:external_ms_total] += external_ms
            r[:max_ms] = duration_ms if duration_ms > r[:max_ms]
            r[:over_limit] += 1 if duration_ms >= BUCKETS.last
          end
        end

        def snapshot
          @mutex.synchronize do
            {
              since: BOOTED_AT.utc.iso8601,
              requests: {
                total: @total,
                duration_ms_total: @duration_ms.round,
                db_ms_total: @db_ms.round,
                view_ms_total: @view_ms.round,
                query_count_total: @queries,
                external_ms_total: @external_ms.round,
                exceptions: @exceptions,
                buckets: cumulative_buckets(@histogram),
                buckets_own: cumulative_buckets(@own_histogram),
                by_status: @status.sort.to_h
              },
              routes: top_routes
            }
          end
        end

        private

        # Cumulative ("how many were at or under this"), which is what makes a
        # percentile a single scan and a merge a plain addition. `+Inf` is the
        # total by definition, and is emitted so a reader never has to know that.
        def cumulative_buckets(histogram)
          running = 0
          out = {}
          BUCKETS.each_with_index do |boundary, i|
            running += histogram[i]
            out[boundary.to_s] = running
          end
          out["+Inf"] = running + histogram.last
          out
        end

        def top_routes
          @routes
            .sort_by { |_, v| -v[:ms_total] }
            .first(TOP_ROUTES)
            .map do |route, v|
              { route: route, count: v[:count],
                ms_total: v[:ms_total].round, db_ms_total: v[:db_ms_total].round,
                external_ms_total: v[:external_ms_total].round,
                max_ms: v[:max_ms].round, over_limit: v[:over_limit] }
            end
        end

        def bucket_for(ms)
          BUCKETS.each_with_index { |boundary, i| return i if ms <= boundary }
          BUCKETS.length
        end

        # Grouped rather than kept exactly: a 404 and a 422 are the same kind of
        # news at this distance, and keeping every code seen would let a scanner
        # walking the app inflate the payload.
        def status_class(status)
          return "error" if status.nil?

          "#{status.to_i / 100}xx"
        end
      end

      module_function

      # Wrap a call to somebody else's service. The time inside is still part of
      # the request — the family waited for it — but it is reported separately
      # so "the app got slower" and "the thing it waits on got slower" are two
      # different sentences.
      #
      #   Estate::Monitor.external { http.request(request) }
      #
      # Returns whatever the block returns, and counts the time even when the
      # block raises: a gateway call that times out is the most expensive
      # waiting there is, and losing it would flatter exactly the wrong request.
      def external
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
      ensure
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
        Thread.current[THREAD_KEY] = Thread.current[THREAD_KEY].to_f + elapsed
      end

      def take_external_ms
        ms = Thread.current[THREAD_KEY].to_f
        Thread.current[THREAD_KEY] = 0.0
        ms
      end

      def collector
        @collector ||= Collector.new
      end

      def snapshot
        collector.snapshot
      rescue StandardError => e
        { unavailable: "#{e.class}: #{e.message}" }
      end

      # Subscribed from the engine so it only happens inside a Rails app, and
      # only once. `monotonic_subscribe` because wall-clock timing goes wrong in
      # exactly the conditions worth measuring — an NTP step during a slow
      # request would otherwise report a negative duration.
      def subscribe!(notifications = ActiveSupport::Notifications)
        return if @subscribed

        # Zero the waiting clock as the request begins. Without this a job that
        # called the gateway on this thread would hand its fourteen seconds to
        # whichever request the thread picked up next, and that request would
        # report itself as almost entirely somebody else's fault.
        notifications.subscribe("start_processing.action_controller") { take_external_ms }

        @subscribed = notifications.monotonic_subscribe("process_action.action_controller") do |*args|
          event = ActiveSupport::Notifications::Event.new(*args)
          record_event(event)
        end
      end

      def record_event(event)
        payload = event.payload
        return if ignored?(payload[:controller])

        collector.record(
          route: route_for(payload),
          duration_ms: event.duration,
          db_ms: payload[:db_runtime].to_f,
          view_ms: payload[:view_runtime].to_f,
          # Rails 7.1+ reports this; older payloads simply do not carry it.
          queries: payload.dig(:db_runtime_queries).to_i,
          status: payload[:status],
          exception: payload[:exception].present?,
          external_ms: take_external_ms
        )
      rescue StandardError # rubocop:disable Lint/SuppressedException
        # A reporter must never be the reason a request fails. Losing one
        # sample is not worth raising inside somebody else's controller.
      end

      def ignored?(controller)
        controller.present? && ignore.include?(controller)
      end

      # controller#action, not the path. `/api/games/824962/factoids` and
      # `/api/games/401873291/factoids` are one route wearing two ids; keying on
      # the path both hides that and lets an unbounded set of ids into memory.
      #
      # The notification carries the controller's class name, so it is put back
      # into the form Rails itself uses everywhere else — `api/games#factoids`
      # rather than `Api::GamesController#factoids`. Same information, and it
      # reads like the routes file it came from.
      def route_for(payload)
        verb = payload[:method] || "?"
        action = payload[:action] || "unknown"
        "#{verb} #{controller_path(payload[:controller])}##{action}"
      end

      def controller_path(name)
        return "unknown" if name.nil? || name.to_s.empty?

        name.to_s
            .sub(/Controller\z/, "")
            .gsub("::", "/")
            .gsub(/([a-z\d])([A-Z])/, '\1_\2')
            .downcase
      end
    end
  end
end
