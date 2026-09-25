# Notification services: bounded Mail lifecycle

`AuthenticatedAlertSettingsSession` provides a safe projected inventory and
reviewed Mail service create, edit, enable, disable and delete actions. It does
not provide arbitrary notification-provider configuration, provider tests, SMTP
send, alert-class overrides or a delivery monitor. All development and validation
used public pinned source and synthetic transports only: no NAS connection,
credentials, SMTP contact, probes or actual mutations were used.

Separate protected workspaces now cover [typed external providers](NOTIFICATION_PROVIDERS.md)
and [alert-class policies](ALERT_POLICIES.md). Their native gateways share the
same pending/unknown mutation guards; this Mail adapter never converts a row
into another provider or opens its credentials.

## Pinned wire contract

Reference tag: **TS-25.10.1**.

- The [alert service schema](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/alertservice.py)
  requires name, attributes and level for both create and update. Update accepts
  `AlertServiceCreate`, **not** a partial-update model. Enabled defaults to true.
  Every native create/update therefore sends the complete supported Mail
  envelope with an explicit enabled value. Unedited supported fields are
  preserved; this is not a changed-field wire patch.
- The [provider union](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/alertservice_attributes.py)
  identifies email by `attributes.type = "Mail"`, not EMAIL. Mail has only
  `type` and `email`; blank email means local-administrator fallback. Native
  create/edit/enable requires one explicit plain ASCII recipient, never fallback.
- [CRUD implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/alert.py)
  validates severity, compresses attributes and writes the datastore. Create and
  update return an entry; delete returns bool. These ordinary authenticated
  ALERT-family methods do not themselves send a test notification. The generic
  [CRUD wrapper](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/service/crud_service.py)
  can perform post-write hooks/events, so a later error is not rollback.
- The [Mail provider](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/alert/service/mail.py)
  calls `mail.send` with subject Alerts, HTML alert details and the configured
  recipient (or administrator fallback). It omits queue=false, so the normal
  [mail queue defaults](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/mail.py)
  apply. Awaiting this call only creates a mail job; it does not establish SMTP
  completion or recipient delivery. No provider-test method is used here.

The only write shapes are:

```text
alertservice.create [ {name, attributes:{type:"Mail",email}, level, enabled:false} ]
alertservice.update [ id, {name, attributes:{type:"Mail",email}, level, enabled:false} ]
alertservice.update [ id, {name, attributes:{type:"Mail",email}, level, enabled:true} ]
alertservice.delete [ id ]
```

Create always stores a disabled row. Editing and deletion require a previously
disabled row. Enable and disable are separate reviews preserving name, recipient
and severity. Strict supported Mail attributes are required for every action;
unsupported provider attributes are never converted, cleared or overwritten.
Safe legacy blank/multiple-recipient rows can be disabled or deleted, and a
disabled legacy row can be edited to an explicit valid recipient. They cannot be
enabled unchanged. Enabled service deletion is not silently preceded by disable.

## Secret-safe, source-compatible inventory

The first query requests only top-level all-provider fields:

```text
alertservice.query [ [], {limit:129,
  select:["id","name","level","enabled","type__title"]} ]
```

It does not request attributes, endpoint URLs, passwords, tokens, SNMP community
strings or recipient-like attributes from arbitrary providers. A second query
always filters on the actual extended Mail discriminant and requests Mail only:

```text
alertservice.query [ [["attributes.type","=","Mail"]], {limit:129,
  select:["id","name","level","enabled","attributes"]} ]
```

No `force_sql_filters` is set. The pinned CRUD extension runs before filtering,
so the public attributes discriminant can be filtered without using private
datastore fields. At most 128 rows are admitted; the extra requested row detects
truncation. IDs must be unique positive JavaScript-safe integers. Safe summaries
are sorted by ID and immutable. The source title Email only marks a candidate:
matching actual Mail attributes and matching header IDs/fields are required for
editability. A title collision or header/detail race fails closed. Unrecognized
other-provider titles are grouped as Other; private title fingerprints detect
drift without exposing arbitrary titles or provider attributes.

Selecting only `attributes.type` for every provider is deliberately avoided:
the [query result model](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/base/model.py)
makes top-level fields optional, but nested provider unions still require their
provider-specific fields. The [result serializer](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/base/handler/result.py)
validates the result model, so a partial Slack attributes object without URL can
fail serialization. Complete Mail attributes are projected privately, with only
the bounded safe recipient published; unknown extra Mail attributes block edits.

Severity and enabled/provider charts count these configured rows only. They do
not show effective notification coverage, frequency, live delivery or queue
health. Other-provider credentials are neither requested nor compared. A
concurrent secret-only change in another provider is therefore intentionally
outside this proof, not asserted to be absent.

## External effects and important limitations

Enabling permits concurrent background alert processing to send HTML containing
complete new/cleared/current alert text, product and NAS hostname. These details
can expose sensitive system information externally. The user must independently
approve the recipient and saved SMTP destination and accept queued retries.
This workspace does not read or change SMTP credentials or transport settings.
Use the separate Email settings workflow to inspect its safe SMTP summary.

The pinned TrueNAS/Python SMTP path does not establish a verified SMTP
certificate/hostname guarantee; API certificate pinning is separate from
server-to-SMTP traffic. See [EMAIL_SETTINGS.md](EMAIL_SETTINGS.md) for the pinned
transport source and its explicit risks. Creating or reviewing a service does
not check ownership, reachability, SMTP credentials or deliverability.

Disabling or deleting a service may remove an important notification path,
including the last enabled Mail service. It cannot recall already queued or
in-flight messages, cancel mail jobs, or suppress independent per-alert default
mail and proactive-support paths. Prior queued messages may retry with current
SMTP settings. The separate fixed SMTP test's queue=false does not apply to
normal alert-service delivery. There is no public queue inspection/cancellation
in this workspace.

Alert policies use shared snapshots and independent class policy/severity
settings; enabling does not guarantee replay of existing alerts. Alert-class
severity/frequency/proactive-support overrides are deferred because they have
separate full-map replacement, visibility and policy effects. No `alertclasses`
method is used by this adapter.

## Review, execution and recovery

Capabilities require stable TrueNAS 25.10 and exact public ordinary authenticated,
non-file method metadata. Create/update/delete capabilities are separate from the
safe inventory capability. Read-only users may inspect safe summaries but cannot
obtain a mutation review. The adapter reuses the conservative power-read guards:
FULL_ADMIN, standalone, READY, no visible running/waiting jobs, healthy online
idle boot pool, and unchanged bootable current/next environments. Host, boot,
state and authorization are rechecked after the service projection. These are
app guards, not atomic server locks, workload-quiescence or delivery guarantees.

An immutable repository-issued inventory, every safe service header/Mail field
and private provider-title proof are bound to a one-use five-minute review.
Reload, superseding review, stale identity/configuration, backwards clock or
expiration invalidates it. Exact confirmation targets include the full public
host ID, action, existing service ID where applicable and the recipient for
create/edit/enable. Public host ID is not cryptographic attestation.

Execute consumes every review attempt. Its required `isCurrent` callback must
track session, route, foreground, reviewed inventory and consent context. False
or throwing callbacks reject before mutation; the callback and review age are
checked after all awaited preflight reads immediately before the single fixed
CRUD call. No retries, test sends, background job polling or reconnects occur.

`completed` requires both the exact expected receipt and one independent fresh
safe-inventory readback, with no unexpected added/missing/changed public rows and
unchanged host/readiness proof. It confirms saved configuration only, not whether
any alert left the NAS, reached SMTP or reached its recipient. All post-dispatch
errors, invalid responses, timeouts, lifecycle loss and mismatches are `unknown`:
a database change may have occurred and background delivery may already differ.
Unknown fences that SDK session against peer mutations permanently. Verified
completion allows a new deliberate inventory and review.

The shared lock covers email, time, reset, restore, backup, power, storage and
other native/generic management workspaces in both directions. The app retains
its own uncertainty fence across reconnection. Recovery requires explicit fresh
connection to the original endpoint, same public host and baseline readiness,
plus independent server/configuration/delivery inspection acknowledgement. This
releases only the app fence, not the uncertain original SDK session. Reconnection
alone is not proof of outcome. No process-death persistence or durable queue
recovery guarantee is made.

Synthetic protocol and independent safety suites exercise strict projections,
full envelopes and explicit enable values, legacy/unsupported rows, metadata,
lease/current races, ambiguous receipts/readback and shared peer fences. No
fixture was sent to a real appliance or recipient.
