# TrueDash Design System Foundation

> 상태: Approved direction specification
>
> 확정일: 2026-09-05
>
> 기준 방향: **A · Calm Ops + B · Precision Console hybrid**
>
> 적용 시작점: `feat/m0-foundation`의 Connection 화면과 이후 Dashboard·Alerts·Jobs

## 1. 목적

TrueDash 디자인 시스템은 모바일과 데스크톱에서 같은 TrueNAS 상태를 서로 다른 정보 밀도로 표현한다. 모바일은 읽기 순서와 조작 안전성을 우선하고, 데스크톱은 운영자가 여러 리소스와 작업 상태를 빠르게 비교하도록 밀도를 높인다. 두 화면은 별도 디자인이 아니라 동일한 semantic token과 컴포넌트를 공유한다.

이 명세는 색상, 타이포그래피, 간격, 밀도, 상태 표현, 반응형 구조와 기본 컴포넌트 계약을 고정한다. 기능 화면은 토큰을 직접 재정의하지 않는다. 디자인 시스템에 없는 표현이 필요하면 화면에 임시 값을 추가하지 않고 semantic token 또는 컴포넌트 계약을 먼저 확장한다.

## 2. 확정된 시각 방향

A안의 차분한 계층과 읽기 쉬운 카드 구조를 기본으로 사용한다. B안의 compact desktop density, 수치용 monospace, hairline divider, 표·목록 스캔 구조를 결합한다. C안의 자연어 health summary는 Home, onboarding, empty state처럼 설명이 필요한 표면에만 사용하며 모든 화면을 큰 안내 카드로 만들지 않는다.

TrueDash는 다음 인상을 목표로 한다.

- 장시간 사용해도 피로가 적은 운영 도구
- 상태와 위험도를 짧은 시간 안에 판별할 수 있는 정보 구조
- 전문 사용자에게 충분히 조밀하지만 초보 사용자를 배제하지 않는 문장
- 장식보다 리소스, 수치, 시간, 상태가 먼저 보이는 화면
- TrueNAS WebUI나 경쟁 앱의 자산·레이아웃을 복제하지 않는 독립 제품

## 3. 시스템 원칙

### 3.1 의미가 원시 값보다 먼저다

화면은 `Color(0xFF...)`, 임의의 `TextStyle`, 임의 간격을 직접 사용하지 않는다. `textPrimary`, `surfaceRaised`, `space16`, `metricLarge`처럼 역할을 나타내는 토큰을 사용한다. Light와 Dark는 동일한 역할을 서로 다른 값으로 해석한다.

### 3.2 정상 상태는 조용하게 표시한다

정상인 모든 행을 녹색으로 칠하지 않는다. 기본 상태는 중립색으로 두고 사용자의 주의가 필요한 warning, critical, offline, stale에만 상태색을 사용한다. 상태색은 반드시 아이콘과 텍스트 라벨을 동반한다.

### 3.3 모바일과 데스크톱은 밀도가 다르다

모바일은 44px 이상의 조작 영역, 56px 기본 행, 단일 pane을 사용한다. 데스크톱은 44px 행과 compact data table을 허용한다. 작은 모바일 컴포넌트를 데스크톱에 확대하거나 데스크톱 표를 모바일에서 가로 스크롤시키는 방식은 기본 해법으로 사용하지 않는다.

### 3.4 위험도는 시각 위계와 상호작용에 함께 반영한다

파괴적 작업은 일반 primary action과 같은 색·위치·확인 흐름을 사용하지 않는다. 경고 설명, 영향 범위, 리소스 이름 확인, 재인증 여부, 실행 버튼이 단계적으로 나타나야 한다. 색만 바꾸는 것으로 위험 표현을 끝내지 않는다.

### 3.5 수치는 비교 가능해야 한다

용량, 백분율, 온도, 처리량, 시간과 job 진행률은 tabular numeral을 사용한다. 수치와 단위는 약 2:1 크기 비율을 유지하고, 카드 사이에서 baseline과 소수점 표현을 일치시킨다. 기술 식별자, API method, host, IP, 버전은 monospace 역할을 사용한다.

## 4. 디자인 토큰 구조

Flutter API는 세 계층으로 나눈다.

```text
Primitive tokens
  └─ raw color, size, spacing, radius, duration
Semantic tokens
  └─ surface, text, border, action, status, focus
Component tokens
  └─ button, field, card, navigation, table, badge
```

Primitive token은 앱 화면에 직접 노출하지 않는다. `TrueDashThemeExtension`이 semantic token을 제공하고, 공용 컴포넌트가 semantic token을 component token으로 조합한다.

## 5. 색상

### 5.1 Dark theme

Dark는 B안의 precision을 사용하되 순수 검정과 순수 흰색을 피한다.

| Semantic role | Value | 용도 |
|---|---:|---|
| `canvas` | `#0B1117` | 앱 최하단 배경 |
| `surfaceBase` | `#111923` | sidebar, 기본 panel |
| `surfaceRaised` | `#18222E` | card, menu, inspector |
| `surfaceOverlay` | `#202C39` | dialog, popover |
| `borderSubtle` | `#253241` | hairline divider |
| `borderStrong` | `#3A495A` | 선택·강조 경계 |
| `borderControl` | `#60758A` | 경계가 유일한 control 식별 수단일 때 |
| `textPrimary` | `#F2F6F8` | 제목·본문 핵심 |
| `textSecondary` | `#AAB6C2` | 설명·보조 정보 |
| `textMuted` | `#7C8997` | metadata·timestamp |
| `actionPrimary` | `#2CC7D4` | 선택·focus·primary action |
| `onActionPrimary` | `#031719` | primary action 위 텍스트 |
| `statusSuccess` | `#42B883` | 명시적 성공·복구 |
| `statusWarning` | `#F2B84B` | 주의 필요 |
| `statusCritical` | `#F16D75` | 오류·위험 |
| `statusInfo` | `#68A7FF` | 정보·진행 |

검증한 대표 대비는 `textPrimary/canvas 17.45:1`, `textSecondary/canvas 9.20:1`, `textMuted/canvas 5.31:1`, `actionPrimary/canvas 9.24:1`, `onActionPrimary/actionPrimary 8.97:1`이다. `borderControl/surfaceBase`는 3.71:1이다.

### 5.2 Light theme

Light는 A안의 calm operational surface를 사용한다. 카드 그림자보다 배경 단계와 border를 사용한다.

| Semantic role | Value | 용도 |
|---|---:|---|
| `canvas` | `#F4F7F8` | 앱 최하단 배경 |
| `surfaceBase` | `#FFFFFF` | 기본 panel·card |
| `surfaceRaised` | `#EEF2F4` | 보조 group·selected row |
| `surfaceOverlay` | `#FFFFFF` | dialog, popover |
| `borderSubtle` | `#D8E0E5` | hairline divider |
| `borderStrong` | `#AAB7C2` | 선택·강조 경계 |
| `borderControl` | `#738393` | 경계가 유일한 control 식별 수단일 때 |
| `textPrimary` | `#18212B` | 제목·본문 핵심 |
| `textSecondary` | `#596878` | 설명·보조 정보 |
| `textMuted` | `#62717F` | metadata·timestamp |
| `actionPrimary` | `#087D87` | 선택·focus·primary action |
| `onActionPrimary` | `#FFFFFF` | primary action 위 텍스트 |
| `statusSuccess` | `#247653` | 명시적 성공·복구 |
| `statusWarningText` | `#7A4D00` | warning surface 위 텍스트 |
| `statusWarningSurface` | `#FFF4D6` | warning 배경 |
| `statusCritical` | `#B83A45` | 오류·위험 |
| `statusInfo` | `#2768B2` | 정보·진행 |

검증한 대표 대비는 `textPrimary/canvas 15.11:1`, `textSecondary/canvas 5.31:1`, `textMuted/canvas 4.66:1`, `actionPrimary/white 4.89:1`, `statusCritical/white 5.63:1`이다. `borderControl/surfaceBase`는 3.89:1이다. 본문 텍스트는 WCAG AA 4.5:1 미만 조합을 허용하지 않는다.

### 5.3 상태 규칙

`healthy`는 목록 기본 행에서 별도 녹색 배경을 사용하지 않는다. 전체 시스템 health, 완료된 복구 작업, 성공 confirmation처럼 의미가 필요한 경우에만 success를 사용한다. Warning과 critical은 tint surface, 아이콘, 제목, 설명을 함께 제공한다. Stale 데이터는 warning이 아니라 전용 `statusStaleForeground`/`statusStaleSurface`와 `stale` 라벨로 표현하고, 실제 위험 상태와 구분한다. Badge의 실제 합성 foreground/background 대비는 label 크기에서 WCAG AA 4.5:1 이상이어야 한다.

## 6. 타이포그래피

### 6.1 글꼴

기본 UI 글꼴은 **Pretendard Variable**을 번들해 한국어와 Latin의 위계를 동일하게 유지한다. 기술 식별자와 수치는 **JetBrains Mono**를 사용한다. 런타임 네트워크 font 다운로드는 사용하지 않는다. 각 font asset과 라이선스 파일은 패키지에 함께 포함하며, 라이선스 확인 전 binary를 커밋하지 않는다.

Fallback은 다음 순서다.

```text
UI: Pretendard → system sans-serif
Mono: JetBrains Mono → SFMono-Regular → Menlo → monospace
```

### 6.2 역할별 scale

| Role | Size / line | Weight | Tracking | 사용 |
|---|---:|---:|---:|---|
| `display` | `32 / 38` | 650 | `-0.9` | Home의 한 줄 상태 제목 |
| `titleLarge` | `28 / 34` | 650 | `-0.7` | 화면 제목 |
| `titleMedium` | `22 / 28` | 620 | `-0.4` | 주요 section |
| `titleSmall` | `18 / 24` | 620 | `-0.2` | card·dialog 제목 |
| `bodyLarge` | `16 / 24` | 450 | `0` | 설명이 긴 본문 |
| `body` | `15 / 22` | 450 | `0` | 일반 본문 |
| `label` | `13 / 18` | 600 | `0` | action·field·row label |
| `metadata` | `12 / 17` | 450 | `0.1` | 시간·보조 속성 |
| `micro` | `11 / 15` | 550 | `0.3` | overline·dense header |
| `metricLarge` | `32 / 36` | 600 | `-0.8` | 주요 수치 |
| `metricMedium` | `24 / 30` | 600 | `-0.5` | compact 수치 |
| `monoBody` | `13 / 19` | 450 | `0` | host·version·API method |
| `monoMetadata` | `11 / 16` | 500 | `0.2` | table metadata·timestamp |

수치 단위는 해당 metric size의 약 50~55%를 사용한다. 긴 본문의 최대 line length는 72자, 상태 설명은 56자를 기준으로 한다. 영문 uppercase overline은 micro 역할에서만 허용하며 한국어 label에는 강제 대문자 규칙을 적용하지 않는다.

## 7. 간격과 크기

### 7.1 spacing scale

Primitive scale은 `4, 8, 12, 16, 20, 24, 32, 40, 48, 64`다. 1px과 2px은 divider와 focus ring에만 사용한다.

| Semantic role | Value |
|---|---:|
| `spaceInlineTight` | `4` |
| `spaceInline` | `8` |
| `spaceRelated` | `12` |
| `spaceComponent` | `16` |
| `spaceGroup` | `24` |
| `spaceSection` | `32` mobile / `40` desktop |
| `spacePage` | `16` mobile / `24` tablet / `32` desktop |

같은 그룹 내부 간격보다 그룹 사이 간격이 한 단계 이상 커야 한다. 예를 들어 field label과 field는 8, field끼리는 16, form section끼리는 24 이상을 사용한다.

### 7.2 radius와 elevation

| Token | Value | 용도 |
|---|---:|---|
| `radiusControl` | `8` | button, field |
| `radiusCard` | `10` | metric card, panel |
| `radiusDialog` | `12` | dialog, sheet |
| `radiusPill` | full | status badge와 filter chip만 |

기본 카드에는 그림자를 사용하지 않는다. Floating menu와 dialog에만 low-opacity 2단 shadow를 허용한다. Dark theme의 깊이는 surface luminance와 border로, Light theme의 깊이는 canvas/surface 대비와 hairline border로 표현한다.

### 7.3 조작 영역과 행 높이

모든 터치 조작 영역은 최소 `44×44`다. 아이콘 자체는 18 또는 20을 사용하되 hit region을 줄이지 않는다. 모바일 기본 row는 56, tablet은 52, desktop compact row는 44다. Primary button은 mobile 48, desktop 40 visual height를 사용할 수 있지만 desktop에서도 pointer 외 입력을 고려한 focus region을 유지한다.

## 8. 밀도

밀도는 theme와 독립된 축이다.

```dart
enum TrueDashDensity { comfortable, standard, compact }
```

`<600`은 comfortable, `600–999`는 standard, `≥1000`은 compact를 기본으로 한다. 사용자가 desktop density를 변경할 수 있는 기능은 v1 이후로 유보한다. 한 화면이 breakpoint와 무관하게 임의 density를 선택하지 않는다.

Compact는 글꼴을 무조건 축소하지 않는다. row height, cell padding, group gap을 줄이고 metadata를 같은 행에 배치한다. 본문 최소 크기는 12px이고 주요 action label은 13px 이상을 유지한다.

## 9. 반응형 구조

### 9.1 `<600`: mobile

- 단일 pane과 page push navigation
- Home, Alerts, Manage, Jobs의 하단 4개 목적지
- page padding 16
- metric은 기본 2열, 320px 이하 또는 긴 locale에서는 1열
- table은 핵심 두 열의 resource row로 변환
- secondary action은 overflow menu 또는 다음 화면으로 이동
- 위험 작업은 full-screen stepper

### 9.2 `600–999`: tablet

- 72px navigation rail
- 목록/상세 2-pane 허용
- page padding 24
- metric 2~3열
- inspector는 modal sheet

### 9.3 `≥1000`: desktop

- 72px rail 또는 224px expanded navigation
- page padding 32, content 최대 폭 1440
- metric 4열
- 목록 + 상세 + inspector 3-pane 허용
- compact 44px row와 keyboard focus navigation
- command palette와 multi-chart layout

Breakpoint 전환은 OS가 아니라 실제 layout width로 결정한다. 화면은 320, 390, 768, 1024, 1440px에서 검증한다.

## 10. 아이콘과 데이터 시각화

아이콘은 Flutter Material Symbols의 rounded/outlined 한 계열만 사용하며 같은 화면에서 fill과 outline을 임의 혼합하지 않는다. Emoji는 navigation, 상태, category icon으로 사용하지 않는다. Icon은 decorative인 경우 semantics에서 제외하고, icon-only action에는 tooltip과 접근성 label을 제공한다.

차트는 accent 하나와 semantic status 색을 구분한다. 여러 series가 필요하면 색뿐 아니라 dash, point, label을 함께 사용한다. 그래프가 없어도 동일 데이터를 표나 summary로 읽을 수 있어야 한다. 용량 막대는 사용량과 warning threshold를 구분하고 색만으로 상태를 전달하지 않는다.

## 11. 기본 컴포넌트 계약

### 11.1 `TdButton`

`primary`, `secondary`, `ghost`, `danger` variant와 `comfortable`, `compact` size를 제공한다. Loading 상태는 label을 유지하고 진행 indicator를 추가하며, 중복 실행을 막되 disabled 색으로 보이지 않는다. Disabled는 `actionDisabled`, `onActionDisabled`, `borderDisabled` semantic roles로 명확히 조용하게 표시한다. Hover와 pressed는 기본 foreground/background를 대체하지 않는, solid와 surface를 구분한 `actionHoverOnSolid`/`actionPressedOnSolid` 및 `actionHoverOnSurface`/`actionPressedOnSurface` state layer로 표시한다. Dark surface에는 밝은 state layer를 사용해 canvas와 panel 모두에서 변화를 보장한다. keyboard focus는 solid/surface별 `actionFocusOnSolid`/`actionFocusOnSurface` 2px ring으로 표시한다. Danger는 일반 primary와 다른 semantic token과 confirmation flow를 요구한다.

상호작용 회귀 계약은 실제 배경에 alpha 합성한 색으로 검증한다. Light/Dark의 모든 button variant는 hover에서 base 대비 최소 `1.10:1` 및 DeltaE76 `5`, pressed에서 최소 `1.20:1` 및 DeltaE76 `10`을 만족하며 pressed는 hover보다 약하지 않다. Ghost는 canvas와 panel 모두에서 검증한다. Focus ring은 각 variant의 인접한 rendered base와 최소 `3:1`, 같은 border pixel의 unfocused treatment와도 최소 `3:1`이어야 한다. 일반 border가 불투명하면 focus border와 그 normal border를 비교하고, ghost처럼 border가 투명하면 그 pixel의 underlying background를 unfocused treatment로 비교한다. 이 수치는 text 대비가 아닌 비텍스트 상호작용 feedback의 최소선이다.

### 11.2 `TdTextField`

항상 외부 label을 유지하고 placeholder만으로 의미를 전달하지 않는다. Helper와 error 영역의 높이 변화가 주변 layout을 불필요하게 흔들지 않도록 한다. Secret field는 기본 마스킹, 노출 action tooltip, 자동완성 정책을 명시한다.

### 11.3 `TdPanel`과 `TdMetricCard`

Panel은 title, optional description, action, body slot을 제공한다. MetricCard는 label, value, unit, trend, freshness를 분리해 screen reader 읽기 순서를 고정한다. 정상 metric마다 success 색을 사용하지 않는다.

### 11.4 `TdStatusBadge`

`neutral`, `success`, `warning`, `critical`, `info`, `stale`을 제공한다. 아이콘, label, semantic color가 함께 바뀐다. Badge를 단순 category chip으로 재사용하지 않는다.

### 11.5 `TdResourceRow`

모바일에서는 resource 이름, 상태, 핵심 metadata, disclosure를 표시한다. Desktop에서는 고정된 column alignment를 사용한다. Quick action은 위험 작업을 직접 실행하지 않고 menu 또는 detail로 연결한다.

### 11.6 `TdEmptyState`, `TdLoadingState`, `TdErrorState`

모든 data surface는 세 상태를 가진다. Empty는 다음 action을 제시하고, Error는 사용자가 할 수 있는 retry 또는 설정 확인을 설명한다. Loading skeleton은 최종 layout과 비슷한 크기를 사용하며 content flashing을 줄인다.

### 11.7 `TdDialog`, `TdSheet`, `TdDangerConfirm`

Dialog는 desktop, Sheet는 mobile의 기본 overlay다. DangerConfirm은 영향 요약, 대상 이름, 되돌릴 수 있는지 여부, 진행 중 job 중단 가능 여부, 최종 action을 순서대로 보여준다. Escape/back 동작과 focus restoration을 테스트한다.

## 12. TrueDash 도메인 컴포넌트

공용 디자인 패키지는 TrueNAS API 모델을 import하지 않는다. 다음 컴포넌트는 앱 또는 feature package에서 공용 primitive를 조합한다.

| Component | 책임 |
|---|---|
| `ServerSwitcher` | 서버 이름, 연결·인증서·버전 상태 |
| `HealthSummary` | 전체 health와 조치가 필요한 수만 요약 |
| `CapacityBar` | used/available/reserved와 threshold |
| `JobProgress` | 진행률, 단계, 취소 가능성, 관련 리소스 |
| `CapabilityNotice` | 버전·에디션·역할로 인한 미지원 이유 |
| `ImpactPreview` | 변경 전후와 연결 손실 가능성 |
| `AnsiLogView` | follow, pause, search, copy, download |
| `TerminalSurface` | reconnect, resize, paste guard, clipboard warning |

## 13. Theme API와 패키지 경계

구현 패키지는 `packages/truedash_design_system`에 둔다.

```text
packages/truedash_design_system/
├── lib/
│   ├── truedash_design_system.dart
│   └── src/
│       ├── foundations/
│       │   ├── color_tokens.dart
│       │   ├── spacing_tokens.dart
│       │   ├── typography_tokens.dart
│       │   ├── radius_tokens.dart
│       │   └── motion_tokens.dart
│       ├── theme/
│       │   ├── truedash_theme.dart
│       │   ├── truedash_theme_extension.dart
│       │   └── truedash_density.dart
│       └── components/
│           ├── td_button.dart
│           ├── td_text_field.dart
│           ├── td_panel.dart
│           ├── td_metric_card.dart
│           ├── td_status_badge.dart
│           └── td_state_view.dart
├── test/
└── assets/fonts/
```

패키지는 `truenas_api`를 의존하지 않는다. 앱은 `ThemeData`와 `TrueDashThemeExtension`을 설치하고 컴포넌트를 import한다. 기존 M0 Connection 화면은 첫 소비자이며, 직접 선언한 색상·타이포그래피·간격을 제거한다.

## 14. Motion

| Token | Duration | 사용 |
|---|---:|---|
| `instant` | `0ms` | reduced motion |
| `fast` | `100ms` | hover, press |
| `standard` | `180ms` | selection, inline state |
| `emphasized` | `240ms` | sheet, dialog |

Motion은 content 접근을 지연하지 않는다. `MediaQuery.disableAnimations` 또는 플랫폼 reduced-motion 설정이 활성화되면 decorative transition을 제거하고 상태 변화는 즉시 반영한다. Progress indicator처럼 의미가 있는 motion은 정적 대체 상태를 제공한다.

## 15. 접근성 기준

- 일반 본문 대비 최소 4.5:1, large text와 UI boundary 최소 3:1
- 모바일 조작 영역 최소 44×44
- keyboard focus가 모든 interactive component에 표시됨
- focus 순서가 시각 순서와 일치함
- 상태는 색, 아이콘, 텍스트를 함께 사용함
- text scale 200%에서 핵심 action과 상태가 잘리지 않음
- screen reader가 metric을 `label, value, unit, freshness` 순서로 읽음
- animation 감소 설정을 존중함
- tooltip 없이 의미를 알 수 없는 icon-only action 금지
- 파괴적 action은 screen reader label에도 대상과 위험을 포함함

## 16. Connection 화면 적용

M0 Connection 화면은 다음 구조로 교체한다.

1. `TdPanel` 안에 제품명, 비공식 클라이언트 설명, 보안 연결 설명을 둔다.
2. Server URL과 API key를 `TdTextField`로 변환한다.
3. Connect는 `TdButton.primary`이며 loading 중 label과 중복 실행 방지를 유지한다.
4. 오류는 `TdErrorState` 또는 inline critical message로 표시한다.
5. 연결 성공 정보는 key-value 나열이 아니라 `TdStatusBadge.success`와 compact definition list로 표시한다.
6. 390px에서는 단일 panel, 1000px 이상에서는 설명 pane과 form pane의 2열을 허용한다.
7. API key sentinel 비노출, 오류 mapping, loading과 성공 summary 테스트를 그대로 유지한다.

## 17. 검증 전략

Foundation token은 값 snapshot보다 관계를 검증한다. 예를 들어 spacing이 오름차순인지, semantic text/background 조합이 요구 대비를 만족하는지, Light/Dark 모두 필수 role을 제공하는지 검사한다. 고정된 token 개수나 전체 색 목록 snapshot은 작성하지 않는다.

컴포넌트 테스트는 다음 행동 계약을 검증한다.

- Button loading 중 중복 action이 실행되지 않음
- Button interaction regression: Flutter `3.47.0`에서 Light/Dark × primary/secondary/ghost/danger의 10개 composited case(ghost의 canvas·panel 각각 포함)가 hover `>=1.10:1`/DeltaE76 `>=5`, pressed `>=1.20:1`/DeltaE76 `>=10`, pressed-not-weaker-than-hover, 2px focus `>=3:1`을 검증함
- Field label과 error semantics가 존재함
- StatusBadge가 아이콘과 label을 함께 제공함
- MetricCard의 screen-reader 읽기 순서가 유지됨
- 200% text scale에서 overflow가 없음
- mobile/desktop density가 breakpoint에 따라 적용됨
- reduced motion에서 transition duration이 0으로 수렴함
- Connection 화면의 기존 13개 provider/widget 테스트가 유지됨

시각 검증 viewport는 `390×844`, `768×1024`, `1440×1000`이다. Light/Dark와 loading/error/success를 확인한다. Golden test는 font와 renderer가 CI에서 고정된 뒤 핵심 컴포넌트에만 도입하며, 모든 화면 snapshot을 품질 기준으로 사용하지 않는다.

## 18. 수용 기준

- `packages/truedash_design_system`이 API 패키지와 독립적으로 빌드된다.
- Light/Dark semantic theme와 세 density가 같은 component API를 사용한다.
- Connection 화면에서 직접 선언한 제품 색상·본문 TextStyle·간격이 디자인 시스템 토큰으로 대체된다.
- 모든 공용 interactive component가 focus, disabled, loading, error 상태를 가진다.
- 대표 text/background 조합이 WCAG AA를 만족한다.
- 390px에서 가로 overflow가 없고 200% text scale에서도 연결 action에 접근할 수 있다.
- 1440px에서 compact density가 적용되고 metric·resource row alignment가 일치한다.
- format, analyze, package tests, app tests, Web release build, macOS release build가 통과한다.
- 실제 렌더를 Light/Dark의 mobile/desktop에서 확인한다.
- 기존 M0 보안 경계와 API key 비노출 계약이 유지된다.

## 19. 비범위

이 디자인 시스템 슬라이스에서는 전체 Dashboard 기능, 실제 chart engine, 광고 UI, 결제 화면, terminal renderer, 위험 작업 workflow 전체를 구현하지 않는다. Font 선택 화면, 사용자 정의 accent, arbitrary theme builder, runtime token download도 추가하지 않는다. 해당 기능은 실제 소비자가 생길 때 별도 설계한다.
