# Deferred runtime admission gate

## Current boundary

Runtime reads are currently restricted to this exact allowlist:

- `system.info`
- `pool.query`
- `pool.dataset.query`
- `service.query`
- `alert.list`
- `core.get_jobs`

The authenticated session's **dashboard runtime query API** accepts only those
methods, and the dashboard maps only those methods to enabled features.
Connection bootstrap uses separate authentication/identity/capability calls;
those are not admissions for dashboard observation reads. See
[dashboard capabilities](../../apps/truedash/lib/features/dashboard/dashboard_capabilities.dart),
[session repository](../../packages/truenas_api/lib/src/session/true_nas_session_repository.dart),
and [deferred fixture contracts](../../apps/truedash/lib/features/dashboard/deferred_observation_contracts.dart).

VDEV, disk, snapshot, and apps observations are fixture-only and runtime-disabled
today, for every version family. Fixture parsing and evidence eligibility do not
enable an API capability; see [live observation evidence](../../apps/truedash/lib/features/dashboard/live_observation_evidence.dart).

Source-backed candidate method facts are recorded in the
[deferred contract discovery ledger](C_DEFERRED_CONTRACT_DISCOVERY_LEDGER.md).
A documented candidate is not an admission: it does not establish a safe request
shape, response-schema fingerprint, RBAC behavior on a real appliance, or
permission to call the method. Do not guess, infer, or recommend a concrete
method beyond the exact source-backed candidate tuple.

## Unit of admission

An admission is scoped to one immutable tuple:

`(version family, domain, exact method, request-shape fingerprint, response-schema fingerprint)`

Version families are `25.04`, `25.10`, and `26+`; domains are `VDEV`, `disk`,
`snapshot`, and `apps`. A fingerprint identifies the exact typed contract,
including its allowed request form or safe output schema and bounds. Evidence,
tests, capability findings, and approval for one tuple never transfer to another
tuple—even when the method name, appliance, or display looks similar.

The version classification is presentation-only and grants no RPC method.
Runtime method metadata can assist discovery but is not a stable cross-version
contract; these protocol statements are sourced in
[TrueNAS API research](../research/TRUENAS_API_RESEARCH.md) [1][8][12].

## Fail-closed admission sequence

Every gate is ordered and mandatory. Failure, absence, ambiguity, or an
out-of-scope result stops the tuple; it remains runtime-disabled.

1. **API docs/source contract intake.** Record immutable, version-specific
   documentation and/or source evidence for the exact method and shape. Missing
   documentation rejects the tuple.
2. **Safe request model.** Define a parameterless or strictly typed, bounded
   request model. No broad passthrough, raw parameter map, or inferred default.
3. **RBAC/capability proof.** Prove that the intended read is advertised and
   authorized for the tested role. A capability mismatch or authorization
   failure rejects it. RBAC is evaluated per call, as sourced in the research
   [11].
4. **Static typed fixture contract.** Define and test the bounded display-only
   output shape before live use. Schema drift, list/map/text bound breaches, or
   secret-like content reject it.
5. **Redacted live evidence.** Capture only safe typed observations; no raw
   transport or payload artifacts are retained.
6. **Version/domain test matrix.** Exercise the exact tuple for its version
   family and domain, including supported, partial, denied, failed, and
   no-observation outcomes. The planning matrix identifies the deferred product
   areas: [capability matrix](TRUEDASH_CAPABILITY_MATRIX.csv).
7. **Separate approval.** Review a complete approval record for this tuple.
   Evidence eligibility is not approval.
8. **Narrow code change.** In a distinct code MR, add only the approved exact
   method and typed adapter; do not widen generic transport access.
9. **Exact-SHA review/CI.** Review the code and immutable evidence/source SHAs,
   then pass CI against the exact tuple.
10. **Live A/E/X verification.** Verify live **A**dmitted, **E**xpected safe
    observation, and **X**cluded unsafe/unsupported paths for that tuple.

## Evidence and outcomes

Evidence may retain only safe, typed observation output. It must not retain raw
JSON or maps; error text; endpoint or host; TLS pins; account data; request IDs;
method parameters; credential-like data; or identifiers/serials. Reject any
secret-like data regardless of field name. A failed response or no observed data
also rejects evidence.

Accept a tuple only when every gate passes, the response is successful, at least
one safe observation is present, all bounds hold, and approval is explicitly
true. Reject it for an unknown version, missing docs, capability mismatch,
authorization failure, schema drift, list/map/text bounds breach, any
secret-like data, failed response, or no observed data.

The UI must distinguish unsupported, partial, and failed requests. None may be
presented as “API unavailable”: unsupported means no admitted tuple; partial
means an admitted request produced incomplete safe observations; failed means
the request did not complete safely. Do not expose remote error text.

## Approval record template

```markdown
## Deferred runtime admission: <tuple id>

- [ ] approved: false  <!-- default; set true only after every item below -->
- [ ] version family: 25.04 | 25.10 | 26+
- [ ] domain: VDEV | disk | snapshot | apps
- [ ] exact method: <source-backed name>
- [ ] request-shape fingerprint: <immutable digest/id>
- [ ] response-schema fingerprint: <immutable digest/id>
- [ ] immutable API docs/source link and SHA/version identifier recorded
- [ ] safe typed request model reviewed
- [ ] RBAC and runtime capability proof recorded
- [ ] static fixture contract and bounds tested
- [ ] redacted live evidence contains safe typed observations only
- [ ] version/domain matrix covers A/E/X and failure cases
- [ ] separate approver and approval date recorded
- [ ] distinct code MR updates the six-method allowlist for this exact tuple
- [ ] exact code SHA reviewed and CI passed

Source record: <immutable repository/docs link, SHA, and version only>
Evidence record: <redacted typed-observation artifact identifier only>
Approval: <approver, date, rationale>
```

Do not place secrets, credentials, endpoints, pins, account data, request
identifiers, parameters, raw payloads, identifiers, or serials in this record.
`approved` is `false` by default. Runtime access remains disabled unless every
field is met **and** a distinct code MR updates the six-method allowlist after
approval.

## Non-goals

- No mutation.
- No auto-retry of uncertain calls.
- No credential or pin persistence.
- No generic raw-payload renderer.
- No UI activation by fixture or evidence.
