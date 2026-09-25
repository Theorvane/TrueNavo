# Native reporting history (verified 25.10 contract)

This is a dedicated, read-only adapter, not a raw method runner. It does not
change retention, generate passwords, export files, or contact Netdata directly.
No live NAS calls or real measurements were used to verify this implementation.

## Public interface

`AuthenticatedReportingSession` exposes `reportingCapabilities`,
`loadReportingGraphs()` and `loadReportingHistory(ReportingRequest)`.
The repository creates the adapter only after successful authentication and
invalidates it on reconnection or close. Stable TrueNAS 25.10 and advertised
`reporting.graphs` / `reporting.get_data` methods are required. Server-side
`REPORTING_READ` authorization remains authoritative.

A request contains the exact session-issued `ReportingGraph` object, a discovered
opaque identifier (or null for a system-wide graph), and a start/end `DateTime`.
Discovery refresh invalidates old graph objects. Foreign, reconstructed or stale
objects cannot issue requests. One read may be in flight per adapter; callers
must disable or queue selection changes rather than race requests.

Discovery uses `reporting.graphs` with `[[], {}]` and preserves server titles,
vertical labels and identifiers. Disk identifiers may include model/serial text;
they must not be shortened before sending them back. Null `identifiers` means
system-wide; an empty list means no instances were discovered.

History uses one selected graph/instance and explicit positive Unix-second
`start` and `end`, with `aggregate: true`. Intervals are limited to one minute
through 365 days. The verified API supports explicit positive epoch bounds and
MONTH/YEAR lookbacks; the response point/series/cell limits remain unchanged for
long intervals. The verified `get_data` name enum includes CPU, temperature,
disk, interface, load, memory, uptime, legacy ARC and UPS metrics. Some new ARC
names appear in discovery but not that enum. Only discovered system-wide graphs
may use the advertised `reporting.graph` fallback; this never fetches every disk
or network interface to select one locally. Both calls return data directly,
not a job ID.

## Interpreting the wire response

The concrete middleware response is a list of objects with `name`, `identifier`,
`legend`, `data`, `aggregations`, `start`, and `end`. `data` is a matrix:
each row starts with a Unix-second timestamp followed by numeric or null values
in legend order. The first legend item is `time`. The public model removes that
column from the legend and exposes typed timestamps separately. A null requested
system-wide identifier is usually returned as the graph name (for example `cpu`).

Range metadata reflects the requested interval; it is not evidence that samples
cover the whole interval. Plot the actual sample timestamps. Missing results,
empty rows, null samples and unavailable aggregate values never become zeros.
Duplicate, decreasing and malformed timestamps are rejected, including on rows
that will not be displayed. Netdata `natural-points` aligns its database and
grouping windows, so one sample can lie just outside the exact range returned by
TrueNAS metadata. The adapter validates the complete matrix, then clips at most
one sample per boundary within the smaller of one observed sampling interval
and 300 seconds. At least one in-window sample is required when clipping;
unrelated ranges, wider offsets and multiple out-of-window rows are rejected.
Retained timestamps and values are unchanged. Clipping sets `truncated: true`
for a visible notice and clears server aggregates because those statistics also
include the omitted samples. Explicit nulls and irregular retained intervals
remain gaps; boundary clipping does not fabricate missing samples.

`aggregations` contains series-keyed `min`, `mean`, `max` maps, or is null.
`aggregate` controls these additional statistics, not whether raw time-series
rows are returned. Missing aggregate series remain null. Unknown aggregate
series and non-finite/non-numeric values are rejected. Result collections are
immutable. Returned values retain the discovered unit, without guessed unit
conversion or negating values on the client.

Important presentation constraints:

- CPU includes the aggregate `cpu` series and individual cores. They overlap and
  must not be summed or drawn as disjoint pie slices.
- The `memory` graph represents **available physical memory**, not used memory
  or a complete allocation breakdown. Do not invent its complementary categories.
- Disk bandwidth is advertised as `Kibibytes/s`; interface traffic is
  `Kilobits/s`. These are not interchangeable with bytes/s. The middleware already
  makes the interface `sent` series positive.
- Middleware asks Netdata for `flip|null2zero|natural-points`, approximately
  2999 points, averaged (UPS uses median). Therefore an upstream zero can already
  be a substituted missing value. The app cannot reconstruct gaps erased upstream
  and must not claim all returned zeros are verified measurements. It preserves
  explicit nulls and flags irregular intervals; it does not synthesize samples.
- Unit/page requests are not used here. In the verified implementation, `page`
  multiplies the lookback duration ending now, rather than selecting an older
  disjoint page. A month is 30 days and a year 365 days.

## Bounds and failure behavior

Discovery is capped at 256 graph types, 4096 identifiers per type and 16384 total
identifiers. Titles, names, identifiers and legends reject controls/bidirectional
formatting characters and have explicit length limits.

One history response may contain at most one selected graph, 4000 rows,
512 value series, and 1.1 million cells. These limits apply before boundary
clipping. Oversized data fails explicitly. `truncated` currently indicates only
the bounded out-of-window alignment clipping described above; no in-window
samples are discarded or downsampled. Callers must show its notice and must show
a bounded-data error rather than silently shortening an oversized chart.

Transport failures, timeouts and permission failures have fixed safe messages.
No error body or response payload is embedded in exception strings. There are no
automatic retries. Stale session responses cannot escape the session guard.

## Evidence and sources

`test/session/session_reporting_test.dart` covers 59 fake-wire cases: discovery,
exact request shape and instance ownership, fallback restrictions, units, matrix
parsing, nulls/gaps, immutable outputs, bounded responses, malformed timestamps,
untrusted labels, missing results, timeout/error redaction, disconnection and
bounded leading/trailing alignment. An integration read-only CPU probe on
25.10.1 reported 901 rows for a 900-second window, with the first timestamp one
second before `start`; the regression fixture retains its 900 in-window samples.
The subsequent guarded read-only probe verified CPU, available-memory,
interface, disk and ARC-size histories against the real 25.10.1 server.
See [exact live scope and limits](../../docs/planning/READONLY_LIVE_VALIDATION.md).

The native client additionally supports custom UTC date ranges, disjoint
earlier/later intervals, refresh of a fixed selection and returning to the named
latest preset. Line, area and grouped-bar modes use the same returned values;
area/bar series are independent rather than stacked. Local zoom and timestamp
inspection do not request or imply higher resolution. Long-range axes show UTC
dates, and the exact table retains the entire bounded response regardless of
the visible zoom window. Null/irregular gaps remain broken in every mode.

- [25.10 get_data API](https://api.truenas.com/v25.10.0/api_methods_reporting.get_data.html)
- [25.10 graph API](https://api.truenas.com/v25.10.0/api_methods_reporting.graph.html)
- [Tagged request/result models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/reporting.py)
- [Public method wrappers](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/reporting/update.py)
- [Discovery and query translation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/reporting/graphs.py)
- [Concrete matrix, identifier and aggregation behavior](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/reporting/netdata/graph_base.py)
- [Graph units and identifiers](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/reporting/netdata/graphs.py)
- [History range and partial-result behavior](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/reporting/utils.py)
- [Netdata natural-points and default alignment options](https://github.com/netdata/netdata/blob/v2.3.2/src/web/api/netdata-swagger.json)
- [Netdata database/granularity/group window alignment](https://github.com/netdata/netdata/blob/v2.3.2/src/web/api/queries/query.c)
