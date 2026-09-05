# M0 Foundation 설계: TrueNAS JSON-RPC 연결 세로 슬라이스

> 상태: 구현 계획. 이 문서는 코드나 실제 TrueNAS 서버 통합 증거가 생기기 전까지 구현 완료를 주장하지 않는다.
>
> 기준: Flutter 3.47.0 stable, Dart 3.13.0, macOS arm64 (2026-09-05에 확인)
>
> 근거: [제품 기획안](./TRUEDASH_PRODUCT_PLAN.md), [TrueNAS API 조사](../research/TRUENAS_API_RESEARCH.md)

## 1. 목적과 지원 경계

M0은 사용자가 TrueNAS 25.04 또는 25.10 장비에 WSS로 API key를 사용해 연결하고, 인증된 서버의 식별 정보와 버전을 확인하는 한 개의 실제·시험 가능한 세로 슬라이스다. 관리 기능, 저장 서버 목록, 자동 복구는 아직 포함하지 않는다.

지원하는 인증 호출 순서는 다음과 같다.

```text
입력 URL 검증·정규화 → WSS 연결 → auth.login_ex(API_KEY_PLAIN)
  → auth.me → system.info → core.get_methods → ServerSummary → 명시적 close
```

`API_KEY_PLAIN`은 25.04/25.10 호환 계층에서만, 그리고 `wss` 연결에서만 사용한다. API 조사 문서가 기록한 대로 API key는 비밀번호와 동등한 비밀이며, 이 슬라이스는 이를 저장하거나 로그에 기록하지 않는다. 26+의 SCRAM과 채널 바인딩은 다음 슬라이스의 별도 설계 대상이다.

## 2. 의도적으로 제외하는 범위

이 설계는 다음을 구현하거나 숨은 임시 구현으로 남기지 않는다.

- SCRAM, 비밀번호 로그인, OTP 후속 인증, HA `REDIRECT` 재연결 처리
- 이벤트 구독, jobs, 파일 전송, 터미널, 재연결, 서버 목록 및 다중 서버 전환
- 인증서 TOFU·고정·예외 신뢰 또는 어떤 형태의 trust-all-certificate 우회
- API key 영속화, OS 보안 저장소 연동, 계정, 원격 서비스, 분석·텔레메트리
- 광고 네트워크, 결제 SDK, entitlement, 생성된 API 모델

자체 서명 인증서 때문에 TLS 검증이 실패하면 앱은 연결을 우회하지 않고 “이 슬라이스에서는 신뢰할 수 있는 TLS 인증서가 필요하며, 인증서 신뢰 정책은 후속 슬라이스의 별도 기능”이라는 실행 가능한 오류를 보인다.

## 3. 저장소와 의존성 구조

루트는 Dart pub workspace를 사용한다. Dart 3.13.0은 workspace 지원 도구체인이므로 이 범위에 Melos를 추가하지 않는다. 패키지 수가 적고 공통 스크립트·릴리스 자동화의 실제 필요가 아직 없으므로 Melos는 정당화되지 않는다.

```text
.
├── pubspec.yaml                         # workspace 루트
├── apps/truedash/                       # Flutter 앱
│   ├── lib/main.dart
│   ├── lib/truedash_app.dart
│   └── lib/features/connection/
└── packages/truenas_api/                 # Flutter 비의존 순수 Dart 패키지
    └── lib/src/
        ├── endpoint/
        ├── transport/
        ├── protocol/
        └── session/
```

의존 방향은 단방향이다.

```text
Flutter presentation / Riverpod controller
                ↓
session repository + credential-vault interface
                ↓
JSON-RPC client / codec
                ↓
WebSocket transport connector
```

`truenas_api`는 Flutter, Riverpod, 플랫폼 채널을 import하지 않는다. 각 층은 생성자 주입으로 아래 층을 받는다. 따라서 단위·통합 테스트는 네트워크 없이 같은 실행 경로에 fake transport를 주입할 수 있다.

## 4. URL 입력과 endpoint 규칙

UI는 사용자가 입력한 원문(host 문자열)을 별도로 보존해 표시·감사 맥락에 사용한다. 연결에는 그 원문을 `.trim()`한 뒤 파싱·검증해 만든 `ValidatedEndpoint`만 사용한다. API key는 이 객체, 오류, 상태, 로그의 어느 곳에도 넣지 않는다.

| 입력 | 결과 |
|---|---|
| `https://nas.example:8443` | 허용. WSS endpoint는 `wss://nas.example:8443/api/current` |
| `wss://nas.example/custom/api` | 허용. 제공 path를 유지 |
| ` wss://nas.example ` | 허용. 원문은 공백 포함으로 보존하고 endpoint는 trim한 `wss://nas.example/api/current` |
| path 없음 또는 `/` | 기본 path `/api/current` |
| `http://`, `ws://` | 거부. 암호화된 WSS만 지원 |
| userinfo, fragment, query string, host 없음 | 거부 |

`https`는 API path를 조합할 때 `wss`로 변환한다. `wss`는 그대로 쓴다. 허용된 명시 path에는 query를 붙이지 않으며, URI의 userinfo·fragment·query 존재 여부는 비어 있는 값이 아니라 구조적으로 검증한다. 포트는 URI 파서가 유효하다고 인정한 값만 유지한다.

## 5. 전송과 JSON-RPC 핵심

### 5.1 전송 계약

`WebSocketConnector.connect(ValidatedEndpoint)`는 `RpcTransport`를 반환하거나 TLS/네트워크 오류를 던진다. `RpcTransport`는 inbound frame stream, text `send`, 명시적 비동기 `close`를 제공한다. 실제 구현은 기본 플랫폼 WebSocket TLS 검증을 그대로 사용하며 인증서 콜백이나 우회 옵션을 노출하지 않는다.

테스트용 `InMemoryTransport`는 송신 프레임 기록과 임의 순서 inbound frame 주입, close 주입을 지원한다. 실제 WebSocket 또는 라이브 TrueNAS가 필요한 테스트는 M0에 없다.

### 5.2 JSON-RPC 계약

- 요청 ID는 caller가 생성한 `String` 또는 `int`로 하며 `JsonRpcClient.call`에 명시해 전달한다. M0 repository는 충돌하지 않는 순차 문자열 ID를 생성한다.
- client는 pending map을 ID로 관리하므로 out-of-order 응답도 정확히 해당 `Future`를 완료한다.
- JSON-RPC `2.0` 응답만 수용한다. notification(특히 ID 없는 `collection_update`)은 이벤트 스트림에만 전달하며 요청을 완료하지 않는다.
- 응답은 정확히 하나의 `result` 또는 `error`를 가져야 한다. 둘 다 있거나 둘 다 없으면 protocol 오류다.
- error object는 code/message/data를 보존한 `JsonRpcRemoteException`으로 변환한다. TrueNAS의 `-32000`, `-32001`도 같은 구조로 표현해 UI가 안전한 메시지를 정할 수 있게 한다.
- duplicate response ID, pending map에 없는 response ID, 잘못된 JSON, 잘못된 `jsonrpc` 버전은 protocol 오류이며 조용히 무시하지 않는다. 이미 완료된 ID의 중복 응답은 해당 요청을 두 번 완료하지 않는다.
- transport가 닫히면 아직 pending인 모든 요청을 `RpcTransportClosedException`으로 완료하고 pending map을 비운다. `close()`는 명시적이고 idempotent하게 설계한다.

프로토콜 오류와 외부 입력은 API key를 포함한 요청 원문을 기록하지 않는다. 오류 객체에도 endpoint의 비밀 아닌 표시 문자열만 넣는다.

## 6. 세션 repository와 서버 요약

`TrueNasSessionRepository`는 endpoint, connector, credential vault, ID generator를 생성자로 받는다. vault는 다음처럼 최소화한다.

```dart
abstract interface class CredentialVault {
  Future<String?> readApiKey(String serverDisplayInput);
  Future<void> writeApiKey(String serverDisplayInput, String apiKey);
  Future<void> deleteApiKey(String serverDisplayInput);
}
```

M0의 `InMemoryCredentialVault`는 프로세스 메모리에만 보관할 수 있고, 기본 `NoopCredentialVault`는 항상 읽기 null·쓰기 무동작으로 동작한다. UI 연결 시 입력한 API key를 즉시 사용하며, 연결 성공 이후에도 영속화하지 않는다. vault는 향후 보안 저장소를 주입할 경계일 뿐, M0 UI는 “저장” 기능을 제공하지 않는다.

repository는 다음을 반환한다.

```text
ServerSummary
  originalHostInput
  endpointUri
  identity                 # auth.me에서 안전하게 추출한 식별 정보
  version                  # system.info의 안전한 버전 값
  availableMethodNames     # core.get_methods의 key 집합
```

`auth.me`, `system.info`, `core.get_methods`의 선택 필드가 누락되거나 형식이 예상과 달라도 repository는 crash하지 않는다. `unknown`/빈 집합 같은 안전한 표현을 사용한다. 필수 응답 구조 자체가 JSON-RPC 규칙을 위반하면 protocol 오류로 끝난다. `auth.login_ex`의 `SUCCESS`만 세션 초기화로 진행한다. `OTP_REQUIRED`, `AUTH_ERR`, `EXPIRED`, `REDIRECT`는 각 상태를 보존한 `AuthenticationStateException`으로 바꾸며, M0은 재인증·OTP·리디렉션을 시도하지 않는다.

## 7. Flutter와 Riverpod 3 경계

`main.dart`는 오직 `ProviderScope(child: TrueDashApp(...))`로 루트를 감싼다. `TrueDashApp`은 scope를 만들지 않는 위젯으로, 테스트에서 `ProviderScope(overrides: [...])`로 connector·repository factory·vault를 교체할 수 있다. Riverpod 3에서 안정된 provider/controller API만 사용하며, 앱의 presentation 계층 밖에서 `BuildContext`를 사용하지 않는다.

첫 화면은 다음 상태를 표현한다.

- 서버 URL, mask 처리한 API key 입력 필드, Connect 버튼
- endpoint 검증 오류와 insecure URL 오류
- 연결 중 progress 및 중복 제출 방지
- TLS, 전송, protocol, remote RPC, 인증 상태별 비밀 없는 오류
- 성공 시 원래 입력 문자열, 정규화 endpoint, identity, version, method count 요약

API key 입력은 기본적으로 obscured이며, 표시 전환은 화면 안에서만 작동한다. controller state와 UI error 문자열에 key를 복사하지 않는다. controller는 repository 인터페이스를 주입받아 UI와 WebSocket을 직접 결합하지 않는다.

## 8. 필수 A/E/X 수용 기준

| 구분 | 사례 | 통과 조건 |
|---|---|---|
| A | 유효 WSS, 일치 ID, 로그인 성공 | `auth.login_ex` 성공 뒤 세 후속 RPC 결과가 `ServerSummary`로 매핑된다. |
| A | 명시적 종료 | repository/session 종료가 transport `close`를 한 번 호출하고 pending을 남기지 않는다. |
| E | out-of-order 응답 | 두 호출이 각자의 ID로 완료된다. |
| E | notification | notification은 요청 Future를 완료하지 않는다. |
| E | 공백 포함 HTTPS 입력 | 원문은 보존되고 trim·WSS 변환·기본 path endpoint로 연결된다. |
| E | 선택 필드 누락 | identity/version/method metadata의 누락으로 crash하지 않는다. |
| X | duplicate/unknown ID | 오류가 관찰 가능하고 요청은 잘못 완료되지 않는다. |
| X | malformed JSON/버전 불일치/불완전 응답 | protocol 오류가 된다. |
| X | remote RPC error | code/message/data를 보존한 오류가 된다. |
| X | pending 중 socket close | 모든 pending Future가 transport-closed 오류로 끝난다. |
| X | `http`/`ws`, userinfo/query/fragment/host 없음 | 연결 전 endpoint validation 오류가 된다. |
| X | OTP_REQUIRED, AUTH_ERR, EXPIRED, REDIRECT | 상태별 인증 오류가 되고 후속 RPC를 보내지 않는다. |
| X | self-signed TLS | TLS 우회 없이 실행 가능한 지원 범위 오류가 UI에 표시된다. |

## 9. 다음 슬라이스

다음 설계·구현은 실제 25.04/25.10 장비 E2E 증거로 이 M0 경계를 검증한 뒤 진행한다. 우선순위는 secure credential storage, 명시적 서버 등록, 26+ SCRAM, 인증서 신뢰 정책 UX, reconnect/subscription/job coordinator, 이어서 capability-driven 화면이다. 제품 기획안의 기능 패리티는 이 연결 세로 슬라이스만으로 충족되지 않는다.
