# Native application management contract

This adapter supports stable TrueNAS 25.10. Catalog installation, upgrade and
removal use its dedicated typed interface and stay blocked in generic
administration. Existing generic start/stop/redeploy entries retain their own
policy review and share the same mutation lock; the native workspace adds
installed-identity checks and independent runtime readback.
Verification uses fake transports only, with no NAS or credential access.

## Pinned source contracts

- [25.10 application API models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/app.py)
- [25.10 installed app query fields](https://api.truenas.com/v25.10/api_methods_app.query.html)
- [25.10 outdated application images](https://api.truenas.com/v25.10/api_methods_app.outdated_docker_images.html)
- [25.10 application image pull job](https://api.truenas.com/v25.10/api_methods_app.pull_images.html)
- [Application inventory, creation and deletion](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/apps/crud.py)
- [Upgrade summary, migration and configuration merge](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/apps/upgrade.py)
- [Question schema construction](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/apps/schema_construction_utils.py)
- [Catalogue details](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/catalog/apps_details.py)
- [25.10 catalogue list response](https://api.truenas.com/v25.10/api_methods_catalog.apps.html)
- [25.10 catalogue configuration](https://api.truenas.com/v25.10/api_methods_catalog.config.html)
- [25.10 available catalogue trains](https://api.truenas.com/v25.10/api_methods_catalog.trains.html)
- [25.10 catalogue preference update](https://api.truenas.com/v25.10/api_methods_catalog.update.html)
- [25.10 catalogue sync job](https://api.truenas.com/v25.10/api_methods_catalog.sync.html)
- [Job identity and redaction](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/job.py)

## Inventory and installation

`app.query` uses a 1025-row sentinel and projects identity, catalogue metadata,
state, version, custom-app status and upgrade availability. It explicitly disables
configuration and application schema retrieval in ordinary inventory. The
dedicated configuration review uses the restricted reads described below.
Inventory also projects the nullable latest application version and a separate
Docker-image update flag. The two signals remain independent and are display
only; they do not start an upgrade or image pull.
When an installed app reports image updates, the user can explicitly check
`app.outdated_docker_images`. The SDK first verifies the exact current app
identity, version and update flag with a configuration-free query, then
returns at most 64 unique safe image names. The list is session-bound,
immutable and never starts a pull.
An explicit, typed-name-reviewed image pull uses the current app handle,
rechecks app/environment and the expected outdated-image set, and submits
only `app.pull_images(name, {redeploy: false})`. Its owned job is checked for
identity and no-redeploy arguments. Server-reported success verifies that
the job finished with the app still present in its original state; it does
not claim the running containers use the new images. Failure or ambiguity
fences further Apps writes because downloads can be partial. Applying the
images requires a separate reviewed redeploy.
Notes and portal URLs are never included in ordinary inventory. Expanding one
installed app makes an exact-ID `app.query` that selects identity, version,
notes, portals and active workloads with configuration/schema retrieval disabled. It requires
the current inventory handle, bounds notes to 4096 characters and portals to
eight label/URL pairs, and rejects malformed or unsafe control/bidi text,
non-HTTP(S) URLs and embedded URL credentials. The immutable projection is
session-bound and discarded when the detail view closes or account changes.
The workload projection retains only bounded running-container, port-mapping,
volume and image counts; mount paths, image references and container details
are never retained or displayed.
Portal addresses are selectable text only; the app does not automatically
visit or fetch them. This is not full WebUI portal launching or notes editing.
More than 1024 installed apps
is rejected. Catalogue discovery uses cached `catalog.apps` with explicit train
options and bounds the response to 32 trains and 2048 apps. Version selection
uses `catalog.get_app_details`, with at most 256 concrete numeric versions.
The same catalogue response projects only bounded public categories (16 per app,
64 distinct overall), tags (32 per app) and the recommended flag. These fields
remain immutable UI discovery hints; README HTML, locations, screenshots and
unbounded metadata do not enter the app model. Malformed, oversized or unsafe
labels fail closed. Missing classification is shown as unclassified, not
invented. Category, train and recommendation filters and tag search act only
on this already loaded catalogue; they never authorize installation.
An explicit server-cached-only catalogue list uses `catalog.apps` with
`cache:true` and `cache_only:true`; the normal path retains `cache_only:false`.
The cached-only list cannot open version details or issue an installation
handle. Switching back requires a fresh normal catalogue read, invalidating
cached-only handles. This still requires an authenticated TrueNAS connection;
it is not an app-local offline copy or a promise that later operations avoid
network access.

Where both read permissions are present, the separate catalogue overview reads
`catalog.trains` and `catalog.config` without exposing the catalogue location.
It projects only bounded, unique, validated available/preferred train names;
malformed settings fail closed and never replace the existing app list. These
are server settings, not app-local filter preferences. The UI can show an
available train with no currently returned app. Browsing never implicitly
calls `catalog.sync`.

Preferred-train editing requires the separate `catalog.update` permission and
an exact overview handle from this connection. Only a bounded unique subset of
server-listed trains can be requested. Previously preferred trains that are no
longer available remain visible as removable chips, but cannot be reselected;
saving is disabled until they are removed. The app shows the old/new lists and
endpoint, requires typing `catalog preferences`, then acquires the shared
operation lock. The SDK rereads both settings and available trains before
submitting exactly `[{"preferred_trains":[...]}]`; changed catalogue identity,
settings or trains reject without a write. It verifies the returned identity
and preference and independently rereads them. Timeout, malformed response or
readback mismatch after submission is unknown, locks further changes on that
connection and is never retried automatically. The UI can still read settings
for inspection. This preference flow is tested only against fake transports,
never the supplied NAS.

Catalogue synchronization is a separate explicitly confirmed job. It
requires the exact current overview handle and `catalog.sync` permission,
rereads catalogue identity and settings before dispatch, and sends no
arguments. The returned positive job ID belongs to that session. Polling
uses a bounded `core.get_jobs` projection with `raw_result:false`, verifies
exact ID, method and empty arguments, and surfaces numeric progress without
descriptions, results or errors. A successful job is verified only after
fresh catalogue settings can be read; failed/aborted jobs release the write
lock and invalidate old catalogue handles. An ambiguous dispatch, mismatched
job or failed readback becomes unknown and fences mutations without replay.
The UI disables sync in server-cached-only browsing mode. No live NAS sync
was run; all sync tests use fake transports.

Catalogue, installed-app, version and upgrade-review handles belong to the exact
authenticated connection that issued them. Reload invalidates earlier relevant
handles. Independent reads are serialized through a queue bounded to eight.

Installation requires an explicit version, supported catalogue questions and
valid name/configuration. The adapter supports typed boolean, integer, string,
enum, dictionary, list, default and supported conditional question shapes.
Unknown active semantics are blocked. Inactive fields are removed, safe hidden
defaults retained, and private defaults stripped. ACL-changing normalization
requires a separate permissions workflow. TrueNAS-managed app volume creation
is disclosed. Port-conflict detection is limited to recognized semantic port
questions; middleware remains responsible for full service-port validation.

Before submission the adapter rereads the exact version schema and its
`app_metadata` name/train/version, verifies the reviewed application pool is
unchanged and Docker is running, checks current names and used ports, then
rechecks the pool and proposed name. The creation payload includes only the
reviewed name, catalogue app, train, version, prepared values and
`custom_app:false`. No `latest` alias, custom YAML or arbitrary RPC is accepted.

## Configuration-preserving upgrades

Upgrades do not use the installer form and do not retrieve stored configuration.
The current app must be running, catalogue-managed, and report upgrade
availability. The chosen catalogue version must be a concrete newer release.

`app.upgrade_summary` is called with
`[app_name,{"app_version":"1.2.3"}]`. Its exact upgrade target, available versions
and release notes issue a session-bound review. Immediately before writing,
the SDK rereads installed identity, catalogue metadata/schema and the summary;
summary or catalogue drift rejects the operation.

The only upgrade options are:

```json
{"app_version":"1.2.3","values":{},"snapshot_hostpaths":false}
```

Nonempty override values are rejected. Middleware migrates existing settings;
installer defaults must not replace saved nested storage, network or secret
configuration. A locally unsupported installer question does not by itself block
this server-managed migration. The server can still reject an upgrade that
requires additional settings. Upgrade never supplies configuration overrides;
supported existing scalar settings use the separate reviewed editor below.

## Existing configuration: bounded scalar edits

The editor obtains the exact installed version's `version_details` through an
exact-ID `app.query` with `include_app_schema:true` and `retrieve_config:false`.
It separately calls `app.config` inside the private SDK gateway. Raw current
configuration never enters the public review, UI provider, job handle or log.
Only sanitized field metadata, non-secret current scalar values, and the
presence of protected fields leave the adapter. Review observations retain
opaque schema/configuration/pool fingerprints, not raw configuration.

All configuration numbers, including unknown preserved siblings, must be finite
and within ±9007199254740991. Larger JSON integers can lose precision during a
Dart/Web decode and re-encode, so review/update fails closed rather than silently
rounding an untouched value. Submitted numeric patches obey the same bound.

Only present, active, supported boolean/integer/string leaves can be patched.
Secrets, hidden/immutable settings, arrays, path/storage/resource controls and
conditional selectors remain read-only. There are no installer-default merges
or arbitrary additional keys. A patch identifies one schema-issued field.
Immediately before dispatch the SDK rereads installed identity, exact installed
schema and current configuration and rejects any drift, including hidden or
secret-value drift. It deeply copies each changed top-level subtree from that
fresh private configuration and replaces only the reviewed leaf. Unknown
fields, lists and secret siblings in that subtree remain unchanged. The payload
is `app.update [app_name,{"values":changed_top_level_subtrees}]` because the
middleware merge is shallow.

Explicit changes to recognized semantic port fields trigger a bounded
`app.used_ports` preflight. Duplicate proposed ports, malformed port inventories
and any proposed port already in use are rejected, including another current
port of the same app. This intentionally blocks port swaps. Unchanged ports are
not treated as proposed changes, and edits with no port changes perform no port
query. The final configuration freshness read occurs after that preflight;
middleware still performs its complete service-port validation.

The four reserved outputs `ix_context`, `ix_volumes`, `ix_certificates` and
`ix_certificate_authorities` are excluded from editable input and verification
fingerprints. Middleware normalizes the full merged configuration, even when
only a scalar changes. Apps with active ACL, ixVolume or GPU normalization are
therefore blocked by this first editor: a scalar edit must not implicitly apply
ACLs, create missing datasets or rewrite GPU settings. Existing-volume
normalization is conditionally idempotent only with separate fresh existence
proofs, which this editor does not perform. See the pinned
[normalization actions](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/apps/schema_action_context.py).

After a successful owned job, the SDK checks app identity/runtime state and
independently rereads the complete non-reserved configuration. Its private
fingerprint must match the intended merged result, including preserved secrets
and unknown values. Unexpected normalization, transport failure or conflicting
readback yields unknown and retains the mutation lock. Failed or aborted update
jobs also remain unknown: middleware can persist configuration before a later
template-rendering or container-recreation failure. Stopped applications
remain stopped; running applications can recreate containers. Completion
invalidates the previous review and requires reloading before another edit.
Secret replacement and broader resource/permission editing remain unavailable.

Configuration comparison and update are separate RPCs. The public API has no
expected revision token or atomic compare-and-update option, so another client
can change configuration after the final read; a copied root could overwrite
that concurrent change. This is separate from app-name replacement. The review
asks users to avoid concurrent edits, and post-job comparison detects conflicting
readbacks, but neither check eliminates the race.

## Lifecycle and uninstall

Start requires a stopped app. Stop and redeploy require a running or crashed app.
Every operation rereads current installed identity and the application pool.

Uninstall requires the user to type the exact installed name. Its options are
always `remove_images:false`, `remove_ix_volumes:false`,
`force_remove_ix_volumes:false`, and `force_remove_custom_app:false`.
This does **not** preserve every kind of application data: the pinned middleware
still invokes Docker Compose teardown with volume removal. Docker-managed
volumes can be deleted. TrueNAS-managed ixVolumes and host paths are retained,
and optional image cleanup is disabled. No forced cleanup, hold removal,
snapshot rollback or extra dataset deletion is performed by the adapter.

## Jobs, secrets and identity limits

Only the exact returned job handle can be polled. `core.get_jobs` is filtered by
its ID and projects method, arguments, state and numeric progress; it does not
request results, logs or error payloads. The adapter verifies the method and
non-secret identity arguments, including concrete versions and deletion flags.
Submitted values are not retained in job handles, observations or results.
Errors are fixed local messages and remote progress descriptions are omitted.

Successful jobs require an independent configuration-free app query confirming
the expected identity/version/state, or exact-name absence after uninstall.
Matching apps still in DEPLOYING or STOPPING remain checkable; they do not become
permanently unknown solely because containers are settling after job completion.
Timeouts, missing/foreign jobs, transport loss or conflicting readbacks produce
an unknown result and block further mutations until the session changes. Config
updates additionally require the private full-configuration proof above. No
mutation is automatically retried. Shared SDK/UI locks cover other server writes.

The public app identifier is its name. The installed API provides no immutable
creation token or atomic compare-and-mutate option. Immediate identity checks
cannot eliminate an external client's same-name/same-version replacement race.
Avoid concurrent app changes in other clients. The adapter does not claim an
atomic identity guarantee. Native rollback, custom YAML and configuration edits
outside the restricted scalar flow remain unavailable in this increment.
