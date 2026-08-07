import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memora/data/services/auth_service.dart';
import 'package:memora/data/services/hosted_ai_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('routes hosted chat and summary to separate backend purposes', () async {
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add(request.url.path);
      final summary = request.url.path.contains('/summary/');
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content': summary
                    ? jsonEncode({
                        'schemaVersion': 1,
                        'title': 'T',
                        'tags': ['A', 'B'],
                        'overview': 'O',
                        'keyPoints': [
                          {'topic': 'K', 'content': 'C'},
                        ],
                        'conclusion': 'Done',
                      })
                    : 'chat answer',
              },
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
    final summary = HostedAiService(
      getSession: () => session,
      refreshSession: () async => null,
      model: 'mimo-v2.5-pro',
      purpose: HostedAiPurpose.summary,
    );

    await http.runWithClient(() async {
      expect(
        await chat.chat(systemPrompt: 'S', userMessage: 'Q'),
        'chat answer',
      );
      expect((await summary.summarizeWithTitle('T', 'Body')).memory, isNotNull);
    }, () => client);

    expect(paths, [
      '/ai/chat/v1/chat/completions',
      '/ai/summary/v1/chat/completions',
    ]);
  });

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
