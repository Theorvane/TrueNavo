# Native live performance

This is an independently gated, read-only TrueNAS 25.10 capability. It does not
claim complete WebUI parity or full live release acceptance. The normal app displays only
received server data; the separate debug preview labels its synthetic fixtures.

## Verified wire contract

- Stable 25.10 versions and authenticated, advertised `core.subscribe` and
  `core.unsubscribe` are required. Event authorization is enforced by TrueNAS's
  `REPORTING_READ` role check, not inferred from RPC method availability.
- Subscribe arguments are `["reporting.realtime:{\"interval\":2}"]`; the result is
  an opaque subscription ID. Unsubscribe sends `[that exact ID]` on the same
  client. Never call the private `reporting.realtime.stats` method.
- Process only `collection_update` notifications with the exact subscribed
  collection and `params.msg == "added"`. Data is in `params.fields`.
  `notify_unsubscribed` terminates the source. The tagged middleware uses `msg`,
  despite one generated JSON-RPC example using a different `event` spelling.
- These events have **no server timestamp**. Charts explicitly use client UTC
  receipt times, not synthetic server sample times.

## Charts and metric meaning

- Aggregate CPU usage is the `cpu` entry, separate from each `cpuN`. Do not sum
  aggregate and per-core percentages. CPU trends use a fixed 0–100% scale;
  per-core bars and temperature in °C remain unavailable when not reported.
- The memory doughnut has exactly two complementary quantities: physical
  available bytes and `physical total - physical available`. The latter is
  labelled **not available**, not process allocation. Linux available memory
  includes reclaimable memory. ARC size is displayed separately, never added as
  a third slice; it can overlap available memory. Missing, zero-total, or
  inconsistent inputs suppress the doughnut.
- Interface throughput uses `received_bytes_rate` / `sent_bytes_rate`, already
  bytes/second. Interface `speed` is megabits/second. No conversion of interval
  counters into rates, no summing physical and virtual interfaces. Down/unknown
  links show unavailable rates, not a measured zero. Each interface has separate
  receive/send histories.
- Disk byte/operation rates are aggregate across disks; busy is the middleware's
  average across disks, not the load of a particular disk. Graphs and labels
  state this scope.
- ZFS ARC data and metadata demand hit percentages refer to separate request
  classes. They are shown as separate figures, not pie slices.
- The tagged middleware itself substitutes zero for some absent Netdata metrics.
  We disclose this limitation; an upstream-generated zero is not proof that an
  absent measurement was actually measured as zero. Locally missing/invalid
  metrics remain null and are never filled with zero.

## Bounds, lifecycle, and stale data

One active feed per authenticated repository. The SDK retains at most one event
before subscription acknowledgement/listening. Late acknowledgement after
timeout/cancellation triggers exact-ID cleanup. Consumer pause cancels the
source rather than building a paused-stream queue. A 1-second watchdog detects
closed/stale authentication, and 15 seconds without data terminates the feed.
No automatic retry loops and no mutation/job RPCs are part of this capability.

Frames are limited at typed parsing to 2,049 CPU entries, 256 interfaces, bounded
objects/names and finite numeric domains. Interface labels reject C0/C1 controls
and bidi formatting controls. Typed maps are immutable. The app retains at most
60 samples, discards duplicate/reversed receipt times, and splits graph paths at
missing values or arrival gaps greater than 6 seconds. A single point is drawn
as a point; an empty or all-null series is not a flat zero line.

The widget automatically pauses when its route is covered, TickerMode is off,
the app is backgrounded, or the dashboard card is hidden/unmounted. It also has
an explicit pause/resume control. Background teardown does not wait for another
render frame. Account/profile/session changes immediately clear all sample data
and close the original feed; new authentication cannot inherit old charts.
Reconnect/resume starts a new window, and an unresolved subscribe acknowledgement
is drained before a second subscription can begin.

## Verification

SDK fake-transport tests cover advertised/version gates, actual notification
shape/filtering, pre-ack events, parallel opening, rejected subscriptions, late
ack cleanup, remote unsubscribe, malformed data, consumer pause and repository
closure, units/memory overlap/null handling, and immutable bounded parsing.
Flutter tests cover the 60-sample window, exact session identity, queued opening,
pause/resume/disposal/background lifecycle, failures without retry, receipt gaps,
zero scales, and narrow 320px layouts at 200% text in both themes. These are not
NAS integration tests. A separate guarded read-only 25.10.1 probe received three
real events with CPU, memory, interface and disk measurements, then closed its
owned subscription. It did not validate every sensor, long-running lifecycle,
or native platform; see [bounded live evidence](docs/planning/READONLY_LIVE_VALIDATION.md).

## Primary contract sources

- [TrueNAS 25.10 reporting.realtime event schema](https://api.truenas.com/v25.10.0/api_events_reporting.realtime.html)
- [core.subscribe](https://api.truenas.com/v25.10.0/api_methods_core.subscribe.html)
- [core.unsubscribe](https://api.truenas.com/v25.10.0/api_methods_core.unsubscribe.html)
- [JSON-RPC notification reference](https://api.truenas.com/v25.10.0/jsonrpc.html)
- [Tagged event source](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/reporting/events.py)
- [Tagged JSON-RPC notification implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/base/server/ws_handler/rpc.py)
- [Tagged subscription authorization and ID implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/service/core_service.py)
- [Memory semantics](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/reporting/realtime_reporting/memory.py)
- [Interface units](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/reporting/realtime_reporting/ifstat.py)
- [CPU metrics](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/reporting/realtime_reporting/cpu.py)
- [Disk aggregation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/reporting/realtime_reporting/iostat.py)
