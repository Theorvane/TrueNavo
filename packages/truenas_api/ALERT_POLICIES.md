# Alert-class policies and selected override reset

This bounded native workspace edits a listed class's severity, notification
policy and eligible proactive-support override, or removes only that selected
class override. It does not implement arbitrary class JSON, global support
enrollment/contact settings, support ticket submission, alert generation, provider
tests, mail delivery or the entire TrueNAS web UI. Development used public pinned
source and synthetic SDK/UI fixtures only: no NAS credentials, appliance contact,
server mutations, SMTP, support requests or host probes were used.

## Verified TS-25.10.1 contract

- The [public alert schema](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/alert.py)
  exposes `alert.list_categories`, `alert.list_policies`, `alertclasses.config`
  and ordinary authenticated `alertclasses.update`. Override fields level,
  policy and proactive_support are optional; omitted fields are not equivalent
  to explicit defaults or null. The configuration contains an ID and complete
  classes map. Update is under the ALERT role family.
- The [implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/alert.py)
  merges the outer configuration object, **replacing** the entire supplied
  classes map. A request containing one class alone resets all other class
  overrides. The native adapter therefore sends exactly one `classes` field
  containing the complete, freshly verified map, with every unrelated class and
  field preserved. No global ID or other field is submitted.
- Default notification policy is IMMEDIATELY. The exact supported vocabulary is
  IMMEDIATELY, HOURLY, DAILY and NEVER. Severity falls back to the class default
  from category metadata. For classes whose `proactive_support` capability is
  true, an absent proactive-support override means **enabled** at the class
  level. This is separate from global support eligibility/enabled state.
- `list_categories` excludes product-inapplicable and deliberately unlisted
  classes. Those classes can still have effective alerts or stored overrides.
  All unlisted override rows are preserved privately, including empty `{}`
  entries; only their count is projected into this UI. They are not removed or
  made editable. If their shape cannot be safely preserved, mutation is blocked.

The wire shape is always:

```text
alertclasses.update [ { classes: COMPLETE_PRESERVED_OVERRIDE_MAP } ]
```

Configure replaces only the selected listed class's override object using typed
optional fields. Choosing Default removes that field; it never sends null. An
empty stored row is preserved as distinct from an absent row. Reset removes only
the selected class key, restoring **all** of its source defaults. The map is
bounded to 1,024 stored overrides, metadata to 64 categories/1,024 listed classes,
and identifiers/titles to strict control-free bounds. A new override is rejected
before dispatch when the stored map is at capacity.

## Visibility and external reporting

NEVER is stronger than simply not emailing: the pinned serializer omits that
class from normal `alert.list` results and related events, and configured alert
services filter it out. Reducing severity can also remove service-threshold
matches. This does not repair an alert condition, dismiss it or erase its data.

NEVER is **not a global mute**. The same source has separate per-alert `mail`
and proactive-support processing paths which do not consult the class's normal
notification policy or dismissal flag. Existing queued/in-flight mail and tickets
cannot be recalled. IMMEDIATELY/HOURLY/DAILY describe batching policy, not delivery
deadlines, replay guarantees, recipient receipt or live alert frequency.

Safe public eligibility reads are
`support.is_available` and `support.is_available_and_enabled`. The pinned
[support implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/support.py)
and [schema](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/support.py)
show that they are SUPPORT_READ ordinary boolean reads of vendor/product/license
eligibility and configured global enabled state. They do not contact the external
support service. This adapter never reads support contact data, serials or
customer/license records directly. Missing methods, errors, malformed booleans
or contradictory eligibility project as unknown, never assumed eligible.

A proactive-support field change/removal requires class support, current public
server eligibility and an explicit dedicated disclosure acknowledgement. A
change that enables reporting, including resetting/removing explicit false to
restore the default, additionally requires globally enabled support. Disabling
the class override is allowed with verified eligibility even if global support
is currently off. Severity/policy-only edits preserve the proactive field exactly
and do not silently require or change global support enrollment.

The pinned automatic ticket path may disclose formatted new/cleared alert text,
appliance serial, software version, licensed customer/company and configured
primary/secondary contact names, titles, email addresses and telephone numbers.
It uses `attach_debug:false`, which does **not** mean no sensitive information is
sent. Resetting a false class override can enable this future reporting even with
NEVER selected previously. The SDK/UI warn and require dedicated acknowledgement;
they do not initiate or test a support ticket. Enabling is not proof that any
ticket will be created, accepted or acted upon.

## Public API and preservation proof

`AuthenticatedAlertPoliciesSession` exposes `alertPoliciesCapabilities`,
`loadAlertPolicies`, `reviewAlertPolicies` and `executeAlertPolicies` with a
required `isCurrent` callback. Inventory is immutable and contains safe listed
class metadata, typed nullable overrides, stored-row presence, a conservative
readiness projection, configuration ID, unlisted override count and the two
optional support booleans. Nullable override fields mean absent, not server null.
Unknown/extra override fields or explicit nulls are rejected instead of discarded.

Class metadata, every override key/value/absence/empty row, configuration ID,
support booleans and baseline identity/readiness are bound privately to each
issued inventory and one-use five-minute review. Neither map ordering nor category
ordering grants a change; canonical proofs compare semantic rows while retaining
exact field presence. Any class default/capability/title, hidden override,
identity, authorization or support-state drift invalidates the review.

The conservative readiness guards reuse public power reads: stable TrueNAS 25.10,
FULL_ADMIN, standalone READY, no visible running/waiting jobs, healthy online idle
boot pool and the same bootable current/next environment. Host, boot, state and
authorization are rechecked after policy reads. These are app guards, not server
API prerequisites, atomic locks, a guarantee of workload quiescence or remote
cryptographic attestation. Read-only users can inspect policy data but cannot
obtain a mutation review. Missing support metadata alone does not disable normal
severity/policy editing that preserves support fields.

The exact confirmation target includes UPDATE or RESET, full public host ID and
class ID. Execute consumes the review on every attempt and checks the required
foreground/route/session/inventory callback around awaited preflight calls, then
again with review age after all awaits immediately before the single update.
False/throwing callbacks, expired/backwards clocks and fabricated/reused reviews
fail closed before dispatch. No retries, polls, forced sends or reconnects occur.

Completion requires an exact expected response and one independent full fresh
configuration/metadata readback. Every unrelated override remains unchanged;
selected field absence/removal must match exactly. `completed` confirms saved
configuration only, not notification/support delivery or visibility in every
client. Any post-dispatch error, timeout, mismatch or lifecycle loss is `unknown`:
the database update may already have happened. There is no rollback claim.

Unknown permanently fences the originating SDK session against shared peer
mutations. The app also retains a separate uncertainty lock across routes and
reconnections. Manual recovery requires a fresh connection to the original
endpoint, same public host and baseline readiness, followed by independent policy
and external-report inspection acknowledgement. The old future must settle before
acknowledgement can release the app lock; late completion cannot clear it or replay
the update. Reconnection alone is not proof of outcome, and no process-death
durability or server-side compare-and-swap guarantee is claimed.

## Native UI and validation

The page includes configured override/default proportions and resolved severity
and policy counts. Charts are explicitly configuration-only, never live alerts,
delivery measurements or support status. Search, readable empty/error states,
bounded list expansion, inline per-class details and independent read refresh are
provided. Editors use inline choice chips rather than popup menus which would
temporarily replace route ownership. The page holds its modal ownership until
`DialogRoute.completed`, so normal closing animations do not expire the parent
review. Unrelated route coverage, backgrounding or changed session/inventory
still expires it. Final confirmation has separate configuration, NEVER-visibility
and proactive-support acknowledgements where applicable.

Synthetic suites cover full-map preservation/absence, hidden classes, optional
eligibility, reset-to-default support effects, metadata and identity races,
lease/current callbacks, readback/uncertain outcomes, peer fences, real dialog
closure/route coverage, large-text/keyboard layouts and reconnect acknowledgement.
No fake fixture was sent to a live server, recipient or support endpoint.
