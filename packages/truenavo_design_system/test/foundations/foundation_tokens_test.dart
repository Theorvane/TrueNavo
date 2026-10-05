import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

void main() {
  test('foundation token relationships are stable', () {
    expect(TdSpacing.scale, isNotEmpty);
    for (final spacing in TdSpacing.scale) {
      expect(spacing.isFinite, isTrue);
      expect(spacing, greaterThan(0));
    }
    for (var index = 1; index < TdSpacing.scale.length; index++) {
      expect(TdSpacing.scale[index], greaterThan(TdSpacing.scale[index - 1]));
    }
    expect(
      TdSpacing.inlineTight,
      lessThan(TdSpacing.inline),
      reason:
          'tighter inline spacing should remain smaller than inline spacing',
    );
    expect(TdSpacing.inline, lessThan(TdSpacing.related));
    expect(TdSpacing.related, lessThan(TdSpacing.component));
    expect(TdSpacing.component, lessThan(TdSpacing.group));
    expect(TdSpacing.pageMobile, lessThan(TdSpacing.pageTablet));
    expect(TdSpacing.pageTablet, lessThan(TdSpacing.pageDesktop));
    expect(TdSpacing.sectionMobile, lessThan(TdSpacing.sectionDesktop));
    for (final semanticSpacing in [
      TdSpacing.inlineTight,
      TdSpacing.inline,
      TdSpacing.related,
      TdSpacing.component,
      TdSpacing.group,
      TdSpacing.sectionMobile,
      TdSpacing.sectionDesktop,
      TdSpacing.pageMobile,
      TdSpacing.pageTablet,
      TdSpacing.pageDesktop,
    ]) {
      expect(TdSpacing.scale, contains(semanticSpacing));
    }
    expect(TdSizing.minimumTouchTarget, greaterThanOrEqualTo(44));
    expect(TdTypography.body.fontSize, greaterThanOrEqualTo(12));
    expect(TdRadius.control, lessThanOrEqualTo(TdRadius.dialog));
    expect(TdRadius.pill, greaterThan(TdRadius.dialog));
    expect(
      TdMotion.effective(TdMotion.standard, disableAnimations: true),
      Duration.zero,
    );
  });

  test('font asset contract is fully declared from verified pinned assets', () {
    final root = Directory.current.path.endsWith('truenavo_design_system')
        ? Directory.current
        : Directory('packages/truenavo_design_system');
    final pubspec = File('${root.path}/pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('family: Pretendard'));
    expect(pubspec, contains('family: JetBrainsMono'));
    expect(TdTypography.uiFamily, 'packages/truenavo_design_system/Pretendard');
    expect(
      TdTypography.monoFamily,
      'packages/truenavo_design_system/JetBrainsMono',
    );
    for (final name in [
      'PretendardVariable.ttf',
      'JetBrainsMonoVariable.ttf',
      'PRETENDARD_LICENSE.txt',
      'JETBRAINS_MONO_OFL.txt',
      'SOURCES.md',
    ]) {
      final file = File('${root.path}/assets/fonts/$name');
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), greaterThan(0));
    }
    final sources = File('${root.path}/assets/fonts/SOURCES.md')
        .readAsStringSync();
    expect(sources, contains('Pretendard 1.3.9'));
    expect(sources, contains('JetBrains Mono 2.304'));
    expect(
      sources,
      contains(
        '3090ccde0442bb347aa7685d9ba8b17436a60682df6e8f92a9a670de14056e22',
      ),
    );
    expect(
      sources,
      contains(
        '662a196d58f1183bf2d77428b6d5283fe3f45161ab021bea4036bc98e5cac016',
      ),
    );
  });
}
