# M0 Foundation Implementation Evidence

> 검증일: 2026-09-05
>
> 범위: Flutter 앱 부트스트랩, 순수 Dart TrueNAS JSON-RPC/session 패키지, 연결 화면
>
> 실제 TrueNAS 장비 검증: 미수행. 이 문서는 deterministic local evidence이며 실제 장비 호환성 보증이 아니다.

## 1. 고정 도구chain

- FVM: `4.0.5`
- Flutter: `3.47.0` stable
- Dart: `3.13.0`
- 저장소 루트 `.fvmrc`가 Flutter `3.47.0`을 고정한다.

## 2. 구현 경계

- `apps/truedash`: Android, iOS, macOS, Windows, Linux, web 타깃 Flutter 앱
- `packages/truenas_api`: Flutter UI에 의존하지 않는 Dart 패키지
- endpoint: `https://`/`wss://`만 허용하고 기본 path를 `/api/current`로 정규화
- transport: 플랫폼 WebSocket/TLS 기본 검증을 그대로 사용하며 인증서 우회 훅 없음
- JSON-RPC 2.0: 증가 ID, out-of-order 응답 상관관계, notification 분리, malformed/unknown/duplicate/error/close 처리
- handshake: `auth.login_ex` positional params → `auth.me` → `system.info` → `core.get_methods`
- UI: Riverpod controller, masked API-key field, connect/loading/error/connected states, 안전한 서버 요약
- 제외: key 영속화, TLS 예외 승인, SCRAM, reconnect, subscriptions/jobs, ads, billing, telemetry

## 3. TDD 기록

### 초기 RED

production 타입이 아직 없을 때 endpoint, JSON-RPC, session repository 테스트를 먼저 실행해 missing import/type 오류를 확인했다. 그 뒤 가장 작은 production surface를 구현해 GREEN으로 전환했다.

### 독립 검토에서 추가한 RED

1. malformed JSON-RPC `error` 객체가 pending request를 완료하지 못할 수 있는 회귀 테스트를 추가했다. 수정 전 테스트는 timeout으로 실패했고, validation 순서를 고쳐 protocol exception으로 완료하도록 했다.
2. `auth.login_ex`가 map params를 보내던 계약 오류를 positional array expectation으로 재현했다. 전송 payload를 `[{mechanism: API_KEY_PLAIN, api_key: ...}]`로 수정했다.
3. Flutter/Riverpod 3 정적 분석을 실행해 provider state/notifier API 불일치를 컴파일 오류로 확인했다. Notifier API로 통일하고 widget test import/가시성 assertion을 수정했다.

API key fixture는 비밀이 아닌 고정 sentinel만 사용하며, 결과 객체와 사용자 가시 오류 텍스트에 그 값이 나타나지 않는지 검사한다.

### 후속 독립 검토 수정 (2026-09-05)

1. id 없는 JSON object가 `jsonrpc: '2.0'`, 비어 있지 않은 string `method`, result/error 부재를 모두 만족할 때만 notification으로 전달되도록 RED 회귀 테스트를 추가했다. `result`만 있는 object와 malformed notification은 protocol error stream으로 보고되고, 이미 pending인 요청은 일치 response 또는 close 전까지 유지되는지 검증한다.
2. notification의 `params`는 없거나 JSON object/array일 때만 전달되도록 추가 검증했다. `null`, number, string, boolean은 protocol error stream으로 보고되고 notification으로 전달되지 않으며, 이미 pending인 요청은 이후 일치 response로 완료되는지 검증한다.
3. Riverpod connector, credential vault, repository factory seam을 각각 override하는 provider-composition test를 추가했다. live socket과 platform storage를 사용하지 않는다.
4. widget test를 table-driven으로 확장해 endpoint validation, TLS certificate, remote RPC, transport close, protocol, OTP_REQUIRED, EXPIRED, REDIRECT, generic failure의 안전한 message mapping과 sentinel 비노출을 검증한다. 성공 요약은 원래 입력, 정규화 endpoint, identity, version, method count를 모두 검증한다.
5. Android release INTERNET permission, macOS client-network entitlements, iOS local-network purpose text는 source-text test가 아닌 manifest/plist static inspection으로 확인했다. Bonjour service declaration은 추가하지 않았다.

## 4. 현재 자동 검증

Codex sandbox 밖의 동일한 격리 worktree에서 다음 명령을 다시 실행했다.

```sh
fvm dart format --set-exit-if-changed .
fvm flutter pub get
(cd packages/truenas_api && fvm dart test --reporter=compact)
(cd apps/truedash && fvm flutter analyze --no-fatal-infos)
(cd apps/truedash && fvm flutter test --reporter=compact)
plutil -lint apps/truedash/ios/Runner/Info.plist apps/truedash/macos/Runner/Release.entitlements apps/truedash/macos/Runner/DebugProfile.entitlements
git diff --check
```

결과:

- Dart protocol/session/endpoint 테스트: **45 passed**
- Flutter widget/provider 테스트: **13 passed**
- Flutter analyzer: **No issues found**
- formatter 및 `git diff --check`: 통과
- iOS plist와 macOS entitlement plist: `plutil -lint` 통과. `NSLocalNetworkUsageDescription`과 양 entitlement의 `com.apple.security.network.client=true`를 static inspection으로 확인했다.
- Android main manifest의 `android.permission.INTERNET`을 static inspection으로 확인했다. debug/profile manifest의 중복 permission은 제거했다.
- Web release build: 성공 (`apps/truedash/build/web`).
- macOS release build: 성공 (`apps/truedash/build/macos/Build/Products/Release/truedash.app`, 42.1 MB).
- 생성된 macOS release 앱을 `codesign -d --entitlements :-`로 읽어 `com.apple.security.network.client=true`가 최종 서명 entitlement에 포함됨을 확인했다.

## 5. 남은 검증 한계

M0에는 실제 TrueNAS 장비 또는 fixture server E2E가 없다. 따라서 다음 항목은 아직 완료로 선언하지 않는다.

- TrueNAS 25.04/25.10 실제 `auth.login_ex` 성공 및 권한 오류
- self-signed certificate 대상의 플랫폼별 오류 UX
- API 응답 shape drift와 26+ SCRAM negotiation
- Android/iOS/Windows/Linux 실기기 또는 CI 빌드. Android/iOS runtime은 검증하지 않았으며, 이번 증거는 manifest/plist/entitlement static configuration inspection에 한정된다.
- secure credential storage와 TOFU/pinning UX

다음 슬라이스는 실제 장비 compatibility evidence와 credential/TLS trust 설계를 먼저 추가해야 한다.
