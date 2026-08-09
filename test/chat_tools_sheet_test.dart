import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/data/models/ai_thinking_level.dart';
import 'package:memora/features/chat/chat_tools_sheet.dart';
import 'package:memora/shared/utils/locale_strings.dart';

void main() {
  testWidgets('shows image, file and Skill actions in one top row', (
    tester,
  ) async {
    final actions = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatToolsSheet(
            s: LocaleStrings.of(2),
            webSearchEnabled: false,
            webSearchAvailable: true,
            thinkingLevel: AiThinkingLevel.none,
            thinkingAvailable: false,
            onToggleWebSearch: (_) {},
            onThinkingChanged: (_) {},
            onAddImage: () => actions.add('image'),
            onAddFile: () => actions.add('file'),
            onOpenSkills: () => actions.add('skill'),
          ),
        ),
      ),
    );

    for (final entry in const [
      (ValueKey('chat-tools-image-button'), 'image'),
      (ValueKey('chat-tools-file-button'), 'file'),
      (ValueKey('chat-tools-skill-button'), 'skill'),
    ]) {
      await tester.tap(find.byKey(entry.$1));
      await tester.pump();
      expect(actions.last, entry.$2);
    }
    expect(find.text('Image'), findsOneWidget);
    expect(find.text('File'), findsOneWidget);
    expect(find.text('Skill'), findsOneWidget);
  });

  testWidgets('web tool switch updates optimistically on the next frame', (
    tester,
  ) async {
    var enabled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ChatToolsSheet(
              s: LocaleStrings.of(2),
              webSearchEnabled: enabled,
              webSearchAvailable: true,
              thinkingLevel: AiThinkingLevel.none,
              thinkingAvailable: false,
              onToggleWebSearch: (value) => setState(() => enabled = value),
              onThinkingChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('chat-tools-web-search')));
    await tester.pump();

    expect(enabled, isTrue);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('chat-tools-web-search')),
          )
          .value,
      isTrue,
    );
  });

  testWidgets('thinking control animates across four selectable levels', (
    tester,
  ) async {
    var selected = AiThinkingLevel.none;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return ChatToolsSheet(
                s: LocaleStrings.of(2),
                webSearchEnabled: false,
                webSearchAvailable: true,
                thinkingLevel: selected,
                thinkingAvailable: true,
                onToggleWebSearch: (_) {},
                onThinkingChanged: (value) {
                  rebuild(() => selected = value);
                },
              );
            },
          ),
        ),
      ),
    );

    expect(find.text('None'), findsOneWidget);
    expect(find.text('Low'), findsOneWidget);
    expect(find.text('Medium'), findsOneWidget);
    expect(find.text('Max'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chat-thinking-level-3')));
    await tester.pump();
    expect(selected, AiThinkingLevel.max);
    final animated = tester.widget<AnimatedAlign>(
      find.byKey(const ValueKey('chat-thinking-thumb')),
    );
    expect(animated.duration, const Duration(milliseconds: 240));
    expect(animated.alignment, const Alignment(1, 0));
    await tester.pumpAndSettle();
  });

  testWidgets('thinking control explains when the model is unsupported', (
    tester,
  ) async {
    var changed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatToolsSheet(
            s: LocaleStrings.of(2),
            webSearchEnabled: false,
            webSearchAvailable: true,
            thinkingLevel: AiThinkingLevel.none,
            thinkingAvailable: false,
            onToggleWebSearch: (_) {},
            onThinkingChanged: (_) => changed = true,
          ),
        ),
      ),
    );

    expect(find.textContaining('DeepSeek only'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-thinking-level-3')));
    expect(changed, isFalse);
  });
}
