import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memora/data/services/auth_service.dart';
import 'package:memora/data/services/hosted_task_run_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'creates a v4 task with a mandatory key and polls a typed result',
    () async {
      final requests = <http.Request>[];
      var tokens = 0;
      final client = MockClient((request) async {
        requests.add(request);
        if (request.method == 'POST') {
          expect(request.url.path, '/ai/tasks/runs');
          expect(_header(request, 'idempotency-key'), 'stable-key');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body, {
            'task': 'summary.final',
            'task_version': 1,
            'model': 'mimo-v2.5-pro',
            'input': {
              'chunks': ['bounded chunk'],
              'language': 'follow-source',
            },
          });
          expect(body.containsKey('system'), isFalse);
          expect(body.containsKey('tools'), isFalse);
          expect(body.containsKey('schema'), isFalse);
          return http.Response(jsonEncode(_snapshot(status: 'queued')), 202);
        }
        expect(request.url.path, '/ai/runs/run-1');
        return http.Response(
          jsonEncode(
            _snapshot(
              status: 'completed',
              result: {
                'schemaVersion': 1,
                'title': 'Generated',
                'overview': 'Overview',
                'keyPoints': [
                  {'topic': 'Pi', 'content': 'Runs the task.'},
                ],
                'conclusion': 'Done',
              },
              usage: {'totalTokens': 17},
            ),
          ),
          200,
        );
      });
      final service = HostedTaskRunService(
        getSession: () => _session(),
        refreshSession: () async => null,
        model: 'mimo-v2.5-pro',
        pollInterval: Duration.zero,
        onTokensUsed: (value) => tokens += value,
      );

      final result = await http.runWithClient(
        () => service.run(
          profile: HostedTaskProfile.summaryFinal,
          idempotencyKey: 'stable-key',
          input: {
            'chunks': ['bounded chunk'],
            'language': 'follow-source',
          },
        ),
        () => client,
      );

      expect(result.runId, 'run-1');
      expect(result.profile, HostedTaskProfile.summaryFinal);
      expect(result.result['overview'], 'Overview');
      expect(tokens, 17);
      expect(requests, hasLength(2));
    },
  );

  test('reconciles an ambiguous create without replaying POST', () async {
    var postCalls = 0;
    var lookupCalls = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        postCalls++;
        throw http.ClientException('connection closed after upload');
      }
      if (request.url.path == '/ai/runs') {
        lookupCalls++;
        expect(_header(request, 'idempotency-key'), 'ambiguous-key');
        return http.Response(
          jsonEncode({'id': 'run-1', 'status': 'completed'}),
          200,
        );
      }
      expect(request.url.path, '/ai/runs/run-1');
      return http.Response(
        jsonEncode(
          _snapshot(
            status: 'completed',
            task: 'retrieval.rewrite',
            result: {'schemaVersion': 1, 'query': 'standalone query'},
          ),
        ),
        200,
      );
    });
    final service = HostedTaskRunService(
      getSession: () => _session(),
      refreshSession: () async => null,
      model: 'mimo-v2.5',
      pollInterval: Duration.zero,
    );

    final result = await http.runWithClient(
      () => service.run(
        profile: HostedTaskProfile.retrievalRewrite,
        idempotencyKey: 'ambiguous-key',
        input: {'question': 'it?', 'language': 'follow-question'},
      ),
      () => client,
    );

    expect(result.result['query'], 'standalone query');
    expect(postCalls, 1);
    expect(lookupCalls, 1);
  });

  test('replays an absent ambiguous create with the same key', () async {
    var postCalls = 0;
    var lookupCalls = 0;
    final postedKeys = <String?>[];
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        postCalls++;
        postedKeys.add(_header(request, 'idempotency-key'));
        if (postCalls == 1) {
          throw http.ClientException('connection closed after upload');
        }
        return http.Response(
          jsonEncode(
            _snapshot(
              status: 'completed',
              task: 'retrieval.rewrite',
              result: {'schemaVersion': 1, 'query': 'safe replay'},
            ),
          ),
          202,
        );
      }
      expect(request.url.path, '/ai/runs');
      lookupCalls++;
      return http.Response(
        jsonEncode({
          'error': {'code': 'ai_run_not_found', 'message': 'not found'},
        }),
        404,
      );
    });
    final service = HostedTaskRunService(
      getSession: () => _session(),
      refreshSession: () async => null,
      model: 'mimo-v2.5',
      pollInterval: Duration.zero,
    );

    final result = await http.runWithClient(
      () => service.run(
        profile: HostedTaskProfile.retrievalRewrite,
        idempotencyKey: 'same-key',
        input: {'question': 'it?', 'language': 'follow-question'},
      ),
      () => client,
    );

    expect(result.result['query'], 'safe replay');
    expect(postCalls, 2);
    expect(lookupCalls, 3);
    expect(postedKeys, ['same-key', 'same-key']);
  });

  test('rejects a missing idempotency key before network I/O', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response('{}', 500);
    });
    final service = HostedTaskRunService(
      getSession: () => _session(),
      refreshSession: () async => null,
      model: 'mimo-v2.5',
    );

    await http.runWithClient(
      () => expectLater(
        service.run(
          profile: HostedTaskProfile.retrievalRewrite,
          idempotencyKey: '   ',
          input: {'question': 'Q', 'language': 'follow-question'},
        ),
        throwsA(
          isA<HostedTaskRunException>().having(
            (error) => error.code,
            'code',
            'invalid_idempotency_key',
          ),
        ),
      ),
      () => client,
    );

    expect(calls, 0);
  });

  test(
    'stable operation key is restart-safe and contains no source text',
    () async {
      final first = await buildHostedTaskOperationKey(
        articleId: 'article-1',
        stage: 'summary',
        generation: 'retry:0|anchor:initial',
        model: 'mimo-v2.5-pro',
        language: 'en',
        content: 'private article body',
      );
      final replay = await buildHostedTaskOperationKey(
        articleId: 'article-1',
        stage: 'summary',
        generation: 'retry:0|anchor:initial',
        model: 'mimo-v2.5-pro',
        language: 'en',
        content: 'private article body',
      );
      final retry = await buildHostedTaskOperationKey(
        articleId: 'article-1',
        stage: 'summary',
        generation: 'retry:1|anchor:2026-08-21T00:00:00.000Z',
        model: 'mimo-v2.5-pro',
        language: 'en',
        content: 'private article body',
      );

      expect(replay, first);
      expect(retry, isNot(first));
      expect(first, isNot(contains('private')));
      expect(first.length, lessThan(100));
    },
  );
}

Map<String, dynamic> _snapshot({
  required String status,
  String task = 'summary.final',
  Map<String, dynamic>? result,
  Map<String, dynamic>? usage,
}) {
  return {
    'id': 'run-1',
    'status': status,
    'task': {'id': task, 'version': 1, 'resultSchemaVersion': 1},
    'result': result,
    'usage': usage ?? const <String, dynamic>{},
  };
}

String? _header(http.Request request, String name) {
  final normalized = name.toLowerCase();
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == normalized) return entry.value;
  }
  return null;
}

AuthSession _session() => AuthSession(
  accessToken: _jwt('access'),
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

String _jwt(String marker) {
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
