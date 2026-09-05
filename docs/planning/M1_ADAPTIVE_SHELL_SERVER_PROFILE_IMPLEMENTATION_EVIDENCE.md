# M1 적응형 셸·세션 메모리 서버 프로필 구현 증적

- 구현 커밋: `903255167a63a47bf54329f39b3903d037185eda`
- 브랜치: `feat/m1-adaptive-shell-server-profile`
- 기준: `design/design-system-foundation`의 원래 스택 기준 `bac42639d5d52eaa1f1c595737bd795142c8414f`
- 범위: 앱 내부의 적응형 탐색 셸 및 프로세스 메모리 `ServerProfile` catalog. TD-002는 완료되지 않았습니다.

## 구현 사실

- 실제 사용 가능 폭 기준으로 `<600`은 `NavigationBar`, `600–999`는 72px `NavigationRail`, `>=1000`은 확장 `NavigationRail`을 사용합니다.
- 고정 목적지는 Home, Alerts, Manage, Jobs뿐입니다. 모든 목적지는 데이터 연결이 후속 슬라이스라는 정적 안내만 보이며, dashboard/alerts/jobs data·차트·metric·명령을 만들지 않습니다.
- `ServerProfile`은 opaque id, display name, original host input, normalized endpoint, last-known version의 다섯 metadata만 가집니다. catalog는 Riverpod process memory 상태만 사용하며 endpoint 중복 upsert는 먼저 등록된 opaque id와 순서를 보존합니다.
- 성공한 기존 M0 연결만 안전한 metadata를 등록·선택하고 셸로 전환합니다. 다른 profile 선택은 표시 context만 바꾸며 연결을 재개하지 않습니다.
- API key/password/token, TLS fingerprint/trust decision, identity, method/capability payload, raw error/log를 profile state, 셸의 렌더링 text, 이 증적에 추가하지 않았습니다. 기존 M0 endpoint/TLS/auth/transport 코드는 변경하지 않았습니다.

## TDD 증적

Codex 격리 lane은 새 profile/controller/shell의 behavioral tests를 먼저 추가했고, 최초 focused test 실행은 누락된 profile/shell 구현에 대한 RED를 확인한 뒤 최소 구현을 추가했습니다. Hermes의 독립 focused 검증에서 switcher test가 중복 tooltip finder로 실패했고, 중복 `Tooltip` wrapper를 제거한 뒤 GREEN을 재실행했습니다.

- RED/독립 첫 focused run: `fvm flutter test apps/truedash/test/features/server_profiles apps/truedash/test/app_shell apps/truedash/test/features/connection/connection_screen_test.dart` — exit 1. 원인: `server_switcher_test.dart`에서 `Choose server` tooltip이 두 개여서 tap finder가 모호함.
- GREEN focused run: 같은 명령 — exit 0, 28 tests passed.

## Hermes 독립 검증

| 명령 | 결과 |
| --- | --- |
| `fvm dart format --set-exit-if-changed .` | exit 0, 61 files unchanged |
| `fvm flutter analyze apps/truedash` | exit 0, no issues |
| `fvm flutter test apps/truedash` | exit 0, 34 tests passed |
| `fvm flutter analyze packages/truedash_design_system` | exit 0, no issues |
| `fvm flutter test packages/truedash_design_system` | exit 0, 27 tests passed |
| `fvm dart test packages/truenas_api` | exit 0, 45 tests passed |
| `git diff --check` before implementation commit | exit 0 |

Breakpoint widget tests cover 599/600/999/1000. Focused connection test coverage additionally checks successful safe seeding/shell transition, failure remains at the form, 320/390 plus 200% text reflow, and API-key sentinel non-rendering.

## Build 및 rendered QA 환경 한계

이 checkout에는 Web과 macOS runner가 구성되어 있지 않습니다. 다음 실제 명령은 source 변경 없이 플랫폼 구성 부재로 종료했습니다.

| 명령 | 실제 결과 |
| --- | --- |
| `fvm flutter build web --release --target apps/truedash/lib/main.dart` | exit 1 — `This project is not configured for the web.` |
| `fvm flutter build macos --release --target apps/truedash/lib/main.dart` | exit 1 — `No macOS desktop project configured.` |
| `codesign --verify --deep --strict build/macos/Build/Products/Release/truedash.app` | macOS build가 app을 만들지 않아 실행 불가 |

따라서 production Web browser matrix, console/scrollWidth, screenshots, local static server 및 browser tab은 생성하지 않았습니다. 이 증적은 browser render 또는 release/codesign 성공을 주장하지 않습니다. runner를 별도 승인 범위로 추가한 뒤 해당 build와 실제 browser QA를 다시 수행해야 합니다.

## 범위·보안 점검

- 변경은 `apps/truedash`와 이 문서/README index로 한정하며 `packages/truenas_api`, `packages/truedash_design_system`, dependency/lockfile, platform TLS 코드에는 변경이 없습니다.
- `git diff --check`로 whitespace 오류를 점검했습니다.
- M1 profile/shell 파일은 persistence, discovery, secure storage, TLS trust mutation, credential persistence, reconnect coordinator, capability registry, operational data, ads/billing을 구현하지 않습니다.
- 이 구현은 credential-backed live switching, real TrueNAS interoperability, 또는 TD-002 완료의 증거가 아닙니다.
