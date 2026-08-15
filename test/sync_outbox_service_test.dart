import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:memora/data/services/sync_outbox_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late SyncOutboxService outbox;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('memora_outbox_test_');
    Hive.init(tempDir.path);
    outbox = SyncOutboxService();
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('compacts repeated changes for the same account entity', () async {
    await outbox.enqueue(
      SyncOutboxRecord.create(
        accountId: 'user-1',
        collection: SyncCollections.articles,
        itemId: 'article-1',
        operation: SyncOperation.upsert,
        payload: {'id': 'article-1', 'title': 'First'},
      ),
    );
    await outbox.enqueue(
      SyncOutboxRecord.create(
        accountId: 'user-1',
        collection: SyncCollections.articles,
        itemId: 'article-1',
        operation: SyncOperation.upsert,
        payload: {'id': 'article-1', 'title': 'Latest'},
      ),
    );

    final pending = await outbox.pending(accountId: 'user-1');
    expect(pending, hasLength(1));
    expect(pending.single.payload?['title'], 'Latest');
  });

  test('keeps pending records isolated by account', () async {
    for (final accountId in ['user-1', 'user-2']) {
      await outbox.enqueue(
        SyncOutboxRecord.create(
          accountId: accountId,
          collection: SyncCollections.articles,
          itemId: 'same-item-id',
          operation: SyncOperation.upsert,
          payload: {'id': 'same-item-id', 'owner': accountId},
        ),
      );
    }

    expect(await outbox.count(), 2);
    expect(await outbox.count(accountId: 'user-1'), 1);
    expect(
      (await outbox.pending(accountId: 'user-2')).single.payload?['owner'],
      'user-2',
    );
  });

  test(
    'claim freezes an event id and later enqueue survives old ack',
    () async {
      await outbox.enqueue(
        SyncOutboxRecord.create(
          accountId: 'user-1',
          collection: SyncCollections.articles,
          itemId: 'article-1',
          operation: SyncOperation.upsert,
          payload: {'id': 'article-1', 'title': 'Before claim'},
        ),
      );

      final claimed = (await outbox.claimPending(accountId: 'user-1')).single;
      expect(claimed.attempts, 1);

      final replacement = SyncOutboxRecord.create(
        accountId: 'user-1',
        collection: SyncCollections.articles,
        itemId: 'article-1',
        operation: SyncOperation.upsert,
        payload: {'id': 'article-1', 'title': 'After claim'},
      );
      await outbox.enqueue(replacement);

      final beforeAck = await outbox.forEntity(
        accountId: 'user-1',
        collection: SyncCollections.articles,
        itemId: 'article-1',
      );
      expect(
        beforeAck.map((record) => record.id),
        containsAll(<String>[claimed.id, replacement.id]),
      );
      expect(replacement.id, isNot(claimed.id));

      await outbox.removeAll([claimed.id]);

      final afterAck = await outbox.forEntity(
        accountId: 'user-1',
        collection: SyncCollections.articles,
        itemId: 'article-1',
      );
      expect(afterAck, hasLength(1));
      expect(afterAck.single.id, replacement.id);
      expect(afterAck.single.payload?['title'], 'After claim');
    },
  );

  test(
    'failed claim update cannot resurrect acked or overwrite conflict',
    () async {
      for (final itemId in const ['acked', 'conflict', 'failed']) {
        await outbox.enqueue(
          SyncOutboxRecord.create(
            accountId: 'user-1',
            collection: SyncCollections.articles,
            itemId: itemId,
            operation: SyncOperation.upsert,
            payload: {'id': itemId},
          ),
        );
      }
      final claimed = await outbox.claimPending(accountId: 'user-1', limit: 3);
      final claimedByItem = {
        for (final record in claimed) record.itemId: record,
      };

      await outbox.removeAll([claimedByItem['acked']!.id]);
      await outbox.markConflict(
        claimedByItem['conflict']!,
        'server-conflict-id',
      );
      await outbox.markFailed(claimed, StateError('later batch failure'));

      expect(
        await outbox.forEntity(
          accountId: 'user-1',
          collection: SyncCollections.articles,
          itemId: 'acked',
        ),
        isEmpty,
      );
      final conflict = (await outbox.forEntity(
        accountId: 'user-1',
        collection: SyncCollections.articles,
        itemId: 'conflict',
      )).single;
      expect(conflict.status, SyncOutboxStatus.conflict);
      expect(conflict.conflictId, 'server-conflict-id');
      final failed = (await outbox.forEntity(
        accountId: 'user-1',
        collection: SyncCollections.articles,
        itemId: 'failed',
      )).single;
      expect(failed.status, SyncOutboxStatus.failed);
    },
  );

  test(
    'settings payload and merge base are sanitized before storage',
    () async {
      await outbox.enqueue(
        SyncOutboxRecord.create(
          accountId: 'user-1',
          collection: SyncCollections.appSettings,
          itemId: 'settings',
          operation: SyncOperation.upsert,
          payload: {
            'schemaVersion': 2,
            'fontSize': 18,
            'aiApiKey': 'sk-local-ai',
            'chatAiApiKey': 'sk-local-chat',
            'imageAiApiKey': 'sk-local-image',
            'embeddingApiKey': 'sk-local-embedding',
            'tavilyApiKey': 'tvly-local',
            'legacyEnvelope': {
              'safe': true,
              'aiApiKey': 'sk-nested-ai',
              'items': [
                {'embeddingApiKey': 'sk-nested-embedding'},
              ],
            },
          },
          basePayload: {
            'fontSize': 14,
            'aiApiKey': 'sk-old',
            'legacyEnvelope': {'tavilyApiKey': 'tvly-nested-old'},
          },
          changedPaths: const [
            r'$.fontSize',
            r'$.aiApiKey',
            r'$.legacyEnvelope.tavilyApiKey',
          ],
        ),
      );

      final pending = (await outbox.pending(accountId: 'user-1')).single;
      expect(pending.payload, containsPair('fontSize', 18));
      for (final key in const [
        'aiApiKey',
        'chatAiApiKey',
        'imageAiApiKey',
        'embeddingApiKey',
        'tavilyApiKey',
      ]) {
        expect(pending.payload?.containsKey(key), isFalse);
      }
      expect(pending.payload?['legacyEnvelope'], {
        'safe': true,
        'items': [<String, dynamic>{}],
      });
      expect(pending.basePayload?.containsKey('aiApiKey'), isFalse);
      expect(pending.changedPaths, [r'$.fontSize']);

      final box = await Hive.openBox<dynamic>('sync_outbox');
      final stored = Map<String, dynamic>.from(box.get(pending.id) as Map);
      expect(stored.toString(), isNot(contains('sk-local')));
      expect(stored.toString(), isNot(contains('sk-old')));
      expect(stored.toString(), isNot(contains('sk-nested')));
      expect(stored.toString(), isNot(contains('tvly-nested')));
    },
  );

  test(
    'attempted legacy settings mutation is sanitized and reissued',
    () async {
      final box = await Hive.openBox<dynamic>('sync_outbox');
      await box.put('legacy-event-id', {
        'id': 'legacy-event-id',
        'accountId': 'user-1',
        'collection': SyncCollections.appSettings,
        'itemId': 'settings',
        'operation': SyncOperation.upsert.name,
        'payload': {'fontSize': 18, 'aiApiKey': 'sk-legacy'},
        'revision': 1,
        'clientUpdatedAt': '2026-08-09T00:00:00.000Z',
        'baseEntityRevision': 1,
        'basePayload': {'fontSize': 14, 'aiApiKey': 'sk-base'},
        'changedPaths': [r'$.fontSize', r'$.aiApiKey'],
        'status': SyncOutboxStatus.failed.name,
        'conflictId': null,
        'attempts': 1,
        'lastError': 'response lost',
      });

      final pending = (await outbox.pending(accountId: 'user-1')).single;
      expect(pending.id, isNot('legacy-event-id'));
      expect(pending.attempts, 0);
      expect(pending.payload?.containsKey('aiApiKey'), isFalse);
      expect(pending.basePayload?.containsKey('aiApiKey'), isFalse);
      expect(box.containsKey('legacy-event-id'), isFalse);
      expect(
        (box.get(pending.id) as Map).toString(),
        isNot(contains('sk-legacy')),
      );
    },
  );

  test(
    'concurrent legacy normalization creates one sanitized replacement',
    () async {
      final box = await Hive.openBox<dynamic>('sync_outbox');
      await box.put('legacy-concurrent-event', {
        'id': 'legacy-concurrent-event',
        'accountId': 'user-1',
        'collection': SyncCollections.appSettings,
        'itemId': 'settings',
        'operation': SyncOperation.upsert.name,
        'payload': {'fontSize': 18, 'aiApiKey': 'sk-legacy-concurrent'},
        'revision': 1,
        'clientUpdatedAt': '2026-08-09T00:00:00.000Z',
        'baseEntityRevision': 1,
        'basePayload': null,
        'changedPaths': [r'$.fontSize', r'$.aiApiKey'],
        'status': SyncOutboxStatus.failed.name,
        'conflictId': null,
        'attempts': 1,
        'lastError': 'response lost',
      });

      await Future.wait<void>([
        () async {
          await outbox.pending(accountId: 'user-1');
        }(),
        () async {
          await outbox.count(accountId: 'user-1');
        }(),
        () async {
          await outbox.forEntity(
            accountId: 'user-1',
            collection: SyncCollections.appSettings,
            itemId: 'settings',
          );
        }(),
      ]);

      final replacements = await outbox.forEntity(
        accountId: 'user-1',
        collection: SyncCollections.appSettings,
        itemId: 'settings',
      );
      expect(replacements, hasLength(1));
      expect(replacements.single.id, isNot('legacy-concurrent-event'));
      expect(replacements.single.attempts, 0);
      expect(replacements.single.payload?.containsKey('aiApiKey'), isFalse);
      expect(box.containsKey('legacy-concurrent-event'), isFalse);
      expect(box.length, 1);
    },
  );
}
