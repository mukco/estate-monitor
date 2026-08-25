# estate-monitor

One JSON reporter per Rails app covering everything the app itself knows:
runtime facts, Solid Queue state, and custom sources. Mount it, set a token,
and the estate dashboard can see your workers.

## Install

```ruby
gem "estate-monitor", github: "mukco/estate-monitor", tag: "v0.2.0"
```

```ruby
# config/routes.rb
mount Estate::Monitor::Engine => "/internal/metrics"
```

Configure (initializer or before mount):

```ruby
Estate::Monitor.configure do |config|
  config.token    = ENV["ESTATE_MONITOR_TOKEN"]
  config.app_name = "Baseball"
end
```

## Payload

`GET /internal/metrics` (Bearer token) →

```json
{
  "app": "Baseball",
  "version": 3,
  "generated_at": "…",
  "sections": {
    "runtime":     { "sha": "…", "booted_at": "…", "db_ping": { "status": "ok" } },
    "solid_queue": { "processes": …, "queues": …, "recurring": …, "failures": …, "totals": … },
    "latency":     { "since": "…", "requests": { … }, "routes": [ … ] }
  }
}
```

Every section is individually rescued; an app without Solid Queue reports
`{ "unavailable": reason }` for that section instead of failing the payload.

## Latency

Added in contract v3, on by default, no configuration. A subscriber on
`process_action.action_controller` keeps counters in the process that serves the
requests; the endpoint reports them.

```json
"latency": {
  "since": "2026-08-25T15:48:02Z",
  "requests": {
    "total": 18432, "duration_ms_total": 412300, "db_ms_total": 96100,
    "view_ms_total": 8800, "query_count_total": 140255, "exceptions": 3,
    "buckets":   { "5": 3021, "10": 8800, …, "30000": 18420, "+Inf": 18432 },
    "by_status": { "2xx": 18100, "4xx": 300, "5xx": 32 }
  },
  "routes": [
    { "route": "GET api/games#factoids", "count": 41, "ms_total": 902000,
      "db_ms_total": 1200, "max_ms": 30003, "over_limit": 6 }
  ]
}
```

Three things are worth knowing before reading it:

**Counters, not windows.** Everything is cumulative since `since`, which is the
process's boot time. An aggregator takes the difference between two scrapes, so
nothing is lost between them; when `since` changes the process restarted, and the
next reading starts a new run rather than recording a negative delta.

**Buckets, not percentiles.** Counts are cumulative — each is "how many were at
or under this boundary" — so any set of scrapes merges by addition and the
percentile is taken at the end. Percentiles cannot be averaged, so an app that
reported one would have thrown the answer away before anybody asked. The last
boundary is 30000 because that is the estate's rack-timeout budget: `over_limit`
counts requests at or beyond it, which are the ones the timeout kills.

**Routes are `controller#action`.** `/api/games/824962/factoids` and
`/api/games/401873291/factoids` are one route wearing two ids. Every route is
counted; the top 15 by total time are serialised — total rather than max, which
is what surfaces "fast but constant" next to "slow and rare".

**Infrastructure is not counted.** `Rails::HealthController` and this gem's own
metrics endpoint are ignored by default. kamal-proxy probes `/up` on a timer and
it always answers in a millisecond or two — on a quiet app that was 8 of 19
requests, enough that the median described `/up` rather than the app. Counting
the scrape that reads the counters has the same problem in reverse: every
aggregator visit would inflate what it came to read.

Add your own — an internal callback, a webhook receiver that is somebody else's
traffic — by naming controller classes:

```ruby
Estate::Monitor::LatencySource.ignore += %w[Api::WebhooksController]
```

This section says how long things took. It does not say whether that is bad;
thresholds belong to whoever watches the estate.

## Client

```ruby
Estate::Monitor::Client.fetch(url, token: token)
# => { ok: true, payload: {...} }  or  { ok: false, error: "…" }
```
