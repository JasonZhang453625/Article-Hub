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
}
