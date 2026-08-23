import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memora/data/services/auth_service.dart';
import 'package:memora/data/services/hosted_task_run_service.dart';
import 'package:memora/data/services/hosted_task_run_store.dart';

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
        maxBodyBytes: 2 * 1024 * 1024,
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
      maxBodyBytes: 2 * 1024 * 1024,
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
      maxBodyBytes: 2 * 1024 * 1024,
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
      maxBodyBytes: 2 * 1024 * 1024,
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
      );
      final replay = await buildHostedTaskOperationKey(
        articleId: 'article-1',
        stage: 'summary',
        generation: 'retry:0|anchor:initial',
        model: 'mimo-v2.5-pro',
        language: 'en',
      );
      final retry = await buildHostedTaskOperationKey(
        articleId: 'article-1',
        stage: 'summary',
        generation: 'retry:1|anchor:2026-08-21T00:00:00.000Z',
        model: 'mimo-v2.5-pro',
        language: 'en',
      );

      expect(replay, first);
      expect(retry, isNot(first));
      expect(first, isNot(contains('private')));
      expect(first.length, lessThan(100));
    },
  );

  test(
    '401 refresh followed by ambiguous create reconciles the same key',
    () async {
      var current = _session();
      final fresh = _session(marker: 'fresh');
      var refreshes = 0;
      var posts = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          posts++;
          if (posts == 1) return http.Response('{}', 401);
          throw http.ClientException('response lost after refreshed upload');
        }
        if (request.url.path == '/ai/runs') {
          return http.Response(
            jsonEncode({'id': 'run-1', 'status': 'completed'}),
            200,
          );
        }
        return http.Response(
          jsonEncode(
            _snapshot(
              status: 'completed',
              task: 'retrieval.rewrite',
              result: {'schemaVersion': 1, 'query': 'reconciled'},
            ),
          ),
          200,
        );
      });
      final service = HostedTaskRunService(
        getSession: () => current,
        refreshSession: () async {
          refreshes++;
          current = fresh;
          return fresh;
        },
        model: 'mimo-v2.5',
        maxBodyBytes: 1024 * 1024,
        pollInterval: Duration.zero,
      );

      final result = await http.runWithClient(
        () => service.run(
          profile: HostedTaskProfile.retrievalRewrite,
          input: {'question': 'Q', 'language': 'en'},
          idempotencyKey: 'refresh-ambiguous',
        ),
        () => client,
      );

      expect(result.result['query'], 'reconciled');
      expect(posts, 2);
      expect(refreshes, 1);
    },
  );

  test('poll continues when refreshed GET has a client ambiguity', () async {
    var current = _session();
    final fresh = _session(marker: 'fresh');
    var getCalls = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        return http.Response(
          jsonEncode(_snapshot(status: 'queued', task: 'retrieval.rewrite')),
          202,
        );
      }
      getCalls++;
      if (getCalls == 1) return http.Response('{}', 401);
      if (getCalls == 2) throw http.ClientException('refreshed poll lost');
      return http.Response(
        jsonEncode(
          _snapshot(
            status: 'completed',
            task: 'retrieval.rewrite',
            result: {'schemaVersion': 1, 'query': 'observed'},
          ),
        ),
        200,
      );
    });
    final service = HostedTaskRunService(
      getSession: () => current,
      refreshSession: () async {
        current = fresh;
        return fresh;
      },
      model: 'mimo-v2.5',
      maxBodyBytes: 1024 * 1024,
      pollInterval: Duration.zero,
    );

    final result = await http.runWithClient(
      () => service.run(
        profile: HostedTaskProfile.retrievalRewrite,
        input: {'question': 'Q', 'language': 'en'},
        idempotencyKey: 'poll-refresh-ambiguity',
      ),
      () => client,
    );

    expect(result.result['query'], 'observed');
    expect(getCalls, 3);
  });

  test('poll delay uses capped exponential backoff with jitter', () async {
    final delays = <Duration>[];
    var getCalls = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        return http.Response(
          jsonEncode(_snapshot(status: 'queued', task: 'retrieval.rewrite')),
          202,
        );
      }
      getCalls++;
      final completed = getCalls == 3;
      return http.Response(
        jsonEncode(
          _snapshot(
            status: completed ? 'completed' : 'running',
            task: 'retrieval.rewrite',
            result: completed
                ? {'schemaVersion': 1, 'query': 'observed'}
                : null,
          ),
        ),
        200,
      );
    });
    final service = HostedTaskRunService(
      getSession: _session,
      refreshSession: () async => null,
      model: 'mimo-v2.5',
      maxBodyBytes: 1024 * 1024,
      pollInterval: const Duration(milliseconds: 100),
      maxPollInterval: const Duration(milliseconds: 250),
      jitterSource: () => 0.5,
      delay: (duration) async => delays.add(duration),
    );

    final result = await http.runWithClient(
      () => service.run(
        profile: HostedTaskProfile.retrievalRewrite,
        input: {'question': 'Q', 'language': 'en'},
        idempotencyKey: 'poll-backoff',
      ),
      () => client,
    );

    expect(result.result['query'], 'observed');
    expect(delays, const [
      Duration(milliseconds: 100),
      Duration(milliseconds: 200),
      Duration(milliseconds: 250),
    ]);
  });

  test(
    'replay reports ambiguity when refreshed POST also loses its response',
    () async {
      var current = _session();
      final fresh = _session(marker: 'fresh');
      var postCalls = 0;
      var lookupCalls = 0;
      var refreshes = 0;
      final postedKeys = <String?>[];
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          postCalls++;
          postedKeys.add(_header(request, 'idempotency-key'));
          if (postCalls == 1) {
            throw http.ClientException('initial response lost');
          }
          if (postCalls == 2) return http.Response('{}', 401);
          throw http.ClientException('refreshed replay response lost');
        }
        lookupCalls++;
        return http.Response(
          jsonEncode({
            'error': {'code': 'ai_run_not_found', 'message': 'not found'},
          }),
          404,
        );
      });
      final service = HostedTaskRunService(
        getSession: () => current,
        refreshSession: () async {
          refreshes++;
          current = fresh;
          return fresh;
        },
        model: 'mimo-v2.5',
        maxBodyBytes: 1024 * 1024,
        pollInterval: Duration.zero,
        jitterSource: () => 0,
      );

      await http.runWithClient(
        () => expectLater(
          service.run(
            profile: HostedTaskProfile.retrievalRewrite,
            input: {'question': 'Q', 'language': 'en'},
            idempotencyKey: 'replay-refresh-ambiguous',
          ),
          throwsA(
            isA<HostedTaskRunException>()
                .having((error) => error.code, 'code', 'task_create_ambiguous')
                .having((error) => error.retryable, 'retryable', isTrue),
          ),
        ),
        () => client,
      );

      expect(postCalls, 3);
      expect(lookupCalls, 3);
      expect(refreshes, 1);
      expect(postedKeys.toSet(), {'replay-refresh-ambiguous'});
    },
  );

  test('UTF-8 body limit rejects before session or network work', () async {
    var networkCalls = 0;
    var sessionReads = 0;
    final service = HostedTaskRunService(
      getSession: () {
        sessionReads++;
        return _session();
      },
      refreshSession: () async => null,
      model: 'mimo-v2.5',
      maxBodyBytes: 100,
    );

    await http.runWithClient(
      () => expectLater(
        service.run(
          profile: HostedTaskProfile.retrievalRewrite,
          input: {'question': List.filled(80, '界').join(), 'language': 'en'},
          idempotencyKey: 'oversize',
        ),
        throwsA(
          isA<HostedTaskRunException>()
              .having(
                (error) => error.code,
                'code',
                'hosted_task_request_too_large',
              )
              .having((error) => error.statusCode, 'status', 413),
        ),
      ),
      () => MockClient((_) async {
        networkCalls++;
        return http.Response('{}', 500);
      }),
    );

    expect(sessionReads, 0);
    expect(networkCalls, 0);
  });

  test('completed binding resumes by run id and counts usage once', () async {
    final store = _MemoryTaskRunStore();
    var posts = 0;
    var gets = 0;
    var tokens = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        posts++;
      } else {
        gets++;
      }
      return http.Response(
        jsonEncode(
          _snapshot(
            status: 'completed',
            task: 'retrieval.rewrite',
            result: {'schemaVersion': 1, 'query': 'same result'},
            usage: {'totalTokens': 19},
          ),
        ),
        200,
      );
    });
    final service = HostedTaskRunService(
      getSession: _session,
      refreshSession: () async => null,
      model: 'mimo-v2.5',
      maxBodyBytes: 1024 * 1024,
      pollInterval: Duration.zero,
      runStore: store,
      onTokensUsed: (value) => tokens += value,
    );
    const operation = HostedTaskOperationContext(
      articleId: 'article-1',
      generation: 'generation-1',
      stage: 'rewrite',
    );

    await http.runWithClient(() async {
      await service.run(
        profile: HostedTaskProfile.retrievalRewrite,
        input: {'question': 'first body', 'language': 'en'},
        idempotencyKey: 'durable-key',
        operation: operation,
      );
      await service.run(
        profile: HostedTaskProfile.retrievalRewrite,
        input: {'question': 'changed page body', 'language': 'en'},
        idempotencyKey: 'durable-key',
        operation: operation,
      );
    }, () => client);

    expect(posts, 1);
    expect(gets, 1);
    expect(tokens, 19);
  });

  test(
    'missing side binding derives a different key for changed page content',
    () async {
      final store = _MemoryTaskRunStore();
      final postedKeys = <String>[];
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        postedKeys.add(_header(request, 'idempotency-key')!);
        final result = postedKeys.length == 1 ? 'old result' : 'new result';
        return http.Response(
          jsonEncode(
            _snapshot(
              status: 'completed',
              task: 'retrieval.rewrite',
              result: {'schemaVersion': 1, 'query': result},
            ),
          ),
          202,
        );
      });
      final service = HostedTaskRunService(
        getSession: _session,
        refreshSession: () async => null,
        model: 'mimo-v2.5',
        maxBodyBytes: 1024 * 1024,
        pollInterval: Duration.zero,
        runStore: store,
      );
      const operation = HostedTaskOperationContext(
        articleId: 'article-1',
        generation: 'generation-1',
        stage: 'rewrite',
      );

      await http.runWithClient(() async {
        final first = await service.run(
          profile: HostedTaskProfile.retrievalRewrite,
          input: {'question': 'old page body', 'language': 'en'},
          idempotencyKey: 'logical-operation-key',
          operation: operation,
        );
        expect(first.result['query'], 'old result');

        // Simulate a cleared/corrupt side box while Article still carries the
        // same generation. A changed refetch must not address the old run.
        store.bindings.clear();
        final second = await service.run(
          profile: HostedTaskProfile.retrievalRewrite,
          input: {'question': 'new page body', 'language': 'en'},
          idempotencyKey: 'logical-operation-key',
          operation: operation,
        );
        expect(second.result['query'], 'new result');
      }, () => client);

      expect(postedKeys, hasLength(2));
      expect(postedKeys[0], isNot(postedKeys[1]));
      expect(postedKeys.every((key) => !key.contains('page body')), isTrue);
    },
  );

  test('changed input without a run id only reconciles the old key', () async {
    final store = _MemoryTaskRunStore();
    var phase = 1;
    var postCalls = 0;
    var lookupCalls = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        postCalls++;
        throw http.ClientException('create response lost');
      }
      lookupCalls++;
      if (phase == 1) throw http.ClientException('lookup unavailable');
      return http.Response(
        jsonEncode({
          'error': {'code': 'ai_run_not_found', 'message': 'not found'},
        }),
        404,
      );
    });
    final service = HostedTaskRunService(
      getSession: _session,
      refreshSession: () async => null,
      model: 'mimo-v2.5',
      maxBodyBytes: 1024 * 1024,
      pollInterval: Duration.zero,
      jitterSource: () => 0,
      runStore: store,
    );
    const operation = HostedTaskOperationContext(
      articleId: 'article-1',
      generation: 'generation-1',
      stage: 'rewrite',
    );

    await http.runWithClient(() async {
      await expectLater(
        service.run(
          profile: HostedTaskProfile.retrievalRewrite,
          input: {'question': 'old page body', 'language': 'en'},
          idempotencyKey: 'logical-operation-key',
          operation: operation,
        ),
        throwsA(
          isA<HostedTaskRunException>().having(
            (error) => error.code,
            'code',
            'task_reconciliation_failed',
          ),
        ),
      );

      phase = 2;
      await expectLater(
        service.run(
          profile: HostedTaskProfile.retrievalRewrite,
          input: {'question': 'changed page body', 'language': 'en'},
          idempotencyKey: 'logical-operation-key',
          operation: operation,
        ),
        throwsA(
          isA<HostedTaskRunException>().having(
            (error) => error.code,
            'code',
            'task_input_changed_during_recovery',
          ),
        ),
      );
    }, () => client);

    expect(postCalls, 1, reason: 'changed input must never replay the old key');
    expect(lookupCalls, 6);
    expect(
      store.bindings.values.single.state,
      HostedTaskBindingState.abandoned,
    );
  });

  test('explicit non-retryable create failure abandons its binding', () async {
    final store = _MemoryTaskRunStore();
    final service = HostedTaskRunService(
      getSession: _session,
      refreshSession: () async => null,
      model: 'mimo-v2.5',
      maxBodyBytes: 1024 * 1024,
      pollInterval: Duration.zero,
      runStore: store,
    );

    await http.runWithClient(
      () => expectLater(
        service.run(
          profile: HostedTaskProfile.retrievalRewrite,
          input: {'question': 'body', 'language': 'en'},
          idempotencyKey: 'logical-operation-key',
          operation: const HostedTaskOperationContext(
            articleId: 'article-1',
            generation: 'generation-1',
            stage: 'rewrite',
          ),
        ),
        throwsA(
          isA<HostedTaskRunException>()
              .having((error) => error.statusCode, 'status', 409)
              .having((error) => error.retryable, 'retryable', isFalse),
        ),
      ),
      () => MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {'code': 'idempotency_conflict', 'message': 'conflict'},
          }),
          409,
        ),
      ),
    );

    expect(
      store.bindings.values.single.state,
      HostedTaskBindingState.abandoned,
    );
  });
}

class _MemoryTaskRunStore implements HostedTaskRunStore {
  final Map<String, HostedTaskRunBinding> bindings = {};
  final Set<String> usage = {};

  String _key(String scope, String key) => '$scope::$key';

  @override
  Future<HostedTaskRunBinding?> readBinding(
    String scopeHash,
    String key,
  ) async => bindings[_key(scopeHash, key)];

  @override
  Future<HostedTaskRunBinding?> readBindingForOperation({
    required String scopeHash,
    required String articleId,
    required String generation,
    required String stage,
  }) async {
    final matches = bindings.entries
        .where(
          (entry) =>
              entry.key.startsWith('$scopeHash::') &&
              entry.value.articleId == articleId &&
              entry.value.generation == generation &&
              entry.value.stage == stage,
        )
        .map((entry) => entry.value)
        .toList();
    if (matches.isEmpty) return null;
    matches.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return matches.first;
  }

  @override
  Future<void> writeBinding(
    String scopeHash,
    HostedTaskRunBinding binding,
  ) async {
    bindings[_key(scopeHash, binding.idempotencyKey)] = binding;
  }

  @override
  Future<bool> recordTokenUsage(
    String scopeHash,
    String runId,
    int totalTokens,
  ) async => usage.add('$scopeHash::$runId');

  @override
  Future<bool> hasReplayableBindings({
    required String scopeHash,
    required String articleId,
    required String generation,
  }) async {
    final matching = bindings.entries
        .where(
          (entry) =>
              entry.key.startsWith('$scopeHash::') &&
              entry.value.articleId == articleId &&
              entry.value.generation == generation,
        )
        .map((entry) => entry.value)
        .toList();
    return matching.isNotEmpty &&
        matching.every((binding) => binding.state.isReplayable);
  }

  @override
  Future<void> finalizeGeneration({
    required String scopeHash,
    required String articleId,
    required String generation,
  }) async {
    bindings.removeWhere(
      (_, binding) =>
          binding.articleId == articleId && binding.generation == generation,
    );
  }

  @override
  Future<void> close() async {}
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

AuthSession _session({String marker = 'access'}) => AuthSession(
  accessToken: _jwt(marker),
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
