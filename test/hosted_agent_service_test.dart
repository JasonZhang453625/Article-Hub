import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memora/data/models/ai_thinking_level.dart';
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
              webSearch: true,
            )
            .toList(),
        () => client,
      );

      expect(chunks, ['Answer [w1]']);
      expect(payload?['memora_tools'], {'web_search': true});
      expect(service.lastEvents.map((event) => event.type), [
        'tool.call.started',
        'sources',
      ]);
      expect(service.lastWebUrls, ['https://example.com/docs']);
      expect(service.lastError, isNull);
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
          expect(
            request.headers['authorization'],
            'Bearer ${fresh.accessToken}',
          );
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
          .chatStream(systemPrompt: 'system', userMessage: 'question')
          .toList(),
      () => client,
    );

    expect(chunks, ['ok']);
    expect(calls, 2);
    expect(refreshes, 1);
    expect(service.lastError, isNull);
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
          .chatStream(systemPrompt: 'system', userMessage: 'question')
          .toList(),
      () => client,
    );

    expect(payload['thinking'], {'type': 'enabled'});
    expect(payload['reasoning_effort'], 'max');
  });

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
