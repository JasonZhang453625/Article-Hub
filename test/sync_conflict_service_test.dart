import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:memora/data/models/settings.dart';
import 'package:memora/data/services/sync_apply_service.dart';
import 'package:memora/data/services/sync_conflict_resolver.dart';
import 'package:memora/data/services/sync_conflict_service.dart';
import 'package:memora/data/services/sync_mutation_service.dart';
import 'package:memora/data/services/sync_outbox_service.dart';
import 'package:memora/data/services/sync_protocol.dart';
import 'package:memora/data/services/sync_shadow_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('memora_sync_conflict_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test(
    'three-way merge keeps independent edits and reports same-field edits',
    () {
      final independent = threeWayMerge(
        base: {
          'title': 'base',
          'meta': {'left': 1, 'right': 1},
        },
        local: {
          'title': 'local',
          'meta': {'left': 1, 'right': 1},
        },
        remote: {
          'title': 'base',
          'meta': {'left': 2, 'right': 1},
        },
      );

      expect(independent.hasConflicts, isFalse);
      expect(independent.merged['title'], 'local');
      expect((independent.merged['meta'] as Map)['left'], 2);

      final conflict = threeWayMerge(
        base: {'title': 'base'},
        local: {'title': 'local'},
        remote: {'title': 'remote'},
      );
      expect(conflict.conflictPaths, contains(r'$.title'));
      expect(conflict.merged['title'], 'local');
    },
  );

  test(
    'legacy settings shadow and conflict records are scrubbed on read',
    () async {
      final shadowBox = await Hive.openBox<dynamic>('sync_shadow');
      const shadowKey = 'user-1::app_settings::settings';
      await shadowBox.put(shadowKey, {
        'accountId': 'user-1',
        'collection': SyncCollections.appSettings,
        'itemId': 'settings',
        'entityRevision': 2,
        'serverSeq': 3,
        'payload': {'fontSize': 16, 'aiApiKey': 'sk-shadow'},
        'deleted': false,
        'deviceId': 'remote-device',
      });

      final shadow = await SyncShadowService().get(
        accountId: 'user-1',
        collection: SyncCollections.appSettings,
        itemId: 'settings',
      );
      expect(shadow?.payload?.containsKey('aiApiKey'), isFalse);
      expect(shadowBox.get(shadowKey).toString(), isNot(contains('sk-shadow')));

      final conflictBox = await Hive.openBox<dynamic>('sync_conflicts');
      await conflictBox.put('legacy-conflict', {
        'id': 'legacy-conflict',
        'accountId': 'user-1',
        'collection': SyncCollections.appSettings,
        'itemId': 'settings',
        'localMutationId': 'mutation-1',
        'baseEntityRevision': 1,
        'remoteEntityRevision': 2,
        'remoteServerSeq': 3,
        'basePayload': {'fontSize': 14, 'aiApiKey': 'sk-base'},
        'localPayload': {'fontSize': 18, 'chatAiApiKey': 'sk-local'},
        'remotePayload': {'fontSize': 20, 'tavilyApiKey': 'tvly-remote'},
        'localDeleted': false,
        'remoteDeleted': false,
        'conflictPaths': [r'$.fontSize', r'$.aiApiKey'],
        'createdAt': '2026-08-09T00:00:00.000Z',
        'status': SyncConflictStatus.pending.name,
      });

      final conflict = (await SyncConflictService().pending()).single;
      expect(conflict.basePayload?.containsKey('aiApiKey'), isFalse);
      expect(conflict.localPayload?.containsKey('chatAiApiKey'), isFalse);
      expect(conflict.remotePayload?.containsKey('tavilyApiKey'), isFalse);
      expect(conflict.conflictPaths, [r'$.fontSize']);
      expect(
        conflictBox.get('legacy-conflict').toString(),
        isNot(
          anyOf(
            contains('sk-base'),
            contains('sk-local'),
            contains('tvly-remote'),
          ),
        ),
      );
    },
  );

  test(
    'incoming newer event is stored as a conflict and can keep local',
    () async {
      final outbox = SyncOutboxService();
      final shadow = SyncShadowService();
      final conflicts = SyncConflictService();
      final applier = SyncApplyService(
        outbox: outbox,
        shadow: shadow,
        conflicts: conflicts,
      );
      await applier.applyEvents(const []);
      final base = AppSettings(fontSize: 14.0).toSyncJson();
      final local = AppSettings(fontSize: 18.0).toSyncJson();
      final remote = AppSettings(fontSize: 20.0).toSyncJson();
      final accountId = 'user-1';

      final settings = await Hive.openBox<AppSettings>('app_settings');
      await settings.put('settings', AppSettings(fontSize: 18.0));
      await outbox.enqueue(
        SyncOutboxRecord.create(
          accountId: accountId,
          collection: SyncCollections.appSettings,
          itemId: 'settings',
          operation: SyncOperation.upsert,
          payload: local,
          baseEntityRevision: 1,
          basePayload: base,
        ),
      );

      final result = await applier.applyEvents([
        {
          'serverSeq': 2,
          'entityRevision': 2,
          'deviceId': 'remote-device',
          'collection': SyncCollections.appSettings,
          'itemId': 'settings',
          'op': SyncOperation.upsert.name,
          'payload': SyncProtocol.wrapPayload(
            accountId: accountId,
            collection: SyncCollections.appSettings,
            itemId: 'settings',
            data: remote,
          ),
        },
      ], accountId: accountId);

      expect(result.conflicts, 1);
      expect((await conflicts.pending(accountId: accountId)), hasLength(1));
      expect(settings.get('settings')?.fontSize, 18);

      final resolver = SyncConflictResolver(
        applier: applier,
        conflicts: conflicts,
        mutations: SyncMutationService(outbox: outbox, shadow: shadow),
        outbox: outbox,
      );
      await resolver.keepLocal(
        (await conflicts.pending(accountId: accountId)).single,
      );

      expect(await conflicts.pending(accountId: accountId), isEmpty);
      expect(settings.get('settings')?.fontSize, 18);
      final pending = await outbox.pending(accountId: accountId);
      expect(pending, hasLength(1));
      expect(pending.single.baseEntityRevision, 2);
    },
  );
}
