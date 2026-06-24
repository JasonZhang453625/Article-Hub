import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:article_hub/data/models/passage.dart';
import 'package:article_hub/data/models/source_platform.dart';
import 'package:article_hub/data/repositories/passage_repository.dart';
import 'package:article_hub/features/chat/chat_screen.dart';
import 'package:article_hub/shared/providers/passage_providers.dart';

/// Phase 3.4 widget tests for the Chat screen states.
///
/// `flutter test` runs widget callbacks in a fake-async zone where real Hive
/// file I/O never completes, so instead of seeding Hive we override the
/// repository with an in-memory fake and leave [hiveInitProvider] pending —
/// this keeps the settings provider in a loading state (valueOrNull == null),
/// which is exactly the "AI not configured" condition the chat flow checks.
void main() {
  Future<void> pumpChat(
    WidgetTester tester, {
    required List<Article> articles,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // Never completes: keeps settings loading without touching Hive.
          hiveInitProvider.overrideWith((ref) => Completer<void>().future),
          // In-memory repository: no file I/O, safe inside fake-async.
          articleRepositoryProvider.overrideWith(
            (ref) async => _InMemoryArticleRepository(articles),
          ),
        ],
        child: const MaterialApp(home: ChatScreen()),
      ),
    );
    // Resolve the repository future and rebuild.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
  }

  testWidgets('empty knowledge base shows process-articles prompt',
      (tester) async {
    await pumpChat(tester, articles: []);

    expect(find.text('Ask your knowledge base'), findsOneWidget);
    expect(find.textContaining('Process some articles first'), findsOneWidget);
  });

  testWidgets('with knowledge available shows example prompts', (tester) async {
    await pumpChat(
      tester,
      articles: [
        Article(
          id: 'k1',
          url: 'https://example.com',
          title: 'AI Basics',
          source: SourcePlatform.web,
          summary: 'An intro to AI.',
          processingStatus: ProcessingStatus.completed,
        ),
      ],
    );

    expect(find.text('Ask your knowledge base'), findsOneWidget);
    expect(find.textContaining('Try:'), findsOneWidget);
  });

  testWidgets('asking without AI configured shows config message',
      (tester) async {
    await pumpChat(
      tester,
      articles: [
        Article(
          id: 'k1',
          url: 'https://example.com',
          title: 'AI Basics',
          source: SourcePlatform.web,
          summary: 'An intro to AI.',
          processingStatus: ProcessingStatus.completed,
        ),
      ],
    );

    await tester.enterText(find.byType(TextField), 'what is ai');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.textContaining('configure your AI provider'), findsOneWidget);
  });

  testWidgets('input bar and send button render', (tester) async {
    await pumpChat(tester, articles: []);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);
  });
}

/// In-memory [ArticleRepository] for widget tests — no Hive, no file I/O.
class _InMemoryArticleRepository extends ArticleRepository {
  final List<Article> _articles;
  _InMemoryArticleRepository(this._articles);

  @override
  Future<void> init() async {}

  @override
  List<Article> getAll() => List<Article>.of(_articles)
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  Article? getById(String id) {
    for (final a in _articles) {
      if (a.id == id) return a;
    }
    return null;
  }

  @override
  Future<void> add(Article article) async => _articles.add(article);

  @override
  Future<int> importAll(Iterable<Article> articles) async {
    _articles.addAll(articles);
    return articles.length;
  }

  @override
  Future<void> update(Article article) async {}

  @override
  Future<void> delete(String id) async =>
      _articles.removeWhere((a) => a.id == id);
}
