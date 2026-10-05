# Deferred live-evidence capture procedure

> **Status: collection procedure only — default deny.** This procedure does not
> admit an API method, enable a dashboard feature, expand transport access, or
> authorize a code change. It prepares a review package for exactly one tuple in
> the [runtime admission gate](C_DEFERRED_RUNTIME_ADMISSION_GATE.md).

## Purpose and boundary

A future operator uses this procedure only after the discovery ledger has a
`candidate-documentation` row and a source artifact can be reproduced. It
creates a **reviewable, redacted typed-observation record**, not a diagnostic
bundle, support export, or raw appliance capture.

The current dashboard runtime query allowlist is unchanged:
`system.info`, `pool.query`, `pool.dataset.query`, `service.query`,
`alert.list`, and `core.get_jobs`. VDEV, disk, snapshot, and apps remain
runtime-disabled. In particular, this procedure must not use an unapproved
method merely to "test" it.

A collection package is scoped to exactly one immutable tuple:

`(version family, domain, exact method, request-shape fingerprint, response-schema fingerprint)`

Do not combine appliance versions, domains, roles, methods, response shapes, or
collection sessions. A package is evidence for a separate human approval; it
never makes `LiveObservationEvidenceGate.apiCapabilityEnabled` true.

## Before a collection session

All items below are required. Any missing, ambiguous, or unsafe item stops the
session before a deferred observation call is attempted.

1. Choose one `candidate-documentation` row in the
   [discovery ledger](C_DEFERRED_CONTRACT_DISCOVERY_LEDGER.md). Rows marked
   `blocked-source`, `rejected`, or `admitted` are not collection instructions.
2. Record the source artifact from that row: version-specific source URL,
   version identifier, retrieval time, body digest, and archive location. Re-fetch
   and compare the digest. A mismatch or archival failure is a rejection.
3. Define the exact method and an immutable request-shape fingerprint. The
   request must be parameterless or a strictly typed bounded form. Never use a
   broad filter/options map, an inferred default, an expansion option, or a
   generic RPC console.
4. Define an immutable safe response-schema fingerprint. It must select only
   typed display fields and reject every unknown field, nested map, oversized
   list, oversized text value, and credential-shaped value.
5. Confirm the appliance version family and tested role. Record only a
   pass/fail capability and authorization result; do not retain account name,
   role membership, endpoint, certificate, connection ID, request ID, or error
   message.
6. Obtain explicit authorization for the isolated collection session from the
   appliance owner. This authorization is not runtime admission and does not
   authorize mutation.

## Collection-session rules

Use a disposable, trusted collection environment. The procedure permits one
source-backed, read-only observation attempt for the selected tuple only. It
never permits a method discovery sweep, event subscription, shell, file transfer,
mutation, retry loop, or fallback method.

- Keep credentials, API keys, OTP values, password-equivalent material, TLS pins,
  hostnames, ports, and raw response data out of transcripts, screenshots, logs,
  tickets, fixtures, and source control.
- Do not retain request parameters, request IDs, raw JSON, maps, remote error
  text, account information, device identifiers, serials, dataset names, pool
  names, snapshot names, application names, or configuration/schema values.
- If the response is denied, fails, has no observations, contains an unknown
  field, or contains any unsafe value, record only the fixed outcome category
  below and stop. Do not retry or collect a "more complete" payload.
- Do not call a candidate that is outside the current production six-method
  allowlist from the TrueNavo application. The collection environment and
  review package are not a transport exception or runtime-admission decision.

## Retained evidence shape

Only a manually curated, display-only record may leave the collection session.
It must conform to the existing fixture gate shape:

```json
{
  "observations": [
    {
      "label": "<approved fixed display label>",
      "state": "<approved fixed state>",
      "summary": "<approved fixed summary>"
    }
  ]
}
```

This is not a copy or serialization of an appliance response. Each value must be
one of the positive display-schema literals accepted by
[`DeferredObservationContract`](../../apps/truenavo/lib/features/dashboard/deferred_observation_contracts.dart).
The record has at most 50 observations; every display string is at most 160
characters. It must pass the fixture parser and the
[`LiveObservationEvidenceGate`](../../apps/truenavo/lib/features/dashboard/live_observation_evidence.dart),
which retains only bounded typed observations and always reports runtime API
access as disabled.

A failed validation is not remediated by editing around the parser. Discard the
record and mark the tuple rejected or incomplete for separate review.

## A/E/X worksheet

Complete one worksheet for the selected tuple. Use fixed outcome categories and
approved display literals only; never insert raw facts from the appliance.

| Check | Required result | Retained value |
| --- | --- | --- |
| **A — admitted request candidate** | Exact method and request fingerprint match the immutable source artifact; a single read-only attempt is authorized for the tested role. | `pass` or `rejected` only |
| **E — expected safe observation** | At least one safe observation maps to the pre-approved positive display schema and passes bounds/secret rejection. | The typed record above, or `none` |
| **X — excluded path** | Each unsafe expansion, unknown field, secret-shaped value, denial, failure, empty result, or unsupported version is rejected and produces no retained payload. | Fixed category only: `unsupported`, `denied`, `failed`, `empty`, `schema-rejected`, or `secret-rejected` |

A package is incomplete unless A, E, and X each have an outcome. `pass` for A
or E is not approval, and any X outcome does not permit a retry or fallback.

## Review package and retention

The reviewer receives only:

- tuple version family and domain;
- source artifact identifier and digest comparison outcome;
- exact method plus request/response fingerprint identifiers (not parameters or
  response data);
- role/capability pass/fail outcome;
- A/E/X fixed outcome categories; and
- the validated bounded typed record only when E is safe and non-empty.

Delete all collection-session material that is outside this list after the
review package is produced, including terminal history where operationally
possible. Do not store the retained record in production persistence, secure
storage, analytics, issue comments, or source control. Keep it only in the
approved review system for the minimum retention period required by the
appliance owner; access must be limited to the approver.

## Approval boundary

The package feeds step 5–7 of the
[runtime admission gate](C_DEFERRED_RUNTIME_ADMISSION_GATE.md). It is insufficient
on its own. The tuple remains runtime-disabled unless a separate approver sets
`approved: true`, then a **distinct narrow code MR** adds exactly the approved
method and typed adapter, and that MR passes exact-SHA review, CI, and live
re-verification.

## Non-goals

- No collection from an appliance without owner authorization.
- No mutation, shell, file transfer, event subscription, or broad method scan.
- No secret, pin, endpoint, raw payload, identifier, or remote-error retention.
- No production runtime query, UI activation, or persistence change.
