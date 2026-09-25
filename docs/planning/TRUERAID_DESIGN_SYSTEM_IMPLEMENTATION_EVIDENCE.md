# TrueRAID design system foundation — implementation evidence

Date: 2026-09-05

This record is intentionally factual. It does not claim Android, iOS, or real
TrueNAS verification.

## Prior sandbox limitation

The prior Codex pass could not start FVM Flutter because its workspace-write
sandbox prevented Flutter 3.47.0 from updating its SDK cache outside the
worktree. That limitation applies only to that prior run. It is not presented
as the outcome of the fresh commands below.

## Test-first remediation evidence

### Button disabled-state remediation

Focused `TdButton` contracts were added before the production change. The
initial RED execution failed because the required disabled and interaction
semantic roles did not yet exist on `TrueRAIDThemeExtension`; it therefore did
not reach the runtime assertions against the all-state color implementation.
The green rerun covers distinct disabled primary foreground/background/border,
disabled semantics and non-invocation, hover/pressed/focus overlays that leave
the semantic base colors intact, active-looking non-invokable loading, every
variant's 44px target, and readable disabled foreground/background contrast in
both themes. The existing gallery already displays primary, loading, and
disabled buttons under light/dark and comfortable/compact previews, so no
gallery structure changed.

Focused contracts were first changed for the reported defects and run before
their production fixes. That RED run failed as intended for:

- missing package font declarations;
- duplicate `TrueRAID` introduction at the 1000px expanded layout;
- density at a 390px test surface resolving incorrectly through the app
  composition; and
- the 200% text-scale header overflow and ambiguous scroll finder.

The green focused rerun passed all 7 selected tests. The final responsive
contracts cover 320px and 390px at 200% text scale, the 600px and 1000px
density boundaries, one introduction in compact/medium/expanded layouts, and
summary-specific success lookup. `TrueRAIDApp` remains scope-free; widget
tests supply `ProviderScope` where the consumer screen is composed.

The gallery contract was also made red before expansion, then green after it
gained light/dark control, comfortable/compact sections, every button and
status variant, field states, metric state, and loading/error/empty states.
It remains a separate `lib/dev/design_system_gallery_main.dart` entrypoint and
is not imported by production `main.dart` or `trueraid_app.dart`.

A post-render review found that disabled primary buttons still used the active
primary colors. Focused contracts were added for disabled semantics and colors,
hover/pressed/focus overlays, loading appearance, and minimum target size. The
contracts failed against the previous implementation and passed after adding
semantic disabled and interaction roles. A fresh gallery render confirmed the
disabled treatment is visually distinct in Light and Dark themes.

## Fresh verification commands and results

| Command | Result |
| --- | --- |
| `fvm dart format --set-exit-if-changed packages/trueraid_design_system` | Pass; 26 files already formatted. |
| `fvm flutter analyze packages/trueraid_design_system` | Pass; no issues. |
| `fvm flutter test packages/trueraid_design_system` | Pass; 15 tests. |
| `fvm flutter analyze apps/trueraid` | Pass; no issues. |
| `fvm flutter test apps/trueraid/test` | Pass; 19 tests. |
| `fvm dart test packages/truenas_api` | Pass; 45 tests. |
| `(cd apps/trueraid && fvm flutter build web --release)` | Pass; `build/web` produced. Flutter reported only its non-blocking missing Cupertino font-family warning; the app does not use Cupertino icons. |
| `(cd apps/trueraid && fvm flutter build macos --release)` | Pass; `trueraid.app` produced. Xcode issued its existing non-blocking Run Script output-dependency warning. |
| `codesign --verify --deep --strict build/macos/Build/Products/Release/trueraid.app` | Pass. |
| static safety scans | Pass; no TLS-bypass/sentinel needles and no production import of `lib/dev`. |
| `git diff --check` | Pass at handoff. |

## Browser render verification

The production Web release and separate gallery release were served only on
localhost and captured through headless Chromium/CDP. The first Browser Use
session timed out, so the same Chromium engine was driven directly through CDP;
this was a tooling fallback rather than an application failure.

| Surface | Viewport/theme | Observed result |
| --- | --- | --- |
| Connection | `1440×1000` Light | Two panes, one introduction, no visible clipping or overlap. |
| Connection | `768×1024` Light | One pane, stable hierarchy, `scrollWidth == 768`. |
| Connection | `390×844` Light/Dark | One pane, fields and action fully visible, `scrollWidth == 390`. |
| Connection | `320×844` Light | One pane and reachable action, `scrollWidth == 320`; the long URL hint ellipsizes inside the field. |
| Component gallery | `1440×1200` Light | Comfortable and compact sections render; representative states are visible. |
| Component gallery | `390×1200` Light/Dark | Components wrap without overlap, status meaning remains icon+label, and `scrollWidth == 390`. |

The widget suite separately exercises Connection at 200% text scale on 320px
and 390px widths without a Flutter overflow exception.

## Font asset verification

The supplied assets were not downloaded or replaced. Their local SHA-256
values match the verified source values:

| File | SHA-256 |
| --- | --- |
| `PretendardVariable.ttf` | `3090ccde0442bb347aa7685d9ba8b17436a60682df6e8f92a9a670de14056e22` |
| `JetBrainsMonoVariable.ttf` | `662a196d58f1183bf2d77428b6d5283fe3f45161ab021bea4036bc98e5cac016` |
| `PRETENDARD_LICENSE.txt` | `d31ddd9f2bed32fd7e302a205cf2380ba0de6529152d239ef99cfb6f261bfc04` |
| `JETBRAINS_MONO_OFL.txt` | `30f0c136e3c88e422d0791acd97238870f9054a9729bc34cf2ff0d4ed8cac4ad` |

`SOURCES.md` records the pinned archive URLs and hashes, committed-file hashes,
and licenses. The package declares `Pretendard` and `JetBrainsMono`, while the
exported text styles use their Flutter package-qualified family names.

## Independent remediation evidence — 2026-09-05

The following focused regression contracts were added before their production
changes. They were executed against `1be3107b2b2f33e3d380eb9b8245495428c434b6`.

| Contract | RED finding | GREEN command/result |
| --- | --- | --- |
| `TdPanel` and Connection success at 320px/390px with 200% text scale | The full Connection probes reported `RenderFlex` right overflows of 86px and 16px respectively. The constrained shared-header contract also failed before the responsive header change. | `fvm flutter test packages/trueraid_design_system/test/components/td_panel_test.dart packages/trueraid_design_system/test/components/td_button_test.dart packages/trueraid_design_system/test/components/td_status_badge_test.dart apps/trueraid/test/features/connection/connection_screen_test.dart --reporter compact` — Pass; 33 tests, including both full success probes. |
| Actual button interaction rendering | Primary hover composited to the unchanged base in light and dark. Focus resolved to its normal 1px border for secondary, ghost, and danger variants; disabled/loading interaction priority also failed. | Same focused command above — Pass. The contracts composite the resolved overlay over each base in light/dark for primary, secondary, ghost, and danger; they also require a distinct 2px focus ring and disabled/loading priority. |
| Actual status-badge composited contrast | `stale` failed at 4.310375257454757:1 in light and 4.256739825216119:1 in dark. | Same focused command above — Pass. Every `TdStatus` is checked against its actual rendered/composited surface in both themes at >=4.5:1. |

### Focus same-pixel regression closure

The focus contract was strengthened before changing production so a 2px focus
ring must contrast at `>=3:1` with both its adjacent rendered button base and
the same pixel's unfocused treatment. For an opaque normal border the latter
is the normal border; for a transparent ghost border it is the underlying
background.

| Stage | Command | Actual result |
| --- | --- | --- |
| RED | `(cd packages/trueraid_design_system && fvm flutter test test/components/td_button_test.dart)` | Failed as expected: `light secondary _ButtonSurface.canvas interactions meet the composited feedback contract` was `1.2569342417114526:1`; `dark secondary _ButtonSurface.canvas interactions meet the composited feedback contract` was `2.3196772540052946:1`. Both fail the required `>=3:1` focused-versus-unfocused-border assertion. |
| GREEN | `(cd packages/trueraid_design_system && fvm flutter test test/components/td_button_test.dart)` | Pass; all 15 tests passed. This covers Light/Dark × primary/secondary/ghost/danger, with ghost on both canvas and panel, for focus-versus-base and focus-versus-unfocused-pixel plus the existing hover/pressed contracts. |

Fresh full verification after the remediation:

| Command | Result |
| --- | --- |
| `fvm dart format --set-exit-if-changed .` | Pass; 51 files unchanged. |
| `fvm flutter analyze packages/trueraid_design_system` | Pass; no issues. |
| `fvm flutter test packages/trueraid_design_system` | Pass; 28 tests. |
| `fvm dart test packages/truenas_api` | Pass; 45 tests. |
| `fvm flutter analyze apps/trueraid` | Pass; no issues. |
| `fvm flutter test apps/trueraid` | Pass; 21 tests. |
| `(cd apps/trueraid && fvm flutter build web --release)` | Pass; `build/web` produced. Flutter emitted its non-blocking Cupertino font-family warning. |
| `(cd apps/trueraid && fvm flutter build macos --release)` | Pass; `trueraid.app` produced. |
| `codesign --verify --deep --strict apps/trueraid/build/macos/Build/Products/Release/trueraid.app` | Pass. |
| static safety scan and `git diff --check` | Pass; no TLS-bypass or sentinel strings in production roots and no production gallery import. |

## External-consumer boundary remediation — 2026-09-05

`examples/design_system_consumer` is a non-published workspace fixture. Its
runtime dependencies are limited to Flutter and `trueraid_design_system`; its
test imports the public barrel and compiles themes/extensions, density,
foundations, and all six exported components. The fixture contains no direct
`truenas_api` or Riverpod dependency/import. Analyzer dependency enforcement
and compiled execution replace the removed implementation-text scan.

| Command | Result |
| --- | --- |
| `fvm dart format --output=none --set-exit-if-changed .` | Pass; 51 files unchanged. |
| `fvm flutter analyze packages/trueraid_design_system` | Pass; no issues. |
| `fvm flutter test packages/trueraid_design_system` | Pass; 27 tests. |
| `(cd examples/design_system_consumer && fvm flutter pub get)` | Pass; dependencies resolved through the workspace. |
| `(cd examples/design_system_consumer && fvm flutter analyze)` | Pass; no issues. A temporary undeclared Riverpod import failed separately with `depend_on_referenced_packages`, proving the analyzer boundary is sensitive; the fixture was restored and re-analyzed cleanly. |
| `(cd examples/design_system_consumer && fvm flutter test)` | Pass; 1 test. |
| `fvm flutter analyze apps/trueraid` | Pass; no issues. |
| `fvm flutter test apps/trueraid` | Pass; 21 tests. |
| `fvm dart test packages/truenas_api` | Pass; 45 tests. |
| `(cd apps/trueraid && fvm flutter build web --release)` | Pass; `build/web` produced with only the previously documented non-blocking Cupertino font warning. |
| `(cd apps/trueraid && fvm flutter build macos --release)` | Pass; `trueraid.app` produced. |
| `codesign --verify --deep --strict apps/trueraid/build/macos/Build/Products/Release/trueraid.app` | Pass; parsed entitlements also contain `com.apple.security.network.client = true`. |
| production-scope check and `git diff --check` | Pass; this remediation changes no production design-system, app, or API source; the source-reading boundary test and exact spacing-list snapshot are absent. |

## Scope and limitations

No connection-controller behavior, credential lifetime, repository override
seam, URL validation, RPC order, or TLS trust policy was changed. No real
server, credentials, Android device, or iOS device was used. Browser checks
covered rendering and responsive geometry, not submission against a live
server. Generated release outputs are not part of the submitted worktree.
