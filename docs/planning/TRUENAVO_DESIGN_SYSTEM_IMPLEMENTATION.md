# TrueNavo Design System Foundation Implementation Plan

> **For Hermes:** Execute this plan task-by-task with Codex CLI in the existing isolated `design/design-system-foundation` worktree. Review each Codex diff, run the stated verification independently, and bind the final review to an exact commit SHA.

**Goal:** Build a reusable Flutter design-system package and refactor the M0 Connection screen as its first responsive, accessible consumer without changing the connection or credential-security behavior.

**Architecture:** Add `packages/truenavo_design_system` as a Flutter workspace package that exposes semantic theme tokens, density resolution, typography, and a small set of shared components. The package remains independent of `truenas_api`; `apps/truenavo` composes domain state into those components. Theme and density are orthogonal: Light/Dark resolve semantic color roles, while width resolves comfortable/standard/compact density.

**Tech Stack:** Flutter 3.47.0 via FVM, Dart 3.13, Material 3, `ThemeExtension`, Flutter widget tests, bundled Pretendard Variable 1.3.9 and JetBrains Mono 2.304 assets.

**Base:** `ab2951d09a57f169fde315de151f5be47b58607b` plus approved design-spec commit `0ee96105666a2be40a2385f375a65b7c7a284b9b` on `design/design-system-foundation`.

**Canonical design:** `docs/planning/TRUENAVO_DESIGN_SYSTEM.md`

---

## 1. Delivery boundaries

This slice includes foundation tokens, semantic Light/Dark themes, three width-derived density modes, the approved first component set, package fonts with licenses, and the Connection screen refactor. It does not implement a real dashboard, navigation shell, chart engine, billing, advertising, secure storage, certificate trust, or new TrueNAS calls.

The design package must not import `truenas_api` or Riverpod. The application keeps connection orchestration in `connection_controller.dart`; visual refactoring must not change API-key lifetime, error redaction, URL validation, RPC order, or existing repository override seams.

No runtime network font download is allowed. Font archives are source inputs only; only the required variable TTF and corresponding license files enter Git. Archive files and extraction directories remain outside the repository.

## 2. Acceptance case ledger

| Type | Case | Executable evidence |
|---|---|---|
| A | Light and Dark themes expose the same semantic roles | `truenavo_theme_test.dart` |
| A | Width `<600`, `600–999`, `≥1000` resolves comfortable, standard, compact | `truenavo_density_test.dart` |
| A | Button, field, panel, badge, metric, and state components consume the theme | focused widget tests |
| A | Connection success and failure render through design-system components | `connection_screen_test.dart` |
| A | 390px Connection is one pane; 1000px is two panes | responsive widget tests and live render |
| E | Widths exactly 599, 600, 999, and 1000 select the documented side of each boundary | table-driven density tests |
| E | Text scale 2.0 keeps the form and Connect action reachable | constrained widget test |
| E | Long host/version values wrap or remain inspectable without horizontal overflow | success-summary widget test |
| E | Reduced motion resolves effective durations to zero | motion test |
| X | Loading button receives repeated taps | callback runs once while disabled |
| X | Status is presented with color alone | semantics/icon/label test fails until all exist |
| X | API-key sentinel reaches rendered text after success/failure | existing sentinel assertions remain zero |
| X | A theme text/background pair falls below required contrast | token contrast test fails |
| X | Design package imports `truenas_api` | dependency/source boundary check fails |

## 3. Pinned font sources

Implementation must use these immutable release URLs and verify archive checksums before extraction.

| Asset | Release URL | SHA-256 | Extract |
|---|---|---|---|
| Pretendard 1.3.9 | `https://github.com/orioncactus/pretendard/releases/download/v1.3.9/Pretendard-1.3.9.zip` | `04be351a74d6bf7d60c480a3087e51d185485d35a52023142af1df19eb8c428a` | `public/variable/PretendardVariable.ttf` |
| JetBrains Mono 2.304 | `https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip` | `6f6376c6ed2960ea8a963cd7387ec9d76e3f629125bc33d1fdcd7eb7012f7bbf` | `fonts/variable/JetBrainsMono[wght].ttf`, `OFL.txt` |

Pretendard’s release archive does not place its license beside the variable file. Fetch `https://raw.githubusercontent.com/orioncactus/pretendard/v1.3.9/LICENSE`, verify SHA-256 `d31ddd9f2bed32fd7e302a205cf2380ba0de6529152d239ef99cfb6f261bfc04`, and retain its reserved-font-name notice. Before committing, record each committed TTF and license SHA-256 in `packages/truenavo_design_system/assets/fonts/SOURCES.md`.

---

### Task 1: Add the Flutter workspace package

**Objective:** Register an independently testable `truenavo_design_system` package without changing app behavior.

**Files:**
- Modify: `pubspec.yaml`
- Create: `packages/truenavo_design_system/pubspec.yaml`
- Create: `packages/truenavo_design_system/analysis_options.yaml`
- Create: `packages/truenavo_design_system/lib/truenavo_design_system.dart`
- Create: `examples/design_system_consumer/`

**Step 1: Add the external-consumer fixture**

Create a non-published workspace fixture that declares only Flutter and
`truenavo_design_system` as runtime dependencies. Its widget test must import
the public barrel and compile representative themes/extensions, density,
foundations, and every component. Do not inspect production source text.

```dart
dependencies:
  flutter:
    sdk: flutter
  truenavo_design_system:
    path: ../../packages/truenavo_design_system
```

**Step 2: Run the fixture and verify RED**

Run from repository root:

```bash
cd examples/design_system_consumer && fvm flutter pub get && fvm flutter analyze && fvm flutter test
```

Expected: FAIL before the public package API is available to the fixture.

**Step 3: Add the minimal package and register the fixture**

Add `packages/truenavo_design_system` and the non-published consumer fixture to
the root workspace. The package uses `resolution: workspace`, `flutter` as its
only runtime dependency, and `flutter_test` plus `flutter_lints` as dev
dependencies. Export no placeholder widget; export files only as later tasks
add them.

**Step 4: Resolve and verify GREEN**

```bash
fvm flutter pub get
cd examples/design_system_consumer && fvm flutter analyze && fvm flutter test
```

Expected: dependency resolution succeeds; the fixture's analyzer and executable
test pass using only its declared runtime dependencies.

**Step 5: Checkpoint**

```bash
git add pubspec.yaml pubspec.lock packages/truenavo_design_system
git commit -m "build: add TrueNavo design system package"
git push
```

---

### Task 2: Implement primitive foundations

**Objective:** Define immutable spacing, radius, sizing, typography, breakpoint, and motion primitives before semantic theme construction.

**Files:**
- Create: `packages/truenavo_design_system/lib/src/foundations/spacing_tokens.dart`
- Create: `packages/truenavo_design_system/lib/src/foundations/radius_tokens.dart`
- Create: `packages/truenavo_design_system/lib/src/foundations/sizing_tokens.dart`
- Create: `packages/truenavo_design_system/lib/src/foundations/typography_tokens.dart`
- Create: `packages/truenavo_design_system/lib/src/foundations/motion_tokens.dart`
- Create: `packages/truenavo_design_system/lib/src/theme/truenavo_density.dart`
- Create: `packages/truenavo_design_system/test/foundations/foundation_tokens_test.dart`
- Create: `packages/truenavo_design_system/test/theme/truenavo_density_test.dart`
- Modify: `packages/truenavo_design_system/lib/truenavo_design_system.dart`

**Step 1: Write RED relationship tests**

Test relationships rather than serializing every constant. Required assertions include:

```dart
expect(TdSpacing.scale, isNotEmpty);
expect(TdSpacing.scale.every((value) => value.isFinite && value > 0), isTrue);
for (var index = 1; index < TdSpacing.scale.length; index++) {
  expect(TdSpacing.scale[index], greaterThan(TdSpacing.scale[index - 1]));
}
expect(TdSpacing.inlineTight, lessThan(TdSpacing.inline));
expect(TdSpacing.inline, lessThan(TdSpacing.related));
expect(TdSpacing.related, lessThan(TdSpacing.component));
expect(TdSpacing.component, lessThan(TdSpacing.group));
expect(TdSpacing.pageMobile, lessThan(TdSpacing.pageTablet));
expect(TdSpacing.pageTablet, lessThan(TdSpacing.pageDesktop));
expect(TdSizing.minimumTouchTarget, greaterThanOrEqualTo(44));
expect(TdTypography.body.fontSize, greaterThanOrEqualTo(12));
expect(TdRadius.control, lessThanOrEqualTo(TdRadius.dialog));
```

Do not assert the complete spacing list, its exact length, or a fixed full token inventory.

Use table-driven boundary cases:

```dart
for (final (width, expected) in [
  (320.0, TrueNavoDensity.comfortable),
  (599.0, TrueNavoDensity.comfortable),
  (600.0, TrueNavoDensity.standard),
  (999.0, TrueNavoDensity.standard),
  (1000.0, TrueNavoDensity.compact),
  (1440.0, TrueNavoDensity.compact),
]) {
  expect(TrueNavoDensity.resolve(width), expected);
}
```

Reduced motion must be explicit:

```dart
expect(TdMotion.effective(TdMotion.standard, disableAnimations: true), Duration.zero);
```

**Step 2: Verify RED**

```bash
fvm flutter test packages/truenavo_design_system/test/foundations packages/truenavo_design_system/test/theme/truenavo_density_test.dart
```

Expected: missing token and density symbols.

**Step 3: Implement minimal immutable APIs**

Use abstract final classes with `static const` values. Typography roles return `TextStyle` with the package font-family names but no colors; color belongs to semantic themes. Density provides semantic row, control, and gap values rather than arbitrary multipliers.

```dart
enum TrueNavoDensity {
  comfortable(rowHeight: 56, controlHeight: 48),
  standard(rowHeight: 52, controlHeight: 44),
  compact(rowHeight: 44, controlHeight: 40);

  const TrueNavoDensity({required this.rowHeight, required this.controlHeight});
  final double rowHeight;
  final double controlHeight;

  static TrueNavoDensity resolve(double width) => width < 600
      ? comfortable
      : width < 1000
      ? standard
      : compact;
}
```

**Step 4: Verify GREEN**

```bash
fvm dart format packages/truenavo_design_system
fvm flutter test packages/truenavo_design_system/test/foundations packages/truenavo_design_system/test/theme/truenavo_density_test.dart
fvm flutter analyze packages/truenavo_design_system
```

**Step 5: Checkpoint**

```bash
git add packages/truenavo_design_system
git commit -m "feat: add TrueNavo foundation tokens"
git push
```

---

### Task 3: Build semantic Light and Dark themes

**Objective:** Map approved color roles and typography to a stable `ThemeExtension` and Material 3 `ThemeData`.

**Files:**
- Create: `packages/truenavo_design_system/lib/src/foundations/color_tokens.dart`
- Create: `packages/truenavo_design_system/lib/src/theme/truenavo_theme_extension.dart`
- Create: `packages/truenavo_design_system/lib/src/theme/truenavo_theme.dart`
- Create: `packages/truenavo_design_system/test/theme/truenavo_theme_test.dart`
- Modify: `packages/truenavo_design_system/lib/truenavo_design_system.dart`

**Step 1: Write RED theme and contrast tests**

Implement the WCAG relative-luminance helper in test code. Assert the exact approved pair thresholds for both themes. At minimum test primary, secondary, muted, action/on-action, critical, warning, and control-boundary pairs. Tests must use the exported semantic extension values, not duplicate hex constants.

```dart
expect(contrast(dark.textPrimary, dark.canvas), greaterThanOrEqualTo(4.5));
expect(contrast(light.textMuted, light.canvas), greaterThanOrEqualTo(4.5));
expect(contrast(dark.borderControl, dark.surfaceBase), greaterThanOrEqualTo(3));
expect(contrast(light.borderControl, light.surfaceBase), greaterThanOrEqualTo(3));
```

Assert `copyWith` and `lerp` preserve every role, and that `TrueNavoTheme.light()` and `.dark()` install `useMaterial3`, matching brightness, typography, input decoration, focus, button, card, divider, and scaffold defaults.

**Step 2: Verify RED**

```bash
fvm flutter test packages/truenavo_design_system/test/theme/truenavo_theme_test.dart
```

Expected: missing theme symbols.

**Step 3: Implement the semantic extension**

`TrueNavoThemeExtension` must include all documented color roles and the current `TrueNavoDensity`. Do not expose raw palettes. `ThemeData` should remain interoperable with Material widgets while shared TrueNavo components read semantic roles from the extension.

Provide a strict accessor:

```dart
extension TrueNavoThemeContext on BuildContext {
  TrueNavoThemeExtension get tdTheme {
    final value = Theme.of(this).extension<TrueNavoThemeExtension>();
    assert(value != null, 'TrueNavoTheme must be installed above this context.');
    return value!;
  }
}
```

**Step 4: Verify GREEN**

```bash
fvm dart format packages/truenavo_design_system
fvm flutter test packages/truenavo_design_system/test/theme
fvm flutter analyze packages/truenavo_design_system
```

**Step 5: Checkpoint**

```bash
git add packages/truenavo_design_system
git commit -m "feat: add semantic TrueNavo themes"
git push
```

---

### Task 4: Vendor pinned fonts and licenses

**Objective:** Bundle consistent Korean/Latin UI and technical numeral fonts without runtime network access.

**Files:**
- Create: `packages/truenavo_design_system/assets/fonts/PretendardVariable.ttf`
- Create: `packages/truenavo_design_system/assets/fonts/JetBrainsMonoVariable.ttf`
- Create: `packages/truenavo_design_system/assets/fonts/PRETENDARD_LICENSE.txt`
- Create: `packages/truenavo_design_system/assets/fonts/JETBRAINS_MONO_LICENSE.txt`
- Create: `packages/truenavo_design_system/assets/fonts/SOURCES.md`
- Modify: `packages/truenavo_design_system/pubspec.yaml`
- Modify: `packages/truenavo_design_system/test/foundations/foundation_tokens_test.dart`

**Step 1: Write RED asset-contract tests**

Assert that the package pubspec declares both families, sources use `packages/truenavo_design_system/...` family names, files exist, license files are non-empty, and `SOURCES.md` records versions, URLs, archive hashes, and committed-file hashes. Do not snapshot binary contents.

**Step 2: Verify RED**

```bash
fvm flutter test packages/truenavo_design_system/test/foundations/foundation_tokens_test.dart
```

Expected: font assets and declarations are absent.

**Step 3: Fetch and verify outside the repository**

```bash
rm -rf /tmp/truenavo-font-source
mkdir -p /tmp/truenavo-font-source
curl -fL --retry 3 -o /tmp/truenavo-font-source/Pretendard-1.3.9.zip \
  https://github.com/orioncactus/pretendard/releases/download/v1.3.9/Pretendard-1.3.9.zip
curl -fL --retry 3 -o /tmp/truenavo-font-source/JetBrainsMono-2.304.zip \
  https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip
printf '%s  %s\n' \
  '04be351a74d6bf7d60c480a3087e51d185485d35a52023142af1df19eb8c428a' \
  '/tmp/truenavo-font-source/Pretendard-1.3.9.zip' | shasum -a 256 -c -
printf '%s  %s\n' \
  '6f6376c6ed2960ea8a963cd7387ec9d76e3f629125bc33d1fdcd7eb7012f7bbf' \
  '/tmp/truenavo-font-source/JetBrainsMono-2.304.zip' | shasum -a 256 -c -
```

Extract only the named files. Fetch Pretendard license from the immutable `v1.3.9` tag and verify it contains `SIL OPEN FONT LICENSE Version 1.1` and the reserved font name. Rename the JetBrains variable TTF to remove brackets from its committed filename.

**Step 4: Declare package fonts and verify GREEN**

Use family identifiers:

```yaml
flutter:
  fonts:
    - family: Pretendard
      fonts:
        - asset: assets/fonts/PretendardVariable.ttf
    - family: JetBrainsMono
      fonts:
        - asset: assets/fonts/JetBrainsMonoVariable.ttf
```

Exported TextStyles must use Flutter package-qualified family names so consuming apps resolve package assets.

```bash
fvm flutter pub get
fvm flutter test packages/truenavo_design_system/test/foundations/foundation_tokens_test.dart
```

Validate actual package-font bundling through the consuming app's Web build after Task 7. Package unit tests prove declarations and files; they do not prove that a production app emitted the font assets.

**Step 5: Checkpoint and cleanup**

```bash
rm -rf /tmp/truenavo-font-source
git add packages/truenavo_design_system/assets packages/truenavo_design_system/pubspec.yaml pubspec.lock packages/truenavo_design_system/test
git commit -m "feat: bundle TrueNavo typography assets"
git push
```

---

### Task 5: Implement action and field components

**Objective:** Build accessible button and form-field primitives with explicit state contracts.

**Files:**
- Create: `packages/truenavo_design_system/lib/src/components/td_button.dart`
- Create: `packages/truenavo_design_system/lib/src/components/td_text_field.dart`
- Create: `packages/truenavo_design_system/test/components/td_button_test.dart`
- Create: `packages/truenavo_design_system/test/components/td_text_field_test.dart`
- Modify: `packages/truenavo_design_system/lib/truenavo_design_system.dart`

**Step 1: Write RED button tests**

Cover `primary`, `secondary`, `ghost`, and `danger`; comfortable/compact sizing; visible focus; disabled semantics; loading label preservation; and duplicate-tap prevention. The loading test must pump a button with `isLoading: true`, tap twice, and verify the callback count remains zero.

**Step 2: Write RED field tests**

Cover persistent external label, helper/error semantics, secret visibility tooltip, enabled/disabled state, and 44px minimum hit target for the trailing action. `TdTextField` accepts an existing controller and does not own/dispose it.

**Step 3: Verify RED**

```bash
fvm flutter test packages/truenavo_design_system/test/components/td_button_test.dart packages/truenavo_design_system/test/components/td_text_field_test.dart
```

**Step 4: Implement the minimal APIs**

```dart
enum TdButtonVariant { primary, secondary, ghost, danger }

class TdButton extends StatelessWidget {
  const TdButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.variant = TdButtonVariant.primary,
    this.isLoading = false,
    this.expand = false,
    super.key,
  });
}
```

`TdTextField` should wrap Material `TextField` while preserving keys used by M0 tests. Do not add validation business logic or credential persistence.

**Step 5: Verify GREEN and checkpoint**

```bash
fvm dart format packages/truenavo_design_system
fvm flutter test packages/truenavo_design_system/test/components/td_button_test.dart packages/truenavo_design_system/test/components/td_text_field_test.dart
fvm flutter analyze packages/truenavo_design_system
git add packages/truenavo_design_system
git commit -m "feat: add TrueNavo action and field components"
git push
```

---

### Task 6: Implement information and state components

**Objective:** Build the panel, status, metric, and reusable loading/error/empty surfaces needed by Connection and later dashboards.

**Files:**
- Create: `packages/truenavo_design_system/lib/src/components/td_panel.dart`
- Create: `packages/truenavo_design_system/lib/src/components/td_status_badge.dart`
- Create: `packages/truenavo_design_system/lib/src/components/td_metric_card.dart`
- Create: `packages/truenavo_design_system/lib/src/components/td_state_view.dart`
- Create: `packages/truenavo_design_system/test/components/td_panel_test.dart`
- Create: `packages/truenavo_design_system/test/components/td_status_badge_test.dart`
- Create: `packages/truenavo_design_system/test/components/td_metric_card_test.dart`
- Create: `packages/truenavo_design_system/test/components/td_state_view_test.dart`
- Modify: `packages/truenavo_design_system/lib/truenavo_design_system.dart`

**Step 1: Write RED behavioral tests**

Panel tests verify title/body/action reading order and no default elevation. Badge tests iterate neutral, success, warning, critical, info, stale and require icon plus label semantics. Metric tests require the semantics order `label, value, unit, freshness`, tabular-numeral typography, and graceful long locale text. State-view tests cover compact inline and full panel layouts with action semantics.

**Step 2: Verify RED**

```bash
fvm flutter test packages/truenavo_design_system/test/components/td_panel_test.dart packages/truenavo_design_system/test/components/td_status_badge_test.dart packages/truenavo_design_system/test/components/td_metric_card_test.dart packages/truenavo_design_system/test/components/td_state_view_test.dart
```

**Step 3: Implement components from semantic tokens**

No component may introduce a raw product color, arbitrary radius, or undocumented spacing value. `TdStatusBadge` must never infer semantics from color only. `TdMetricCard` takes already-formatted strings; locale/measurement formatting remains a domain concern.

**Step 4: Verify GREEN and checkpoint**

```bash
fvm dart format packages/truenavo_design_system
fvm flutter test packages/truenavo_design_system/test/components
fvm flutter analyze packages/truenavo_design_system
git add packages/truenavo_design_system
git commit -m "feat: add TrueNavo information components"
git push
```

---

### Task 7: Install the design system in the app

**Objective:** Replace the one-off app theme while keeping the existing home screen and state providers intact.

**Files:**
- Modify: `apps/truenavo/pubspec.yaml`
- Modify: `apps/truenavo/lib/truenavo_app.dart`
- Create: `apps/truenavo/test/truenavo_app_theme_test.dart`
- Modify: `pubspec.lock`

**Step 1: Write RED app-theme tests**

Pump `TrueNavoApp` and assert both `theme` and `darkTheme` are installed, `themeMode` follows the system, the semantic extension is present, and no old seed/scaffold colors remain in app source. Test 390 and 1440 widths to prove density resolution can reach comfortable and compact values.

**Step 2: Verify RED**

```bash
fvm flutter test apps/truenavo/test/truenavo_app_theme_test.dart
```

**Step 3: Add dependency and theme composition**

Add a path dependency on `../../packages/truenavo_design_system`. `MaterialApp` receives `TrueNavoTheme.light()`, `TrueNavoTheme.dark()`, and `ThemeMode.system`. Use a small `builder` only if needed to update width-derived density; avoid rebuilding state providers or nesting another `MaterialApp`.

**Step 4: Verify GREEN and checkpoint**

```bash
fvm flutter pub get
fvm flutter test apps/truenavo/test/truenavo_app_theme_test.dart
fvm flutter test apps/truenavo/test/features/connection/connection_screen_test.dart
fvm flutter analyze apps/truenavo
git add apps/truenavo pubspec.lock
git commit -m "feat: install TrueNavo themes in the app"
git push
```

---

### Task 8: Refactor Connection into the first responsive consumer

**Objective:** Apply the approved visual hierarchy and shared components without changing connection behavior.

**Files:**
- Modify: `apps/truenavo/lib/features/connection/connection_screen.dart`
- Modify: `apps/truenavo/test/features/connection/connection_screen_test.dart`
- Create: `apps/truenavo/test/features/connection/connection_screen_accessibility_test.dart`

**Step 1: Preserve and adapt existing behavior assertions**

Keep the 13 existing success, failure mapping, loading, provider composition, and API-key sentinel cases. Update widget-type assertions from `FilledButton`/raw `TextField` only where the public shared component changes them; retain stable keys `server-url-field`, `api-key-field`, and `connect-button`.

**Step 2: Add RED responsive tests**

At `390×844`, assert one visible form pane, no horizontal overflow exception, and Connect is reachable by scrolling. At `1000×800` and `1440×1000`, assert the intro and form panes are side-by-side using stable keys such as `connection-intro-pane` and `connection-form-pane`.

Use actual test surface sizes:

```dart
await tester.binding.setSurfaceSize(const Size(390, 844));
addTearDown(() => tester.binding.setSurfaceSize(null));
```

At text scale 2.0, enter long host/version fixtures and assert no Flutter overflow exception and that status/action text remains discoverable.

**Step 3: Verify RED**

```bash
fvm flutter test apps/truenavo/test/features/connection/connection_screen_test.dart apps/truenavo/test/features/connection/connection_screen_accessibility_test.dart
```

Expected: new design-system widgets/layout keys are absent.

**Step 4: Implement the approved composition**

Use `TdPanel`, `TdTextField`, `TdButton`, `TdStatusBadge`, and compact `TdStateView`. Mobile remains one panel. Expanded layout uses an intro pane and form pane but does not duplicate fields or state widgets. Success rows use a private definition-list widget with mono values and wrapping/copy-safe presentation; do not reintroduce API-key state.

Required content hierarchy:

```text
TrueNavo
Unofficial TrueNAS client
Secure local connection explanation
Server URL
API key
Connect / Connecting securely…
Inline failure or Connected summary
```

**Step 5: Verify GREEN**

```bash
fvm dart format apps/truenavo
fvm flutter test apps/truenavo/test/features/connection/connection_screen_test.dart apps/truenavo/test/features/connection/connection_screen_accessibility_test.dart
fvm flutter analyze apps/truenavo
```

**Step 6: Check for token bypass**

Search the refactored screen for direct product styling:

```bash
python3 - <<'PY'
from pathlib import Path
p=Path('apps/truenavo/lib/features/connection/connection_screen.dart')
s=p.read_text()
for prohibited in ('Color(0x', 'TextStyle(', 'EdgeInsets.all(28)', 'BorderRadius.circular(12)'):
    assert prohibited not in s, prohibited
PY
```

This check does not ban layout-specific `EdgeInsets`; it bans only the removed one-off values named above. Review remaining numeric literals manually and move reusable values into the design package.

**Step 7: Checkpoint**

```bash
git add apps/truenavo/lib/features/connection apps/truenavo/test/features/connection
git commit -m "feat: apply design system to Connection"
git push
```

---

### Task 9: Add a component gallery route for development verification

**Objective:** Make all implemented component states inspectable without wiring production navigation or domain data.

**Files:**
- Create: `apps/truenavo/lib/dev/design_system_gallery.dart`
- Create: `apps/truenavo/lib/dev/design_system_gallery_main.dart`
- Create: `apps/truenavo/test/dev/design_system_gallery_test.dart`

**Step 1: Write RED gallery contract test**

The gallery must include every variant and state implemented in Tasks 5–6, Light/Dark theme switching, and comfortable/compact preview sections. It must not be imported by the production `main.dart` or `truenavo_app.dart`. Test direct widget construction rather than relying on hidden navigation.

**Step 2: Verify RED**

```bash
fvm flutter test apps/truenavo/test/dev/design_system_gallery_test.dart
```

**Step 3: Implement a separate development entrypoint**

Expose the gallery through `lib/dev/design_system_gallery_main.dart`. Do not import it from the production entrypoint or add a user-visible production route. A developer launches it explicitly with `-t lib/dev/design_system_gallery_main.dart`.

**Step 4: Verify GREEN and release exclusion**

```bash
fvm flutter test apps/truenavo/test/dev/design_system_gallery_test.dart
(cd apps/truenavo && fvm flutter build web --release)
```

Search the production entrypoint and app shell to confirm they do not import `lib/dev/`. Do not claim tree-shaking removed every string unless artifact inspection proves it.

**Step 5: Checkpoint**

```bash
git add apps/truenavo/lib/dev apps/truenavo/test/dev
git commit -m "feat: add TrueNavo component gallery"
git push
```

---

### Task 10: Run full deterministic verification

**Objective:** Prove package, app, API regressions, formatting, build, dependency, and secret boundaries before visual review.

**Files:**
- Modify if needed: `docs/planning/M0_IMPLEMENTATION_EVIDENCE.md`
- Create: `docs/planning/DESIGN_SYSTEM_IMPLEMENTATION_EVIDENCE.md`
- Modify: `docs/README.md`

**Step 1: Run format and static analysis**

```bash
fvm dart format --set-exit-if-changed .
fvm flutter analyze packages/truenavo_design_system
fvm flutter analyze apps/truenavo
```

**Step 2: Run all tests**

```bash
fvm flutter test packages/truenavo_design_system
fvm flutter test apps/truenavo
fvm dart test packages/truenas_api
```

Record actual test counts; do not copy historical M0 counts.

**Step 3: Run production builds**

```bash
(cd apps/truenavo && fvm flutter build web --release)
(cd apps/truenavo && fvm flutter build macos --release)
codesign --verify --deep --strict apps/truenavo/build/macos/Build/Products/Release/truenavo.app
```

Use the project’s actual Flutter output path if Flutter resolves it differently. Re-check the macOS network entitlement and Android/iOS declarations preserved from M0.

**Step 4: Re-check safety boundaries**

```bash
python3 - <<'PY'
from pathlib import Path
roots=[Path('apps/truenavo/lib'),Path('packages/truenavo_design_system/lib'),Path('packages/truenas_api/lib')]
needles=['badCertificateCallback','allowBadCertificates','trustAll','test-api-key']
for root in roots:
    for p in root.rglob('*'):
        if p.is_file():
            text=p.read_text(errors='ignore')
            for needle in needles:
                assert needle not in text, (p, needle)
PY
git diff --check
```

Also verify `packages/truenavo_design_system/pubspec.yaml` has no TrueNAS/API/state-management dependency.

**Step 5: Write evidence from real output**

Document command, tool version, exact pass/fail output, platform limitations, and unverified claims in `DESIGN_SYSTEM_IMPLEMENTATION_EVIDENCE.md`. Do not overwrite historical M0 evidence; link the two documents.

**Step 6: Checkpoint**

```bash
git add docs/README.md docs/planning/DESIGN_SYSTEM_IMPLEMENTATION_EVIDENCE.md docs/planning/M0_IMPLEMENTATION_EVIDENCE.md
git commit -m "docs: record design system verification"
git push
```

---

### Task 11: Verify the real rendered app

**Objective:** Confirm that the production Web build visibly matches the approved A+B direction across theme, width, and connection state.

**Files:**
- Modify only if defects are found: implementation and regression tests from Tasks 2–9
- Update after final render: `docs/planning/DESIGN_SYSTEM_IMPLEMENTATION_EVIDENCE.md`

**Step 1: Serve the release build locally**

Start a bounded local server from the actual Web output directory. Record its PID/session and stop it before the session ends.

**Step 2: Inspect mandatory matrices**

Render Connection at:

| Width | Theme | States |
|---:|---|---|
| 390×844 | Light, Dark | idle, error, success |
| 768×1024 | Light or Dark | idle |
| 1440×1000 | Light, Dark | idle, error, success |

Use deterministic provider overrides or debug fixture state. Never type a real API key. Use a sentinel and assert it does not appear in DOM/accessibility text, screenshots, logs, or error output.

**Step 3: Measure the runtime**

For each viewport, capture `innerWidth`, document `scrollWidth`, relevant panel bounding boxes, computed font family, and console errors. Required outcomes:

- `scrollWidth == innerWidth`
- 390px uses one pane
- 1440px uses two panes
- Connect is visible or reachable by vertical scrolling
- no clipped long server/version values
- no missing font requests
- no browser console errors

**Step 4: Fix blocking visual defects with RED tests**

Any clipping, missing asset, inaccessible action, insufficient contrast, stale raw styling, or layout that does not visibly reflect A+B is blocking. Add the smallest regression test, run it RED, fix, then repeat deterministic and rendered verification.

**Step 5: Stop all processes and checkpoint evidence**

Stop local servers and task-created browsers. Remove temporary screenshots/profiles unless evidence policy requires checked-in artifacts. Commit only source/evidence changes, then push.

---

### Task 12: Exact-SHA review and delivery

**Objective:** Obtain independent specification and code-quality review of the immutable final commit and prepare a stacked merge request.

**Files:** No planned source changes unless review finds a blocker.

**Step 1: Establish immutable review subject**

```bash
git status --short --branch
git rev-parse HEAD
git merge-base HEAD origin/feat/m0-foundation
git diff --stat origin/feat/m0-foundation...HEAD
```

Require a clean tree and record final SHA.

**Step 2: Request independent review**

Reviewer instructions must name:

- repository path `/Users/jungwon/workspace/.worktrees/truenavo-design-system`
- exact final SHA
- base `ab2951d09a57f169fde315de151f5be47b58607b`
- approved `TRUENAVO_DESIGN_SYSTEM.md`
- security boundary: no credential persistence or TLS weakening
- accessibility, package independence, responsive behavior, font licensing, test quality, and actual render evidence

Ask the reviewer to stop on SHA mismatch. Specification compliance review must pass before code-quality review.

**Step 3: Resolve findings**

For behavioral findings, add a RED regression test before the fix. Re-run all relevant checks, commit, push, and invalidate prior review by requesting a new exact-SHA review.

**Step 4: Create a stacked GitLab merge request**

Because MR !1 (`feat/m0-foundation` → `main`) is still open, target this branch’s MR at `feat/m0-foundation`, not `main`. State that it is stacked on MR !1. Do not merge either MR without explicit user approval and required policy checks.

**Step 5: Read back remote state**

Verify MR source SHA equals local `HEAD`, target is `feat/m0-foundation`, state is open, and conflict status is mergeable. Report absent GitLab CI honestly if no pipeline configuration exists.

## 4. Final verification checklist

- [ ] Workspace contains `packages/truenavo_design_system`
- [ ] Design package has no API, Riverpod, HTTP, ad, analytics, or billing dependency
- [ ] Font sources, versions, archive hashes, file hashes, and licenses are tracked
- [ ] Light/Dark semantic themes expose matching roles
- [ ] 599/600/999/1000 breakpoint edges are tested
- [ ] All shared components cover focus, disabled, loading, error, and semantics as applicable
- [ ] Connection behavior and API-key sentinel tests remain green
- [ ] 200% text scale test passes
- [ ] Web and macOS release builds pass or exact environment blocker is documented
- [ ] 390/768/1440 real render matrix is inspected
- [ ] All task-created servers and browsers are stopped
- [ ] Final exact-SHA reviews pass with no blocker
- [ ] Stacked MR targets `feat/m0-foundation`
- [ ] No merge or deployment occurs without explicit approval
