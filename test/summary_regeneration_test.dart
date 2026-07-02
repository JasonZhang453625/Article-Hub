import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/settings.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/features/reader/summary_regeneration_provider.dart';

void main() {
  final article = Article(
    id: 'article-1',
    url: 'https://example.com/article',
    title: 'Original title',
    source: SourcePlatform.web,
  );
  final settings = AppSettings(
    aiBaseUrl: 'https://example.com/v1',
    aiApiKey: 'test-key',
  );

  test('job continues and saves after the launching screen is gone', () async {
    final completion = Completer<SummaryRegenerationResult>();
    final saves = <SummaryRegenerationResult>[];
    final controller = SummaryRegenerationController(
      runner: (_, _) => completion.future,
      save: (id, title, summary, coverImageUrl) async {
        saves.add(SummaryRegenerationResult(title: title, summary: summary));
      },
    );

    final job = controller.regenerate(article, settings);
    expect(controller.state, contains(article.id));

    completion.complete(
      const SummaryRegenerationResult(
        title: 'Generated title',
        summary: 'Generated summary',
      ),
    );
    final result = await job;

    expect(result.succeeded, isTrue);
    expect(saves.single.title, 'Generated title');
    expect(saves.single.summary, 'Generated summary');
    expect(controller.state, isEmpty);
  });

  test('duplicate taps reuse the same active job', () async {
    final completion = Completer<SummaryRegenerationResult>();
    var runs = 0;
    final controller = SummaryRegenerationController(
      runner: (_, _) {
        runs++;
        return completion.future;
      },
      save: (_, _, _, _) async {},
    );

    final first = controller.regenerate(article, settings);
    final second = controller.regenerate(article, settings);
    expect(runs, 1);

    completion.complete(
      const SummaryRegenerationResult(summary: 'Generated summary'),
    );
    expect((await first).succeeded, isTrue);
    expect((await second).succeeded, isTrue);
  });

  test('failed job clears its running state without saving', () async {
    var saves = 0;
    final controller = SummaryRegenerationController(
      runner: (_, _) async => const SummaryRegenerationResult(error: 'failed'),
      save: (_, _, _, _) async {
        saves++;
      },
    );

    final result = await controller.regenerate(article, settings);

    expect(result.succeeded, isFalse);
    expect(saves, 0);
    expect(controller.state, isEmpty);
  });
}
