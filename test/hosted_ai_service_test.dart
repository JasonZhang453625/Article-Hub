import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memora/data/models/ai_image_input.dart';
import 'package:memora/data/services/auth_service.dart';
import 'package:memora/data/services/hosted_ai_service.dart';
import 'package:memora/data/services/hosted_task_run_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'hosted summary uses v4 tasks while chat keeps its completion path',
    () async {
      final paths = <String>[];
      final client = MockClient((request) async {
        paths.add(request.url.path);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'chat answer'},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      });
      final session = _session(_jwt('old'));
      final chat = HostedAiService(
        getSession: () => session,
        refreshSession: () async => null,
        model: 'mimo-v2.5',
        purpose: HostedAiPurpose.chat,
      );
      final tasks = _FakeTaskGateway();
      final summary = HostedAiService(
        getSession: () => session,
        refreshSession: () async => null,
        model: 'mimo-v2.5-pro',
        purpose: HostedAiPurpose.summary,
        taskGateway: tasks,
      );

      await http.runWithClient(() async {
        expect(
          await chat.chat(systemPrompt: 'S', userMessage: 'Q'),
          'chat answer',
        );
        expect(
          (await summary.summarizeWithTitle('T', 'Body')).memory,
          isNotNull,
        );
      }, () => client);

      expect(paths, ['/ai/chat/v1/chat/completions']);
      expect(tasks.calls.map((call) => call.profile), [
        HostedTaskProfile.summaryChunk,
        HostedTaskProfile.summaryFinal,
      ]);
    },
  );

  test(
    'refreshes once after a backend 401 and retries with fresh token',
    () async {
      var calls = 0;
      final authorizations = <String?>[];
      final client = MockClient((request) async {
        calls++;
        authorizations.add(request.headers['authorization']);
        if (calls == 1) {
          return http.Response(
            jsonEncode({
              'error': {'code': 'invalid_token', 'message': 'expired'},
            }),
            401,
          );
        }
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'ok'},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      });
      final old = _session(_jwt('old'));
      final fresh = _session(_jwt('fresh'));
      var refreshes = 0;
      final service = HostedAiService(
        getSession: () => old,
        refreshSession: () async {
          refreshes++;
          return fresh;
        },
        model: 'mimo-v2.5',
        purpose: HostedAiPurpose.chat,
      );

      final result = await http.runWithClient(
        () => service.chat(systemPrompt: 'S', userMessage: 'Q'),
        () => client,
      );

      expect(result, 'ok');
      expect(calls, 2);
      expect(refreshes, 1);
      expect(authorizations, [
        'Bearer ${old.accessToken}',
        'Bearer ${fresh.accessToken}',
      ]);
    },
  );

  test('hosted chatStream refreshes before the first SSE delta', () async {
    var calls = 0;
    var refreshes = 0;
    final old = _session(_jwt('old'));
    final fresh = _session(_jwt('fresh'));
    final client = MockClient.streaming((request, _) async {
      calls++;
      if (calls == 1) {
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable([
            utf8.encode('{"error":{"code":"invalid_token"}}'),
          ]),
          401,
          headers: {'content-type': 'application/json'},
        );
      }
      expect(request.headers['authorization'], 'Bearer ${fresh.accessToken}');
      return http.StreamedResponse(
        Stream<List<int>>.fromIterable([
          utf8.encode('data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'),
          utf8.encode('data: [DONE]\n\n'),
        ]),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final service = HostedAiService(
      getSession: () => old,
      refreshSession: () async {
        refreshes++;
        return fresh;
      },
      model: 'mimo-v2.5',
      purpose: HostedAiPurpose.chat,
    );

    final chunks = await http.runWithClient(
      () => service.chatStream(systemPrompt: 'S', userMessage: 'Q').toList(),
      () => client,
    );

    expect(chunks, ['ok']);
    expect(calls, 2);
    expect(refreshes, 1);
    expect(service.lastError, isNull);
  });

  test('daily quota 429 is preserved and is not retried', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response(
        jsonEncode({
          'error': {
            'code': 'daily_quota_exceeded',
            'message': 'Daily chat limit reached. Try again tomorrow.',
          },
        }),
        429,
      );
    });
    final session = _session(_jwt('old'));
    final service = HostedAiService(
      getSession: () => session,
      refreshSession: () async => null,
      model: 'mimo-v2.5',
      purpose: HostedAiPurpose.chat,
    );

    final result = await http.runWithClient(
      () => service.chat(systemPrompt: 'S', userMessage: 'Q'),
      () => client,
    );

    expect(result, isNull);
    expect(calls, 1);
    expect(service.lastError, contains('Try again tomorrow'));
  });

  test(
    'hosted multimodal chat keeps the chat endpoint and account token',
    () async {
      late Uri requestUri;
      late String? authorization;
      late Map<String, dynamic> payload;
      final client = MockClient.streaming((request, bodyStream) async {
        requestUri = request.url;
        authorization = request.headers['authorization'];
        payload =
            jsonDecode(await bodyStream.bytesToString())
                as Map<String, dynamic>;
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable([
            utf8.encode('data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'),
            utf8.encode('data: [DONE]\n\n'),
          ]),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final session = _session(_jwt('vision'));
      final service = HostedAiService(
        getSession: () => session,
        refreshSession: () async => null,
        model: 'mimo-v2.5',
        purpose: HostedAiPurpose.chat,
      );

      final chunks = await http.runWithClient(
        () => service
            .chatStreamWithImages(
              systemPrompt: 'S',
              userMessage: 'Q',
              images: [
                AiImageInput(
                  id: 'image',
                  fileName: 'image.png',
                  mimeType: 'image/png',
                  bytes: Uint8List.fromList([1]),
                ),
              ],
            )
            .toList(),
        () => client,
      );

      expect(chunks, ['ok']);
      expect(requestUri.path, '/ai/chat/v1/chat/completions');
      expect(authorization, 'Bearer ${session.accessToken}');
      final messages = payload['messages'] as List<dynamic>;
      expect((messages.last as Map)['content'], isA<List<dynamic>>());
    },
  );

  test('v4 summary tasks preserve structured Memora memory fields', () async {
    final tasks = _FakeTaskGateway();
    final service = HostedAiService(
      getSession: () => _session(_jwt('task')),
      refreshSession: () async => null,
      model: 'mimo-v2.5-pro',
      purpose: HostedAiPurpose.summary,
      taskGateway: tasks,
    );
    final operationKey = 'memora-task-v4-${List.filled(64, 'a').join()}';

    final result = await service.summarizeWithTitleTask(
      'Original',
      'Article body',
      language: HostedTaskSummaryLanguage.en,
      operationKey: operationKey,
    );

    expect(tasks.calls.map((call) => call.profile), [
      HostedTaskProfile.summaryChunk,
      HostedTaskProfile.summaryFinal,
    ]);
    expect(tasks.calls.map((call) => call.idempotencyKey), [
      '$operationKey-summary-chunk-0',
      '$operationKey-summary-final',
    ]);
    expect(tasks.calls.first.input['language'], 'en');
    expect(result.title, 'Generated title');
    expect(result.tags, isEmpty);
    expect(result.memory?.overview, 'Structured overview');
    expect(result.memory?.keyPoints, hasLength(2));
    expect(result.memory?.keyPoints.first.topic, 'Runtime');
    expect(result.memory?.keyPoints.first.content, 'Pi runs the task.');
    expect(result.memory?.keyPoints.first.order, 1);
    expect(result.memory?.keyPoints.first.id, startsWith('kp_'));
    expect(result.memory?.keyPoints.first.sourceRefs, isEmpty);
    expect(result.memory?.conclusion, 'Structured conclusion');
  });

  test('follow-system summary no longer misroutes to Chinese', () async {
    final tasks = _FakeTaskGateway();
    final service = HostedAiService(
      getSession: () => _session(_jwt('task')),
      refreshSession: () async => null,
      model: 'mimo-v2.5-pro',
      purpose: HostedAiPurpose.summary,
      taskGateway: tasks,
    );

    await service.summarizeWithTitle(
      'English title',
      'English source',
      languageHint:
          'Respond in the same language as the article title. If the title is in Chinese, respond in Chinese. If in English, respond in English.',
    );

    expect(tasks.calls.first.input['language'], 'follow-source');
  });

  test(
    'summary final worst-case preflight runs before any paid chunk',
    () async {
      final tasks = _PreflightTaskGateway(maxBodyBytes: 100000);
      final service = HostedAiService(
        getSession: () => _session(_jwt('task')),
        refreshSession: () async => null,
        model: 'mimo-v2.5-pro',
        purpose: HostedAiPurpose.summary,
        taskGateway: tasks,
      );

      final result = await service.summarizeWithTitleTask(
        'Title',
        List.filled(12001, 'a').join(),
        language: HostedTaskSummaryLanguage.en,
        operationKey: 'summary-preflight',
      );

      expect(result.memory, isNull);
      expect(tasks.calls, isEmpty);
      expect(service.lastStatusCode, 413);
    },
  );

  test('summary final worst-case boundary permits one bounded chunk', () async {
    final tasks = _PreflightTaskGateway(maxBodyBytes: 130000);
    final service = HostedAiService(
      getSession: () => _session(_jwt('task')),
      refreshSession: () async => null,
      model: 'mimo-v2.5-pro',
      purpose: HostedAiPurpose.summary,
      taskGateway: tasks,
    );

    final result = await service.summarizeWithTitleTask(
      'Title',
      List.filled(12000, 'a').join(),
      language: HostedTaskSummaryLanguage.en,
      operationKey: 'summary-preflight-one',
    );

    expect(result.memory, isNotNull);
    expect(tasks.calls.map((call) => call.profile), [
      HostedTaskProfile.summaryChunk,
      HostedTaskProfile.summaryFinal,
    ]);
  });
}

class _TaskCall {
  final HostedTaskProfile profile;
  final Map<String, dynamic> input;
  final String idempotencyKey;
  final HostedTaskOperationContext? operation;

  const _TaskCall(
    this.profile,
    this.input,
    this.idempotencyKey,
    this.operation,
  );
}

class _FakeTaskGateway implements HostedTaskGateway {
  final List<_TaskCall> calls = [];

  @override
  Future<HostedTaskRunResult> run({
    required HostedTaskProfile profile,
    required Map<String, dynamic> input,
    required String idempotencyKey,
    HostedTaskOperationContext? operation,
  }) async {
    calls.add(_TaskCall(profile, input, idempotencyKey, operation));
    final result = switch (profile) {
      HostedTaskProfile.summaryChunk => {
        'schemaVersion': 1,
        'summaryMarkdown': 'Chunk summary',
      },
      HostedTaskProfile.summaryFinal => {
        'schemaVersion': 1,
        'title': 'Generated title',
        'overview': 'Structured overview',
        'keyPoints': [
          {'topic': 'Runtime', 'content': 'Pi runs the task.'},
          {'topic': 'Schema', 'content': 'The result stays typed.'},
        ],
        'conclusion': 'Structured conclusion',
      },
      HostedTaskProfile.memoryTags => {
        'schemaVersion': 1,
        'tags': ['Pi', 'Memora'],
      },
      HostedTaskProfile.retrievalRewrite => {
        'schemaVersion': 1,
        'query': 'standalone query',
      },
      HostedTaskProfile.memoryFolder => {'schemaVersion': 1, 'folderId': null},
    };
    return HostedTaskRunResult(
      runId: 'run-${calls.length}',
      profile: profile,
      profileVersion: 1,
      resultSchemaVersion: 1,
      result: result,
    );
  }
}

class _PreflightTaskGateway extends _FakeTaskGateway
    implements HostedTaskRequestPreflight {
  @override
  final int maxBodyBytes;

  _PreflightTaskGateway({required this.maxBodyBytes});

  @override
  void validateRequest({
    required HostedTaskProfile profile,
    required Map<String, dynamic> input,
  }) {}
}

AuthSession _session(String accessToken) => AuthSession(
  accessToken: accessToken,
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
