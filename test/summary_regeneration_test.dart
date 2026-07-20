import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/memory_document.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/settings.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/features/reader/summary_regeneration_provider.dart';

void main() {
  final generatedMemory = MemoryDocument.ai(
    overview: 'Generated overview',
    keyPoints: const [
      MemoryKeyPoint(
        id: 'kp-1',
        order: 1,
        topic: 'Topic',
        content: 'Generated fact',
      ),
    ],
    conclusion: 'Generated conclusion',
  );
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
      save: (id, title, memory, tags, coverImageUrl) async {
        saves.add(
          SummaryRegenerationResult(title: title, memory: memory, tags: tags),
        );
      },
    );

    final job = controller.regenerate(article, settings);
    expect(controller.state, contains(article.id));

    completion.complete(
      SummaryRegenerationResult(
        title: 'Generated title',
        memory: generatedMemory,
        tags: const ['AI', 'Agents'],
      ),
    );
    final result = await job;

    expect(result.succeeded, isTrue);
    expect(saves.single.title, 'Generated title');
    expect(saves.single.memory?.overview, 'Generated overview');
    expect(saves.single.tags, ['AI', 'Agents']);
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
      save: (_, _, _, _, _) async {},
    );

    final first = controller.regenerate(article, settings);
    final second = controller.regenerate(article, settings);
    expect(runs, 1);

    completion.complete(SummaryRegenerationResult(memory: generatedMemory));
    expect((await first).succeeded, isTrue);
    expect((await second).succeeded, isTrue);
  });

  test('failed job clears its running state without saving', () async {
    var saves = 0;
    final controller = SummaryRegenerationController(
      runner: (_, _) async => const SummaryRegenerationResult(error: 'failed'),
      save: (_, _, _, _, _) async {
        saves++;
      },
    );

    final result = await controller.regenerate(article, settings);

    expect(result.succeeded, isFalse);
    expect(saves, 0);
    expect(controller.state, isEmpty);
  });

  test(
    'regeneration is durably scheduled instead of being tied to the detail page',
    () async {
      final scheduled = <Article>[];
      final controller = SummaryRegenerationController(
        schedule: (value) async => scheduled.add(value),
      );

      final result = await controller.regenerate(article, settings);

      expect(result.scheduled, isTrue);
      expect(scheduled.single.memory, isNull);
      expect(scheduled.single.summary, isNull);
      expect(scheduled.single.processingStatus, ProcessingStatus.pending);
      expect(controller.state, isEmpty);
    },
  );
}
