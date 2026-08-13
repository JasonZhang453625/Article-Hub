import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memora/data/services/agent_client_tool_api.dart';
import 'package:memora/data/services/agent_client_tool_store.dart';
import 'package:memora/data/services/auth_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AgentClientToolStore store;
  const binding = AgentToolRunBinding(
    ownerUserId: 'user-1',
    ownerDeviceId: 'device-1',
    runId: 'run-1',
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('memora-agent-api-');
    Hive.init(directory.path);
    store = AgentClientToolStore();
    await store.init();
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('pending and claim strictly parse remaining run result bytes', () async {
    final seenKeys = <String?>[];
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'runId': 'run-1',
            'status': 'waiting_client',
            'calls': [_callJson(status: 'pending', remainingResultBytes: 321)],
          }),
          200,
        );
      }
      seenKeys.add(request.headers['idempotency-key']);
      return http.Response(
        jsonEncode({
          ..._callJson(status: 'claimed', remainingResultBytes: 300),
          'claimToken': _claimToken,
        }),
        200,
      );
    });
    final api = _api();
    await http.runWithClient(() async {
      final pending = await api.pending(binding: binding);
      expect(pending.calls.single.remainingResultBytes, 321);
      final claim = await api.claim(
        binding: binding,
        call: pending.calls.single,
        idempotencyKey: 'persisted-claim-key',
      );
      expect(claim.call.remainingResultBytes, 300);
    }, () => client);
    expect(seenKeys, ['persisted-claim-key']);
  });

  test('claim parser rejects a malformed non-UUID token', () {
    expect(
      () => AgentClientToolClaim.fromJson({
        ..._callJson(status: 'claimed', remainingResultBytes: 65536),
        'claimToken': 'not-a-uuid',
      }),
      throwsFormatException,
    );
  });

  test(
    'call status is exact, token-free, and bound to local identity',
    () async {
      final receipt = await store.beginClaimIntent(
        binding: binding,
        callId: 'call-1',
        tool: 'local_search',
        arguments: const {'query': 'private derived query'},
      );
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'callId': 'call-1',
            'tool': 'local_search',
            'status': 'completed',
            'leaseEpoch': '7',
            'leaseExpiresAt': null,
            'completedAt': '2026-08-12T00:02:00.000Z',
            'remainingResultBytes': 64000,
            'createdAt': '2026-08-12T00:00:00.000Z',
          }),
          200,
        ),
      );

      final status = await http.runWithClient(
        () => _api().callStatus(binding: binding, receipt: receipt),
        () => client,
      );

      expect(status.status, 'completed');
      expect(status.leaseEpoch, '7');
      expect(status.completedAt, DateTime.utc(2026, 8, 12, 0, 2));
    },
  );

  test(
    'call status rejects extra secret fields and identity changes',
    () async {
      final receipt = await store.beginClaimIntent(
        binding: binding,
        callId: 'call-1',
        tool: 'local_search',
        arguments: const {'query': 'private derived query'},
      );
      for (final body in [
        {
          'callId': 'call-1',
          'tool': 'local_search',
          'status': 'claimed',
          'leaseEpoch': '7',
          'leaseExpiresAt': '2026-08-12T00:01:00.000Z',
          'completedAt': null,
          'remainingResultBytes': 64000,
          'createdAt': '2026-08-12T00:00:00.000Z',
          'claimToken': 'must-not-be-exposed',
        },
        {
          'callId': 'other-call',
          'tool': 'local_search',
          'status': 'completed',
          'leaseEpoch': '7',
          'leaseExpiresAt': null,
          'completedAt': '2026-08-12T00:02:00.000Z',
          'remainingResultBytes': 64000,
          'createdAt': '2026-08-12T00:00:00.000Z',
        },
      ]) {
        final client = MockClient(
          (_) async => http.Response(jsonEncode(body), 200),
        );
        await expectLater(
          http.runWithClient(
            () => _api().callStatus(binding: binding, receipt: receipt),
            () => client,
          ),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'lost claim and result responses replay durable keys and payload',
    () async {
      var claimAttempts = 0;
      var resultAttempts = 0;
      final claimKeys = <String?>[];
      final resultKeys = <String?>[];
      final resultBodies = <String>[];
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/claim')) {
          claimAttempts++;
          claimKeys.add(request.headers['idempotency-key']);
          if (claimAttempts == 1) {
            throw http.ClientException('claim response lost');
          }
          return http.Response(
            jsonEncode({
              ..._callJson(status: 'claimed', remainingResultBytes: 65536),
              'claimToken': _claimToken,
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/result')) {
          resultAttempts++;
          resultKeys.add(request.headers['idempotency-key']);
          resultBodies.add(request.body);
          if (resultAttempts == 1) {
            throw http.ClientException('result ACK lost');
          }
          return http.Response(
            jsonEncode({
              'accepted': true,
              'idempotent': true,
              'run': {'id': 'run-1', 'status': 'running'},
            }),
            200,
          );
        }
        throw StateError('unexpected route');
      });
      final api = _api();
      var receipt = await store.beginClaimIntent(
        binding: binding,
        callId: 'call-1',
        tool: 'local_search',
        arguments: const {'query': 'private derived query'},
      );
      final call = AgentClientToolCall.fromJson(
        _callJson(status: 'pending', remainingResultBytes: 65536),
      );

      await http.runWithClient(() async {
        await expectLater(
          api.claim(
            binding: binding,
            call: call,
            idempotencyKey: receipt.claimRequestKey,
          ),
          throwsA(isA<AgentClientToolApiException>()),
        );
        final replayed = await store.beginClaimIntent(
          binding: binding,
          callId: 'call-1',
          tool: 'local_search',
          arguments: const {'query': 'private derived query'},
        );
        final claim = await api.claim(
          binding: binding,
          call: call,
          idempotencyKey: replayed.claimRequestKey,
        );
        receipt = await store.recordClaim(
          receipt: replayed,
          claimToken: claim.claimToken,
          leaseEpoch: claim.call.leaseEpoch,
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
        receipt = await store.markSubmitting(receipt);
        await expectLater(
          api.submitResult(binding: binding, receipt: receipt),
          throwsA(isA<AgentClientToolApiException>()),
        );
        await api.submitResult(binding: binding, receipt: receipt);
      }, () => client);

      expect(claimKeys, [receipt.claimRequestKey, receipt.claimRequestKey]);
      expect(resultKeys, [receipt.resultReceiptKey, receipt.resultReceiptKey]);
      expect(resultBodies.toSet(), hasLength(1));
    },
  );

  test('result replay rejects a locally corrupted extra field before PUT', () {
    expect(
      () => validateAgentClientToolResult(
        tool: 'local_search',
        argumentsJson: '{"query":"x"}',
        result: const {
          'schemaVersion': 1,
          'status': 'empty',
          'results': <Object>[],
          'truncated': false,
          'notes': 'must not leave device',
        },
      ),
      throwsFormatException,
    );
  });

  test('local-search result rejects duplicate article_ref values', () {
    const duplicateRef = 'ar_abcdefghijklmnopqrstuv';
    expect(
      () => validateAgentClientToolResult(
        tool: 'local_search',
        argumentsJson: '{"query":"x"}',
        result: const {
          'schemaVersion': 1,
          'status': 'ok',
          'results': [
            {
              'article_ref': duplicateRef,
              'title': 'First',
              'snippets': [
                {'kind': 'summary', 'text': 'First evidence'},
              ],
            },
            {
              'article_ref': duplicateRef,
              'title': 'Duplicate',
              'snippets': [
                {'kind': 'summary', 'text': 'Duplicate evidence'},
              ],
            },
          ],
          'truncated': false,
        },
      ),
      throwsFormatException,
    );
  });

  test('result ACK is bound to the requested run', () async {
    final receipt = await _readyReceipt(store);
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'accepted': true,
          'idempotent': false,
          'run': {'id': 'run-other', 'status': 'running'},
        }),
        200,
      ),
    );

    await expectLater(
      http.runWithClient(
        () => _api().submitResult(binding: binding, receipt: receipt),
        () => client,
      ),
      throwsFormatException,
    );
  });

  test(
    '401 refresh replays result with the same key and owner identity',
    () async {
      var active = _session();
      final fresh = active.copyWith(accessToken: _jwt('fresh'));
      var requests = 0;
      var refreshes = 0;
      final keys = <String?>[];
      final client = MockClient((request) async {
        requests++;
        keys.add(request.headers['idempotency-key']);
        if (requests == 1) {
          return http.Response('{"code":"UNAUTHORIZED"}', 401);
        }
        expect(request.headers['authorization'], 'Bearer ${fresh.accessToken}');
        return http.Response(
          jsonEncode({
            'accepted': true,
            'idempotent': false,
            'run': {'id': 'run-1', 'status': 'running'},
          }),
          200,
        );
      });
      final api = AgentClientToolApi(
        getSession: () => active,
        refreshSession: () async {
          refreshes++;
          active = fresh;
          return fresh;
        },
      );
      final receipt = await _readyReceipt(store);
      await http.runWithClient(
        () => api.submitResult(binding: binding, receipt: receipt),
        () => client,
      );
      expect(refreshes, 1);
      expect(requests, 2);
      expect(keys, [receipt.resultReceiptKey, receipt.resultReceiptKey]);
    },
  );

  test('401 refresh to another device fails before replay', () async {
    var active = _session();
    final moved = active.copyWith(
      accessToken: _jwt('moved'),
      device: const AuthDevice(
        id: 'device-2',
        userId: 'user-1',
        deviceName: 'other',
        platform: 'test',
        appVersion: '1.0.0',
      ),
    );
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response('{"code":"UNAUTHORIZED"}', 401);
    });
    final api = AgentClientToolApi(
      getSession: () => active,
      refreshSession: () async {
        active = moved;
        return moved;
      },
    );
    final receipt = await _readyReceipt(store);
    await expectLater(
      http.runWithClient(
        () => api.submitResult(binding: binding, receipt: receipt),
        () => client,
      ),
      throwsA(
        isA<AgentClientToolApiException>()
            .having((error) => error.statusCode, 'statusCode', 401)
            .having((error) => error.retryable, 'retryable', isFalse),
      ),
    );
    expect(requests, 1);
  });

  test(
    'concurrent 401 responses share one refresh and preserve request identity',
    () async {
      var active = _session();
      final fresh = active.copyWith(accessToken: _jwt('single-flight'));
      var refreshes = 0;
      var oldRequests = 0;
      var freshRequests = 0;
      final oldToken = active.accessToken;
      final client = MockClient((request) async {
        if (request.headers['authorization'] == 'Bearer $oldToken') {
          oldRequests++;
          return http.Response(
            jsonEncode({
              'error': {'code': 'invalid_authorization', 'retryable': false},
            }),
            401,
          );
        }
        expect(request.headers['authorization'], 'Bearer ${fresh.accessToken}');
        freshRequests++;
        return http.Response(
          jsonEncode({
            'runId': 'run-1',
            'status': 'waiting_client',
            'calls': <Object>[],
          }),
          200,
        );
      });
      final api = AgentClientToolApi(
        getSession: () => active,
        refreshSession: () async {
          refreshes++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          active = fresh;
          return fresh;
        },
      );

      await http.runWithClient(() async {
        await Future.wait([
          api.pending(binding: binding),
          api.pending(binding: binding),
        ]);
      }, () => client);

      expect(oldToken, isNot(fresh.accessToken));
      expect(oldRequests, 2);
      expect(freshRequests, 2);
      expect(refreshes, 1);
    },
  );

  test('parses nested backend lease and fence codes exactly', () async {
    final receipt = await _readyReceipt(store);
    for (final testCase in const [
      (code: 'client_tool_lease_expired', retryable: true),
      (code: 'client_tool_fenced', retryable: false),
    ]) {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {
              'code': testCase.code,
              'message': 'fenced',
              'retryable': testCase.retryable,
              'requestId': 'request-1',
            },
          }),
          409,
        ),
      );
      final error = await http.runWithClient(() async {
        try {
          await _api().submitResult(binding: binding, receipt: receipt);
          fail('expected a result conflict');
        } on AgentClientToolApiException catch (caught) {
          return caught;
        }
      }, () => client);
      expect(error.code, testCase.code);
      expect(error.conflict, isTrue);
      expect(error.retryable, testCase.retryable);
    }
  });
}

Future<AgentClientToolReceipt> _readyReceipt(AgentClientToolStore store) async {
  var receipt = await store.beginClaimIntent(
    binding: const AgentToolRunBinding(
      ownerUserId: 'user-1',
      ownerDeviceId: 'device-1',
      runId: 'run-1',
    ),
    callId: 'call-ready',
    tool: 'local_search',
    arguments: const {'query': 'private query'},
  );
  receipt = await store.recordClaim(
    receipt: receipt,
    claimToken: _claimToken,
    leaseEpoch: '1',
  );
  return store.recordResultReady(
    receipt: receipt,
    result: const {
      'schemaVersion': 1,
      'status': 'empty',
      'results': <Object>[],
      'truncated': false,
    },
  );
}

Map<String, dynamic> _callJson({
  required String status,
  required int remainingResultBytes,
}) => {
  'callId': 'call-1',
  'tool': 'local_search',
  'arguments': {'query': 'private derived query'},
  'status': status,
  'leaseEpoch': status == 'claimed' ? '1' : '0',
  'remainingResultBytes': remainingResultBytes,
  'leaseExpiresAt': status == 'claimed'
      ? DateTime.utc(2026, 8, 12, 1).toIso8601String()
      : null,
  'createdAt': DateTime.utc(2026, 8, 12).toIso8601String(),
};

AgentClientToolApi _api() {
  final session = _session();
  return AgentClientToolApi(
    getSession: () => session,
    refreshSession: () async => session,
  );
}

AuthSession _session() => AuthSession(
  accessToken: _jwt(),
  refreshToken: 'refresh-token',
  refreshTokenExpiresAt: null,
  user: const AuthUser(
    id: 'user-1',
    email: 'user@example.com',
    displayName: null,
    status: 'active',
    plan: 'free',
    storageUsedBytes: '0',
  ),
  device: const AuthDevice(
    id: 'device-1',
    userId: 'user-1',
    deviceName: 'test',
    platform: 'test',
    appVersion: '1.0.0',
  ),
);

String _jwt([String marker = 'active']) {
  final payload = base64Url.encode(
    utf8.encode(
      jsonEncode({
        'sessionId': '11111111-1111-4111-8111-111111111111',
        'deviceId': '22222222-2222-4222-8222-222222222222',
        'marker': marker,
      }),
    ),
  );
  return 'header.${payload.replaceAll('=', '')}.signature';
}

const _claimToken = '11111111-1111-4111-8111-111111111111';
