# Native notification providers

This workspace implements a bounded non-Mail `alertservice` lifecycle for stable TrueNAS 25.10, using the released [25.10.1 discriminated provider schema](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/alertservice_attributes.py). Mail notification services, SMTP settings and alert-class policies remain separate workflows.

## Supported variants

| Provider | Native variant / reviewed destination |
| --- | --- |
| Slack | HTTPS webhook; only hostname and opaque keyed reference displayed |
| Mattermost | HTTPS webhook, display username/channel, optional protected HTTPS icon URL |
| Telegram | Bot token and 1–32 unique exact signed chat IDs; partial multi-recipient delivery is possible |
| PagerDuty | Private integration key, client name; source-defined legacy events endpoint |
| OpsGenie | Private API key and optional protected HTTPS base URL; blank selects the source default |
| VictorOps | Private API/routing keys restricted to path-safe characters; no raw private endpoint display |
| Amazon SNS | Exact topic ARN and matching region; both access-key ID and secret key protected |
| InfluxDB | Source-fixed port 8086, without TLS; separate plaintext disclosure consent before enable |
| SNMP trap | IPv4/DNS UDP v2c only; community protected locally but transmitted unencrypted; separate consent |

SNMP v3, mixed legacy SNMP fields, unknown providers, unknown attributes and masked or unprovable credentials are not writable here. This is explicit partial variant coverage, not a claim that every WebUI form variant has been ported. Current titles are read-only hints; a selected row's actual discriminator and complete attributes are verified privately before any write.

For new/replacement and enable operations, secret-bearing URLs must already be canonical HTTPS: lowercase scheme/hostname, an explicit absolute path (use `/` when needed), no explicit default port, userinfo, fragment, whitespace, backslash, dot segments or percent-encoded variants. This narrower subset prevents a known successful write from becoming an unknown result merely because server URL normalization changed the returned value. Existing supported HTTP rows may be disabled/deleted without rewriting their URL; they cannot be enabled here. Credentials are capped at 1024 printable ASCII characters and cannot be redaction placeholders. Other field bounds and enums are compiled, not learned from arbitrary server forms.

## Deliberate workflow

Creation always sends `enabled:false`. Replacement is allowed only after a separate disable, requires every compiled public field and fresh credential, cannot convert provider type, and never silently keeps omitted credentials. Enable, disable and disabled-only delete each require a separate single-use exact-target review. The server requires a complete create-style update envelope; every update explicitly supplies name, severity, attributes and enabled state. No partial-wire patch is claimed.

The native editor never prefills stored secrets. It clears and disposes actual input controllers on provider switches, handoff, cancellation, lifecycle loss, session replacement and unrelated route coverage. Input is handed to a private byte-backed credential capsule with no raw getter. Capsule buffers are zeroed best-effort on expiry/rejection/abandonment, execution completion, reload and session close. Managed-language input/encoding strings and OS keyboard copies cannot be guaranteed erased from memory; there is no persistent credential cache, log, clipboard action or raw-JSON editor in this workflow.

Inventory requests select public service headers only. Review/execute privately read attributes solely for the exact selected ID plus exact provider discriminator; they never request all-provider secret attributes. A per-session random HMAC key binds private attributes, public readiness and header drift. Reviews expose compiled nonsecret fields, exact nonsecret recipients where available, and sanitized destination hostnames. Opaque destination references use that private HMAC key, not a public password hash; they bind a review but prove neither destination ownership nor remote attestation.

## Authorization and uncertainty

SDK reviews expire after five minutes and are consumed once. Server identity, boot identity, readiness, full-administrator role, version, unchanged boot environment and visible job conflicts are rechecked. Final caller/lifecycle authorization and credential validity are checked throughout awaited preflight and immediately before dispatch. The shared SDK/app operation fences prevent competing mutations. Checks are bounded and non-atomic; there is no claim of atomic coordination with other administrators or background alert processing.

After a write, the expected full response and complete affected-row readback must match; deletion requires a true response and verified absence. A timeout, response/hook error, mismatched readback or lost authorization after invocation is **unknown**, not rollback. Unknown permanently fences this SDK session. No provider test, SMTP test, probe, forced delivery, job polling, retry, automatic reconnect or replay occurs.

The app retains its unresolved write fence across route changes and manual reconnections. Recovery requires a fresh manually authenticated session at the original endpoint, an explicit read verifying the same claimed full host ID and readiness, then an independent-inspection acknowledgment. The old pending invocation must settle first. That acknowledgment releases only the app fence; it does not establish the earlier write's result or any delivery result. Restarting the app is not durable recovery evidence.

## Outbound effects

The [pinned notification implementations](https://github.com/truenas/middleware/tree/TS-25.10.1/src/middlewared/middlewared/alert/service) can disclose formatted alerts and system identifiers after a service is enabled. Cleared alerts can resolve external incidents. Disabling/deleting cannot recall messages, cancel already-running calls, resolve all open incidents or globally mute separate alert paths. Existing alerts need not be replayed. Provider libraries and background batching have their own behavior; Mail's queue semantics are not generalized to other providers.

The app's NAS certificate pin does not secure server-to-provider traffic. HTTPS configuration does not prove recipient ownership; HTTP clients can follow redirects. SNS topic subscriptions and fan-out recipients are unverified. Mattermost may cause an additional icon fetch. InfluxDB and SNMP v2c explicitly expose credentials/data without transport encryption; SNMP can log a delivery error without raising it. Enabling requires explicit external-disclosure consent and, for those two plaintext variants, an additional controller-enforced plaintext consent.

Charts show configured enabled/disabled flags and provider/severity row counts, including disabled rows. They are not alert frequencies, delivery success rates, queue depth or notification coverage. Tests and previews use synthetic transports only; no NAS or external provider is contacted.
