# M1 design: TLS TOFU certificate pinning

> Status: approved planned design — **not a shipped capability**.
>
> Scope: TD-003 / GitLab issue #2. This document is a design and implementation-handoff contract; it makes no claim of live-server interoperability.
>
> Foundations: [TrueDash Design System](./TRUEDASH_DESIGN_SYSTEM.md), [Product Plan](./TRUEDASH_PRODUCT_PLAN.md), and [M1 adaptive shell design](./M1_ADAPTIVE_SHELL_SERVER_PROFILE_DESIGN.md).

## 1. Purpose, scope, and non-goals

TrueDash needs a deliberately narrow way for a native user to trust a self-signed or privately issued server certificate without weakening TLS. The approved approach is two-phase: probe and inspect a certificate without sending credentials, obtain explicit user approval, then make a new TLS connection that is pinned to the approved leaf certificate before any API key is transmitted.

This slice designs certificate inspection, first-use trust-on-first-use (TOFU), stored leaf-certificate pins, and explicit certificate replacement. It applies to Android, iOS, macOS, Windows, and Linux. It does not persist Server Profile metadata or API keys; existing M1 profiles remain process-memory-only.

Non-goals are certificate/CA management, client certificates, automatic renewal acceptance, background reconnect, server discovery, profile persistence, telemetry, a Web workaround, or a generic “ignore TLS errors” option. There is no trust-all mode, arbitrary-certificate acceptance callback, TLS downgrade, hidden bypass, or automatic pin rotation.

## 2. Platform contract

| Platform | Probe / leaf inspection | Explicit pin + fresh reconnect | Storage | UX |
|---|---|---|---|---|
| Android, iOS, macOS, Windows, Linux | Required | Required before credentials | OS secure storage only | First-trust and replacement flows |
| Flutter Web | Browser controls TLS; app cannot inspect or override it | Not available | No app pin | Explain that the certificate must be trusted by browser/OS, then retry |

The UI must use the existing width-based shell: `<600` retains the native `NavigationBar`; `600–999` retains the 72px `NavigationRail`; `>=1000` retains the expanded rail. Trust UI is a route/modal above the connection flow, never a replacement shell. Mobile is a 320px-safe full-screen stepper/sheet; desktop uses a bounded dialog or sheet appropriate at 1000px and above.

## 3. Boundaries and interfaces

The application owns this feature under a future `apps/truedash/lib/features/tls_trust/` boundary. `truenas_api` owns transport mechanics only; `truedash_design_system` remains generic and exposes no TLS domain model. The M1 ServerProfile model and catalog must not receive a certificate, fingerprint, pin decision, or API key.

```text
ConnectionScreen / ConnectionController
  → EndpointAuthorityNormalizer
  → NativeCertificateProbe (no API key; no session/RPC)
  → CertificateTrustCoordinator + TrustPrompt
  → PinStore (OS secure storage: pins only)
  → PinnedTlsConnector (new TLS connection; leaf must match)
  → existing SessionRepository.connect / API-key handshake
```

Suggested contracts:

```text
NormalizedAuthority parseAndNormalize(endpoint)
CertificateProbeResult probe(NormalizedAuthority, timeout)
PinRecord? read(NormalizedAuthority)
void writePendingReplacement(NormalizedAuthority, PinRecord) // transaction intent only
PinnedTransport connectPinned(NormalizedAuthority, PinRecord, timeout)
void commitPinAfterVerifiedReconnect(NormalizedAuthority, PinRecord)
```

`CertificateProbeResult` carries parsed, non-secret certificate facts plus whether platform trust succeeded; it never opens the RPC session. `PinnedTlsConnector` must reject every leaf other than the candidate pin and must also preserve hostname, validity, and protocol checks. A secure-store write is not a successful trust decision until the fresh pinned TLS connection succeeds. An implementation may use platform APIs/adapters, but it must not expose a callback whose default behavior can accept arbitrary certificates.

## 4. Certificate identity and secure-store lifecycle

The pin is `SHA-256(leaf certificate DER)`, rendered as exactly 64 uppercase hexadecimal digits: 16 groups of 4 hex digits (two bytes) for legibility, for example `A4C9 7E12 6B8F 420D 9A31 55C8 0E4D 7F22 918A 3B6E 40D5 7C19 8E2F 6A90 B3CD 11F4`. The UI additionally shows normalized host, subject common name or a concise SAN summary, issuer, `valid from`/`valid until`, and “Platform trust: passed” or “Platform trust: did not pass.” The latter is information, not an override control.

The secure-store key is the canonical normalized authority: `scheme + lowercase IDNA host + explicit/effective port` (for example, `https://nas.home.example:443`). Parsing rejects user info, fragments, unsupported schemes, invalid ports, malformed hosts, and ambiguous normalization. The stored value contains only a versioned algorithm record, such as `{version: 1, leafDerSha256: ..., fingerprintFormat: "SHA-256/DER", createdAt: ...}`. It must not contain an API key, credential reference, ServerProfile metadata, raw certificate bytes, or UI history.

Lifecycle:

1. Read the pin before every native connection attempt.
2. With no pin, run a credential-free probe; after approval, attempt a fresh pinned reconnect. Write/commit the pin only after that reconnect succeeds.
3. With a matching pin, proceed through the pinned connector and only then start the existing API-key handshake.
4. With a different leaf, block all API-key/RPC work and enter replacement review. Keep the old pin active until the new pinned reconnect succeeds.
5. On successful replacement reconnect, atomically overwrite the old record with the new record. On cancellation, timeout, error, app termination, or secure-store failure, preserve the old record.
6. Read/write/delete errors fail closed. A migration reads only recognized record versions/algorithms; unknown or malformed records block connection and request secure-store repair rather than treating the entry as unpinned.

## 5. State machine and data flow

```text
Idle
  → NormalizeAuthority
  → ReadPin
      ├─ store failure / malformed entry → Blocked(store failure)
      ├─ no pin → ProbeWithoutCredentials
      │             ├─ invalid/host/validity/malformed/timeout → Blocked
      │             ├─ cancelled → Idle (no mutation)
      │             └─ approved candidate → FreshPinnedReconnect
      │                                      ├─ failure → Blocked (no pin)
      │                                      └─ success → CommitNewPin → Authenticate
      └─ pin exists → Probe/ConnectPinned
                    ├─ exact leaf + normal TLS checks → Authenticate
                    ├─ different leaf → ReplacementReview
                    │                   ├─ cancel → Blocked; old pin retained
                    │                   └─ approve → FreshPinnedReconnect(candidate)
                    │                                  ├─ failure → Blocked; old retained
                    │                                  └─ success → ReplacePin → Authenticate
                    └─ host/validity/malformed/timeout → Blocked; pin unchanged
Authenticate → existing M0 success/failure flow
```

Only one coordinator may own an authority at a time. A second attempt for the same canonical authority joins the visible in-progress state or is disabled with “Certificate check already in progress”; it cannot create a second prompt or race a replacement. Different authorities may proceed independently. Closing a prompt cancels its probe/reconnect token and invalidates late results. The controller must re-check ownership and candidate fingerprint immediately before commit.

## 6. UI content hierarchy

The supplied mockups are normative for hierarchy, copy, and behavior. Flutter implementation uses existing semantic theme/component tokens rather than literal SVG colors or measurements: `TdPanel`, `TdButton`, `TdTextField`, `TdStateView`, `TdStatusBadge`, semantic warning/critical surfaces, mono typography for authority and fingerprints, and the existing 2px focus treatment.

### First trust

1. Heading: “Review certificate” and host (`nas.home.example:443`) as the context.
2. Warning: “This certificate is not yet pinned to this server.” Explain that no API key has been sent.
3. Facts in this order: platform trust result, subject/SAN, issuer, validity, SHA-256 fingerprint with a labelled Copy fingerprint action.
4. Consequence: approval allows only this certificate for the normalized authority; it does not trust other servers or future replacements.
5. Actions: secondary “Cancel”; primary “Trust certificate and connect.” The primary action is disabled while details are loading and becomes “Verifying pinned connection…” during the fresh reconnect. Success leads to the existing connection/authentication flow, not a fabricated connected state.

### Changed certificate

Use a critical heading: “Certificate changed — connection blocked.” State the authority and that the stored pin does not match. Present **old** and **new** fingerprints side-by-side on desktop and stacked, old then new, on mobile. Include both certificate summaries and the exact warning: “Do not continue unless you expected this replacement.” The explicit action is “Replace pin and connect”; its progress text is “Verifying new pinned connection…”. Cancellation is “Keep existing pin” and preserves it. A failed replacement shows the reason and keeps the old pin.

### Web

Do not present a fingerprint, approval checkbox, pin action, or browser-bypass option. Display: “This browser cannot inspect or override TLS certificates. Install a certificate trusted by your browser or operating system, or fix the server’s certificate, then try again.” Provide Retry and Cancel only. Browser errors are summarized safely; no certificate data is inferred from an untrusted error string.

## 7. Errors, cancellation, and accessibility

All of the following are fail-closed: pin mismatch, host mismatch, expired or not-yet-valid certificate, malformed certificate, cancelled approval, probe timeout, fresh pinned reconnect failure, and secure-store failure. Error copy names the stage and offers only safe remediation: correct the server certificate/host/time, ask an administrator, retry, or keep the existing pin. It never offers “continue anyway.” No API key is handed to any probe, error reporter, or connector until the verified pinned connection has completed.

Every action is at least 44×44 logical pixels with an icon and text label; the Copy action has an accessible name including “SHA-256 fingerprint.” Fingerprint groups are selectable/copyable and have a screen-reader-friendly ungrouped equivalent. `Review certificate` and `Certificate changed — connection blocked` are headings; warning/critical regions are announced once with `liveRegion` semantics without focus theft. Keyboard order is heading → facts → copy → warning → secondary → primary; Esc/Cancel returns focus to Connect. Keep a visible 2px focus ring, 200% text-scale reflow, 320px no-horizontal-overflow behavior, contrast-compliant semantic colors, and reduced-motion behavior. Icons supplement, never replace, warning/critical text.

## 8. Privacy and security threat analysis

| Threat or failure | Required control |
|---|---|
| Active MITM on first contact | User sees the leaf identity/fingerprint; explicit TOFU approval is required; no credential leaves before approval. Document the out-of-band fingerprint verification expectation. |
| MITM or legitimate certificate replacement later | Mismatch blocks by default; old/new comparison and explicit replacement; overwrite only after a fresh pinned reconnect. |
| Host rebinding / equivalent URL ambiguity | Canonical authority includes scheme, lowercased IDNA host, and effective port; normal hostname validation remains required. |
| Stolen local application data | OS secure storage contains only a non-secret certificate pin record, never API keys or profile metadata. |
| Malformed or stale local record | Version/algorithm validation and fail-closed error; no fallback to unpinned behavior. |
| Race/cancel/late probe result | Per-authority coordinator, cancellation tokens, candidate re-check before storage commit. |
| Social engineering via UI | Strong replacement warning, copyable comparison values, no hidden trust control, no automatic rotation. |
| Web platform limitation | Browser/OS trust stays authoritative; application has no TLS inspection/override path. |

## 9. Acceptance criteria and deterministic tests

### A — acceptance

- Native first trust uses a credential-free probe, explicit approval, fresh pinned TLS reconnect, then existing authentication; no API key is sent earlier.
- Pin identity is SHA-256 over leaf DER, displayed in grouped uppercase hex with copy affordance and required certificate facts.
- Canonical authority key and versioned metadata are persisted only in OS secure storage; no API keys or ServerProfile metadata are stored.
- Replacement blocks, compares old/new fingerprints, requires explicit approval, and changes storage only after successful fresh reconnect.
- Mobile/desktop/web copy and hierarchy match the supplied mockups; native navigation remains native.

### E — error and edge cases

- Deterministic fakes cover probe timeout, parse failure, host mismatch, expired/not-yet-valid leaf, malformed leaf, normal trust success/failure, pin mismatch, secure-store read/write failure, fresh reconnect failure, cancellation, late completion, and concurrent same-authority attempts.
- Each case proves fail-closed behavior, zero API-key handoff before verification, and correct old-pin preservation where applicable.
- Canonicalization tests include case folding, IDNA conversion, default/effective ports, explicit ports, invalid authority forms, and distinct scheme/port keys.

### X — excluded behavior

- Tests/static review prove no trust-all path, arbitrary-certificate acceptance callback, TLS downgrade, auto-accept rotation, hidden bypass, API-key persistence, or ServerProfile trust metadata.
- Web tests prove the UI offers no inspection/override/pin action and communicates browser/OS remediation.

Run unit tests with fake clock, deterministic DER fixtures, fake secure storage, and a scripted fake connector that records every API-key handoff. Widget/golden tests cover 320, 390, 600, 1000, and 1440 widths; light/dark; 200% text; keyboard/focus; first trust; replacement; blocked error; and Web explanatory state. Native integration testing is necessarily adapter-specific: platform trust stores and TLS stacks must be tested on Android/iOS/macOS/Windows/Linux emulators or devices with local test CAs and controlled endpoints. Those tests cannot establish browser behavior or production TrueNAS interoperability; a real-device E2E environment, certificate fixture provisioning, and OS secure-storage reset discipline are separate implementation work.

## 10. Implementation handoff boundaries

Implementation may add app-owned trust coordinator, native adapter, secure pin store, UI routes, fixtures, and tests after a separate implementation plan is approved. It must not modify existing design-system token values, alter `truenas_api` into a broad trust policy, persist M1 profile metadata, or add credentials to secure storage in this slice. The existing M0 default TLS path remains the baseline for normal publicly trusted certificates; trust UI is invoked only through the explicit new coordinator. Any request for profile persistence, automatic renewal, CA import, pin deletion UI, background reconnect, browser fallback, or credential persistence is out of scope and needs a new design/threat-model approval.
