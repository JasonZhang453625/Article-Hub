import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/data/repositories/article_repository.dart';
import 'package:memora/data/services/ai_service.dart';
import 'package:memora/features/reader/summary_screen.dart';
import 'package:memora/shared/providers/ai_providers.dart';
import 'package:memora/shared/providers/article_providers.dart';
import 'package:memora/shared/providers/settings_providers.dart';

void main() {
  testWidgets('queued summary shows the generating state on its detail page', (
    tester,
  ) async {
    final article = Article(
      id: 'queued-summary',
      url: 'https://example.com/queued-summary',
      title: 'Queued summary',
      source: SourcePlatform.web,
      processingStatus: ProcessingStatus.pending,
    );
    final repositoryGate = Completer<ArticleRepository>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          languageIndexProvider.overrideWithValue(1),
          articleRepositoryProvider.overrideWith(
            (ref) => repositoryGate.future,
          ),
          articlesProvider.overrideWith(
            (ref) => _TestArticlesNotifier(ref, article),
          ),
          summaryAiGatewayProvider.overrideWithValue(
            AiService(
              baseUrl: 'https://example.com',
              apiKey: 'test-key',
              model: 'test-model',
            ),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: SummaryContent(article: article)),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('正在生成摘要…'), findsOneWidget);
    expect(find.text('生成摘要'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(button.onPressed, isNull);
  });
}

class _TestArticlesNotifier extends ArticlesNotifier {
  _TestArticlesNotifier(super.ref, Article article) {
    state = AsyncValue.data([article]);
  }
}
