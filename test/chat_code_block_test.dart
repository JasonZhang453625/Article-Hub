import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/features/chat/chat_bubble.dart';
import 'package:memora/features/chat/chat_message.dart';
import 'package:memora/shared/providers/settings_providers.dart';

void main() {
  testWidgets('renders fenced code in a labeled, copyable code card', (
    tester,
  ) async {
    String? copiedCode;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedCode =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [languageIndexProvider.overrideWithValue(1)],
        child: MaterialApp(
          home: Scaffold(
            body: ChatBubble(
              message: ChatMessage(
                role: MessageRole.assistant,
                text: '```dart\nvoid main() {}\n```',
              ),
              articlesById: const {},
              onFeedback: (_) {},
              onCitationClick: (_) {},
              onSuggestionTap: (_) {},
              onRetry: (_) {},
              onSave: (_) async {},
              onBrowseKnowledge: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('DART'), findsOneWidget);
    expect(find.byIcon(Icons.content_copy_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.content_copy_rounded));
    await tester.pump();

    expect(copiedCode, 'void main() {}');
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });

  testWidgets('hides horizontal rules and gives paragraphs 12px spacing', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [languageIndexProvider.overrideWithValue(1)],
        child: MaterialApp(
          home: Scaffold(
            body: ChatBubble(
              message: ChatMessage(
                role: MessageRole.assistant,
                text: 'First paragraph.\n\n---\n\nSecond paragraph.',
              ),
              articlesById: const {},
              onFeedback: (_) {},
              onCitationClick: (_) {},
              onSuggestionTap: (_) {},
              onRetry: (_) {},
              onSave: (_) async {},
              onBrowseKnowledge: () {},
            ),
          ),
        ),
      ),
    );

    final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(markdown.styleSheet?.pPadding, const EdgeInsets.only(bottom: 12));
    final horizontalRule =
        markdown.styleSheet?.horizontalRuleDecoration as BoxDecoration;
    expect(horizontalRule.border, isNull);
    expect(horizontalRule.color, isNull);
  });

  testWidgets('renders wide assistant tables in a horizontal scroll region', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [languageIndexProvider.overrideWithValue(1)],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: ChatBubble(
                message: ChatMessage(
                  role: MessageRole.assistant,
                  text: '''
| Product | Detailed capability | Availability | Notes |
| --- | --- | --- | --- |
| Memora | Long-form knowledge retrieval and synthesis | Available now | Preserves citations and source context |
''',
                ),
                articlesById: const {},
                onFeedback: (_) {},
                onCitationClick: (_) {},
                onSuggestionTap: (_) {},
                onRetry: (_) {},
                onSave: (_) async {},
                onBrowseKnowledge: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final markdownFinder = find.byType(MarkdownBody);
    final markdown = tester.widget<MarkdownBody>(markdownFinder);
    expect(markdown.styleSheet?.tableColumnWidth, isA<IntrinsicColumnWidth>());
    expect(markdown.styleSheet?.tableScrollbarThumbVisibility, isTrue);

    final horizontalScroller = find.descendant(
      of: markdownFinder,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      ),
    );
    expect(horizontalScroller, findsOneWidget);
    expect(
      find.descendant(of: markdownFinder, matching: find.byType(Scrollbar)),
      findsOneWidget,
    );

    final scroller = tester.widget<SingleChildScrollView>(horizontalScroller);
    expect(scroller.controller, isNotNull);
    expect(scroller.controller!.position.maxScrollExtent, greaterThan(0));

    await tester.drag(horizontalScroller, const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(scroller.controller!.offset, greaterThan(0));
  });
}
