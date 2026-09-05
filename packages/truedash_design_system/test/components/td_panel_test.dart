import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truedash_design_system/truedash_design_system.dart';

void main() {
  testWidgets('panel reads title, description, action, then body', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TrueDashTheme.dark(),
        home: const Scaffold(
          body: TdPanel(
            title: 'Title',
            description: 'Description',
            action: TdButton(label: 'Action', onPressed: _noop),
            child: Text('Body'),
          ),
        ),
      ),
    );
    expect(find.text('Title'), findsOneWidget);
    expect(find.text('Description'), findsOneWidget);
    expect(find.text('Action'), findsOneWidget);
    expect(find.text('Body'), findsOneWidget);
  });

  testWidgets('header reflows title before action at 200% text scale', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TrueDashTheme.dark(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 320,
                child: TdPanel(
                  title: 'Connection summary',
                  action: TdButton(label: 'Connected', onPressed: _noop),
                  child: const Text('Body'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Connection summary'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    final title = tester.getTopLeft(find.text('Connection summary'));
    final action = tester.getTopLeft(find.text('Connected'));
    expect(action.dy, greaterThan(title.dy));
  });
}

void _noop() {}
