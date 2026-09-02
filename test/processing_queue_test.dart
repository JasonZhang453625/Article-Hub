import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/data/services/processing_queue.dart';

void main() {
  Article article(
    String id, {
    ProcessingStatus status = ProcessingStatus.completed,
  }) {
    return Article(
      id: id,
      url: 'https://example.com/$id',
      title: id,
      source: SourcePlatform.web,
      processingStatus: status,
    );
  }

  test(
    'enqueueAll persists every item as pending before the first job finishes',
    () async {
      final records = <String, Article>{
        'one': article('one'),
        'two': article('two'),
      };
      final firstRun = Completer<void>();
      final started = Completer<void>();
      final queue = ProcessingQueue(
        getArticles: () => records.values.toList(),
        save: (value) async => records[value.id] = value,
        prepareRetry: (value) async => value,
        canProcess: (_) => true,
        process: (value) async {
          if (!started.isCompleted) started.complete();
          await firstRun.future;
          final completed = value.copyWith(
            processingStatus: ProcessingStatus.completed,
          );
          records[value.id] = completed;
          return completed;
        },
      );

      await queue.enqueueAll(records.values);
      await started.future;

      expect(records['one']!.processingStatus, ProcessingStatus.pending);
      expect(records['two']!.processingStatus, ProcessingStatus.pending);

      firstRun.complete();
      await queue.whenIdle;
    },
  );

  test(
    'enqueueAll defers re-entrant resume signals until the batch is durable',
    () async {
      final records = <String, Article>{
        'one': article('one'),
        'two': article('two'),
      };
      var savedCount = 0;
      final observedSaveCounts = <int>[];
      late ProcessingQueue queue;
      queue = ProcessingQueue(
        getArticles: () => records.values.toList(),
        save: (value) async {
          records[value.id] = value;
          savedCount++;
          queue.resume();
        },
        prepareRetry: (value) async => value,
        canProcess: (_) => true,
        process: (value) async {
          observedSaveCounts.add(savedCount);
          final completed = value.copyWith(
            processingStatus: ProcessingStatus.completed,
          );
          records[value.id] = completed;
          return completed;
        },
      );

      await queue.enqueueAll(records.values);
      await queue.whenIdle;

      expect(observedSaveCounts.first, 2);
    },
  );

  test(
    'resume processes persisted pending and interrupted jobs serially',
    () async {
      final records = <String, Article>{
        'interrupted': article(
          'interrupted',
          status: ProcessingStatus.processing,
        ),
        'queued': article('queued', status: ProcessingStatus.pending),
      };
      final processed = <String>[];
      final queue = ProcessingQueue(
        getArticles: () => records.values.toList(),
        save: (value) async => records[value.id] = value,
        prepareRetry: (value) async => value,
        canProcess: (_) => true,
        process: (value) async {
          processed.add(value.id);
          final completed = value.copyWith(
            processingStatus: ProcessingStatus.completed,
            processingStage: Article.clearValue,
          );
          records[value.id] = completed;
          return completed;
        },
      );

      queue.resume();
      await queue.whenIdle;

      expect(processed, ['interrupted', 'queued']);
      expect(
        records.values.every(
          (value) => value.processingStatus == ProcessingStatus.completed,
        ),
        isTrue,
      );
    },
  );

  test(
    'resume leaves jobs waiting until their prerequisites are ready',
    () async {
      final records = <String, Article>{
        'waiting': article('waiting', status: ProcessingStatus.pending),
      };
      var ready = false;
      var runs = 0;
      final queue = ProcessingQueue(
        getArticles: () => records.values.toList(),
        save: (value) async => records[value.id] = value,
        prepareRetry: (value) async => value,
        canProcess: (_) => ready,
        process: (value) async {
          runs++;
          final completed = value.copyWith(
            processingStatus: ProcessingStatus.completed,
          );
          records[value.id] = completed;
          return completed;
        },
      );

      queue.resume();
      await queue.whenIdle;
      expect(runs, 0);
      expect(records['waiting']!.processingStatus, ProcessingStatus.pending);

      ready = true;
      queue.resume();
      await queue.whenIdle;
      expect(runs, 1);
    },
  );

  test(
    'an unexpected worker error is persisted as failed so it cannot loop forever',
    () async {
      final records = <String, Article>{
        'broken': article('broken', status: ProcessingStatus.pending),
      };
      final queue = ProcessingQueue(
        getArticles: () => records.values.toList(),
        save: (value) async => records[value.id] = value,
        prepareRetry: (value) async => value,
        canProcess: (_) => true,
        process: (_) async => throw StateError('worker crashed'),
      );

      queue.resume();
      await queue.whenIdle;

      expect(records['broken']!.processingStatus, ProcessingStatus.failed);
      expect(records['broken']!.processingError, contains('worker crashed'));
    },
  );

  test('retry prepares a fresh attempt before the queue persists it', () async {
    final failed = article('failed', status: ProcessingStatus.failed).copyWith(
      processingError: 'summary: task_invalid_output',
      retryCount: 4,
      hostedTaskGeneration: 'failed-generation',
    );
    final records = <String, Article>{'failed': failed};
    var prepareCalls = 0;
    final queue = ProcessingQueue(
      getArticles: () => records.values.toList(),
      save: (value) async => records[value.id] = value,
      prepareRetry: (value) async {
        prepareCalls++;
        return value.copyWith(
          retryCount: value.retryCount + 1,
          hostedTaskGeneration: 'fresh-generation',
        );
      },
      canProcess: (_) => false,
      process: (_) async => null,
    );

    await queue.retry(failed);

    expect(prepareCalls, 1);
    expect(records['failed']!.processingStatus, ProcessingStatus.pending);
    expect(records['failed']!.processingError, isNull);
    expect(records['failed']!.retryCount, 5);
    expect(records['failed']!.hostedTaskGeneration, 'fresh-generation');
  });
}
