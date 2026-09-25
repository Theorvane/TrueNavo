# M1 적응형 셸·세션 메모리 서버 프로필 구현 증적

- 검증 대상 기능·CI 커밋: `8d0536f3c4d6aab14179c31e09a15661aeaec7e0`
- 브랜치: `feat/m1-adaptive-shell-server-profile`
- target 기준: `main`의 `3ae642a6165c126623e6dd164de640c429ba26b3`
- 범위: 앱 내부 적응형 탐색 셸과 프로세스 메모리 `ServerProfile` catalog. TD-002는 완료되지 않았습니다.

## 구현 사실

- 실제 사용 가능 폭 기준으로 `<600`은 native `NavigationBar`, `600–999`는 native 72px `NavigationRail`, `>=1000`은 native extended `NavigationRail`을 사용합니다.
- 고정 목적지는 Home, Alerts, Manage, Jobs뿐입니다. 각 목적지는 서로 다른 scope 문구와 공통 후속-slice 상태를 별도로 표시하며 dashboard/alerts/jobs data·차트·metric·명령을 만들지 않습니다.
- keyboard traversal은 server catalog trigger → Home → Alerts → Manage → Jobs → Return action 순서입니다. Return action은 profile이 없는 shell 상태에서 connection 화면으로 돌아가기 위해 표시되며, 연결 성공 시 중첩된 connection route를 자동으로 닫고 Home과 선택 서버를 표시합니다.
- native navigation action과 native server popup trigger가 primary focus를 가질 때 2px focus ring을 실제 action rect에 렌더합니다. native selection, semantics, Enter/Space 활성화, popup focus restoration은 유지합니다.
- 각 navigation action, server trigger, popup item, Return action은 최소 `44×44` 조작 영역을 유지합니다.
- `ServerProfile`은 opaque id, display name, original host input, normalized endpoint, last-known version의 다섯 metadata만 가집니다. catalog는 Riverpod process memory 상태만 사용합니다.
- ID와 endpoint가 서로 다른 기존 profile을 동시에 가리키는 충돌에서도 catalog ID가 중복되지 않습니다. 기존 ID 위치에 새 metadata를 반영하고 endpoint 충돌 항목을 제거하며 selected ID는 유일하게 유지합니다.
- 성공한 기존 M0 연결만 안전한 metadata를 등록·선택하고 셸로 전환합니다. 다른 profile 선택은 표시 context만 바꾸며 연결을 재개하지 않습니다.
- API key/password/token, TLS fingerprint/trust decision, identity, method/capability payload, raw error/log를 profile state, 셸 렌더링 text, 이 증적에 추가하지 않았습니다. 기존 M0 endpoint/TLS/auth/transport 코드는 변경하지 않았습니다.

## 회귀 테스트 증적

수정 전 구현에서는 다음 RED가 독립 재현됐습니다.

- 서로 다른 endpoint가 같은 suggested ID를 사용할 때 IDs가 `[one, two, one]`이 되어 catalog identity가 모호해졌습니다.
- 강화된 accessibility suite에서 compact navigation focus 순서, 실제 destination action, 개별 `44×44` target, 실제 focus ring, server menu focus 복원 계약이 실패했습니다.
- 기존 Return action은 독립 `ConnectionScreen` route를 push한 뒤 연결 성공 시에도 그 route를 닫지 않아 Home이 보이지 않았습니다. 새 widget test가 원본에서 `Home` 0건으로 RED인 것을 확인한 뒤 성공 callback으로 route를 닫도록 수정했습니다.

`ad7f2805812e9bfdaa93db8afd1e224d06495734`에서 focused suite를 다시 실행한 결과:

```text
fvm flutter test \
  test/features/server_profiles/server_profiles_controller_test.dart \
  test/features/server_profiles/server_switcher_test.dart \
  test/app_shell/adaptive_shell_test.dart \
  test/app_shell/adaptive_shell_accessibility_test.dart \
  --reporter expanded
```

- exit 0, **30 tests passed**
- destination semantics는 label과 `Tab n of 4`, tap action, selected `Tristate`를 실제 native action에서 확인합니다.
- Tab마다 `FocusManager.instance.primaryFocus` rect가 실제 server/destination/Return action rect와 겹치는지 확인하고 Enter·Space 활성화를 검증합니다.
- focus ring 테스트는 key 존재만 보지 않고 실제 action rect 중첩, 2px 이상 border, 디자인 시스템 focus color를 확인합니다.
- reflow 테스트는 light/dark, 320/390/768/1024/1440, 200% text scale, reduced motion에서 실제 rendered rect가 viewport 안에 있는지 확인합니다.

## Hermes 독립 검증

| 대상 | 명령 | 실제 결과 |
| --- | --- | --- |
| 앱 format | `cd apps/trueraid && fvm dart format --output=none --set-exit-if-changed lib test` | exit 0, 22 files unchanged |
| 앱 analyze | `cd apps/trueraid && fvm flutter analyze` | exit 0, no issues |
| 앱 전체 | `cd apps/trueraid && fvm flutter test --reporter compact` | exit 0, **55 tests passed** |
| 디자인 시스템 analyze | `cd packages/trueraid_design_system && fvm flutter analyze` | exit 0, no issues |
| 디자인 시스템 전체 | `cd packages/trueraid_design_system && fvm flutter test --reporter compact` | exit 0, **27 tests passed** |
| API analyze | `cd packages/truenas_api && fvm dart analyze` | exit 0; 기존 info diagnostics 4건, error/warning 0 |
| API 전체 | `cd packages/truenas_api && fvm dart test --reporter compact` | exit 0, **45 tests passed** |
| 외부 consumer | `cd examples/design_system_consumer && fvm flutter analyze && fvm flutter test --reporter compact` | exit 0, no issues, **1 test passed** |
| whitespace | `git diff --check` | exit 0 |

Breakpoint widget tests는 599/600/999/1000을 포함합니다. connection tests는 성공한 safe metadata seeding/shell 전환, 실패 시 form 유지, API-key sentinel 비렌더링을 별도로 검증합니다.

## Hosted exact-head CI

GitLab pipeline [`528`](https://git.sanhouse.kr/sjungwon03/trueraid/-/pipelines/528)은 기능·CI 커밋 `8d0536f3c4d6aab14179c31e09a15661aeaec7e0`에서 **success**였습니다.

| job | runner | 실제 결과 |
| --- | --- | --- |
| [`portable_quality_and_web` #1690](https://git.sanhouse.kr/sjungwon03/trueraid/-/jobs/1690) | protected `shared-build` Linux amd64 | format, API/design-system/consumer/app analyze와 전체 tests, Web release build 성공 |
| [`macos_release` #1691](https://git.sanhouse.kr/sjungwon03/trueraid/-/jobs/1691) | protected `shared-macos` arm64 | macOS release build, strict codesign, `network.client=true` 검증 성공 |

CI는 `.fvmrc`의 Flutter `3.47.0`을 사용합니다. Linux shell runner는 exact Flutter tag를 job workspace에 준비하고, macOS runner는 FVM의 pinned SDK를 사용합니다. source branch도 force-push 금지·Maintainer 전용 protected branch로 설정했습니다.

## Release build·서명 검증

| 명령 | 실제 결과 |
| --- | --- |
| `cd apps/trueraid && fvm flutter build web --release` | exit 0 — `✓ Built build/web` |
| `cd apps/trueraid && fvm flutter build macos --release` | exit 0 — `✓ Built .../trueraid.app (49.7MB)` |
| `codesign --verify --deep --strict --verbose=2 .../trueraid.app` | exit 0 — valid on disk, satisfies Designated Requirement |
| `codesign -d --entitlements :- .../trueraid.app` | `com.apple.security.app-sandbox=true`, `com.apple.security.network.client=true` |
| `macos/Runner/Release.entitlements` 직접 확인 | app sandbox와 network client만 선언 |

로컬 산출물은 ad-hoc signature(`TeamIdentifier=not set`)이며 배포용 Developer ID/App Store 서명 또는 notarization 증거가 아닙니다.

## Production Web rendered QA

검증 대상 구현의 실제 `AdaptiveShell`, 실제 `ServerProfile`, 실제 Riverpod controller를 저장소에 남기지 않는 QA entrypoint로 구성하고 `flutter build web --release`로 production bundle을 만든 뒤 localhost static server와 별도 임시 Chrome/CDP profile에서 검사했습니다. QA entrypoint·서버·Chrome profile은 검사 후 제거했습니다.

| viewport/theme | 실제 결과 |
| --- | --- |
| 320×800 light/dark | compact `NavigationBar`; 네 destination 전체 표시; body text 정상 줄바꿈; `innerWidth == scrollWidth == 320` |
| 390×800 light/dark | compact `NavigationBar`; 네 destination 전체 표시; `innerWidth == scrollWidth == 390` |
| 768×800 dark | compact rail; label·icon·content overlap/clip 없음 |
| 1024×800 dark | extended rail; label·icon·content overlap/clip 없음 |
| 1440×900 light/dark | extended rail; content max-width와 중앙 정렬 유지; light에서 `innerWidth == scrollWidth == 1440` |

추가 interaction capture:

- 390×800 light에서 첫 Tab 후 실제 `Studio NAS` popup trigger 외곽에 focus ring이 렌더되고 잘리지 않았습니다.
- 두 번째 Tab 후 실제 Home bottom-navigation action rect에 selected pill과 구분되는 focus ring이 렌더되고 잘리지 않았습니다.
- CDP runtime 수집 결과 `Runtime.exceptionThrown=0`, browser error/warning log entry `0`입니다.

육안/이미지 검토에서 missing icon/text, navigation overlap, horizontal overflow, clipping, blank frame, blocking contrast defect를 발견하지 못했습니다.

## 범위·보안 점검

- remediation 변경은 `apps/trueraid`의 shell/profile 구현과 테스트, root GitLab CI와 runner bootstrap shim, 이 evidence 문서에 한정합니다. dependency/lockfile, `packages/truenas_api`, platform TLS 코드는 변경하지 않았습니다.
- M1 profile/shell 파일은 persistence, discovery, secure storage, TLS trust mutation, credential persistence, reconnect coordinator, capability registry, operational data, ads/billing을 구현하지 않습니다.
- 이 구현은 credential-backed live switching, real TrueNAS interoperability, Developer ID/notarized distribution, Android/iOS build, 또는 TD-002 완료의 증거가 아닙니다.
