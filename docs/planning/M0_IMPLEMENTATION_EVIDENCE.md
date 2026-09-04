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

## 4. 최종 자동 검증

저장소 루트에서 아래 명령을 fresh run했다.

```sh
fvm dart format --set-exit-if-changed .
fvm flutter pub get
(cd packages/truenas_api && fvm dart test)
(cd apps/truedash && fvm flutter analyze)
(cd apps/truedash && fvm flutter test)
git diff --check
```

결과:

- Dart protocol/session/endpoint 테스트: **31 passed**
- Flutter widget/controller 테스트: **3 passed**
- Flutter analyze: **No issues found**
- format 및 `git diff --check`: 통과

빌드 검증:

```sh
(cd apps/truedash && fvm flutter build web --release)
(cd apps/truedash && fvm flutter build macos --debug)
(cd apps/truedash && fvm flutter build macos --release)
```

세 빌드 모두 exit 0. 생성 결과:

- web release: `apps/truedash/build/web`
- macOS debug: `apps/truedash/build/macos/Build/Products/Debug/truedash.app`
- macOS release: `apps/truedash/build/macos/Build/Products/Release/truedash.app`

## 5. 실제 렌더 검증

web release 산출물을 `127.0.0.1:7357`에서 임시 서빙해 로컬 Chrome으로 확인했다.

- desktop `1280×800`: 앱·카드·입력·Connect 버튼 렌더 정상, clipping/overflow 없음
- CDP mobile emulation `375×812`: `innerWidth=375`, `scrollWidth=375`, `innerHeight=812`, `scrollHeight=812`
- mobile 캡처에서 카드, Server URL, masked API key, visibility control, Connect 버튼이 모두 viewport 안에 표시됨
- 검증 후 HTTP server, CDP Chrome, Browser Use task processes를 종료함

## 6. 남은 검증 한계

M0에는 실제 TrueNAS 장비 또는 fixture server E2E가 없다. 따라서 다음 항목은 아직 완료로 선언하지 않는다.

- TrueNAS 25.04/25.10 실제 `auth.login_ex` 성공 및 권한 오류
- self-signed certificate 대상의 플랫폼별 오류 UX
- API 응답 shape drift와 26+ SCRAM negotiation
- Android/iOS/Windows/Linux 실기기 또는 CI 빌드
- secure credential storage와 TOFU/pinning UX

다음 슬라이스는 실제 장비 compatibility evidence와 credential/TLS trust 설계를 먼저 추가해야 한다.
