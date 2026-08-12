import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memora/data/models/ai_thinking_level.dart';
import 'package:memora/data/models/ai_image_input.dart';
import 'package:memora/data/services/auth_service.dart';
import 'package:memora/data/services/hosted_agent_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'streams Agent answer and captures tool events and web sources',
    () async {
      Map<String, dynamic>? payload;
      final client = MockClient.streaming((request, bodyStream) async {
        if (request.method == 'POST') {
          payload = jsonDecode(await bodyStream.bytesToString());
          return http.StreamedResponse(
            Stream<List<int>>.value(
              utf8.encode(
                jsonEncode({
                  'id': 'run-1',
                  'status': 'queued',
                  'lastEventSeq': 1,
                }),
              ),
            ),
            202,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable([
            utf8.encode(
              'id: 2\n'
              'event: agent\n'
              'data: {"type":"tool.call.started","runId":"run-1",'
              '"step":1,"callId":"call-1","tool":"web_search"}\n\n',
            ),
            utf8.encode(
              'id: 3\n'
              'event: agent\n'
              'data: {"type":"sources","runId":"run-1","sources":['
              '{"id":"w1","title":"Docs","url":"https://example.com/docs",'
              '"content":"Current docs","score":0.9}]}\n\n',
            ),
            utf8.encode(
              'id: 4\n'
              'event: agent\n'
              'data: {"type":"run.result","runId":"run-1",'
              '"answer":"Answer [w1]","sources":[]}\n\n',
            ),
          ]),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final session = _session(_jwt('active'));
      final service = HostedAgentService(
        getSession: () => session,
        refreshSession: () async => null,
        model: 'mimo-v2.5',
      );

      final chunks = await http.runWithClient(
        () => service
            .chatStream(
              systemPrompt: 'system',
              userMessage: 'latest docs',
              userQuestion: 'latest docs',
              webSearch: true,
            )
            .toList(),
        () => client,
      );

      expect(chunks, ['Answer [w1]']);
      expect(payload?['memora_tools'], {'web_search': true});
      expect(payload?['user_question'], 'latest docs');
      expect(service.lastEvents.map((event) => event.type), [
        'tool.call.started',
        'sources',
      ]);
      expect(service.lastWebUrls, ['https://example.com/docs']);
      expect(service.lastError, isNull);
    },
  );

  test('sends native image blocks through the durable Agent run', () async {
    Map<String, dynamic>? payload;
    final client = MockClient.streaming((request, bodyStream) async {
      if (request.method == 'POST') {
        payload = jsonDecode(await bodyStream.bytesToString());
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode('{"id":"run-image","status":"queued"}'),
          ),
          202,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode(
            'id: 1\n'
            'event: agent\n'
            'data: {"type":"run.result","runId":"run-image",'
            '"answer":"A chart.","sources":[]}\n\n',
          ),
        ),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final session = _session(_jwt('image'));
    final service = HostedAgentService(
      getSession: () => session,
      refreshSession: () async => null,
      model: 'mimo-v2.5',
      imageInputEnabled: true,
    );
    final bytes = Uint8List.fromList([
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
    ]);

    final chunks = await http.runWithClient(
      () => service
          .chatStream(
            systemPrompt: 'system',
            userMessage: 'Describe this image.',
            userQuestion: 'Describe this image.',
            images: [
              AiImageInput(
                id: 'image-1',
                fileName: 'chart.png',
                mimeType: 'image/png',
                bytes: bytes,
              ),
            ],
          )
          .toList(),
      () => client,
    );

    final messages = payload?['messages'] as List<dynamic>;
    final user = Map<String, dynamic>.from(messages.last as Map);
    final content = (user['content'] as List<dynamic>)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    expect(chunks, ['A chart.']);
    expect(content.first, {'type': 'text', 'text': 'Describe this image.'});
    expect(content.last, {
      'type': 'image',
      'data': base64.encode(bytes),
      'mimeType': 'image/png',
    });
  });

  test('Stop closes an in-flight create upload without replaying it', () async {
    final client = _CloseAwareClient();
    final service = HostedAgentService(
      getSession: () => _session(_jwt('cancel-create')),
      refreshSession: () async => null,
      model: 'mimo-v2.5',
      imageInputEnabled: true,
    );

    final completion = http.runWithClient(
      () => service
          .chatStream(
            systemPrompt: 'system',
            userMessage: 'Describe this image.',
            userQuestion: 'Describe this image.',
            images: [
              AiImageInput(
                id: 'image-1',
                fileName: 'chart.png',
                mimeType: 'image/png',
                bytes: Uint8List.fromList([
                  0x89,
                  0x50,
                  0x4e,
                  0x47,
                  0x0d,
                  0x0a,
                  0x1a,
                  0x0a,
                ]),
              ),
            ],
            idempotencyKey: 'stable-image-attempt',
          )
          .toList(),
      () => client,
    );

    await client.started.future;
    service.cancelPendingCreate();

    expect(await completion, isEmpty);
    expect(client.sendCount, 1);
    expect(client.closed, isTrue);
    expect(service.lastRunId, isNull);
    expect(service.lastError, 'Hosted Agent request was cancelled.');
  });

  test(
    'rejects images unless Agent protocol capability was negotiated',
    () async {
      final service = HostedAgentService(
        getSession: () => _session(_jwt('no-image-capability')),
        refreshSession: () async => null,
        model: 'mimo-v2.5',
      );

      await expectLater(
        service
            .chatStream(
              systemPrompt: 'system',
              userMessage: 'image',
              userQuestion: 'image',
              images: [
                AiImageInput(
                  id: 'image-1',
                  fileName: 'image.png',
                  mimeType: 'image/png',
                  bytes: Uint8List.fromList([1]),
                ),
              ],
            )
            .toList(),
        throwsA(
          isA<HostedAgentInputException>().having(
            (error) => error.code,
            'code',
            'image_input_not_negotiated',
          ),
        ),
      );
    },
  );

  test(
    'rejects a request above the advertised body limit before POST',
    () async {
      final service = HostedAgentService(
        getSession: () => _session(_jwt('small-body-cap')),
        refreshSession: () async => null,
        model: 'mimo-v2.5',
        maxBodyBytes: 64,
      );

      await expectLater(
        service
            .chatStream(
              systemPrompt: 'system prompt that exceeds the tiny cap',
              userMessage: 'question that also exceeds the tiny cap',
              userQuestion: 'question',
              idempotencyKey: 'small-body-cap',
            )
            .toList(),
        throwsA(
          isA<HostedAgentInputException>().having(
            (error) => error.code,
            'code',
            'request_too_large',
          ),
        ),
      );
    },
  );

  test('refreshes once when Agent endpoint rejects the access token', () async {
    var calls = 0;
    var refreshes = 0;
    final old = _session(_jwt('old'));
    final fresh = _session(_jwt('fresh'));
    final client = MockClient.streaming((request, _) async {
      if (request.method == 'POST') {
        calls++;
        if (calls == 1) {
          return http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode('{"error":"expired"}')),
            401,
            headers: {'content-type': 'application/json'},
          );
        }
        expect(request.headers['authorization'], 'Bearer ${fresh.accessToken}');
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode(
              jsonEncode({
                'id': 'run-2',
                'status': 'queued',
                'lastEventSeq': 1,
              }),
            ),
          ),
          202,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode(
            'id: 2\n'
            'event: agent\n'
            'data: {"type":"run.result","runId":"run-2",'
            '"answer":"ok","sources":[]}\n\n',
          ),
        ),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final service = HostedAgentService(
      getSession: () => old,
      refreshSession: () async {
        refreshes++;
        return fresh;
      },
      model: 'mimo-v2.5',
    );

    final chunks = await http.runWithClient(
      () => service
          .chatStream(
            systemPrompt: 'system',
            userMessage: 'question',
            userQuestion: 'question',
          )
          .toList(),
      () => client,
    );

    expect(chunks, ['ok']);
    expect(calls, 2);
    expect(refreshes, 1);
    expect(service.lastError, isNull);
  });

  test('replays an ambiguous create with the same idempotency key', () async {
    var createCalls = 0;
    final seenKeys = <String?>[];
    final client = MockClient.streaming((request, _) async {
      if (request.method == 'POST') {
        createCalls++;
        seenKeys.add(request.headers['idempotency-key']);
        if (createCalls == 1) {
          throw http.ClientException('response lost', request.url);
        }
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode(
              jsonEncode({
                'id': 'run-idempotent-replay',
                'status': 'queued',
                'lastEventSeq': 1,
              }),
            ),
          ),
          202,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode(
            'id: 2\n'
            'event: agent\n'
            'data: {"type":"run.result",'
            '"runId":"run-idempotent-replay",'
            '"answer":"created once","sources":[]}\n\n',
          ),
        ),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final service = HostedAgentService(
      getSession: () => _session(_jwt('active')),
      refreshSession: () async => null,
      model: 'mimo-v2.5',
    );

    final chunks = await http.runWithClient(
      () => service
          .chatStream(
            systemPrompt: 'system',
            userMessage: 'prompt bundle',
            userQuestion: 'raw question',
            idempotencyKey: 'attempt-key-1',
          )
          .toList(),
      () => client,
    );

    expect(chunks, ['created once']);
    expect(createCalls, 2);
    expect(seenKeys, ['attempt-key-1', 'attempt-key-1']);
    expect(service.lastRunId, 'run-idempotent-replay');
  });

  test('forwards DeepSeek max thinking to the hosted Agent endpoint', () async {
    late Map<String, dynamic> payload;
    final client = MockClient.streaming((request, bodyStream) async {
      if (request.method == 'POST') {
        payload = jsonDecode(await bodyStream.bytesToString());
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode(
              jsonEncode({
                'id': 'run-3',
                'status': 'queued',
                'lastEventSeq': 1,
              }),
            ),
          ),
          202,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode(
            'id: 2\n'
            'event: agent\n'
            'data: {"type":"run.result","runId":"run-3",'
            '"answer":"ok","sources":[]}\n\n',
          ),
        ),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final service = HostedAgentService(
      getSession: () => _session(_jwt('active')),
      refreshSession: () async => null,
      model: 'deepseek-v4-pro',
      thinkingLevel: AiThinkingLevel.max,
    );

    await http.runWithClient(
      () => service
          .chatStream(
            systemPrompt: 'system',
            userMessage: 'question',
            userQuestion: 'question',
          )
          .toList(),
      () => client,
    );

    expect(payload['thinking'], {'type': 'enabled'});
    expect(payload['reasoning_effort'], 'max');
  });

  test('replays a truncated SSE event without skipping its id', () async {
    var eventRequests = 0;
    final afterValues = <String?>[];
    final lastEventIds = <String?>[];
    final client = MockClient.streaming((request, _) async {
      if (request.method == 'POST') {
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode(
              jsonEncode({
                'id': 'run-replay',
                'status': 'queued',
                'lastEventSeq': 0,
              }),
            ),
          ),
          202,
          headers: {'content-type': 'application/json'},
        );
      }

      eventRequests++;
      afterValues.add(request.url.queryParameters['after']);
      lastEventIds.add(request.headers['last-event-id']);
      if (eventRequests == 1) {
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode(
              'id: 1\n'
              'event: agent\n'
              'data: {"type":"tool.call.started","runId":"run-replay",'
              '"callId":"call-1","tool":"web_search"}\n\n'
              'id: 2\n'
              'event: agent\n'
              'data: {"type":"run.result","runId":"run-replay",'
              '"answer":"truncated',
            ),
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode(
            'id: 2\n'
            'event: agent\n'
            'data: {"type":"run.result","runId":"run-replay",'
            '"answer":"replayed answer","sources":[]}\n\n',
          ),
        ),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final service = HostedAgentService(
      getSession: () => _session(_jwt('active')),
      refreshSession: () async => null,
      model: 'mimo-v2.5',
    );

    final chunks = await http.runWithClient(
      () => service
          .chatStream(
            systemPrompt: 'system',
            userMessage: 'question',
            userQuestion: 'question',
          )
          .toList(),
      () => client,
    );

    expect(chunks, ['replayed answer']);
    expect(eventRequests, 2);
    expect(afterValues, ['0', '1']);
    expect(lastEventIds, ['0', '1']);
    expect(service.lastEventSeq, 2);
    expect(service.lastEvents.map((event) => event.type), [
      'tool.call.started',
    ]);
    expect(service.lastError, isNull);
  });

  test('refreshes once when the Agent event stream returns 401', () async {
    var eventRequests = 0;
    var refreshes = 0;
    final old = _session(_jwt('old'));
    final fresh = _session(_jwt('fresh'));
    final client = MockClient.streaming((request, _) async {
      if (request.method == 'POST') {
        expect(request.headers['authorization'], 'Bearer ${old.accessToken}');
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode(
              jsonEncode({
                'id': 'run-refresh-events',
                'status': 'queued',
                'lastEventSeq': 0,
              }),
            ),
          ),
          202,
          headers: {'content-type': 'application/json'},
        );
      }

      eventRequests++;
      if (eventRequests == 1) {
        expect(request.headers['authorization'], 'Bearer ${old.accessToken}');
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode('{"error":"expired"}')),
          401,
          headers: {'content-type': 'application/json'},
        );
      }
      expect(request.headers['authorization'], 'Bearer ${fresh.accessToken}');
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode(
            'id: 1\n'
            'event: agent\n'
            'data: {"type":"run.result","runId":"run-refresh-events",'
            '"answer":"fresh stream","sources":[]}\n\n',
          ),
        ),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final service = HostedAgentService(
      getSession: () => old,
      refreshSession: () async {
        refreshes++;
        return fresh;
      },
      model: 'mimo-v2.5',
    );

    final chunks = await http.runWithClient(
      () => service
          .chatStream(
            systemPrompt: 'system',
            userMessage: 'question',
            userQuestion: 'question',
          )
          .toList(),
      () => client,
    );

    expect(chunks, ['fresh stream']);
    expect(eventRequests, 2);
    expect(refreshes, 1);
    expect(service.lastStatusCode, 200);
    expect(service.lastError, isNull);
  });

  test(
    'keeps one SSE connection from run.completed through run.result',
    () async {
      var eventRequests = 0;
      final client = MockClient.streaming((request, _) async {
        if (request.method == 'POST') {
          return http.StreamedResponse(
            Stream<List<int>>.value(
              utf8.encode(
                jsonEncode({
                  'id': 'run-legacy-order',
                  'status': 'queued',
                  'lastEventSeq': 0,
                }),
              ),
            ),
            202,
            headers: {'content-type': 'application/json'},
          );
        }

        eventRequests++;
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode(
              'id: 1\n'
              'event: agent\n'
              'data: {"type":"run.completed",'
              '"runId":"run-legacy-order"}\n\n'
              'id: 2\n'
              'event: agent\n'
              'data: {"type":"run.result","runId":"run-legacy-order",'
              '"answer":"legacy final [w1]","sources":['
              '{"id":"w1","title":"Legacy source",'
              '"url":"https://legacy.example/source",'
              '"content":"source body","score":0.8}]}\n\n',
            ),
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final service = HostedAgentService(
        getSession: () => _session(_jwt('active')),
        refreshSession: () async => null,
        model: 'mimo-v2.5',
      );

      final chunks = await http.runWithClient(
        () => service
            .chatStream(
              systemPrompt: 'system',
              userMessage: 'question',
              userQuestion: 'question',
            )
            .toList(),
        () => client,
      );

      expect(chunks, ['legacy final [w1]']);
      expect(eventRequests, 1);
      expect(service.lastEventSeq, 2);
      expect(service.lastEvents.map((event) => event.type), ['run.completed']);
      expect(service.lastWebUrls, ['https://legacy.example/source']);
      expect(service.lastStatusCode, 200);
      expect(service.lastError, isNull);
    },
  );

  test('restores a completed durable run from its snapshot', () async {
    var requests = 0;
    final client = MockClient.streaming((request, _) async {
      requests++;
      expect(request.method, 'GET');
      expect(request.url.path, '/ai/runs/run-9');
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode(
            jsonEncode({
              'id': 'run-9',
              'status': 'completed',
              'answer': 'Restored after process death',
              'lastEventSeq': 6,
              'sources': [],
            }),
          ),
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final service = HostedAgentService(
      getSession: () => _session(_jwt('active')),
      refreshSession: () async => null,
      model: 'mimo-v2.5',
    );

    final chunks = await http.runWithClient(
      () => service.resumeStream('run-9').toList(),
      () => client,
    );

    expect(chunks, ['Restored after process death']);
    expect(service.lastEventSeq, 6);
    expect(requests, 1);
  });

  test(
    'resume replays from the persisted cursor and treats run.result as full',
    () async {
      var requests = 0;
      String? requestedAfter;
      String? requestedLastEventId;
      final replayedEvents = <String>[];
      final client = MockClient.streaming((request, _) async {
        requests++;
        if (request.url.path == '/ai/runs/run-cursor') {
          return http.StreamedResponse(
            Stream<List<int>>.value(
              utf8.encode(
                jsonEncode({
                  'id': 'run-cursor',
                  'status': 'completed',
                  'answer': null,
                  'lastEventSeq': 8,
                  'sources': [],
                }),
              ),
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        expect(request.url.path, '/ai/runs/run-cursor/events');
        requestedAfter = request.url.queryParameters['after'];
        requestedLastEventId = request.headers['last-event-id'];
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode(
              'id: 6\n'
              'event: completion\n'
              'data: {"choices":[{"delta":{"content":" replayed suffix"}}]}\n\n'
              'id: 7\n'
              'event: agent\n'
              'data: {"type":"run.completed","runId":"run-cursor"}\n\n'
              'id: 8\n'
              'event: agent\n'
              'data: {"type":"run.result","runId":"run-cursor",'
              '"answer":"Authoritative full answer","sources":[]}\n\n',
            ),
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final service = HostedAgentService(
        getSession: () => _session(_jwt('active')),
        refreshSession: () async => null,
        model: 'mimo-v2.5',
      );

      final chunks = await http.runWithClient(
        () => service
            .resumeStream(
              'run-cursor',
              afterEventSeq: 5,
              onEvent: (event) => replayedEvents.add(event.type),
            )
            .toList(),
        () => client,
      );

      expect(requestedAfter, '5');
      expect(requestedLastEventId, '5');
      expect(chunks, [' replayed suffix', 'Authoritative full answer']);
      expect(replayedEvents, ['run.snapshot', 'run.completed']);
      expect(service.lastChunkIsFullAnswer, isTrue);
      expect(service.lastEventSeq, 8);
      expect(requests, 2);
    },
  );

  test(
    'resume rejects a full frame before the snapshot cursor is caught up',
    () async {
      final client = MockClient.streaming((request, _) async {
        if (request.url.path == '/ai/runs/run-cursor-gap') {
          return http.StreamedResponse(
            Stream<List<int>>.value(
              utf8.encode(
                jsonEncode({
                  'id': 'run-cursor-gap',
                  'status': 'completed',
                  'answer': null,
                  'lastEventSeq': 8,
                  'sources': [],
                }),
              ),
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        expect(request.url.path, '/ai/runs/run-cursor-gap/events');
        expect(request.url.queryParameters['after'], '5');
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode(
              'id: 6\n'
              'event: completion\n'
              'data: {"choices":[{"message":{"content":"early full answer"}}]}\n\n',
            ),
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final service = HostedAgentService(
        getSession: () => _session(_jwt('active')),
        refreshSession: () async => null,
        model: 'mimo-v2.5',
      );
      final chunks = <String>[];

      final failure = await http.runWithClient(() async {
        try {
          await for (final chunk in service.resumeStream(
            'run-cursor-gap',
            afterEventSeq: 5,
          )) {
            chunks.add(chunk);
          }
        } on HostedAgentResumeException catch (error) {
          return error;
        }
        throw StateError('resumeStream unexpectedly completed');
      }, () => client);

      expect(chunks, ['early full answer']);
      expect(service.lastEventSeq, 6);
      expect(failure.retryable, isTrue);
      expect(failure.message, contains('events are not fully available'));
    },
  );

  test('resume rejects DONE without a durable terminal result', () async {
    final client = MockClient.streaming((request, _) async {
      if (request.url.path == '/ai/runs/run-done-only') {
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode(
              jsonEncode({
                'id': 'run-done-only',
                'status': 'running',
                'answer': null,
                'lastEventSeq': 5,
                'sources': [],
              }),
            ),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      expect(request.url.path, '/ai/runs/run-done-only/events');
      return http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode('data: [DONE]\n\n')),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final service = HostedAgentService(
      getSession: () => _session(_jwt('active')),
      refreshSession: () async => null,
      model: 'mimo-v2.5',
    );

    final failure = await http.runWithClient(() async {
      try {
        await service.resumeStream('run-done-only', afterEventSeq: 5).toList();
      } on HostedAgentResumeException catch (error) {
        return error;
      }
      throw StateError('resumeStream unexpectedly completed');
    }, () => client);

    expect(failure.retryable, isTrue);
    expect(service.lastRunStatus, 'running');
    expect(service.lastEventSeq, 5);
  });

  test(
    'an empty run.result overrides an earlier full completion frame',
    () async {
      final client = MockClient.streaming((request, _) async {
        if (request.url.path == '/ai/runs/run-empty-authoritative-result') {
          return http.StreamedResponse(
            Stream<List<int>>.value(
              utf8.encode(
                jsonEncode({
                  'id': 'run-empty-authoritative-result',
                  'status': 'running',
                  'answer': null,
                  'lastEventSeq': 5,
                  'sources': [],
                }),
              ),
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        expect(
          request.url.path,
          '/ai/runs/run-empty-authoritative-result/events',
        );
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode(
              'id: 6\n'
              'event: completion\n'
              'data: {"choices":[{"message":{"content":"early full answer"}}]}\n\n'
              'id: 7\n'
              'event: agent\n'
              'data: {"type":"run.result","answer":"","sources":[]}\n\n',
            ),
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final service = HostedAgentService(
        getSession: () => _session(_jwt('active')),
        refreshSession: () async => null,
        model: 'mimo-v2.5',
      );
      final chunks = <String>[];

      final failure = await http.runWithClient(() async {
        try {
          await for (final chunk in service.resumeStream(
            'run-empty-authoritative-result',
            afterEventSeq: 5,
          )) {
            chunks.add(chunk);
          }
        } on HostedAgentResumeException catch (error) {
          return error;
        }
        throw StateError('resumeStream unexpectedly completed');
      }, () => client);

      expect(chunks, ['early full answer']);
      expect(service.lastRunStatus, 'completed');
      expect(service.lastEventSeq, 7);
      expect(failure.retryable, isTrue);
      expect(failure.message, contains('answer was available'));
    },
  );

  test(
    'resume rejects a whitespace run.result without yielding a full frame',
    () async {
      var requests = 0;
      String? requestedAfter;
      String? requestedLastEventId;
      final client = MockClient.streaming((request, _) async {
        requests++;
        if (request.url.path == '/ai/runs/run-empty-result') {
          return http.StreamedResponse(
            Stream<List<int>>.value(
              utf8.encode(
                jsonEncode({
                  'id': 'run-empty-result',
                  'status': 'running',
                  'answer': null,
                  'lastEventSeq': 5,
                  'sources': [],
                }),
              ),
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        expect(request.url.path, '/ai/runs/run-empty-result/events');
        requestedAfter = request.url.queryParameters['after'];
        requestedLastEventId = request.headers['last-event-id'];
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode(
              'id: 6\n'
              'event: agent\n'
              'data: {"type":"run.result","runId":"run-empty-result",'
              '"answer":"   ","sources":[]}\n\n',
            ),
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final service = HostedAgentService(
        getSession: () => _session(_jwt('active')),
        refreshSession: () async => null,
        model: 'mimo-v2.5',
      );
      final chunks = <String>[];

      final failure = await http.runWithClient(() async {
        try {
          await for (final chunk in service.resumeStream(
            'run-empty-result',
            afterEventSeq: 5,
          )) {
            chunks.add(chunk);
          }
        } on HostedAgentResumeException catch (error) {
          return error;
        }
        throw StateError('resumeStream unexpectedly completed');
      }, () => client);

      expect(requestedAfter, '5');
      expect(requestedLastEventId, '5');
      expect(chunks, isEmpty);
      expect(failure.retryable, isTrue);
      expect(failure.message, contains('answer was available'));
      expect(service.lastRunStatus, 'completed');
      expect(service.lastEventSeq, 6);
      expect(requests, 2);
    },
  );

  test(
    'classifies snapshot 503 as retryable and 404 as nonretryable',
    () async {
      for (final statusCode in [503, 404]) {
        final client = MockClient.streaming((request, _) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/ai/runs/run-$statusCode');
          return http.StreamedResponse(
            Stream<List<int>>.value(
              utf8.encode(
                jsonEncode({
                  'error': {'message': 'snapshot unavailable'},
                }),
              ),
            ),
            statusCode,
            headers: {'content-type': 'application/json'},
          );
        });
        final service = HostedAgentService(
          getSession: () => _session(_jwt('active')),
          refreshSession: () async => null,
          model: 'mimo-v2.5',
        );

        final failure = await http.runWithClient(() async {
          try {
            await service.resumeStream('run-$statusCode').toList();
          } on HostedAgentResumeException catch (error) {
            return error;
          }
          throw StateError('resumeStream unexpectedly completed');
        }, () => client);

        expect(failure.statusCode, statusCode);
        expect(failure.retryable, statusCode == 503);
        expect(service.lastStatusCode, statusCode);
      }
    },
  );

  test('records failed and cancelled durable snapshot statuses', () async {
    for (final status in ['failed', 'cancelled']) {
      var requests = 0;
      final client = MockClient.streaming((request, _) async {
        requests++;
        expect(request.method, 'GET');
        expect(request.url.path, '/ai/runs/run-$status');
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode(
              jsonEncode({
                'id': 'run-$status',
                'status': status,
                'lastEventSeq': 7,
                'errorMessage': '$status by worker',
              }),
            ),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = HostedAgentService(
        getSession: () => _session(_jwt('active')),
        refreshSession: () async => null,
        model: 'mimo-v2.5',
      );

      final chunks = await http.runWithClient(
        () => service.resumeStream('run-$status').toList(),
        () => client,
      );

      expect(chunks, isEmpty);
      expect(service.lastRunStatus, status);
      expect(service.lastEventSeq, 7);
      expect(requests, 1);
    }
  });

  test(
    'keeps failed status when run.failed follows a partial answer',
    () async {
      final client = MockClient.streaming((request, _) async {
        if (request.url.path == '/ai/runs/run-partial-failed') {
          return http.StreamedResponse(
            Stream<List<int>>.value(
              utf8.encode(
                jsonEncode({
                  'id': 'run-partial-failed',
                  'status': 'running',
                  'lastEventSeq': 0,
                }),
              ),
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        expect(request.url.path, '/ai/runs/run-partial-failed/events');
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode(
              'id: 1\n'
              'event: completion\n'
              'data: {"choices":[{"delta":{"content":"partial answer"}}]}\n\n'
              'id: 2\n'
              'event: agent\n'
              'data: {"type":"run.failed","runId":"run-partial-failed",'
              '"error":"provider rejected request"}\n\n',
            ),
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final service = HostedAgentService(
        getSession: () => _session(_jwt('active')),
        refreshSession: () async => null,
        model: 'mimo-v2.5',
      );

      final chunks = await http.runWithClient(
        () => service.resumeStream('run-partial-failed').toList(),
        () => client,
      );

      expect(chunks, ['partial answer']);
      expect(service.lastRunStatus, 'failed');
      expect(service.lastError, 'provider rejected request');
      expect(service.lastEventSeq, 2);
    },
  );

  test(
    'cancel uses the POST control route without polluting stream state',
    () async {
      final session = _session(_jwt('active'));
      final client = MockClient.streaming((request, _) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/ai/runs/run-state-1/cancel');
        expect(
          request.headers['authorization'],
          'Bearer ${session.accessToken}',
        );
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode('{"id":"run-state-1","status":"cancelled"}'),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service =
          HostedAgentService(
              getSession: () => session,
              refreshSession: () async => null,
              model: 'mimo-v2.5',
            )
            ..lastError = 'existing stream error'
            ..lastStatusCode = 206
            ..lastRunId = 'observed-run'
            ..lastEventSeq = 9
            ..lastRunStatus = 'running';

      await http.runWithClient(
        () => service.cancelRun('run-state-1'),
        () => client,
      );

      expect(service.lastError, 'existing stream error');
      expect(service.lastStatusCode, 206);
      expect(service.lastRunId, 'observed-run');
      expect(service.lastEventSeq, 9);
      expect(service.lastRunStatus, 'running');
    },
  );

  test(
    'reconciles a create with GET and the exact idempotency header',
    () async {
      final session = _session(_jwt('lookup'));
      var requests = 0;
      final client = MockClient.streaming((request, _) async {
        requests++;
        expect(request.method, 'GET');
        expect(request.url.path, '/ai/runs');
        expect(request.headers['idempotency-key'], 'attempt-lookup-1');
        expect(
          request.headers['authorization'],
          'Bearer ${session.accessToken}',
        );
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode('{"id":"run-lookup-1","status":"running"}'),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final control = HostedAgentControlService(
        getSession: () => session,
        refreshSession: () async => null,
      );

      final result = await http.runWithClient(
        () => control.lookupRunByIdempotencyKey(' attempt-lookup-1 '),
        () => client,
      );

      expect(result.runId, 'run-lookup-1');
      expect(result.status, 'running');
      expect(requests, 1);
    },
  );

  test('lookup refreshes one 401 and classifies 404 without POST', () async {
    final old = _session(_jwt('lookup-old'));
    final fresh = _session(_jwt('lookup-fresh'));
    var requests = 0;
    var refreshes = 0;
    final client = MockClient.streaming((request, _) async {
      requests++;
      expect(request.method, 'GET');
      if (requests == 1) {
        expect(request.headers['authorization'], 'Bearer ${old.accessToken}');
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode('{"error":"expired"}')),
          401,
        );
      }
      expect(request.headers['authorization'], 'Bearer ${fresh.accessToken}');
      return http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode('{"error":"not_found"}')),
        404,
      );
    });
    final control = HostedAgentControlService(
      getSession: () => old,
      refreshSession: () async {
        refreshes++;
        return fresh;
      },
    );

    await expectLater(
      http.runWithClient(
        () => control.lookupRunByIdempotencyKey('attempt-missing'),
        () => client,
      ),
      throwsA(
        isA<HostedAgentLookupException>()
            .having((error) => error.statusCode, 'statusCode', 404)
            .having((error) => error.notFound, 'notFound', isTrue)
            .having((error) => error.retryable, 'retryable', isFalse),
      ),
    );
    expect(requests, 2);
    expect(refreshes, 1);
  });

  test('lookup timeout remains retryable and never replays create', () async {
    var requests = 0;
    final client = MockClient.streaming((request, _) async {
      requests++;
      expect(request.method, 'GET');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode('{}')),
        200,
      );
    });
    final control = HostedAgentControlService(
      getSession: () => _session(_jwt('lookup-timeout')),
      refreshSession: () async => null,
      timeout: const Duration(milliseconds: 10),
    );

    await expectLater(
      http.runWithClient(
        () => control.lookupRunByIdempotencyKey('attempt-timeout'),
        () => client,
      ),
      throwsA(
        isA<HostedAgentLookupException>()
            .having((error) => error.statusCode, 'statusCode', isNull)
            .having((error) => error.retryable, 'retryable', isTrue)
            .having((error) => error.notFound, 'notFound', isFalse),
      ),
    );
    expect(requests, 1);
  });

  test(
    'lookup refuses an account mismatch before any network request',
    () async {
      var requests = 0;
      final client = MockClient.streaming((_, _) async {
        requests++;
        return http.StreamedResponse(Stream<List<int>>.empty(), 500);
      });
      final control = HostedAgentControlService(
        getSession: () => _session(_jwt('lookup-owner')),
        refreshSession: () async => null,
      );

      await expectLater(
        http.runWithClient(
          () => control.lookupRunByIdempotencyKey(
            'attempt-other-owner',
            expectedOwnerUserId: 'user-2',
          ),
          () => client,
        ),
        throwsA(
          isA<HostedAgentLookupException>()
              .having(
                (error) => error.accountMismatch,
                'accountMismatch',
                isTrue,
              )
              .having((error) => error.retryable, 'retryable', isFalse),
        ),
      );
      expect(requests, 0);
    },
  );

  test('cancel refreshes one 401 and treats a later 404 as terminal', () async {
    final old = _session(_jwt('old'));
    final fresh = _session(_jwt('fresh'));
    var requests = 0;
    var refreshes = 0;
    final client = MockClient.streaming((request, _) async {
      requests++;
      if (requests == 1) {
        expect(request.headers['authorization'], 'Bearer ${old.accessToken}');
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode('{"error":"expired"}')),
          401,
        );
      }
      expect(request.headers['authorization'], 'Bearer ${fresh.accessToken}');
      return http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode('{"error":"gone"}')),
        404,
      );
    });
    final control = HostedAgentControlService(
      getSession: () => old,
      refreshSession: () async {
        refreshes++;
        return fresh;
      },
    );

    await http.runWithClient(() => control.cancelRun('run-gone'), () => client);

    expect(requests, 2);
    expect(refreshes, 1);
  });
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

class _CloseAwareClient extends http.BaseClient {
  final started = Completer<void>();
  final _response = Completer<http.StreamedResponse>();
  int sendCount = 0;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sendCount++;
    if (!started.isCompleted) started.complete();
    return _response.future;
  }

  @override
  void close() {
    if (closed) return;
    closed = true;
    if (!_response.isCompleted) {
      _response.completeError(
        http.ClientException('request closed before response'),
      );
    }
  }
}
