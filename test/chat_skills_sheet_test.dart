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
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('chat-skill-research')),
          )
          .value,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('chat-skills-clear')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chat-skill-summarize')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chat-skills-apply')));
    await tester.pumpAndSettle();

    expect(result, {'summarize'});
  });
}
