# M1 설계: 적응형 앱 셸과 메모리 전용 서버 프로필

> 상태: 사용자 승인된 설계의 작성 명세. 이 문서는 M1의 작은 세로 슬라이스만 정의하며, TD-002 또는 다중 서버 연결 기능의 완료를 주장하지 않는다.
>
> 기준 커밋: `3ae642a6165c126623e6dd164de640c429ba26b3` (`main`, 2026-09-05)
>
> 선행 근거: [M0 Foundation 설계](./M0_FOUNDATION_DESIGN.md), [TrueDash 디자인 시스템](./TRUEDASH_DESIGN_SYSTEM.md), [제품 기획안](./TRUEDASH_PRODUCT_PLAN.md)

## 1. 목적과 범위

M1은 보안 WSS/API-key 연결을 이미 제공하는 M0 위에 실제 제품 탐색 구조를 놓는다. 연결이 성공하면 사용자는 현재 세션에서 선택된 서버의 이름을 확인하고 Home, Alerts, Manage, Jobs 네 목적지 사이를 이동할 수 있다. 각 목적지는 데이터·명령·재연결을 제공하지 않는 명시적 placeholder로 시작한다.

이 슬라이스는 앱 소유의 `ServerProfile`과 `ServerProfileCatalog` 경계를 정의한다. catalog는 프로세스 메모리에만 존재하며 현재 선택과 안전한 메타데이터만 관리한다. `truenas_api`의 전송·JSON-RPC·인증 계약과 `truedash_design_system`의 범용 토큰·컴포넌트는 이 경계에 의존하지 않는다.

## 2. 구현 경계와 의존성

앱 패키지 `apps/truedash` 안에 셸과 프로필 기능을 둔다. 제안 파일 배치는 다음과 같으며, 정확한 private file name은 구현 계획에서 확정한다.

```text
apps/truedash/lib/
  features/server_profiles/
    server_profile.dart                 # 불변 metadata 값 객체
    server_profile_catalog.dart         # session-memory 선택/등록 경계
    server_profile_providers.dart       # Riverpod provider와 controller
  features/shell/
    app_shell.dart                      # breakpoint별 navigation layout
    shell_destination.dart              # 네 고정 목적지와 label/icon
    destination_placeholder.dart        # 비데이터 상태 화면
  truedash_app.dart                     # 연결 화면 또는 shell의 최상위 전환
```

의존 방향은 한쪽뿐이다.

```text
ConnectionController 성공 ServerSummary
              ↓  (안전한 필드만 변환)
App-owned ServerProfileCatalog ← Shell controller/UI
              ↓
truedash_design_system tokens/theme/components

truenas_api transport/session ── X ── ServerProfileCatalog
```

`ServerProfile`은 다음 다섯 값만 가진다.

| 필드 | 의미 | 출처 |
|---|---|---|
| `id` | 앱이 만든 opaque identifier | catalog |
| `displayName` | 사용자에게 표시할 비밀 없는 서버 이름 | 안전하게 추출한 M0 summary |
| `originalHostInput` | 사용자가 연결 화면에 입력한 원문 | M0 summary |
| `normalizedEndpoint` | 검증 후 연결에 사용된 endpoint | M0 summary |
| `lastKnownVersion` | 마지막으로 성공한 연결에서 얻은 버전 | M0 summary |

이 모델에는 API key, 비밀번호, bearer token, credential reference, TLS fingerprint, 인증서 trust 결정, RPC method/capability payload, 인증 identity detail, raw 오류, 로그를 넣지 않는다. 프로필 ID는 endpoint 또는 서버 identity를 재료로 재현하지 않는 opaque 값이며 보안 식별자나 영속 키로 취급하지 않는다.

`ServerProfileCatalog`은 `registerAndSelect(profile)`, `select(id)`, `selectedProfile`, `profiles`라는 메모리 범위의 계약만 가진다. 등록은 동일 ID의 metadata를 갱신할 수 있으나 네트워크 요청·자격 증명 조회·연결 재시도·저장을 수행하지 않는다. 선택도 UI 상태 변경일 뿐, 서버 세션을 바꾸거나 live data를 로드하지 않는다.

## 3. 화면 구조와 반응형 규칙

목적지는 고정 순서 Home, Alerts, Manage, Jobs다. 선택 항목은 icon, text label, selected semantic state를 동시에 가진다. 서버 전환과 검색은 목적지가 아닌 전역 action으로 분류한다. M1에서 전역 서버 action은 session-memory catalog의 프로필을 선택할 수 있는 UI 경계만 제공할 수 있으며, 검색은 비데이터 placeholder 또는 후속 범위 안내를 제공한다. 어느 action도 연결·재연결 성공을 암시하지 않는다.

| layout width | navigation | content 규칙 |
|---|---|---|
| `<600` | 하단 `NavigationBar` | 단일 pane, 4개 목적지, page padding 16 |
| `600–999` | 72px `NavigationRail` | rail 옆 단일 content pane, page padding 24 |
| `>=1000` | 확장된 `NavigationRail` | label이 보이는 224px 이하 rail과 content, page padding 32, content max-width 1440 |

분기는 OS 종류나 orientation이 아니라 `LayoutBuilder`의 실제 사용 가능 width로 결정한다. 600과 1000은 각각 새 구간에 포함된다. 이 규칙은 이미 디자인 시스템의 `TrueDashDensity.resolve`: `<600` comfortable, `600–999` standard, `>=1000` compact와 반드시 동일한 width를 사용한다.

각 목적지는 제목, 짧은 범위 설명, 선택된 서버의 비밀 없는 이름, 그리고 “데이터 연결은 후속 슬라이스에서 제공”이라는 상태를 표시한다. Home은 Dashboard를, Alerts는 경고 데이터를, Manage는 관리 명령을, Jobs는 job feed를 대체하지 않는다. 화면에는 0개 데이터·차트·행이 있는 것이 정상 상태이며 fake metric이나 성공 수치를 표시하지 않는다.

## 4. 상태 전환과 데이터 흐름

앱은 여전히 M0 연결 화면에서 시작한다. M0의 endpoint 검증, WSS-only 규칙, TLS 기본 검증, API key 마스킹, 인증 오류 분류, transport close 계약은 변경하지 않는다.

```text
ConnectionScreen
  ├─ idle / validating / connecting / failed  → M0 화면에 머무름
  └─ success(ServerSummary)
       → ServerProfile.fromSafeSummary(summary)
       → catalog.registerAndSelect(profile)
       → AppShell(selectedProfile, initial Home)

AppShell
  ├─ destination tap / keyboard activation → selected destination만 변경
  ├─ profile selection → catalog selectedProfile만 변경
  └─ app process 종료 / provider dispose → catalog과 profiles 소멸
```

`ServerSummary`에서 변환하는 값은 original host input, normalized endpoint, version과 표시 가능한 안전한 이름뿐이다. M0 summary의 identity나 available method names는 profile에 전달하지 않는다. 성공 후 M0의 실제 transport가 살아 있는지, 어떤 권한이 있는지, 선택한 다른 profile에 연결되었는지는 shell 상태로부터 추론할 수 없다.

다음 전환을 UI 문구와 테스트에서 구분한다.

- 연결 성공은 “이 세션에서 프로필 metadata가 선택되어 shell로 이동”만 의미한다.
- 기존 profile 선택은 “표시 대상 변경”만 의미한다. live reconnection 또는 active session 교체가 아니다.
- 앱 재시작, provider 재생성, logout 성격의 session dispose는 catalog를 비운다. profile이 복원되었다고 표시하지 않는다.
- M0 연결 실패와 TLS·인증 오류는 connection 화면에 남으며 profile을 생성하거나 shell로 이동하지 않는다.
- catalog가 비어 있는데 shell을 직접 열게 되는 테스트·복구 경로는 Home에서 “선택된 서버 없음” empty state를 표시하고, 서버 선택 UI는 비어 있음을 설명한다. 자동 발견이나 연결 시작은 하지 않는다.

## 5. Empty, error, loading 상태

M1은 destination data를 요청하지 않으므로 destination별 loading spinner, 실패 재시도, stale indicator를 만들지 않는다. placeholder는 loading으로 오해되지 않는 정적 non-data state다.

| 상황 | 표시 | 금지 동작 |
|---|---|---|
| 선택된 profile과 destination | 서버 이름과 목적지별 non-data 안내 | metric, alert, job, capability 결과 표시 |
| catalog가 비어 있음 | “선택된 서버 없음”과 연결 화면으로 돌아갈 수 있는 명시적 action | discovery, 자동 reconnect, credential prompt |
| profile 선택 UI에 항목 없음 | session-memory profile이 없음을 설명 | persistence가 있는 것처럼 보이는 recent-server UI |
| M0 연결 실패 | 기존 M0의 비밀 없는 오류와 재시도 흐름 | shell 전환, TLS 우회, API key 노출 |
| 지원하지 않는 전역 search | 아직 데이터 검색을 제공하지 않는다는 안내 | 서버·dataset·job 결과를 꾸며서 표시 |

오류 문자열, analytics event, debug logging에 profile 외 금지 데이터와 원본 API key를 추가하지 않는다. 디자인 시스템의 기존 `TdStateView`와 semantic color/token을 우선 사용하며, M1이 새로운 transport 오류 체계를 만들지 않는다.

## 6. 접근성 및 사용자 영향

셸은 320, 390, 599, 600, 768, 999, 1000, 1440 CSS logical-pixel width에서 가로 overflow가 없어야 한다. `599→600`과 `999→1000` 변화는 navigation container만 바꾸고 선택한 목적지·profile·읽기 순서를 잃지 않는다. 320에서 긴 서버 이름과 locale text는 줄바꿈 또는 truncation+전체 접근 가능한 label을 사용하며 하단 목적지를 가리지 않는다.

모든 navigation destination, profile selector, 전역 action, 연결 화면으로 돌아가기 action은 최소 44×44 hit target을 제공한다. icon-only control은 accessible name을 갖고 tooltip만으로 의미를 전달하지 않는다. 선택된 목적지는 screen reader에서 label과 selected state가 읽혀야 하며, placeholder의 제목과 현재 서버 이름은 의미 있는 heading/label 관계를 가진다.

키보드 사용자는 시각 순서와 일치하는 Tab traversal로 global action, navigation, content action에 도달하고 Enter/Space로 목적지를 활성화할 수 있어야 한다. focus는 디자인 시스템의 2px semantic focus ring으로 항상 보인다. profile selector를 열고 닫을 때 focus를 예측 가능한 trigger 또는 선택 항목으로 복원한다. 200% text scale에서 primary action, selected destination, current server label, placeholder 상태가 clipping 또는 overlap 없이 접근 가능해야 한다. reduced-motion 설정에서는 transition을 추가하지 않거나 시스템의 감소 설정을 따른다.

## 7. 테스트와 검증 계약

구현은 existing M0 connection·security tests를 변경 기준으로 유지한다. 새 테스트는 실제 TrueNAS·네트워크·secure storage 없이 fake M0 summary와 in-memory catalog으로 다음 계약을 증명한다.

| 구분 | 검증 |
|---|---|
| 모델 | 허용된 다섯 metadata field만 생성·비교 가능하고 secret/TLS/capability field가 public 모델에 없음 |
| catalog | 등록 후 선택, 복수 seed profile 선택, dispose 후 비어 있음, 선택이 transport 호출을 만들지 않음 |
| 연결 전환 | M0 성공만 profile seed 및 Home shell 진입을 만들며 실패·인증·TLS 오류는 만들지 않음 |
| navigation | Home/Alerts/Manage/Jobs가 모든 density에서 선택·semantic label·selected state를 유지 |
| breakpoint | 599/600/999/1000에서 각각 bottom bar/rail/extended rail 계약과 density가 일치 |
| layout | 320/390/599/600/768/999/1000/1440에서 overflow가 없고 긴 label을 안전하게 처리 |
| accessibility | 44×44 target, keyboard activation, visible focus, 올바른 focus order, 200% text scale, icon accessible name |
| regression | format, analyze, workspace/package/app tests, Web release build, macOS release build와 M0 보안 테스트가 통과 |

시각 검증은 light/dark, selected/unselected destination, profile 있음/없음, 긴 server label, 200% text, reduced motion을 포함한다. 실제 browser QA나 release build가 성공해도 live TrueNAS interoperability 또는 TD-002 완료의 증거로 해석하지 않는다.

## 8. 명시적 비목표와 후속 경계

이 문서는 다음을 구현하지 않으며, 임시 메모리 모델로 대체하지도 않는다.

- profile persistence, OS secure vault, credential reference, credential-backed reconnection
- LAN discovery, recent-server history, 자동 선택, background reconnect
- TLS pinning, certificate trust 화면, TOFU, trust mutation, 인증서 검증 우회
- password/SCRAM/2FA/OTP/RBAC 및 active-session switching
- `core.get_methods` 또는 capability payload의 profile 저장·목적지 gating
- Dashboard, Alerts, Manage, Jobs의 실제 data/query/command/event/job 화면
- global server/data search 결과, analytics, logging, billing, 광고

이 제한은 TD-002의 미완료를 의도적으로 보장한다. 후속 설계는 secure storage 및 credential lifecycle, TLS trust UX, authentication state, session lifecycle, capability registry를 별도 위협 모델과 수용 기준으로 승인한 뒤에만 profile persistence 또는 live switching을 추가할 수 있다.

## 9. 구현 인계 기준

구현 계획은 이 명세의 public boundary를 유지하고 M0 `ConnectionController`와 `ServerSummary`의 실제 API에 맞춘 최소 adapter를 정의한다. `truenas_api`와 `truedash_design_system`에 M1 전용 navigation·profile domain을 밀어 넣지 않는다. 모든 UI copy는 session-memory 한계와 비데이터 placeholder임을 숨기지 않아야 하며, 구현 diff가 이 문서의 비목표를 침범하면 별도 설계 승인을 받아야 한다.
