import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:memora/data/services/hosted_task_run_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'memora-hosted-task-store-',
    );
    Hive.init(tempDirectory.path);
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  HostedTaskRunBinding binding({
    HostedTaskBindingState state = HostedTaskBindingState.running,
    String? runId = 'run-1',
  }) {
    return HostedTaskRunBinding(
      idempotencyKey: 'memora-task-v4-key',
      profile: 'summary.chunk',
      model: 'mimo-v2.5-pro',
      inputDigest: 'sha256-only-no-article-text',
      planDigest: 'summary-plan-sha256-only',
      articleId: 'article-1',
      generation: 'generation-1',
      stage: 'summary.chunk.0',
      runId: runId,
      state: state,
      updatedAt: DateTime.utc(2026, 8, 23),
    );
  }

  test(
    'persists metadata binding and isolates account/device scopes',
    () async {
      final store = HiveHostedTaskRunStore();
      await store.writeBinding('scope-a', binding());

      final restored = await store.readBinding('scope-a', 'memora-task-v4-key');
      expect(restored?.runId, 'run-1');
      expect(restored?.generation, 'generation-1');
      expect(restored?.planDigest, 'summary-plan-sha256-only');
      expect(await store.readBinding('scope-b', 'memora-task-v4-key'), isNull);
      expect(
        (await store.readBindingForOperation(
          scopeHash: 'scope-a',
          articleId: 'article-1',
          generation: 'generation-1',
          stage: 'summary.chunk.0',
        ))?.runId,
        'run-1',
      );
      expect(
        await store.readBindingForOperation(
          scopeHash: 'scope-b',
          articleId: 'article-1',
          generation: 'generation-1',
          stage: 'summary.chunk.0',
        ),
        isNull,
      );

      final raw = await Hive.openBox<Map>(HiveHostedTaskRunStore.boxName);
      final encoded = raw.values.single.toString();
      expect(encoded, isNot(contains('private article body')));
      expect(raw.values.single.keys, isNot(contains('input')));
      expect(raw.values.single.keys, isNot(contains('content')));
      await store.close();
    },
  );

  test(
    'completed binding remains replayable until generation finalizes',
    () async {
      final store = HiveHostedTaskRunStore();
      await store.writeBinding(
        'scope-a',
        binding(state: HostedTaskBindingState.completed),
      );

      expect(
        await store.hasReplayableBindings(
          scopeHash: 'scope-a',
          articleId: 'article-1',
          generation: 'generation-1',
        ),
        isTrue,
      );

      await store.finalizeGeneration(
        scopeHash: 'scope-a',
        articleId: 'article-1',
        generation: 'generation-1',
      );
      expect(
        await store.hasReplayableBindings(
          scopeHash: 'scope-a',
          articleId: 'article-1',
          generation: 'generation-1',
        ),
        isFalse,
      );
      await store.close();
    },
  );

  test('terminal failure is not replayable', () async {
    final store = HiveHostedTaskRunStore();
    await store.writeBinding(
      'scope-a',
      binding(state: HostedTaskBindingState.failed),
    );

    expect(
      await store.hasReplayableBindings(
        scopeHash: 'scope-a',
        articleId: 'article-1',
        generation: 'generation-1',
      ),
      isFalse,
    );
    await store.close();
  });

  test('mixed completed and failed bindings rotate the generation', () async {
    final store = HiveHostedTaskRunStore();
    await store.writeBinding(
      'scope-a',
      binding(state: HostedTaskBindingState.completed),
    );
    await store.writeBinding(
      'scope-a',
      HostedTaskRunBinding(
        idempotencyKey: 'memora-task-v4-tags',
        profile: 'memory.tags',
        model: 'mimo-v2.5-pro',
        inputDigest: 'tags-digest',
        articleId: 'article-1',
        generation: 'generation-1',
        stage: 'memory.tags',
        runId: 'run-tags',
        state: HostedTaskBindingState.failed,
        updatedAt: DateTime.utc(2026, 8, 23),
      ),
    );

    expect(
      await store.hasReplayableBindings(
        scopeHash: 'scope-a',
        articleId: 'article-1',
        generation: 'generation-1',
      ),
      isFalse,
    );
    await store.close();
  });

  test('token usage is durably deduplicated by scope and run id', () async {
    var store = HiveHostedTaskRunStore();
    final concurrent = await Future.wait(
      List.generate(8, (_) => store.recordTokenUsage('scope-a', 'run-1', 42)),
    );
    expect(concurrent.where((recorded) => recorded), hasLength(1));
    expect(await store.recordTokenUsage('scope-a', 'run-1', 42), isFalse);
    expect(await store.recordTokenUsage('scope-b', 'run-1', 42), isTrue);
    await store.close();

    store = HiveHostedTaskRunStore();
    expect(await store.recordTokenUsage('scope-a', 'run-1', 42), isFalse);
    await store.close();
  });
}
