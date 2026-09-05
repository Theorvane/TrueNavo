# M1 적응형 앱 셸 및 세션 메모리 서버 프로필 구현 계획

> **For Hermes:** 이 계획을 구현할 때에는 작업별로 격리 worktree에서 Codex CLI를 좁은 프롬프트와 `--sandbox workspace-write`로 호출하고, Hermes가 모든 RED/GREEN 결과·diff·최종 검증을 독립 확인한다.

**Goal:** 기존 M0 보안 연결 성공 뒤에 비밀 없는 세션 메모리 프로필을 만들고, Home/Alerts/Manage/Jobs를 실제 폭에 따라 탐색하는 접근 가능한 M1 셸을 제공한다.

**Architecture:** 모든 M1 도메인은 `apps/truedash`에만 둔다. `ServerProfile`은 다섯 개의 허용 metadata만 가진 immutable 값 객체이고, Riverpod `Notifier` 기반 catalog/controller는 프로세스 메모리의 정렬·중복 endpoint upsert·선택·제거 fallback만 담당한다. 연결 controller는 성공한 `ServerSummary`에서 허용 필드만 한 번 변환하여 catalog에 등록한 뒤 상태를 성공으로 바꾸며, 앱 root는 성공+선택 profile일 때에만 `AdaptiveShell`을 표시한다. 셸의 profile 선택은 표시 context만 바꾸며 transport·credential·reconnect·data fetch를 호출하지 않는다.

**Tech Stack:** Flutter/Dart 3.13, flutter_riverpod 3, Material 3, 기존 `truedash_design_system`, FVM, `flutter_test`, `glab`.

**승인/기준:** 사용자 승인 설계 `docs/planning/M1_ADAPTIVE_SHELL_SERVER_PROFILE_DESIGN.md`(69b1b21), 원래 스택 기준 `bac42639d5d52eaa1f1c595737bd795142c8414f`, 구현 브랜치 `feat/m1-adaptive-shell-server-profile`. 이 계획은 `design/design-system-foundation` 위의 stack이며 M1 MR은 !2가 열려 있는 동안 그 branch를 target으로 한다.

**불변 안전 경계:** `truenas_api`와 `truedash_design_system`은 수정하지 않는다. 새 패키지/플러그인을 추가하지 않는다. `ServerProfile`, catalog state, UI copy, test fixture, evidence에 API key/password/token/credential reference, TLS fingerprint·trust decision, identity, method/capability set, raw error/log를 저장·표시하지 않는다. HTTPS/WSS-only 및 기본 TLS 검증은 M0 그대로 둔다.

---

## 구현 전 공통 규칙

- 작업 시작 전에 `git status --short --branch`, `git rev-parse HEAD`, `git merge-base --is-ancestor bac42639d5d52eaa1f1c595737bd795142c8414f HEAD`를 확인한다. 공유 checkout과 `/Users/jungwon/workspace/.worktrees/truedash-design-system`은 사용하지 않는다.
- 각 RED는 코드 구현 전 별도 커밋 없이 실제 실패 원인(미구현 type/widget/behavior assertion)을 기록한다. 그 뒤 최소 구현만 하고 같은 command가 GREEN인지 확인한다. Codex에는 해당 Task의 파일 목록과 금지 경계만 전달하며, 비밀 읽기, dependency 변경, merge/rebase/push는 허용하지 않는다.
- fixture의 `ServerSummary`는 API key·TLS·identity·availableMethodNames를 profile 또는 렌더링 assertion에 전달하지 않는다. endpoint는 `https`/`wss`의 이미 검증된 예시만 쓴다.
- 각 Task 완료 후 `fvm dart format <변경 dart 경로>`와 해당 test를 실행한다. 계획 문서는 마지막 단일 docs commit으로 묶고, 구현에서는 기능 단위 Korean commit을 만든다.

## Task 1: 허용 metadata 모델과 순수 변환 경계를 고정

**Objective:** 다섯 개 필드만 갖는 immutable `ServerProfile` 및 안전한 M0 summary 변환 계약을 test-first로 만든다.

**Files:**
- Create: `apps/truedash/lib/features/server_profiles/server_profile.dart`
- Create: `apps/truedash/test/features/server_profiles/server_profile_test.dart`

**Step 1 — RED test 작성:** `ServerProfile`의 `id`, `displayName`, `originalHostInput`, `normalizedEndpoint`, `lastKnownVersion` equality와 `copyWith` 또는 동일 목적의 metadata update를 검증한다. `ServerSummary(identity: 'private-identity', availableMethodNames: {'private.method'})`에서 생성한 profile이 endpoint/original host/version 및 안전한 display name만 갖는지 검증한다. reflection 대신 생성자와 public getter만 사용해 허용 필드가 API surface의 전부임을 코드 review checklist에 기록한다.

**Step 2 — RED 실행:**
```bash
fvm flutter test apps/truedash/test/features/server_profiles/server_profile_test.dart
```
Expected: FAIL — `ServerProfile` 또는 safe conversion API가 정의되지 않음.

**Step 3 — 최소 GREEN 구현:** `final class ServerProfile`을 immutable constructor와 value equality로 구현한다. profile id는 catalog가 제공한 opaque 문자열을 받으며 endpoint/identity로 재생성하지 않는다. `fromSafeSummary`는 original host, `endpointUri.toString()`, version, 안전한 표시명만 추출한다. identity와 method names를 읽거나 보관하지 않는다; displayName의 fallback은 original host의 비밀 없는 host 부분으로 정한다.

**Step 4 — GREEN 실행:** 같은 command가 PASS여야 한다.

**Step 5 — 검토:** `git diff -- apps/truedash/lib/features/server_profiles/server_profile.dart`에서 금지 field/import/log가 없는지 확인한다.

## Task 2: 메모리 전용 catalog/controller의 결정적 상태 계약

**Objective:** 네트워크·저장소 없이 profile upsert/select/remove fallback을 deterministic하게 제공한다.

**Files:**
- Create: `apps/truedash/lib/features/server_profiles/server_profiles_controller.dart`
- Create: `apps/truedash/test/features/server_profiles/server_profiles_controller_test.dart`
- Modify: `apps/truedash/lib/features/server_profiles/server_profile.dart` (Task 1 API가 필요한 경우만)

**Step 1 — RED test 작성:** `ProviderContainer`에서 다음을 검증한다: (a) `registerAndSelect`는 id 순서 또는 최초 등록 순서로 문서화된 안정 순서를 유지하고 선택한다, (b) 동일 normalized endpoint의 새 metadata는 새 entry를 추가하지 않고 기존 opaque id를 유지하며 갱신·선택한다, (c) `select`는 unknown id에서 state를 바꾸지 않는다, (d) 선택 항목 제거 시 남은 profile 중 문서화한 첫 항목을 선택하고 마지막 제거 시 null, (e) 새 container에서는 catalog가 비어 있어 memory-only임을 보인다.

**Step 2 — RED 실행:**
```bash
fvm flutter test apps/truedash/test/features/server_profiles/server_profiles_controller_test.dart
```
Expected: FAIL — controller/provider/state가 없음.

**Step 3 — 최소 GREEN 구현:** `ServerProfilesState`는 unmodifiable ordered profiles와 `selectedProfileId`만 가진 immutable state로 둔다. `ServerProfilesController extends Notifier<ServerProfilesState>` 및 provider를 추가한다. 정책은 **normalizedEndpoint exact match가 duplicate key이고, first-registration order를 보존하며, duplicate upsert는 기존 id를 보존하고 해당 profile을 선택한다; selected removal은 남아 있는 first-registration profile을 선택한다**로 코드와 test에 동일하게 명시한다. I/O, transport, vault, persistence, logging API를 추가하지 않는다.

**Step 4 — GREEN 실행:** Task 2 command PASS.

**Step 5 — focused regression:**
```bash
fvm flutter test apps/truedash/test/features/server_profiles/
```
Expected: PASS.

## Task 3: 고정 목적지와 breakpoint selector를 순수 UI contract로 분리

**Objective:** 네 목적지 순서와 599/600/999/1000 navigation mode를 독립적으로 testable하게 만든다.

**Files:**
- Create: `apps/truedash/lib/app_shell/app_destination.dart`
- Create: `apps/truedash/lib/app_shell/adaptive_shell.dart`
- Create: `apps/truedash/test/app_shell/app_destination_test.dart`
- Create: `apps/truedash/test/app_shell/adaptive_shell_test.dart`

**Step 1 — RED test 작성:** `AppDestination.values`가 정확히 Home, Alerts, Manage, Jobs 순인지, 각각 semantic label이 있는지 검증한다. `AdaptiveShell`을 599/600/999/1000 logical px에 pump해 `<600`은 `NavigationBar`, `600–999`는 non-extended `NavigationRail`, `>=1000`은 extended rail임을 검증한다. selected destination은 mode 교체 뒤에도 유지해야 한다.

**Step 2 — RED 실행:**
```bash
fvm flutter test apps/truedash/test/app_shell/app_destination_test.dart apps/truedash/test/app_shell/adaptive_shell_test.dart
```
Expected: FAIL — app-shell library가 없음.

**Step 3 — 최소 GREEN 구현:** `AppDestination` enum에 고정 label/icon을 정의한다. `AdaptiveShell`은 `LayoutBuilder`의 실제 maxWidth만 기준으로 `NavigationBar`/72px rail/`extended: true` rail을 선택하고, 모바일 padding 16, tablet 24, desktop 32 및 desktop content max-width 1440을 적용한다. Flutter selected semantics를 유지하고 icon-only 전역 action에는 `Tooltip`과 `Semantics(label: ...)`을 함께 준다. 목적지 내용은 각 제목, selected profile의 displayName 또는 “선택된 서버 없음”, “데이터 연결은 후속 슬라이스에서 제공” 정적 안내만 출력한다.

**Step 4 — GREEN 실행:** Task 3 command PASS.

**Step 5 — mode boundary regression:**
```bash
fvm flutter test apps/truedash/test/app_shell/adaptive_shell_test.dart --plain-name '599'
fvm flutter test apps/truedash/test/app_shell/adaptive_shell_test.dart --plain-name '600'
fvm flutter test apps/truedash/test/app_shell/adaptive_shell_test.dart --plain-name '999'
fvm flutter test apps/truedash/test/app_shell/adaptive_shell_test.dart --plain-name '1000'
```
Expected: all PASS.

## Task 4: profile switcher와 honest empty/non-data UI

**Objective:** 현재 세션의 profile metadata만 전환하고 live reconnection/data를 암시하지 않는 selector를 제공한다.

**Files:**
- Create: `apps/truedash/lib/features/server_profiles/server_switcher.dart`
- Modify: `apps/truedash/lib/app_shell/adaptive_shell.dart`
- Modify: `apps/truedash/test/app_shell/adaptive_shell_test.dart`
- Create or Modify: `apps/truedash/test/features/server_profiles/server_switcher_test.dart`

**Step 1 — RED test 작성:** 두 seeded profile을 selector에서 선택하면 제목/현재 서버 label만 바뀌고 controller profile count/order가 유지됨을 검증한다. empty catalog는 “선택된 서버 없음” 및 memory-only 설명을 보이고 discovery/reconnect/credential prompt를 보이지 않아야 한다. Home/Alerts/Manage/Jobs 모두 non-data placeholder를 표시하고 metric/chart/job row/성공 수치를 보이지 않아야 한다.

**Step 2 — RED 실행:**
```bash
fvm flutter test apps/truedash/test/features/server_profiles/server_switcher_test.dart apps/truedash/test/app_shell/adaptive_shell_test.dart
```
Expected: FAIL — switcher/empty-state behavior가 없음.

**Step 3 — 최소 GREEN 구현:** `ServerSwitcher`는 catalog profiles에서만 목록을 만들며 44×44 이상 trigger·menu item, explicit semantics label, 예측 가능한 focus restoration을 제공한다. AppShell은 profile 선택에서 controller `select`만 호출한다. “서버 선택은 이 앱 실행 동안 표시 대상만 변경하며 연결을 재개하지 않습니다.”와 destination별 non-data copy를 사용한다. empty return action은 `ConnectionScreen`을 push하는 명시적 UI 경로만 제공하고, catalog에 profile을 만들거나 session을 복원하지 않는다.

**Step 4 — GREEN 실행:** Task 4 command PASS.

**Step 5 — secret boundary assertion:** widget tree visible text에서 test sentinel, `private-identity`, `private.method`, `TLS fingerprint`, `trust decision`, `API key`가 없음을 assert한다.

## Task 5: M0 성공을 safe profile seed 및 shell 진입에 연결

**Objective:** 성공 연결만 profile을 등록·선택하고 root를 shell로 전환하며 M0 오류 처리와 TLS 계약은 보존한다.

**Files:**
- Modify: `apps/truedash/lib/features/connection/connection_controller.dart`
- Modify: `apps/truedash/lib/features/connection/connection_screen.dart`
- Modify: `apps/truedash/lib/truedash_app.dart`
- Modify: `apps/truedash/test/features/connection/connection_screen_test.dart`
- Modify: `apps/truedash/test/features/connection/connection_screen_accessibility_test.dart`
- Modify: `apps/truedash/test/truedash_app_theme_test.dart` (root mode assertion에 필요한 경우만)

**Step 1 — RED test 작성:** fake success repository로 connect하면 Home shell과 safe display name만 보이고 `Connection summary`, identity/method count, secret sentinel은 보이지 않아야 한다. success profile은 controller에 하나 등록·선택되어야 한다. fake auth/TLS/validation failures는 connection form에 남고 profile catalog가 empty여야 한다. 기존 secure endpoint validation·masked API-key assertion을 유지한다.

**Step 2 — RED 실행:**
```bash
fvm flutter test apps/truedash/test/features/connection/connection_screen_test.dart apps/truedash/test/features/connection/connection_screen_accessibility_test.dart
```
Expected: FAIL — success는 현재 connection summary만 표시하고 catalog/shell 전환이 없음.

**Step 3 — 최소 GREEN 구현:** `ConnectionController`에서 repository success 직후 `ServerProfile.fromSafeSummary`와 catalog의 `registerAndSelect`만 호출하고 `ConnectionSucceeded`를 유지한다. transport, credential vault, TLS setting, session repository interface를 변경하지 않는다. `TrueDashApp`은 `ConsumerWidget` 또는 동등한 Riverpod root로서 성공 상태와 selected profile가 있을 때만 AppShell을 선택한다. ConnectionScreen은 기존 safe failure/busy flow를 보존하고 성공 summary/identity/method UI를 제거한다.

**Step 4 — GREEN 실행:** Task 5 command PASS.

**Step 5 — controller regression:**
```bash
fvm flutter test apps/truedash/test/features/connection/connection_screen_test.dart --reporter expanded
```
Expected: PASS with success and all failure cases.

## Task 6: 접근성·reflow·theme/reduced-motion widget 검증

**Objective:** 최소 target, focus/keyboard/semantics, 200% text, all required widths, light/dark와 reduced-motion-safe 정적 UI를 실제 widget tests로 증명한다.

**Files:**
- Modify: `apps/truedash/test/app_shell/adaptive_shell_test.dart`
- Create or Modify: `apps/truedash/test/app_shell/adaptive_shell_accessibility_test.dart`
- Modify: `apps/truedash/test/features/connection/connection_screen_accessibility_test.dart` (M0→shell focus path 필요한 경우만)

**Step 1 — RED test 작성:** 320/390/768/1024/1440에서 `tester.takeException()`이 null이고 render object 폭이 viewport를 넘지 않는지, long display name + 200% text에서 layout overflow가 없는지 검증한다. navigation/profile/return actions의 hit bounds가 44×44 이상인지, keyboard Tab order가 global action→navigation→content action인지, Enter/Space로 destination 전환되는지, selected navigation semantic state와 icon semantic labels가 있는지 검증한다. light/dark pump에 exception이 없고 `MediaQuery.disableAnimations`에서도 controller가 animation을 새로 만들지 않는 정적 UI인지 검증한다.

**Step 2 — RED 실행:**
```bash
fvm flutter test apps/truedash/test/app_shell/adaptive_shell_accessibility_test.dart
```
Expected: FAIL — 누락된 semantics/focus/reflow 보장이 드러남.

**Step 3 — 최소 GREEN 구현:** 필요한 경우에만 `FocusTraversalGroup`, `Semantics`, `ConstrainedBox`, `Expanded/Flexible`, overflow-safe `Text(maxLines/overflow/semanticsLabel)`을 추가한다. 목적지 전환용 custom animation을 추가하지 않는다. `TdStateView` 및 design-system semantic token을 우선 사용한다.

**Step 4 — GREEN 실행:** same command PASS.

**Step 5 — full app test:**
```bash
fvm flutter test apps/truedash
```
Expected: PASS; no rendered overflow, Flutter exception, or secret-visible assertion failure.

## Task 7: 정적 경계·회귀·release build 검증 및 evidence

**Objective:** scope/security boundary와 빌드 결과를 사실 기반 evidence로 남긴다.

**Files:**
- Create: `docs/planning/M1_ADAPTIVE_SHELL_SERVER_PROFILE_IMPLEMENTATION_EVIDENCE.md`
- Modify: `docs/README.md`

**Step 1 — RED-equivalent scope audit:** 다음 command를 실행해 forbidden surface가 새 M1 파일에 생기지 않았는지 확인한다. 매치는 fixture/legacy M0 code가 아닌 새 profile/shell/evidence paths로 한정해 해석한다.
```bash
rg -n -i 'api[ -]?key|password|token|credential|fingerprint|trust|availableMethodNames|identity|reconnect|secure.?storage|shared_preferences|discovery|billing|advert' apps/truedash/lib/app_shell apps/truedash/lib/features/server_profiles docs/planning/M1_ADAPTIVE_SHELL_SERVER_PROFILE_IMPLEMENTATION_EVIDENCE.md
```
Expected: non-zero/no matches after allowlisted explanatory non-secret copy를 제거하거나 wording을 고친 상태. `TLS` 또는 credential을 설명하는 text도 rendered UI/evidence에는 넣지 않는다.

**Step 2 — format/analyze/tests:**
```bash
fvm dart format --set-exit-if-changed .
fvm flutter analyze packages/truedash_design_system
fvm flutter analyze apps/truedash
fvm flutter test packages/truedash_design_system
fvm flutter test apps/truedash
fvm dart test packages/truenas_api
```
Expected: every command exit 0. 실패하면 해당 범위만 수정하고 RED/GREEN을 재기록한다.

**Step 3 — release builds:**
```bash
fvm flutter build web --release --target apps/truedash/lib/main.dart
fvm flutter build macos --release --target apps/truedash/lib/main.dart
codesign --verify --deep --strict build/macos/Build/Products/Release/truedash.app
```
Expected: web build exit 0; macOS build/codesign은 host signing configuration의 실제 결과를 evidence에 그대로 기록한다. signing entitlement/provisioning 문제는 성공으로 바꾸지 말고 blocker로 분리한다.

**Step 4 — evidence 작성:** command, exit code, pass count, build output path, environment limits, commit SHA, no-secret scan 결과를 기록한다. 실제 TrueNAS interoperability, credential-backed switching 또는 TD-002 완료를 주장하지 않는다. README에 design 및 implementation plan/evidence index links를 추가한다.

## Task 8: production Web rendered QA, cleanup, commit/push, GitLab MR handoff

**Objective:** 실제 production Web build를 browser matrix로 확인하고, issue-linked stacked MR을 정확한 SHA로 전달한다.

**Files:**
- Modify: `docs/planning/M1_ADAPTIVE_SHELL_SERVER_PROFILE_IMPLEMENTATION_EVIDENCE.md` (actual matrix/result만)

**Step 1 — production serving:** `build/web`만 local static server로 serve한다. 개발 서버나 mock API를 사용하지 않는다. task-created process PID와 port를 기록한다.

**Step 2 — browser matrix:** production build를 실제 browser에서 320/390/768/1024/1440 viewport, light/dark, connection form, seeded shell profile, empty shell, long display name, 200% text, reduced motion으로 확인한다. 각 상태에서 viewport, `document.documentElement.scrollWidth <= innerWidth`, console error count, screenshot/evidence path를 기록한다. browser automation은 task-created tab만 닫고 verification 직후 local server/process도 종료한다.

**Step 3 — diff review:**
```bash
git diff --check
git status --short
git diff --name-only design/design-system-foundation...HEAD
git diff -- apps/truedash/lib/app_shell apps/truedash/lib/features/server_profiles apps/truedash/lib/features/connection apps/truedash/lib/truedash_app.dart docs
```
Expected: permitted app/docs paths만 보이며 packages 변경, lockfile/dependency drift, secrets/TLS contract change가 없음.

**Step 4 — commits and remote verification:** implementation and evidence/docs를 Korean conventional commits로 commit하고 `git push origin feat/m1-adaptive-shell-server-profile`한다. `git ls-remote origin refs/heads/feat/m1-adaptive-shell-server-profile`의 SHA가 local `HEAD`와 같은지 확인한다.

**Step 5 — GitLab MR:** verified M1 issue description의 `Closes #<issue>`를 포함해 source `feat/m1-adaptive-shell-server-profile`, target `design/design-system-foundation` MR을 **한 개만** 생성한다. body에는 !2/!1 위 stacked dependency, TD-002 미완료, no-live-data/no-reconnect/no-persistence boundary, verification table을 쓴다. merge/rebase/history rewrite는 하지 않는다. `glab mr view <number>` 및 API/readback으로 URL, open state, source SHA, target branch, pipeline/approval status, mergeability를 evidence와 Kanban handoff에 기록한다.

**Step 6 — retarget protocol:** !2가 `feat/m0-foundation`에 merge된 뒤에만 target을 `feat/m0-foundation`으로 retarget하고 diff/mergeability를 재검증한다. !1이 `main`에 merge된 뒤에만 target을 `main`으로 retarget하고 다시 재검증한다. 어느 retarget도 auto-merge/merge를 수행하지 않는다.

**Step 7 — cleanup:** remote SHA와 GitLab readback 뒤 `git status --short`가 clean인 task-created worktree만 `git worktree remove <task-worktree>`로 제거한다. production browser tab, static server, mock process가 남지 않았음을 process/tab list로 확인한다.

---

## Codex delegation boundary

Codex implementation prompt마다 다음을 명시한다: 현재 Task의 exact files만 수정, first write tests and show the RED result, then minimal implementation and show GREEN; `packages/truenas_api`, `packages/truedash_design_system`, workspace dependency files, credential/TLS behavior, Git history/remotes는 변경 금지; secret files/environment를 읽지 말 것; no `git commit`, `git push`, merge, browser/server 실행. Hermes는 Codex 결과 후 `git diff`, `git diff --check`, permitted-file allowlist, secret/TLS scan과 모든 required command를 독립 실행한다.

## Issue/MR delivery workflow

1. 이 문서와 README index를 commit/push한 뒤 (구현 전) GitLab issue 한 개를 만든다. Issue는 approved design/this plan links, scope, non-goals, acceptance checklist, `TD-002는 완료되지 않음`을 포함한다.
2. `glab issue view <number>`로 URL/number/open state/body를 readback한다. issue가 없거나 readback가 실패하면 구현 card를 unblock하지 않는다.
3. 구현 card는 issue와 exact planning SHA를 전제조건으로 삼는다. MR은 implementation 완료 뒤에만 생성한다.
4. final review handoff에는 exact remote SHA, issue URL/number, MR URL/number, target/source, pipeline/approval/mergeability readback, command results, browser QA matrix와 cleanup 증거를 넣는다.
