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
  "version": 2,
  "generated_at": "…",
  "sections": {
    "runtime":     { "sha": "…", "booted_at": "…", "db_ping": { "status": "ok" } },
    "solid_queue": { "processes": …, "queues": …, "recurring": …, "failures": …, "totals": … }
  }
}
```

Every section is individually rescued; an app without Solid Queue reports
`{ "unavailable": reason }` for that section instead of failing the payload.

## Client

```ruby
Estate::Monitor::Client.fetch(url, token: token)
# => { ok: true, payload: {...} }  or  { ok: false, error: "…" }
```
