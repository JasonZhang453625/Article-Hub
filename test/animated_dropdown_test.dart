import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memora/shared/widgets/animated_dropdown.dart';

void main() {
  testWidgets('AnimatedDropdownButton opens menu and selects option',
      (tester) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AnimatedDropdownButton<String>(
              value: 'gpt-4o-mini',
              options: const ['gpt-4o-mini', 'gpt-4o', 'claude-3-5-sonnet'],
              labelOf: (v) => v,
              onChanged: (v) => selected = v,
            ),
          ),
        ),
      ),
    );

    expect(find.text('gpt-4o-mini'), findsOneWidget);

    // Open the menu.
    await tester.tap(find.text('gpt-4o-mini'));
    await tester.pumpAndSettle();

    // All options visible.
    expect(find.text('claude-3-5-sonnet'), findsOneWidget);

    // Select a new option.
    await tester.tap(find.text('claude-3-5-sonnet'));
    await tester.pumpAndSettle();

    expect(selected, 'claude-3-5-sonnet');
  });

  testWidgets(
      'AnimatedDropdownButton reopens after dismissing via outside tap',
      (tester) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AnimatedDropdownButton<String>(
              value: 'gpt-4o-mini',
              options: const ['gpt-4o-mini', 'gpt-4o', 'claude-3-5-sonnet'],
              labelOf: (v) => v,
              onChanged: (v) => selected = v,
            ),
          ),
        ),
      ),
    );

    // Open the menu, then dismiss it by tapping the outside barrier.
    await tester.tap(find.text('gpt-4o-mini'));
    await tester.pumpAndSettle();
    expect(find.text('claude-3-5-sonnet'), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('claude-3-5-sonnet'), findsNothing);

    // Tapping the trigger again must reopen the menu.
    await tester.tap(find.text('gpt-4o-mini'));
    await tester.pumpAndSettle();
    expect(find.text('claude-3-5-sonnet'), findsOneWidget);

    // And the menu is still interactive.
    await tester.tap(find.text('gpt-4o'));
    await tester.pumpAndSettle();
    expect(selected, 'gpt-4o');
  });
}
