import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/data/services/hosted_agent_service.dart';
import 'package:memora/features/chat/chat_skills_sheet.dart';
import 'package:memora/shared/utils/locale_strings.dart';

void main() {
  testWidgets('selects only Skills from the backend catalog', (tester) async {
    Set<String>? result;
    const catalog = HostedAgentSkillCatalog(
      resourceRevision: 12,
      skills: [
        HostedAgentSkill(name: 'research', description: 'Research workflow'),
        HostedAgentSkill(name: 'summarize', description: 'Summarize material'),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  result = await showModalBottomSheet<Set<String>>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => ChatSkillsSheet(
                      s: LocaleStrings.of(2),
                      loadCatalog: () async => catalog,
                      initialSelection: const {'research'},
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Agent revision 12'), findsOneWidget);
    expect(find.text('1 of 2 selected'), findsOneWidget);
    expect(
      tester
          .widget<Checkbox>(
            find.byKey(const ValueKey('chat-skill-checkbox-research')),
          )
          .value,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('chat-skills-clear')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('chat-skill-checkbox-summarize')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chat-skills-apply')));
    await tester.pumpAndSettle();

    expect(result, {'summarize'});
  });

  testWidgets('Chinese descriptions use fixed collapsed rows and expand', (
    tester,
  ) async {
    const catalog = HostedAgentSkillCatalog(
      resourceRevision: 1,
      skills: [
        HostedAgentSkill(
          name: 'office',
          description:
              'Use dedicated tools for PDF, Word, and Excel files. Discover structure first, search before reading full documents, then read selectively.',
        ),
        HostedAgentSkill(
          name: 'memora-assistant',
          description: 'Answer Memora questions using personal memory.',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showModalBottomSheet<Set<String>>(
                context: context,
                isScrollControlled: true,
                builder: (_) => ChatSkillsSheet(
                  s: LocaleStrings.of(1),
                  loadCatalog: () async => catalog,
                  initialSelection: null,
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('智能体版本 1'), findsOneWidget);
    expect(find.textContaining('Use dedicated tools'), findsNothing);
    final office = find.byKey(const ValueKey('chat-skill-office'));
    final assistant = find.byKey(const ValueKey('chat-skill-memora-assistant'));
    expect(tester.getSize(office).height, tester.getSize(assistant).height);
    expect(tester.getSize(office).height, 84);

    await tester.tap(office);
    await tester.pumpAndSettle();
    expect(tester.getSize(office).height, greaterThan(84));
    expect(
      tester.widget<Text>(find.textContaining('使用专用工具读取和搜索')).maxLines,
      isNull,
    );
  });
}
