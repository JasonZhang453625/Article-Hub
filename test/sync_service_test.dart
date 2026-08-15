import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memora/data/models/settings.dart';
import 'package:memora/data/services/auth_service.dart';
import 'package:memora/data/services/sync_apply_service.dart';
import 'package:memora/data/services/sync_outbox_service.dart';
import 'package:memora/data/services/sync_protocol.dart';
import 'package:memora/data/services/sync_service.dart';
import 'package:memora/data/services/sync_state_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late SyncOutboxService outbox;
  late SyncStateService state;
  late SyncApplyService applier;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'memora_sync_service_test_',
    );
    Hive.init(tempDir.path);
    if (!Hive.isAdapterRegistered(AppSettings.typeId)) {
      Hive.registerAdapter(AppSettingsAdapter());
    }
    outbox = SyncOutboxService();
    state = SyncStateService();
    applier = SyncApplyService(outbox: outbox);
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('one sync job drains all batches and sends plaintext JSON', () async {
    for (var i = 0; i < 125; i++) {
      await outbox.enqueue(
        SyncOutboxRecord.create(
          accountId: 'user-1',
          collection: SyncCollections.articles,
          itemId: 'article-$i',
          operation: SyncOperation.upsert,
          payload: {
            'schemaVersion': 2,
            'id': 'article-$i',
            'apiKeyProbe': i == 0 ? 'sk-synced-in-json' : '',
          },
        ),
      );
    }

    final batchSizes = <int>[];
    final client = MockClient((request) async {
      expect(
        request.headers['x-memora-sync-protocol'],
        SyncProtocol.protocolVersion.toString(),
      );
      expect(request.headers.containsKey('x-memora-key-fingerprint'), isFalse);
      if (request.url.path == '/sync/push') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final events = body['events'] as List<dynamic>;
        batchSizes.add(events.length);
        expect(body['protocolVersion'], SyncProtocol.protocolVersion);
        final first = events.first as Map<String, dynamic>;
        expect(first['protocolVersion'], SyncProtocol.protocolVersion);
        expect(first['payloadFormat'], SyncProtocol.payloadFormat);
        expect(first['payload'], isA<Map<String, dynamic>>());
        expect(first.containsKey('ciphertext'), isFalse);
        expect(first.containsKey('nonce'), isFalse);
        if (batchSizes.length == 1) {
          expect(request.body, contains('sk-synced-in-json'));
        }
        return http.Response(
          jsonEncode({'accepted': events.length}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/sync/pull') {
        return http.Response(
          jsonEncode({'events': <Object>[], 'nextCursor': 0}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('not found', 404);
    });
    final service = SyncService(
      outbox: outbox,
      state: state,
      applier: applier,
      client: client,
    );

    final result = await service.sync(_session());

    expect(result.pushed, 125);
    expect(batchSizes, [50, 50, 25]);
    expect(await outbox.count(accountId: 'user-1'), 0);
    expect(await state.cursor('user-1'), 0);
  });

  test(
    'legacy settings outbox is sanitized on the wire and in shadow',
    () async {
      final box = await Hive.openBox<dynamic>('sync_outbox');
      await box.put('legacy-settings-event', {
        'id': 'legacy-settings-event',
        'accountId': 'user-1',
        'collection': SyncCollections.appSettings,
        'itemId': 'settings',
        'operation': SyncOperation.upsert.name,
        'payload': {
          'schemaVersion': 1,
          'fontSize': 18,
          'aiApiKey': 'sk-ai',
          'chatAiApiKey': 'sk-chat',
          'imageAiApiKey': 'sk-image',
          'embeddingApiKey': 'sk-embedding',
          'tavilyApiKey': 'tvly-secret',
        },
        'revision': 1,
        'clientUpdatedAt': '2026-08-09T00:00:00.000Z',
        'baseEntityRevision': 0,
        'basePayload': null,
        'changedPaths': [r'$'],
        'status': SyncOutboxStatus.pending.name,
        'conflictId': null,
        'attempts': 0,
        'lastError': null,
      });

      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final event = (body['events'] as List).single as Map<String, dynamic>;
        final envelope = event['payload'] as Map<String, dynamic>;
        final data = envelope['data'] as Map<String, dynamic>;
        expect(data['fontSize'], 18);
        for (final key in const [
          'aiApiKey',
          'chatAiApiKey',
          'imageAiApiKey',
          'embeddingApiKey',
          'tavilyApiKey',
        ]) {
          expect(data.containsKey(key), isFalse);
        }
        return http.Response(
          jsonEncode({'accepted': 1}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = SyncService(
        outbox: outbox,
        state: state,
        applier: applier,
        client: client,
      );

      final result = await service.pushPending(_session());
      expect(result.pushed, 1);
      final shadowBox = await Hive.openBox<dynamic>('sync_shadow');
      final stored = shadowBox.get('user-1::app_settings::settings') as Map;
      expect(stored.toString(), isNot(contains('sk-ai')));
      expect(stored.toString(), isNot(contains('tvly-secret')));
    },
  );

  test(
    'legacy remote settings secret forces a clean rebased scrub event',
    () async {
      await outbox.enqueue(
        SyncOutboxRecord.create(
          accountId: 'user-1',
          collection: SyncCollections.appSettings,
          itemId: 'settings',
          operation: SyncOperation.upsert,
          payload: const {'schemaVersion': 2, 'fontSize': 18},
          baseEntityRevision: 1,
          basePayload: const {'schemaVersion': 2, 'fontSize': 18},
          changedPaths: const [r'$.fontSize'],
        ),
      );

      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final event = (body['events'] as List).single as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'results': [
              {
                'clientEventId': event['clientEventId'],
                'status': 'conflict',
                'entityRevision': 2,
                'serverSeq': 9,
                'current': {
                  'deviceId': 'legacy-device',
                  'collection': SyncCollections.appSettings,
                  'itemId': 'settings',
                  'op': SyncOperation.upsert.name,
                  'entityRevision': 2,
                  'serverSeq': 9,
                  'payload': SyncProtocol.wrapPayload(
                    accountId: 'user-1',
                    collection: SyncCollections.appSettings,
                    itemId: 'settings',
                    data: const {
                      'schemaVersion': 2,
                      'fontSize': 18,
                      'aiApiKey': 'sk-legacy-remote',
                    },
                  ),
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = SyncService(
        outbox: outbox,
        state: state,
        applier: applier,
        client: client,
      );

      final result = await service.pushPending(_session());

      expect(result.processed, 1);
      expect(result.conflicts, 0);
      final scrub = (await outbox.pending(accountId: 'user-1')).single;
      expect(scrub.baseEntityRevision, 2);
      expect(scrub.changedPaths, [r'$']);
      expect(scrub.payload?['fontSize'], 18);
      expect(scrub.payload?.containsKey('aiApiKey'), isFalse);
      final box = await Hive.openBox<dynamic>('sync_outbox');
      expect(box.get(scrub.id).toString(), isNot(contains('sk-legacy-remote')));
    },
  );

  test(
    'late batch failure preserves earlier ack and conflict transitions',
    () async {
      for (final entry in const [
        ('event-acked', 'article-acked', '2026-08-09T00:00:00.001Z'),
        ('event-conflict', 'article-conflict', '2026-08-09T00:00:00.002Z'),
        ('event-failed', 'article-failed', '2026-08-09T00:00:00.003Z'),
      ]) {
        await outbox.enqueue(
          SyncOutboxRecord(
            id: entry.$1,
            accountId: 'user-1',
            collection: SyncCollections.articles,
            itemId: entry.$2,
            operation: SyncOperation.upsert,
            payload: {'id': entry.$2},
            revision: 1,
            clientUpdatedAt: entry.$3,
          ),
        );
      }

      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final events = (body['events'] as List).cast<Map<String, dynamic>>();
        String idFor(String itemId) =>
            events.singleWhere(
                  (event) => event['itemId'] == itemId,
                )['clientEventId']
                as String;

        return http.Response(
          jsonEncode({
            'accepted': 1,
            'conflicts': 1,
            'results': [
              {
                'clientEventId': idFor('article-acked'),
                'status': 'applied',
                'entityRevision': 2,
                'serverSeq': 1,
              },
              {
                'clientEventId': idFor('article-conflict'),
                'status': 'conflict',
                'entityRevision': 2,
                'serverSeq': 2,
                'current': {
                  'deviceId': 'remote-device',
                  'collection': SyncCollections.articles,
                  'itemId': 'article-conflict',
                  'op': SyncOperation.delete.name,
                  'payload': null,
                  'entityRevision': 2,
                  'serverSeq': 2,
                },
              },
              {
                'clientEventId': idFor('article-failed'),
                'status': 'unexpected',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = SyncService(
        outbox: outbox,
        state: state,
        applier: applier,
        client: client,
      );

      await expectLater(
        service.pushPending(_session()),
        throwsA(isA<SyncApiException>()),
      );

      expect(
        await outbox.forEntity(
          accountId: 'user-1',
          collection: SyncCollections.articles,
          itemId: 'article-acked',
        ),
        isEmpty,
      );
      final conflict = (await outbox.forEntity(
        accountId: 'user-1',
        collection: SyncCollections.articles,
        itemId: 'article-conflict',
      )).single;
      expect(conflict.status, SyncOutboxStatus.conflict);
      expect(conflict.conflictId, isNotNull);
      final failed = (await outbox.forEntity(
        accountId: 'user-1',
        collection: SyncCollections.articles,
        itemId: 'article-failed',
      )).single;
      expect(failed.status, SyncOutboxStatus.failed);
    },
  );

  test('pullAll reads pages until the server returns a short page', () async {
    var pullCalls = 0;
    final client = MockClient((request) async {
      final since = int.parse(request.url.queryParameters['since']!);
      pullCalls++;
      final events = since == 0
          ? [_selfDeleteEvent(1), _selfDeleteEvent(2)]
          : [_selfDeleteEvent(3)];
      return http.Response(
        jsonEncode({'events': events, 'nextCursor': since == 0 ? 2 : 3}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final service = SyncService(
      outbox: outbox,
      state: state,
      applier: applier,
      client: client,
    );

    final result = await service.pullAll(_session(), pageSize: 2);

    expect(result.pulled, 3);
    expect(result.applied, 0);
    expect(result.cursor, 3);
    expect(pullCalls, 2);
  });

  test(
    'auto-merged push is rebased and drained in the same sync job',
    () async {
      final accountId = _session().user.id;
      final base = AppSettings(fontSize: 14.0).toSyncJson();
      final local = AppSettings(fontSize: 18.0).toSyncJson();
      final remote = {
        'schemaVersion': 1,
        ...AppSettings(
          aiBaseUrl: 'https://remote.example',
          aiApiKey: 'sk-remote-ai',
          chatAiApiKey: 'sk-remote-chat',
          imageAiApiKey: 'sk-remote-image',
          embeddingApiKey: 'sk-remote-embedding',
          tavilyApiKey: 'tvly-remote',
        ).toBackupJson(),
      };
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

      var pushCalls = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/sync/push') {
          pushCalls++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final event = (body['events'] as List).single as Map<String, dynamic>;
          if (pushCalls == 1) {
            return http.Response(
              jsonEncode({
                'accepted': 0,
                'conflicts': 1,
                'latestCursor': '1',
                'results': [
                  {
                    'clientEventId': event['clientEventId'],
                    'status': 'conflict',
                    'entityRevision': '2',
                    'serverSeq': '1',
                    'current': {
                      'serverSeq': '1',
                      'entityRevision': '2',
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
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          expect(event['baseEntityRevision'], 2);
          expect(request.body, isNot(contains('sk-remote')));
          expect(request.body, isNot(contains('tvly-remote')));
          return http.Response(
            jsonEncode({
              'accepted': 1,
              'conflicts': 0,
              'latestCursor': '2',
              'results': [
                {
                  'clientEventId': event['clientEventId'],
                  'status': 'applied',
                  'entityRevision': '3',
                  'serverSeq': '2',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path == '/sync/pull') {
          return http.Response(
            jsonEncode({'events': <Object>[], 'nextCursor': 2}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      });

      final service = SyncService(
        outbox: outbox,
        state: state,
        applier: applier,
        client: client,
      );
      final result = await service.sync(_session());

      expect(result.pushed, 1);
      expect(pushCalls, 2);
      expect(await outbox.pending(accountId: accountId), isEmpty);
      final shadowBox = await Hive.openBox<dynamic>('sync_shadow');
      expect(
        shadowBox.get('$accountId::app_settings::settings').toString(),
        isNot(contains('sk-remote')),
      );
    },
  );
}

AuthSession _session() {
  return const AuthSession(
    accessToken: 'test-access-token',
    refreshToken: 'test-refresh-token',
    refreshTokenExpiresAt: null,
    user: AuthUser(
      id: 'user-1',
      email: 'user@example.com',
      displayName: null,
      status: 'active',
      plan: 'free',
      storageUsedBytes: '0',
    ),
    device: AuthDevice(
      id: 'device-1',
      userId: 'user-1',
      deviceName: 'Test device',
      platform: 'test',
      appVersion: '1.0.0',
    ),
  );
}

Map<String, dynamic> _selfDeleteEvent(int cursor) {
  return {
    'serverSeq': cursor,
    'deviceId': 'device-1',
    'collection': SyncCollections.articles,
    'itemId': 'article-$cursor',
    'op': SyncOperation.delete.name,
    'revision': cursor,
  };
}
