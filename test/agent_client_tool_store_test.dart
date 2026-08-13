import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:memora/data/services/agent_client_tool_store.dart';

void main() {
  late Directory directory;
  late AgentClientToolStore store;
  const binding = AgentToolRunBinding(
    ownerUserId: 'user-a',
    ownerDeviceId: 'device-a',
    runId: 'run-a',
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('memora-agent-store-');
    Hive.init(directory.path);
    store = AgentClientToolStore();
    await store.init();
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('opaque reference is scoped by account, device, and run', () async {
    final created = await store.createArticleReference(
      binding: binding,
      articleId: 'real-article-id',
      title: 'Safe title',
    );
    expect(created.articleRef, matches(AgentClientToolStore.articleRefPattern));
    expect(
      (await store.resolveArticleReference(
        binding: binding,
        articleRef: created.articleRef,
      ))?.articleId,
      'real-article-id',
    );
    expect(
      await store.resolveArticleReference(
        binding: const AgentToolRunBinding(
          ownerUserId: 'user-b',
          ownerDeviceId: 'device-a',
          runId: 'run-a',
        ),
        articleRef: created.articleRef,
      ),
      isNull,
    );
  });

  test('claim intent is durable and canonical across response loss', () async {
    final first = await store.beginClaimIntent(
      binding: binding,
      callId: 'call-1',
      tool: 'local_search',
      arguments: {'query': 'flutter'},
    );
    final replay = await store.beginClaimIntent(
      binding: binding,
      callId: 'call-1',
      tool: 'local_search',
      arguments: {'query': 'flutter'},
    );
    expect(replay.claimRequestKey, first.claimRequestKey);
    expect(replay.resultReceiptKey, first.resultReceiptKey);
    expect(replay.state, 'claim_intent');

    final claimed = await store.recordClaim(
      receipt: replay,
      claimToken: '11111111-1111-4111-8111-111111111111',
      leaseEpoch: '1',
    );
    final ready = await store.recordResultReady(
      receipt: claimed,
      result: {
        'schemaVersion': 1,
        'status': 'empty',
        'results': <Object>[],
        'truncated': false,
      },
    );
    final reclaimed = await store.prepareReclaim(ready);
    expect(reclaimed.result, ready.result);
    expect(reclaimed.argumentsHash, ready.argumentsHash);
    expect(reclaimed.claimToken, isNull);
    expect(reclaimed.leaseEpoch, isNull);
    expect(reclaimed.claimRequestKey, isNot(first.claimRequestKey));

    final reClaimed = await store.recordClaim(
      receipt: reclaimed,
      claimToken: '22222222-2222-4222-8222-222222222222',
      leaseEpoch: '2',
    );
    await store.markSubmitting(reClaimed);
    await store.acknowledgeReceipt(binding: binding, callId: 'call-1');
    expect(await store.getReceipt(binding: binding, callId: 'call-1'), isNull);
  });

  test(
    'lease reclaim rotates keys but preserves the computed result',
    () async {
      var receipt = await store.beginClaimIntent(
        binding: binding,
        callId: 'call-lease',
        tool: 'local_search',
        arguments: const {'query': 'agent'},
      );
      receipt = await store.recordClaim(
        receipt: receipt,
        claimToken: '11111111-1111-4111-8111-111111111111',
        leaseEpoch: '1',
      );
      receipt = await store.recordResultReady(
        receipt: receipt,
        result: const {
          'schemaVersion': 1,
          'status': 'empty',
          'results': <Object>[],
          'truncated': false,
        },
      );
      final oldClaimKey = receipt.claimRequestKey;
      final oldResultKey = receipt.resultReceiptKey;

      final reclaimed = await store.prepareLeaseReclaim(receipt);

      expect(reclaimed.state, 'claim_intent');
      expect(reclaimed.claimToken, isNull);
      expect(reclaimed.leaseEpoch, isNull);
      expect(reclaimed.result, receipt.result);
      expect(reclaimed.claimRequestKey, isNot(oldClaimKey));
      expect(reclaimed.resultReceiptKey, isNot(oldResultKey));
    },
  );

  test(
    'receipt enumeration is sorted and exact owner-device-run scoped',
    () async {
      await store.beginClaimIntent(
        binding: binding,
        callId: 'call-b',
        tool: 'local_search',
        arguments: const {'query': 'b'},
      );
      await store.beginClaimIntent(
        binding: binding,
        callId: 'call-a',
        tool: 'local_search',
        arguments: const {'query': 'a'},
      );
      await store.beginClaimIntent(
        binding: const AgentToolRunBinding(
          ownerUserId: 'user-b',
          ownerDeviceId: 'device-a',
          runId: 'run-a',
        ),
        callId: 'call-other-owner',
        tool: 'local_search',
        arguments: const {'query': 'other'},
      );
      await store.beginClaimIntent(
        binding: const AgentToolRunBinding(
          ownerUserId: 'user-a',
          ownerDeviceId: 'device-b',
          runId: 'run-a',
        ),
        callId: 'call-other-device',
        tool: 'local_search',
        arguments: const {'query': 'other'},
      );

      expect((await store.receiptsForRun(binding)).map((item) => item.callId), [
        'call-a',
        'call-b',
      ]);
      await store.acknowledgeReceipt(binding: binding, callId: 'call-a');
      expect((await store.receiptsForRun(binding)).map((item) => item.callId), [
        'call-b',
      ]);
    },
  );

  test(
    'citation mapping validates local existence and deleteRun erases data',
    () async {
      final reference = await store.createArticleReference(
        binding: binding,
        articleId: 'article-1',
        title: 'One',
      );
      final cited = await store.resolveCitedArticleIds(
        binding: binding,
        answer: 'Evidence [1], but not [2].',
        localSources: [(id: '1', articleRef: reference.articleRef)],
        existingArticleIds: {'article-1'},
      );
      expect(cited, ['article-1']);
      expect(
        await store.resolveCitedArticleIds(
          binding: binding,
          answer: '[1]',
          localSources: [(id: '1', articleRef: reference.articleRef)],
          existingArticleIds: const {},
        ),
        isEmpty,
      );

      await store.deleteRun(binding);
      expect(
        await store.resolveArticleReference(
          binding: binding,
          articleRef: reference.articleRef,
        ),
        isNull,
      );
    },
  );
}
