import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/data/repositories/article_repository.dart';
import 'package:memora/features/inbox/inbox_screen.dart';
import 'package:memora/shared/providers/passage_providers.dart';
import 'package:memora/shared/providers/settings_providers.dart';

/// Phase 1.4 widget tests for [InboxScreen].
///
/// Mirrors the pattern from chat_screen_widget_test.dart: override
/// [hiveInitProvider] with a never-completing future and
/// [articleRepositoryProvider] with an in-memory fake — `flutter test` runs
/// in a fake-async zone where real Hive file I/O never completes, so the
/// in-memory repo is the only safe substrate.
void main() {
  Future<void> pumpInbox(
    WidgetTester tester, {
    required List<Article> articles,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hiveInitProvider.overrideWith((ref) => Completer<void>().future),
          languageIndexProvider.overrideWith((ref) => 2), // force English
          articleRepositoryProvider.overrideWith(
            (ref) async => _InMemoryArticleRepository(articles),
          ),
        ],
        child: const MaterialApp(home: InboxScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
  }

  Article seed({
    required String id,
    required ProcessingStatus status,
    ProcessingStage? stage,
    String? error,
    int retryCount = 0,
  }) =>
      Article(
        id: id,
        url: 'https://example.com/$id',
        title: 'Article $id',
        source: SourcePlatform.web,
        processingStatus: status,
        processingStage: stage,
        processingError: error,
        retryCount: retryCount,
      );

  testWidgets('empty inbox shows the empty state', (tester) async {
    await pumpInbox(tester, articles: []);
    expect(find.text('No articles in progress'), findsOneWidget);
    expect(
      find.textContaining('Articles being processed will appear here'),
      findsOneWidget,
    );
  });

  testWidgets('completed articles are not shown in the inbox', (tester) async {
    await pumpInbox(
      tester,
      articles: [
        seed(id: 'done', status: ProcessingStatus.completed),
      ],
    );
    // Completed articles live in Library; they must not surface in Inbox.
    expect(find.text('No articles in progress'), findsOneWidget);
    expect(find.text('Article done'), findsNothing);
  });

  testWidgets('pending article shows the Waiting section', (tester) async {
    await pumpInbox(
      tester,
      articles: [
        seed(
          id: 'p1',
          status: ProcessingStatus.pending,
          stage: ProcessingStage.summary,
        ),
      ],
    );
    expect(find.text('Waiting'), findsOneWidget);
    expect(find.text('Article p1'), findsOneWidget);
    expect(find.text('Queued'), findsOneWidget);
    // Pending rows do not expose a retry button.
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
  });

  testWidgets('pending article appears under the Waiting section',
      (tester) async {
    await pumpInbox(
      tester,
      articles: [
        seed(id: 'q1', status: ProcessingStatus.pending),
      ],
    );
    expect(find.text('Waiting'), findsOneWidget);
    expect(find.text('Queued'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
  });

  testWidgets('failed article shows the error and exposes a retry button',
      (tester) async {
    await pumpInbox(
      tester,
      articles: [
        seed(
          id: 'f1',
          status: ProcessingStatus.failed,
          error: 'summary: API rate limited',
          retryCount: 2,
        ),
      ],
    );
    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('summary: API rate limited'), findsOneWidget);
    expect(find.text('x2'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
  });

  testWidgets('mixed inbox renders Processing, Waiting and Failed sections',
      (tester) async {
    await pumpInbox(
      tester,
      articles: [
        seed(id: 'q1', status: ProcessingStatus.pending),
        seed(
          id: 'f1',
          status: ProcessingStatus.failed,
          error: 'content: 500',
        ),
        // Completed should still be filtered out.
        seed(id: 'done', status: ProcessingStatus.completed),
      ],
    );
    expect(find.text('Waiting'), findsOneWidget);
    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('Article done'), findsNothing);
  });
}

/// In-memory [ArticleRepository] for widget tests — no Hive, no file I/O.
class _InMemoryArticleRepository implements ArticleRepository {
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

  @override
  List<Article> search(String query) => getAll();

  @override
  List<Article> filterBySource(String sourceName) => getAll();

  @override
  Future<void> unsetFolder(String folderId) async {}

  @override
  Future<void> unsetFolderBatch(String folderId) async {}
}


