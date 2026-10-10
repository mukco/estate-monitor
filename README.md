# estate-monitor

One JSON reporter per Rails app covering everything the app itself knows:
runtime facts, Solid Queue state, and custom sources. Mount it, set a token,
and the estate dashboard can see your workers.

Since 0.7 it also reports errors and deliberate log lines — from the browser,
from unhandled request and job failures, and from the app on purpose — to the
estate's Errors panel. See [Errors](#errors). Since 0.8 it also reports a
phone running a page whose files a deploy has deleted — see
[Stale pages](#stale-pages).

## Install

```ruby
gem "estate-monitor", github: "mukco/estate-monitor", tag: "v0.9.0"
```

```ruby
# config/routes.rb
mount Estate::Monitor::Engine => "/internal/metrics"     # bearer-gated, for the estate
mount Estate::Monitor::ErrorsApp => "/internal/errors"   # open, for the app's own pages
```

Mount both above any SPA catch-all route.

Configure (initializer or before mount):

```ruby
Estate::Monitor.configure do |config|
  config.token    = ENV["ESTATE_MONITOR_TOKEN"]
  config.app_name = "Baseball"
  # Optional, for error reports — see Errors.
  config.current_user_id = ->(request) { request.session[:user_id] }
end
```

(`configure` was documented here before it existed; from 0.7 it does. Setting
`Estate::Monitor.token = …` directly still works.)

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
    "latency":     { "since": "…", "requests": { … }, "routes": [ … ] },
    "errors":      { "pending": 0, "delivered": 12, "events": [ … ] }
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

## Errors

Added in 0.7 (contract v5). Three ways in, one way out:

```
browser / TV ──POST /internal/errors──┐
Rails.error (requests, jobs) ─────────┼─▶ stamp ─▶ buffer ─▶ POST {ESTATE_URL}/api/ingest/events
Estate::Monitor.report ───────────────┘                 └──▶ `errors` section of /internal/metrics
```

### Config

| Setting | Default | |
|---|---|---|
| `token` | — | The existing `ESTATE_MONITOR_TOKEN`. No token, no reporting. |
| `estate_url` | `ENV["ESTATE_URL"]` or `https://estate.edwardsfamily.app` | |
| `enabled` | `nil` = on when there is a token, except in test | `true` in a spec that wants to see events |
| `current_user_id` | `nil` | `->(request) { … }` → the signed-in user's id or nil. Raising means nil. |
| `ignored_exceptions` | `RoutingError`, `RecordNotFound`, `InvalidAuthenticityToken`, `UnknownFormat` | Class names; subclasses match too |
| `release` | the runtime sha (`SOURCE_VERSION` / `KAMAL_VERSION` / `/rails/.git-sha`) | string or lambda |
| `report_stale_assets` | `true` | See [Stale pages](#stale-pages) |
| `stale_asset_paths` | `["/assets/"]` | Prefixes of the app's own built files |
| `recover_stale_scripts` | `true` | Answer a missing script with one that reloads the page — see [Stale pages](#stale-pages) |

Apps behind the WARP `HTTPS_PROXY` must add `estate.edwardsfamily.app` to
`NO_PROXY`; until they do, `errors.last_error` in the metrics says why pushes
fail, and the scrape collects the events instead.

`current_user_id` gets an `ActionDispatch::Request` — from the browser
endpoint, or the request an unhandled error happened in. The session is there
if the app has session middleware:

```ruby
config.current_user_id = ->(request) { request.session[:user_id] }                     # cookie session
config.current_user_id = ->(request) { request.env["warden"]&.user&.id }               # Devise
config.current_user_id = ->(request) { request.cookie_jar.signed[:user_id] }            # signed cookie
```

### Browser endpoint

`POST /internal/errors`, a plain Rack app — so no login, no CSRF, and nothing
in `ApplicationController` can reach it. Body `{ "events": [Event, …] }`, as
JSON or as a `navigator.sendBeacon` text/plain string. At most 10 events and
64 KB per request, 30 events a minute per client address (in-process; excess
dropped). Always `202 {}` — rate-limited, oversized and disabled included —
except `400` for a body that is not JSON. A browser may say `source: "client"`
or `"tv"`, never `"server"`. `@mukco/ui-kit/observability` is the client.

Each event is stamped with `app`, `release`, `user_id`, `ip_hash` (first 12
hex of sha256 of the address and a daily salt derived from the token),
`received_at` and `host` (the container's hostname).

### Server-side

Subscribed to `Rails.error` by the engine, nothing to configure. Unhandled
request errors arrive as `level: error, source: server, kind: exception` with
`route`, `method` and `action` in the context; job failures as `source: job,
kind: job` with `job`, `queue`, `job_id`, `executions`. `Rails.error.report(e,
severity: :warning)` → `warning`, `:info` → `info`; `Rails.error.handle { }`
is Rails' default for a handled error, `warning`. The stack is the app's own
frames first, then the rest, 40 lines, relative to the app root.

### On purpose

```ruby
Estate::Monitor.report(:warning, "Lidarr refused import", context: { album: album.title })
Estate::Monitor.report(:error, exception, context: { feed: feed.id })
Estate::Monitor.report(:info, "Nightly warm finished", context: { games: 14 }, fingerprint: "nightly-warm")
```

Returns the event_id, or nil when reporting is off; never raises. Inside a
request or job it picks up the route, job and user like an unhandled error.
Strings are `kind: manual`. The ignore list does not apply.

### Delivery

One buffer per process, flushed by a background thread every 2 s or at once
at 20 events, in batches of at most 50 events / 512 KB. A failed push keeps
the events and backs off (2 s doubling to 5 min); the buffer holds 500 and
drops the oldest. A `429` or `413` lets the batch go — the estate has already
counted it, and resending only spends more of the budget. The thread starts
on the first event in each process, so Puma workers and Solid Queue's forked
processes each run their own; a forked child starts with an empty buffer.

### The `errors` section

```json
"errors": {
  "pending": 3, "delivered": 120, "dropped": 0, "rejected": 0,
  "consecutive_failures": 4, "last_delivered_at": "…",
  "last_error": "Errno::ECONNREFUSED: …", "last_error_at": "…",
  "events": [ { "event_id": "…", "level": "error", "source": "server", "message": "…",
                "app": "Baseball", "release": "…", "user_id": 7, "ip_hash": "…",
                "received_at": "…", "host": "…", "occurred_at": "…", "context": { … } } ]
}
```

Undelivered events, oldest first, at most 100 / 256 KB per scrape. Each is
shown to two scrapes and then dropped from the buffer — the second showing
covers a scrape whose response was lost. Pushes keep retrying meanwhile, so
the estate must dedupe on `event_id`.

## Stale pages

Added in 0.8. A phone that restores an old `index.html` from its cache asks
for the JS and CSS that page was built with; if a later deploy deleted them,
every one is a 404, no app code runs, and the browser reporter never loads.
The 404 is a `RoutingError`, which is on the ignore list (bots probe for files
all day), so until 0.8 the server said nothing either. That was Football's
white screen on 2026-10-09.

The engine now inserts `Estate::Monitor::StaleAssets` just below
`ActionDispatch::Static` (at the top of the stack when the app serves no
files) — nothing to mount. When a request's final answer is a 404 and

- it is a `GET` or `HEAD`,
- the path starts with one of `stale_asset_paths` (default `/assets/`, Vite's
  output) and ends `.js`, `.mjs` or `.css`,
- the User-Agent contains `Mozilla/` and none of `bot`, `crawler`, `spider`,
  `curl`, `python`, `go-http`,

it is reported as a client error. A stale page asks for several files at
once, so the first 404 from an address opens a five-second window, the rest
join it, and the window closes into **one** event listing every path (at most
20). Opening a window counts against the browser endpoint's limit, 30 a minute
per address. Windows are closed by a background thread, so a request does
nothing but a status check — and for a 404 a prefix check and a hash append;
nothing here can raise into a request.

```json
{
  "level": "error", "source": "client", "fingerprint": "stale-asset",
  "message": "A phone asked for /assets/index-wQ90q-cT.js, which this deploy no longer has",
  "context": {
    "kind": "stale_asset",
    "path": "/assets/index-wQ90q-cT.js",
    "paths": ["/assets/index-wQ90q-cT.js", "/assets/index-BXpUa--r.css"],
    "ua": "Mozilla/5.0 (iPhone; …)", "referer": "https://…/", "accept": "*/*",
    "ip_hash": "3f9c…", "release": "<sha>"
  }
  // + the usual stamps: event_id, app, release, user_id, ip_hash, received_at, host, occurred_at
}
```

One group per app (`stale-asset`), whatever the paths. Turn it off with
`config.report_stale_assets = false`; add a prefix with
`config.stale_asset_paths = ["/assets/", "/packs/"]`. An app whose SPA
catch-all answers `/assets/*.js` with `index.html` and a 200 is never seen —
keep the catch-all off the asset prefix.

### The way back (0.9)

Reporting did not end the white screen: Safari reopens a tab from its own copy
of a page several deploys old, which predates anything on the page that could
recover, and Kamal's asset bridging keeps only one deploy back. So when the
missing file is a **script** (`.js`, `.mjs`) from a browser, the answer is not a
404 but a 200 `text/javascript`, `cache-control: no-store`, `x-estate-stale:
recover` — about 500 bytes that reload the page (fetching today's
`index.html`). If that page is stale too, the second try loads it under a new
address (`?_fresh=…`); a third try within 30 seconds stops, so it can never
loop. Stylesheets stay 404s. The report goes out exactly as before, and the
answer is given even with `report_stale_assets = false`. Turn it off with
`recover_stale_scripts = false`.

## Client

```ruby
Estate::Monitor::Client.fetch(url, token: token)
# => { ok: true, payload: {...} }  or  { ok: false, error: "…" }
```
