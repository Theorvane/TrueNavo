# M0 Foundation 구현 계획: Flutter와 TrueNAS JSON-RPC 연결

> 상태: 구현 계획. 아래 절차를 수행하고 코드·테스트·실제 서버 통합 증거를 확보하기 전까지 M0은 완료가 아니다.
>
> 기준 도구체인: Flutter 3.47.0 stable, Dart 3.13.0, macOS arm64
>
> 설계 기준: [M0 설계](./M0_FOUNDATION_DESIGN.md), [제품 기획안](./TRUENAVO_PRODUCT_PLAN.md), [TrueNAS API 조사](../research/TRUENAS_API_RESEARCH.md)

## 1. 실행 규칙

- 모든 명령은 저장소 루트에서 실행한다: `/Users/jungwon/workspace/.worktrees/truenavo-m0`.
- Flutter 명령은 `fvm flutter`, 순수 Dart 명령은 `fvm dart`만 사용한다.
- 각 행동 조각은 먼저 RED 테스트를 추가하고, 그 테스트를 실행해 예상 실패를 기록한 뒤 최소 구현으로 GREEN을 만든다. 리팩터링은 GREEN 뒤에만 한다.
- 테스트는 `InMemoryTransport`/fake connector를 통해 production protocol·repository·controller 코드 경로를 실행한다. 소스 텍스트 검사, live TrueNAS, 인터넷 의존 테스트는 금지한다.
- secret은 fixture, expectation, 오류 메시지, 로그에 평문으로 넣지 않는다. 테스트 key는 `test-api-key`처럼 고정된 비밀 아닌 sentinel로만 쓴다.
- 이 단계에서는 credential 영속화, TLS 우회, telemetry, ad/billing SDK, remote service, 생성 모델을 추가하지 않는다.

기본 반복 명령은 다음과 같다.

```sh
fvm dart format --set-exit-if-changed .
(cd apps/truenavo && fvm flutter analyze)
(cd apps/truenavo && fvm flutter test)
(cd packages/truenas_api && fvm dart test)
```

## 2. 순차 작업 목록

### 2.1 Workspace와 Flutter bootstrap

생성·수정 대상은 `pubspec.yaml`, `apps/truenavo/pubspec.yaml`, `packages/truenas_api/pubspec.yaml`, `.fvmrc`, 그리고 최소 앱/패키지 소스와 테스트 디렉터리다. 루트 `pubspec.yaml`에는 Dart pub workspace의 members로 `apps/truenavo`, `packages/truenas_api`를 선언한다. 앱은 path dependency로 `truenas_api`를 사용한다. workspace가 정상 해석된 뒤에만 Melos를 추가하지 않기로 확정한다.

RED:

```sh
fvm flutter pub get
(cd packages/truenas_api && fvm dart test)
(cd apps/truenavo && fvm flutter test)
```

예상 실패: package/app 또는 test target이 아직 없다는 오류.

GREEN 구현과 검증:

```sh
fvm flutter pub get
(cd packages/truenas_api && fvm dart test)
(cd apps/truenavo && fvm flutter test)
```

통과 기준: 두 프로젝트가 workspace에서 해석되고, package와 앱의 최소 smoke test가 통과한다. `apps/truenavo/lib/main.dart`는 `ProviderScope`만 만들고, `apps/truenavo/lib/truenavo_app.dart`의 `TrueNavoApp`은 scope-free 상태로 분리한다.

### 2.2 Endpoint 검증과 정규화

대상 파일은 `packages/truenas_api/lib/src/endpoint/validated_endpoint.dart`, `packages/truenas_api/lib/truenas_api.dart`, `packages/truenas_api/test/endpoint/validated_endpoint_test.dart`다.

RED 테스트는 아래 사례를 table-driven으로 추가한다.

- `https://nas.example:8443`가 `wss://nas.example:8443/api/current`가 되는 경우
- 명시 `wss://nas.example/custom/api` path를 보존하는 경우
- 공백이 있는 ` https://nas.example `에서 원문을 보존하고 trim한 endpoint를 만드는 경우
- path 없음과 `/`가 `/api/current`가 되는 경우
- `http`, `ws`, userinfo, query, fragment, host 없는 URI가 거부되는 경우

```sh
(cd packages/truenas_api && fvm dart test test/endpoint/validated_endpoint_test.dart)
```

예상 실패: `ValidatedEndpoint`와 validation 오류 타입이 아직 없어 compile failure 또는 assertion failure.

GREEN 구현 후 같은 명령을 실행한다. 통과 기준은 original input과 연결 URI가 분리되고, 금지 URI에서는 connector가 호출되기 전 validation 오류가 발생하는 것이다.

### 2.3 JSON-RPC codec/client와 fake transport

대상 파일은 `packages/truenas_api/lib/src/transport/rpc_transport.dart`, `packages/truenas_api/lib/src/protocol/json_rpc_client.dart`, `packages/truenas_api/lib/src/protocol/json_rpc_exceptions.dart`, test 지원의 `packages/truenas_api/test/support/in_memory_transport.dart`, 그리고 protocol tests다.

RED는 다음 순서로 작고 독립된 테스트를 추가한다.

1. caller가 준 ID를 포함한 JSON-RPC 2.0 request를 송신하고 일치 응답의 result를 반환한다.
2. 두 요청에 역순 응답을 주입해 ID별 Future가 올바르게 완료되는지 확인한다.
3. ID 없는 notification이 어느 pending Future도 완료하지 않는지 확인한다.
4. RPC error가 code/message/data 보존 예외가 되는지 확인한다.
5. duplicate ID, unknown ID, malformed JSON, `jsonrpc != '2.0'`, result/error 동시 존재, result/error 모두 부재를 protocol 오류로 확인한다.
6. pending 요청 중 transport close가 모든 Future를 transport-closed 오류로 완료하고, `close()`가 명시적·idempotent인지 확인한다.

```sh
(cd packages/truenas_api && fvm dart test test/protocol)
```

예상 실패: codec/client/transport 계약이 없거나 상관관계·오류 규칙이 구현되지 않았다.

GREEN에서는 real connector를 이 단계에서 만들지 않는다. `RpcTransport`와 connector interface를 production code에 두고 fake를 생성자 주입한다. 통과 기준은 fake inbound 프레임만으로 여섯 동작이 production `JsonRpcClient`를 거쳐 검증되는 것이다.

### 2.4 세션 handshake repository

대상 파일은 `packages/truenas_api/lib/src/session/true_nas_session_repository.dart`, `server_summary.dart`, `credential_vault.dart`, `authentication_exception.dart`와 `packages/truenas_api/test/session/true_nas_session_repository_test.dart`다.

RED 테스트 순서는 다음과 같다.

1. valid WSS endpoint에서 `auth.login_ex`에 `API_KEY_PLAIN`을 쓰고 `SUCCESS` 뒤 `auth.me`, `system.info`, `core.get_methods`를 호출해 ServerSummary를 만드는 A 사례.
2. `auth.me` identity, `system.info` version, methods metadata의 선택 필드 누락이 crash하지 않는 E 사례.
3. `OTP_REQUIRED`, `AUTH_ERR`, `EXPIRED`, `REDIRECT` 각각이 후속 RPC 없이 구별 가능한 인증 오류가 되는 X 사례.
4. `https` 입력 URL이 이미 검증된 WSS endpoint로 connector에 전달되는 E 사례.
5. transport가 self-signed TLS failure를 보고하면 trust callback 없이 actionable unsupported-for-this-slice 오류가 되는 X 사례.
6. repository 종료가 transport close를 호출하는 A 사례.

```sh
(cd packages/truenas_api && fvm dart test test/session/true_nas_session_repository_test.dart)
```

예상 실패: handshake orchestration, summary mapper, vault interface, auth-state mapping이 아직 없다.

GREEN에서 `NoopCredentialVault`와 `InMemoryCredentialVault`만 구현하고 UI에 저장 동작을 추가하지 않는다. fake connector는 TLS failure를 예측 가능하게 던진다. 통과 기준은 테스트가 외부 socket 없이 실제 repository→client→transport 경로를 실행하고 API key가 summary·오류에 포함되지 않는 것이다.

### 2.5 Riverpod 3 controller와 연결 화면

대상 파일은 `apps/truenavo/lib/features/connection/connection_controller.dart`, `connection_state.dart`, `connection_screen.dart`, `apps/truenavo/lib/truenavo_app.dart`, `apps/truenavo/lib/main.dart`와 widget tests다. provider는 connector/repository factory/vault를 override 가능하게 선언한다.

RED 테스트 순서는 다음과 같다.

1. 앱 root 바깥 test-owned `ProviderScope(overrides: ...)`가 fake repository를 주입하고, `TrueNavoApp`이 추가 scope 없이 연결 화면을 보이는지 확인한다.
2. URL·masked API key 입력과 Connect 버튼, connecting progress, 중복 제출 방지를 확인한다.
3. 성공 시 원래 host 입력, normalized endpoint, identity/version/method count가 표시되는지 확인한다.
4. validation, TLS, RPC, transport, protocol, OTP/AUTH_ERR/EXPIRED/REDIRECT 오류가 API key를 노출하지 않는지 확인한다.

```sh
(cd apps/truenavo && fvm flutter test test/features/connection)
```

예상 실패: scope-free 앱, controller state, 주입 경계, 입력/결과 UI가 아직 없다.

GREEN에서 controller는 injected repository만 호출한다. `main.dart`는 `ProviderScope(child: TrueNavoApp())`를 제공하고, widget test는 `ProviderScope`를 직접 만든다. 통과 기준은 live network 없이 사용자가 한 연결 흐름의 상태 변화를 볼 수 있고, API key 필드는 기본 mask이며 상태/오류에 sentinel key가 나타나지 않는 것이다.

### 2.6 Quality, build, 문서 증거

각 구현 조각이 GREEN인 뒤 format과 analyze를 실행한다. 완료 전에는 다음 전체 검증을 수행한다.

```sh
fvm dart format --set-exit-if-changed .
(cd apps/truenavo && fvm flutter analyze)
(cd apps/truenavo && fvm flutter test)
(cd packages/truenas_api && fvm dart test)
(cd apps/truenavo && fvm flutter build web --release)
(cd apps/truenavo && fvm flutter build macos --debug)
(cd apps/truenavo && fvm flutter build macos --release)
```

macOS desktop build가 로컬 Flutter 설치에 의해 지원되지 않으면, 해당 명령의 정확한 실패 출력과 환경 제약을 구현 증거에 기록하고 다른 검증을 성공으로 오인하지 않는다. 웹은 제품 기획안에서 v1 릴리스 게이트가 아니지만, 이 M0 UI의 build·반응형 렌더 검증 대상이다.

마지막으로 release가 아닌 테스트용 served web 앱을 실행해 browser inspection을 한다.

```sh
(cd apps/truenavo && fvm flutter run -d chrome --web-port 7357)
```

검사 기준:

- desktop viewport에서 URL, API key mask, Connect, 진행/오류/성공 요약이 잘림 없이 보인다.
- 375px narrow viewport에서 필드와 버튼이 가로 overflow 없이 접근 가능하고, 성공 요약과 오류가 읽힌다.
- UI의 어떤 상태에서도 API key가 평문으로 나타나지 않는다.

서버 프로세스는 inspection 뒤 정상 종료한다. 이 시각 검사는 widget test를 대체하지 않으며, 실제 TrueNAS E2E 검증도 대체하지 않는다.

## 3. 완료 수용 기준

- pub workspace가 Flutter 앱과 순수 Dart `truenas_api`를 해석하며 Melos가 없다.
- 모든 A/E/X 사례가 production code path와 fake/in-memory transport로 자동화되어 있다.
- WSS만 사용하고 URL validation은 연결 전 실행된다. TLS 검증을 끄는 코드·옵션은 없다.
- `auth.login_ex(API_KEY_PLAIN)`은 25.04/25.10 M0 경계에 제한되고, `SUCCESS`만 `auth.me`·`system.info`·`core.get_methods`로 진행한다.
- API key는 M0에서 영속화되지 않고, UI/state/error/log에 노출되지 않는다.
- transport, protocol, repository/session, Flutter presentation이 생성자 주입 가능한 별도 경계다.
- 위의 format, analyze, package/app tests, web release build, 가능한 macOS builds, 두 viewport served-web inspection 결과가 실행 증거로 남는다.

## 4. 다음 슬라이스 제외 항목

이 계획은 SCRAM, secure platform credential storage, certificate trust UX, reconnect, subscriptions, jobs, API model generation, billing, ads, telemetry, 계정/remote service를 다음 슬라이스로 남긴다. 실제 25.04 및 25.10 장비에서 성공·권한 거부·TLS 실패를 검증한 증거가 생기기 전에는 이 M0 구현 계획을 실제 서버 호환성 보증으로 해석하지 않는다.
