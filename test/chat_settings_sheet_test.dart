import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memora/features/chat/chat_settings_sheet.dart';
import 'package:memora/shared/utils/locale_strings.dart';

Widget _wrap(LocaleStrings s) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () => Navigator.of(context).push(
              PageRouteBuilder<void>(
                opaque: false,
                barrierColor: Colors.black54,
                barrierDismissible: true,
                pageBuilder: (_, _, _) => ChatSettingsSheet(
                  s: s,
                  answerLength: 0,
                  knowledgeSource: 0,
                  onChanged: (a, k) async {},
                ),
                transitionsBuilder: (_, animation, _, child) {
                  final curved = CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                    reverseCurve: Curves.easeInCubic,
                  );
                  return AnimatedBuilder(
                    animation: curved,
                    builder: (context, _) => Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionalTranslation(
                        translation: Offset(0, 0.5 * (1 - curved.value)),
                        child: child,
                      ),
                    ),
                  );
                },
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _dragHandle(WidgetTester tester, Offset delta) async {
  final handle = find.byKey(const ValueKey('chat-settings-handle'));
  final gesture = await tester.startGesture(tester.getCenter(handle));
  // First move crosses the touch slop, then the rest tracks the finger.
  final steps = 8;
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(Offset(0, delta.dy / steps));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  final s = LocaleStrings.of(0);

  testWidgets('dragging the handle down past threshold dismisses the sheet', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(s));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(s.chatSettings), findsOneWidget);

    // Drag down 200px on a 600px test screen (> 20% threshold).
    await _dragHandle(tester, const Offset(0, 200));

    expect(find.text(s.chatSettings), findsNothing);
  });

  testWidgets('small drag snaps back and keeps the sheet open', (tester) async {
    await tester.pumpWidget(_wrap(s));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(s.chatSettings), findsOneWidget);

    await _dragHandle(tester, const Offset(0, 30));

    expect(find.text(s.chatSettings), findsOneWidget);
  });

  testWidgets('uses a half-screen sheet and leaves the barrier tappable', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(s));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final sheet = find.byKey(const ValueKey('chat-settings-sheet'));
    final screenHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(tester.getSize(sheet).height, screenHeight * 0.5);
    expect(tester.getTopLeft(sheet).dy, screenHeight * 0.5);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text(s.chatSettings), findsNothing);
  });

  testWidgets('small drag returns continuously instead of jumping at the end', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(s));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final title = find.text(s.chatSettings);
    final restingTop = tester.getTopLeft(title).dy;

    final handle = find.byKey(const ValueKey('chat-settings-handle'));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();

    final draggedTop = tester.getTopLeft(title).dy;
    expect(draggedTop, greaterThan(restingTop));

    // Start the controller's first frame before advancing half its duration.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 130));
    final midAnimationTop = tester.getTopLeft(title).dy;
    expect(midAnimationTop, lessThan(draggedTop));
    expect(midAnimationTop, greaterThan(restingTop));

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(title).dy, restingTop);
  });
}
