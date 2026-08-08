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
                        translation: Offset(0, 1 - curved.value),
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

  testWidgets('dragging the handle down past threshold dismisses the sheet',
      (tester) async {
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
}
