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
  "version": 4,
  "generated_at": "…",
  "sections": {
    "runtime":     { "sha": "…", "booted_at": "…", "db_ping": { "status": "ok" } },
    "solid_queue": { "processes": …, "running": …, "recent": …, "queues": …, "recurring": …,
                     "failures": …, "failure_counts": …, "totals": …, "timing": …, "retention": … },
    "latency":     { "since": "…", "requests": { … }, "routes": [ … ] }
  }
}
```

Every section is individually rescued; an app without Solid Queue reports
`{ "unavailable": reason }` for that section instead of failing the payload.

## Solid Queue

```json
"solid_queue": {
  "processes": { "count": 4, "stale_count": 0, "rows": [ … ] },
  "running":   { "count": 1, "rows": [ { "class_name": "WarmOttoneuCacheJob",
                                         "queue": "cache_warming", "claimed_at": "…" } ] },
  "recent":    { "count": 25, "rows": [ { "class_name": "RefreshLiveJob", "queue": "background",
                                          "finished_at": "…", "turnaround_ms": 1840 } ] },
  "queues":    { "cache_warming": { "ready": 0, "claimed": 2, "failed": 13 } },
  "recurring": [ { "key": "warm_cache", "schedule": "every 30 minutes",
                   "last_enqueued_at": "…", "due_at": "…" } ],
  "failures":  [ { "class_name": "WarmAnswersJob", "queue": "cache_warming", "failed_at": "…",
                   "error_class": "SolidQueue::Processes::ProcessPrunedError",
                   "error_message": "Process was found dead and pruned (last heartbeat at: …)",
                   "pruned": true } ],
  "failure_counts": { "total": 16, "last_24h": 1, "last_7d": 6, "pruned": 15 },
  "totals":    { "ready": 0, "claimed": 1, "failed": 16, "finished_last_24h": 812 },
  "timing":    { "finished_last_hour": 41, "turnaround_ms": { "p50": 120, "p90": 2100, "max": 9400 },
                 "slowest": [ { "class_name": "WarmSimulationCacheJob", "count": 2, "max_ms": 9400 } ] },
  "retention": { "finished_jobs_after_seconds": 86400 }
}
```

Four things are worth knowing before reading it:

**An instant is not a history.** `ready`, `claimed` and `failed` describe the
moment of the scrape. A reader polls once a minute and most jobs take seconds,
so `running` is usually empty even on an app doing hundreds of jobs an hour —
a queue that has run four hundred jobs today looks exactly like one that has
run none. `recent` and `timing` are the log of the work, and are what "is the
nightly warm still happening" actually asks for.

**The lifetime failure count is an archive.** Nothing deletes a failed
execution, so `totals[:failed]` counts every failure since the table was
created and only ever grows. `failure_counts` is the same rows over windows.

**Most failures are not the job's fault.** Solid Queue files a claim whose
worker stopped answering as a failure, so every deploy through a nightly warm
produces one. Those rows carry `pruned: true`, and `failure_counts[:pruned]`
counts them, so a real error is not buried in container churn.

**A missing last run may be a swept one.** `recurring[].last_enqueued_at` comes
from the recurring executions, and one is deleted with the job it enqueued —
so a task that fired outside `retention` reports null, meaning "no run on
record" rather than "never ran". `due_at` is when the schedule last came due;
comparing the two is the reader's job, not this gem's.

`retention` is the configured window and not a measurement.
`clear_finished_jobs_after` defaults to a day whether or not anything is
scheduled to act on it, so an app with no sweep reports 86400 while in fact
keeping everything for ever. The error is in the forgiving direction, but do
not read it as "rows older than this are gone".

This section says what happened. It does not say whether that is bad;
thresholds belong to whoever watches the estate.

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

**Waiting is separated from working.** Wrap a call to somebody else's service and
its time is reported apart from the app's own:

```ruby
Estate::Monitor.external { http.request(request) }
```

`buckets_own` is then the same requests timed without that waiting, and
`external_ms_total` is how much there was. An app that calls the gateway spends
most of a slow request waiting — the mean completion there is fourteen seconds —
so undivided, its p90 stops being a statement about the app and becomes "did an
LLM call happen". The time is counted even when the call raises, because a
gateway call that times out is the most expensive waiting there is.

Apps that never call it report `buckets_own` identical to `buckets`, which is
the truth: nothing was waited on.

This section says how long things took. It does not say whether that is bad;
thresholds belong to whoever watches the estate.

## Client

```ruby
Estate::Monitor::Client.fetch(url, token: token)
# => { ok: true, payload: {...} }  or  { ok: false, error: "…" }
```
