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
      final remote = AppSettings(
        aiBaseUrl: 'https://remote.example',
      ).toSyncJson();
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
