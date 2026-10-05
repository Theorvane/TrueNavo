# M1 TLS TOFU certificate pinning implementation plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

> Status: implementation handoff for the approved design only. This is not evidence of server interoperability or of native-platform validation.

**Goal:** Add native, per-authority TLS trust-on-first-use for self-signed/private certificates without ever sending an API key before an explicit approval and a separate, successfully pinned TLS reconnect. Keep pins only in OS secure storage, retain all existing M1 profile/API-key memory-only behavior, and leave Web under browser/OS TLS trust only.

**Architecture:** Put the app-owned policy boundary in `apps/truenavo/lib/features/tls_trust/`: pure canonical-authority, `PinRecord`, certificate-fact, and coordinator state-machine code sits above injected `PinStore`, `NativeCertificateProbe`, and `PinnedRpcConnector` ports. Native-only implementations are selected with conditional imports; the Web implementation has no inspection, storage, or bypass port. The probe owns a one-use TLS handshake and can return parsed certificate facts only; it exposes neither a socket nor send/RPC methods, sends no application frames or credentials, and closes immediately after capture. The pinned connector establishes a new TLS connection, verifies the candidate leaf before its WebSocket HTTP upgrade/application frames, then supplies the existing RPC transport; it is the only route from approval to `TrueNasSessionRepository.connect`. `ConnectionController` calls the coordinator before it hands the API key to the repository. `truenas_api` keeps its normal platform-validated connector as the public-trust baseline and never becomes a general trust-policy API.

**Tech Stack:** Flutter 3.47.0 / Dart 3.13 (`.fvmrc`), `flutter_riverpod` 3.4.2 locked under `>=3.0.3 <4.0.0`, Material 3, existing `truenavo_design_system`, Dart `dart:io` only behind native conditional imports, FVM, `flutter_test`/`test`, GitLab CI and `glab`. At planning time there is no secure-storage dependency. `flutter_secure_storage` 11.0.0 is currently available and supports the target platforms, but its current Windows implementation documents encrypted files rather than Windows Credential Manager; it must not be selected unless the dependency decision task proves the exact platform backend satisfies this plan's OS-store requirements.

## Operating rules and non-negotiable boundaries

- Work from a protected `feat/tls-tofu-pinning` source branch based on current `main`; this planning branch is not an implementation branch. Run `git status --short --branch`, `git fetch origin main`, `git merge-base --is-ancestor origin/main HEAD`, and `fvm doctor` before implementation. Do not amend unrelated work, merge/rebase someone else's work, push secrets, or delete any remote branch without the user's explicit approval.
- Every task is TDD: add the stated narrow test first, run its RED command and record the actual failure, make only the stated implementation change, then run its GREEN and focused regression commands. Use deterministic fake clock, DER fixtures, store, probe, and connector in unit/widget tests; no test uses live TrueNAS, Internet endpoints, personal certificates, or real API keys. Use the sentinel `test-api-key` only, and assert it never appears in errors, UI state, storage values, probes, or logs.
- A native probe is a separate, capability-limited API: `Future<CertificateProbeResult> probe(NormalizedAuthority, CancellationToken)`. It is not an `RpcConnector`, returns no `Socket`/`SecureSocket`/transport, has no `send`, URL, header, or credential parameter, closes in `finally` immediately after TLS certificate capture, and must not perform an HTTP/WebSocket upgrade or send application frames. Its temporary certificate-exception decision is scoped to that one probe object and is never reusable by a connector.
- A pinned reconnect is a fresh native TLS+WebSocket connection. If a platform callback is necessary, it returns `true` only after candidate leaf-DER SHA-256 equality **and** required hostname and validity checks; every other callback result is `false`. The connector must check a publicly trusted leaf too before upgrade/application data. Normal unpinned/publicly trusted M0 connections remain platform-validated and have no acceptance callback.
- Fail closed on malformed authority/record/certificate, hostname mismatch, expired/not-yet-valid leaf, mismatch, probe/reconnect timeout, cancellation, store read/write/atomic-commit failure, or late result. There is no trust-all setting, certificate/CA import, TLS downgrade, automatic rotation, broad bad-certificate callback, logging/analytics of certificate/API-key data, profile pin metadata, API-key persistence, or browser workaround.
- Use `TdPanel`, `TdButton`, `TdTextField`, `TdStateView`, `TdStatusBadge`, semantic theme colors, mono typography, existing spacing/sizing, and the existing focus treatment. Do not change design-system token values or replace the existing `<600` `NavigationBar`, `600–999` 72px `NavigationRail`, or `>=1000` extended rail.

## Sequential implementation tasks

### Task 1 — Lock the app-facing pure trust vocabulary

**Files:**

- Create `apps/truenavo/lib/features/tls_trust/models.dart`
- Create `apps/truenavo/test/features/tls_trust/models_test.dart`

**RED:** Add table-driven tests for `NormalizedAuthority`, version-1 `PinRecord`, uppercase 64-hex `leafDerSha256`, grouped fingerprint display, non-secret certificate facts, and typed failure states. Cover lowercased host, IDNA host, default/effective port, explicit port, distinct scheme/port keys, user-info/query/fragment/unsupported scheme/invalid port/malformed-host rejection, malformed/unknown pin records, and equality.

```sh
(cd apps/truenavo && fvm flutter test test/features/tls_trust/models_test.dart)
```

Expected failure: the `tls_trust` model API does not exist.

**Minimal GREEN:** Make the authority parser accept only the M0 secure input forms and canonically key `scheme://lowercase-idna-host:effective-port`; retain the M0 RPC endpoint path separately, not in the pin key. Represent a pin as only `{version, leafDerSha256, fingerprintFormat, createdAt}` with `fingerprintFormat == 'SHA-256/DER'`; reject rather than coerce invalid JSON/algorithm/digest. Keep raw DER out of `PinRecord`, `ServerProfile`, and error strings.

```sh
(cd apps/truenavo && fvm flutter test test/features/tls_trust/models_test.dart)
fvm dart format apps/truenavo/lib/features/tls_trust apps/truenavo/test/features/tls_trust
```

### Task 2 — Decide and prove the OS pin-store mechanism before adding a package

**Files:**

- Modify `apps/truenavo/pubspec.yaml` and root `pubspec.lock` only if a selected implementation actually needs a package
- Create `apps/truenavo/lib/features/tls_trust/pin_store.dart`
- Create `apps/truenavo/test/features/tls_trust/pin_store_test.dart`
- Modify platform files only after the selection checklist passes: `apps/truenavo/android/app/src/main/AndroidManifest.xml`, `apps/truenavo/macos/Runner/DebugProfile.entitlements`, `apps/truenavo/macos/Runner/Release.entitlements`, and any generated platform registration files produced by the supported Flutter tool

**RED:** Test an in-memory `PinStore` contract: absent/read, recognized write/read, replacement staging with old record still readable, atomic commit, abort, malformed-store value, and read/write/delete error all return typed failures without silently treating data as no pin. Test that serialization contains only the four `PinRecord` fields and canonical authority key, not the sentinel API key or profile fields.

```sh
(cd apps/truenavo && fvm flutter test test/features/tls_trust/pin_store_test.dart)
```

Expected failure: no store port/transaction semantics exist.

**Minimal GREEN and dependency decision:** Add the port plus deterministic in-memory fake first. Then evaluate the currently available `flutter_secure_storage` 11.0.0 API in a throwaway, non-committed spike against Flutter 3.47/Dart 3.13. Reject it for this feature if its exact Windows backend cannot meet Windows credential-protection policy (current package release notes say encrypted files), or if Web storage could be selected. Prefer a small app-owned native channel/FFI adapter when needed: Android Keystore-backed encrypted storage, iOS/macOS Keychain, Windows Credential Manager/DPAPI-backed credential protection, and Linux Secret Service/libsecret. Do not invent a package API or claim a backend is credential-protected without a platform test. If a dependency is selected, pin its reviewed compatible version exactly in `apps/truenavo/pubspec.yaml`, run `fvm flutter pub get` to update only `pubspec.lock`, review its platform registrations, and re-run the contract tests.

Set platform requirements in the selected adapter/setup and test them: Android must use authenticated encrypted storage and disable/exclude cloud backup per the selected backend; macOS must retain network-client entitlement and add the required Keychain access-group capability in both existing entitlements; iOS must use the app Keychain and add its required Keychain entitlement/capability if the selected API requires it; Windows must demonstrate the chosen credential-protection store; Linux packaging/build documentation must require `libsecret` development/runtime plus a Secret Service/keyring; Web must provide an unsupported/no-op implementation that performs no storage operation. Do not add a pin deletion UI.

```sh
(cd apps/truenavo && fvm flutter test test/features/tls_trust/pin_store_test.dart)
(cd apps/truenavo && fvm flutter analyze)
```

**Checkpoint commit:** `feat(tls): OS pin store contract and platform setup`.

### Task 3 — Create deterministic certificate fixtures and parsing policy

**Files:**

- Create `apps/truenavo/test/features/tls_trust/fixtures/certificates.dart`
- Create `apps/truenavo/test/features/tls_trust/certificate_facts_test.dart`
- Create `apps/truenavo/lib/features/tls_trust/certificate_facts.dart`

**RED:** Use checked-in, non-production DER byte fixtures for a valid host-matching leaf, a changed leaf, an expired leaf, a not-yet-valid leaf, a hostname-mismatching leaf, and malformed bytes. Assert SHA-256 is calculated over DER independently from the fixture's advertised string, exact uppercase 64 hex is required, CN/SAN summary/issuer/validity are concise, and malformed, invalid-time, and hostname failure never yield an approvable candidate.

```sh
(cd apps/truenavo && fvm flutter test test/features/tls_trust/certificate_facts_test.dart)
```

Expected failure: no certificate fact/parser policy exists.

**Minimal GREEN:** Implement a narrow parser/validator interface whose native adapter supplies leaf DER and parsed SAN/CN facts; validate clock interval and normalized authority hostname before producing `CertificateProbeResult.approvable`. Do not use error-string parsing, record raw DER in state, or implement a permissive hostname matcher. Store only fixture source bytes needed to make tests deterministic.

```sh
(cd apps/truenavo && fvm flutter test test/features/tls_trust/certificate_facts_test.dart)
```

### Task 4 — Establish the safe native TLS capability boundary

**Files:**

- Create `apps/truenavo/lib/features/tls_trust/native_tls_ports.dart`
- Create `apps/truenavo/lib/features/tls_trust/native_tls_stub.dart`
- Create `apps/truenavo/lib/features/tls_trust/native_tls_io.dart`
- Create `apps/truenavo/lib/features/tls_trust/native_tls_web.dart`
- Create `apps/truenavo/test/features/tls_trust/native_tls_ports_test.dart`

**RED:** With scripted fake native backends, prove a probe receives only authority/timeout/cancellation, captures facts, emits zero application frames, exposes no transport, and always closes; prove a reconnect starts a second handshake and refuses mismatched, bad-host, expired, malformed, timeout, and cancellation cases before the fake records an upgrade/frame/API-key handoff. Assert a normal trusted connection follows platform validation and does not invoke a certificate-acceptance callback.

```sh
(cd apps/truenavo && fvm flutter test test/features/tls_trust/native_tls_ports_test.dart)
```

Expected failure: the bounded probe/pinned connector ports and conditional implementations do not exist.

**Minimal GREEN:** Define separate `NativeCertificateProbe` and `PinnedRpcConnector` ports plus a test-only scripted backend. On Web, return a typed browser-managed-TLS result and expose neither certificate bytes/fingerprint nor an approval method. On non-IO unsupported test targets, fail closed. The IO file may import `dart:io`; no Web-reachable library may import it. Do not connect this port to `RpcConnector` yet.

```sh
(cd apps/truenavo && fvm flutter test test/features/tls_trust/native_tls_ports_test.dart)
(cd apps/truenavo && fvm flutter build web --release)
```

### Task 5 — Implement and audit the native probe, not a reusable bypass

**Files:**

- Modify `apps/truenavo/lib/features/tls_trust/native_tls_io.dart`
- Create native bridge sources under `apps/truenavo/android/app/src/main/kotlin/com/truenavo/truenavo/`, `apps/truenavo/ios/Runner/`, `apps/truenavo/macos/Runner/`, `apps/truenavo/windows/runner/`, and `apps/truenavo/linux/runner/` only for the selected bridge design
- Create `apps/truenavo/test/features/tls_trust/native_certificate_probe_test.dart`

**RED:** Add fake-bridge tests for one bounded TLS handshake per probe, immediate close after leaf capture, no HTTP/WebSocket/RPC bytes, no credential argument, cancellation/timeout cleanup, and host/validity/malformed failure. Add a static source scan test/script that fails if probe types implement/import `RpcConnector`, return sockets/transports, or expose `send`/`apiKey` parameters.

```sh
(cd apps/truenavo && fvm flutter test test/features/tls_trust/native_certificate_probe_test.dart)
```

Expected failure: native probe/bridge contract is absent.

**Minimal GREEN:** Implement the selected native bridge so it parses/captures the leaf and enforces hostname and validity policy before it returns an approvable result. A temporary certificate callback, where platform APIs require one to obtain an otherwise-untrusted leaf, belongs to this one-shot handshake only and may not outlive it; it cannot send frames and closes in `finally`. A `dart:io` feasibility check alone is insufficient where it cannot verify SAN hostname or prevent a WebSocket upgrade before pin decision; keep the bridge below that boundary. Document each platform's trusted/public path and fail closed when its runner cannot provide the required facts.

```sh
(cd apps/truenavo && fvm flutter test test/features/tls_trust/native_certificate_probe_test.dart)
(cd apps/truenavo && fvm flutter analyze)
! rg -n --glob '*.dart' 'class .*Probe.*RpcConnector|Future<(RpcTransport|SecureSocket|Socket)> probe|probe\([^)]*(apiKey|headers|frame)' apps/truenavo/lib/features/tls_trust
```

### Task 6 — Implement fresh exact-pin reconnect before WebSocket/API-key work

**Files:**

- Modify `apps/truenavo/lib/features/tls_trust/native_tls_io.dart`
- Modify the selected native bridge sources from Task 5
- Create `apps/truenavo/test/features/tls_trust/pinned_rpc_connector_test.dart`

**RED:** Script a successful probe followed by a reconnect whose leaf is equal, changed, valid-public, host-mismatched, expired, malformed, or times out. Assert only exact SHA-256 leaf DER equality plus hostname/validity permits the WebSocket upgrade; assert the callback returns false for every non-match; assert public trust still uses platform validation; assert no API-key/RPC frame precedes the completed reconnect.

```sh
(cd apps/truenavo && fvm flutter test test/features/tls_trust/pinned_rpc_connector_test.dart)
```

Expected failure: there is no exact-pin connector or pre-upgrade gate.

**Minimal GREEN:** Make the bridge perform a fresh connection, compare candidate digest before it upgrades/supplies an `RpcTransport`, and preserve platform TLS protocol/hostname/validity checks. Do not reuse the probe connection. If a native exception callback exists, its only `true` branch is exact candidate digest equality after required checks; its default and every unmatched branch are false. Keep `packages/truenas_api/lib/src/transport/web_socket_connector.dart` unchanged as the normal platform-trust path.

```sh
(cd apps/truenavo && fvm flutter test test/features/tls_trust/pinned_rpc_connector_test.dart)
(cd packages/truenas_api && fvm dart test)
```

**Checkpoint commit:** `feat(tls): bounded native TLS probe and exact pin reconnect`.

### Task 7 — Make the per-authority trust state machine race-safe

**Files:**

- Create `apps/truenavo/lib/features/tls_trust/certificate_trust_coordinator.dart`
- Create `apps/truenavo/test/features/tls_trust/certificate_trust_coordinator_test.dart`

**RED:** Exercise the approved state graph with fakes: no-pin probe → approval → fresh reconnect → commit → authenticated-ready; matching stored pin → pinned-ready; changed leaf → replacement review; cancelled/timeout/malformed/store/reconnect failure; and normal platform trust fact display. Assert read occurs before each native attempt, old pin remains through every failed/cancelled replacement, commit is after fresh success only, store failure blocks, and candidate+ownership are rechecked immediately before commit. Add concurrent same-authority attempts (one visible operation/join or disabled second action), different-authority independence, cancellation plus late completion, and zero API-key handoff before `PinnedReady`.

```sh
(cd apps/truenavo && fvm flutter test test/features/tls_trust/certificate_trust_coordinator_test.dart)
```

Expected failure: coordinator/state/cancellation ownership do not exist.

**Minimal GREEN:** Implement an injected-clock, per-canonical-authority coordinator with opaque operation tokens and explicit `approve`, `cancel`, `retry`, and `commit` transitions. It returns a verified connector/session capability only after reconnect, never an approval boolean that callers could misuse. Replacement staging is internal transaction intent; only `commitPinAfterVerifiedReconnect` atomically overwrites old data.

```sh
(cd apps/truenavo && fvm flutter test test/features/tls_trust/certificate_trust_coordinator_test.dart)
(cd apps/truenavo && fvm flutter test test/features/tls_trust)
```

### Task 8 — Integrate Riverpod and authentication without moving secret boundaries

**Files:**

- Modify `apps/truenavo/lib/features/connection/connection_controller.dart`
- Modify `apps/truenavo/lib/features/connection/connection_state.dart`
- Create `apps/truenavo/lib/features/tls_trust/tls_trust_providers.dart`
- Create `apps/truenavo/test/features/connection/connection_controller_tls_test.dart`

**RED:** Override coordinator, connector, store, and repository providers in a `ProviderContainer`. Assert first trust/replacement starts with no repository call; a repository observes `test-api-key` only after verified connector completion; existing profile registration occurs only after normal repository success; secure-store payloads and `ServerProfile` never contain the sentinel/pin; and Web routes only to browser-managed explanatory state.

```sh
(cd apps/truenavo && fvm flutter test test/features/connection/connection_controller_tls_test.dart)
```

Expected failure: connection controller still sends its API key straight to the repository.

**Minimal GREEN:** Add overrideable providers and extend connection state with typed trust-review/blocked/Web states. Parse/normalize before prompt; delegate native flow to the coordinator; inject the verified pinned connector into the existing repository factory only after approval/reconnect. Preserve existing public certificate behavior through the normal connector. Do not store credentials, alter `ServerProfile`, or add logging.

```sh
(cd apps/truenavo && fvm flutter test test/features/connection/connection_controller_tls_test.dart test/features/connection/connection_screen_test.dart)
(cd apps/truenavo && fvm flutter analyze)
```

### Task 9 — Add first-trust, replacement, and Web UI as an overlay on the native shell

**Files:**

- Modify `apps/truenavo/lib/features/connection/connection_screen.dart`
- Create `apps/truenavo/lib/features/tls_trust/trust_review.dart`
- Create `apps/truenavo/test/features/tls_trust/trust_review_test.dart`
- Create `apps/truenavo/test/features/tls_trust/trust_review_accessibility_test.dart`

**RED:** Widget tests assert exact approved headings/actions/copy: first trust has facts in approved order, `Copy fingerprint`, Cancel, and `Trust certificate and connect`; replacement has critical heading, authority, old/new summaries/fingerprints, exact warning, `Keep existing pin`, and `Replace pin and connect`; progress disables the primary action. Web has only the approved browser/OS remediation, Retry, and Cancel—no fingerprint, pin, checkbox, or bypass. Test 320/390/600/1000/1440 widths, light/dark, 200% text, no horizontal overflow, 44px targets, selectable grouped fingerprint plus ungrouped semantic value, live warning announced once, heading semantics, prescribed keyboard order, 2px focus ring, Esc/Cancel focus restoration, and reduced motion.

```sh
(cd apps/truenavo && fvm flutter test test/features/tls_trust/trust_review_test.dart test/features/tls_trust/trust_review_accessibility_test.dart)
```

Expected failure: the trust route/modal and accessibility contract do not exist.

**Minimal GREEN:** Render trust UI as a route/modal above `ConnectionScreen`; use full-screen safe 320px step/sheet on mobile and bounded dialog/sheet at desktop widths. Use only current design-system components/tokens, preserve `AdaptiveShell` navigation untouched, expose safe stage-specific remediation only, and never construct a connected success UI before the existing authentication flow succeeds.

```sh
(cd apps/truenavo && fvm flutter test test/features/tls_trust/trust_review_test.dart test/features/tls_trust/trust_review_accessibility_test.dart test/features/connection)
```

**Checkpoint commit:** `feat(tls): trust coordinator connection flow and accessible review UI`.

### Task 10 — Test platform stores and TLS bridges outside deterministic CI

**Files:**

- Create `apps/truenavo/integration_test/tls_tofu_native_test.dart`
- Create `apps/truenavo/integration_test/support/local_tls_fixture/` (fixture generator/configuration only; never production certificates)
- Create `docs/evidence/M1_TLS_TOFU_PINNING_EVIDENCE.md` only after the tests are actually run

**RED:** On each available native runner, run the integration test first and capture its failure as unavailable runner/fixture/setup versus product defect; do not mark unavailable platforms passed.

```sh
fvm flutter devices
test -n "${TLS_TOFU_DEVICE_ID:-}" && (cd apps/truenavo && fvm flutter test integration_test/tls_tofu_native_test.dart -d "$TLS_TOFU_DEVICE_ID")
```

Expected failure: before adapter and local fixture provisioning, the native test cannot complete the controlled TLS scenario.

**Minimal GREEN:** Against a local controlled endpoint/CA, verify Android, iOS, macOS, Windows, and Linux separately where SDK/runners exist: public normal validation; self-signed first trust; exact reconnect before API-key test endpoint observes a credential; mismatch block; approved replacement preserves old record until successful atomic commit; reset/reinstall storage discipline; and actual backend access (Android encrypted storage, iOS/macOS Keychain and entitlements, Windows credential protection, Linux libsecret/keyring). Test browser separately only for its explanatory no-override UI. Record command, device/OS, fixture identity, result, and limitations in evidence; an absent iOS/Windows/Linux runner stays explicitly unverified. Never run these live endpoints in shared CI.

```sh
test -n "${TLS_TOFU_DEVICE_ID:-}" && (cd apps/truenavo && fvm flutter test integration_test/tls_tofu_native_test.dart -d "$TLS_TOFU_DEVICE_ID")
```

### Task 11 — Run static security review, full verification, and GitLab handoff

**Files:**

- Modify `.gitlab-ci.yml` only if a portable static scan/test command cannot be represented by the existing `portable_quality_and_web` job
- Create `apps/truenavo/test/security/tls_tofu_static_review_test.dart`
- Modify `docs/evidence/M1_TLS_TOFU_PINNING_EVIDENCE.md` only with observed evidence

**RED:** Add CI-safe scans that intentionally fail on a controlled local bad pattern before committing them: source paths containing `badCertificateCallback` returning unconditional `true`, `acceptBadCertificates`, `SecurityContext(withTrustedRoots: false)`, `HttpOverrides.global`, `ws://`/`http://` TLS downgrade, `API_KEY_PLAIN` outside the post-verified repository route, pin/profile/API-key persistence, telemetry/logging, and Web pin/override controls. Use structural tests too; scans are review backstops, not the security proof.

```sh
(cd apps/truenavo && fvm flutter test test/security/tls_tofu_static_review_test.dart)
```

Expected failure: the static-review test has not been created.

**Minimal GREEN:** Commit a narrowly scoped CI script/test with allowlisted literals only where the normal M0 UI/test fixtures need them; make it fail closed on a trust bypass, storage of API/profile fields, or Web inspection action. Update `.gitlab-ci.yml` only to invoke the portable checks already runnable on shared Linux; do not pretend it runs native integration hardware. Add the A/E/X mapping below to the merge-request description and evidence.

```sh
fvm dart format --output=none --set-exit-if-changed packages/truenas_api packages/truenavo_design_system examples/design_system_consumer apps/truenavo
( ! rg -n --glob '*.dart' 'HttpOverrides\.global|withTrustedRoots:\s*false|acceptBadCertificates|badCertificateCallback\s*=\s*\([^)]*\)\s*=>\s*true|ws://|http://' apps/truenavo/lib packages/truenas_api/lib )
! rg -n --glob '*.dart' '(print\(|debugPrint\(|Logger\(|analytics|telemetry)' apps/truenavo/lib/features/tls_trust
(cd packages/truenas_api && fvm dart analyze && fvm dart test)
(cd packages/truenavo_design_system && fvm flutter analyze && fvm flutter test)
(cd examples/design_system_consumer && fvm flutter analyze && fvm flutter test)
(cd apps/truenavo && fvm flutter analyze && fvm flutter test && fvm flutter build web --release)
(cd apps/truenavo && fvm flutter build macos --release)
codesign --verify --deep --strict apps/truenavo/build/macos/Build/Products/Release/truenavo.app
codesign -d --entitlements :- apps/truenavo/build/macos/Build/Products/Release/truenavo.app 2>/dev/null | plutil -convert json -o - - | python3 -c "import json,sys; e=json.load(sys.stdin); assert e.get('com.apple.security.network.client') is True; assert 'keychain-access-groups' in e"
git diff --check
```

**Checkpoint commit:** `test(tls): enforce pinning boundaries and verification` (and a separate `docs(tls): record observed evidence` only if evidence exists).

Open/update GitLab issue #2 and create an MR from the protected feature branch to `main`; do not target a stale feature branch. Push only after local checks pass, wait for the hosted pipeline, and request a code reviewer to inspect the exact immutable head reported by `git rev-parse HEAD` (include that SHA, pipeline URL, A/E/X mapping, static-scan output, and each unverified native runner). Merge only after required approvals and successful hosted pipeline; do not delete the remote source branch without explicit user approval.

## Exact A/E/X evidence mapping

| Contract | Automated evidence | Manual/native evidence |
|---|---|---|
| **A1** First trust is probe → explicit approval → fresh exact-pin reconnect → authentication | Tasks 4, 6, 7, and 8 scripted connector/repository tests prove no API-key handoff before `PinnedReady` | Task 10 controlled self-signed endpoint observes no credential until reconnect |
| **A2** Pin is leaf-DER SHA-256, exactly uppercase 64 hex, keyed by canonical authority | Tasks 1 and 3 model/fixture tests; independent digest assertion | Task 10 compares displayed and endpoint fixture digest |
| **A3** Only a versioned pin record is in OS storage; profile/API key stay memory-only | Task 2 serialization/store failures and Task 8 provider assertions | Task 10 inspects each selected OS store/reset behavior |
| **A4** Replacement blocks and atomically preserves old pin until new fresh reconnect succeeds | Tasks 2, 6, and 7 replacement/cancel/late-result tests | Task 10 replacement success/failure on each available native runner |
| **A5** Native navigation and responsive design-system trust UI remain intact | Task 9 width/theme/widget/accessibility tests plus existing shell tests | Rendered QA below |
| **E1** Timeout, parse, host, validity, malformed, normal trust failure, mismatch, store errors, reconnect failure, cancellation, late result, and same-authority concurrency fail closed | Tasks 1–8 deterministic fake clock/fixture tests | Task 10 only where native fixture can induce the condition |
| **E2** 320/390/600/1000/1440, light/dark, 200% text, keyboard/focus/reduced motion work | Task 9 widget/accessibility tests | Rendered QA below |
| **X1** No trust-all, TLS downgrade, auto rotation, broad callback, hidden bypass, secrets/profile metadata persistence, logging, or analytics | Tasks 5–6 capability tests and Task 11 static scans/reviewer checklist | Exact-head reviewer inspects every callback true branch and native bridge |
| **X2** Web has browser/OS trust only and no inspection/override/pin action | Tasks 4, 8, and 9 Web conditional/widget/build tests | Browser rendered QA below |

## Rendered QA and honest platform limits

After automated GREEN, serve only a local test build and inspect first-trust, replacement, blocked, and Web states at 320, 390, 600, 1000, and 1440 logical pixels in light/dark and 200% text. Verify no clipping/overflow, native navigation mode remains correct, focus order/ring works, and API key/plain DER never appears. This is a visual supplement, not a substitute for widget/native tests.

```sh
(cd apps/truenavo && fvm flutter run -d chrome --web-port 7357)
```

Stop the process after inspection. Browser rendering cannot validate TLS inspection or pinning. The checked-in GitLab pipeline currently has a shared Linux portable/web job and a macOS release build; it is not an Android/iOS/Windows/Linux hardware matrix. Do not state that all five native platforms are verified unless Task 10 has recorded successful tests on each actual SDK/device/runner. A macOS build verifies compilation/entitlements, not Keychain behavior or real TLS interoperability.
