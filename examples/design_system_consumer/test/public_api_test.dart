import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

void main() {
  testWidgets('public barrel supports an external consumer', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: TrueRAIDTheme.light(density: TrueRAIDDensity.standard),
        home: Scaffold(
          body: Column(
            children: [
              TdPanel(
                title: 'Overview',
                child: TdMetricCard(
                  label: 'Storage',
                  value: '42',
                  unit: '%',
                  freshness: 'Now',
                  trend: 'Stable',
                ),
              ),
              TdButton(label: 'Connect', onPressed: () {}),
              TdTextField(label: 'Server URL', controller: controller),
              const TdStatusBadge(status: TdStatus.success, label: 'Healthy'),
              const TdStateView(kind: TdStateKind.empty, title: 'Nothing here'),
            ],
          ),
        ),
      ),
    );

    final extension = tester.element(find.byType(TdPanel).first).tdTheme;
    expect(extension.density, TrueRAIDDensity.standard);
    expect(TrueRAIDDensity.resolve(600), TrueRAIDDensity.standard);
    expect(TdSpacing.scale, isNotEmpty);
    expect(TdRadius.control, greaterThan(0));
    expect(TdSizing.minimumTouchTarget, greaterThanOrEqualTo(44));
    expect(TdTypography.body.fontSize, greaterThan(0));
    expect(
      TdMotion.effective(TdMotion.fast, disableAnimations: true),
      Duration.zero,
    );
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Healthy'), findsOneWidget);
  });
}
