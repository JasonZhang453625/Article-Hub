import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:memora/data/services/auth_service.dart';
import 'package:memora/data/services/conversation_feedback_service.dart';

AuthSession testSession() {
  final payload = base64Url
      .encode(
        utf8.encode(
          jsonEncode({
            'sessionId': '11111111-1111-4111-8111-111111111111',
            'deviceId': '22222222-2222-4222-8222-222222222222',
          }),
        ),
      )
      .replaceAll('=', '');
  return AuthSession(
    accessToken: 'header.$payload.signature',
    refreshToken: 'refresh-token',
    refreshTokenExpiresAt: null,
    user: const AuthUser(
      id: 'user-1',
      email: 'test@example.com',
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
      appVersion: null,
    ),
  );
}

void main() {
  test('uploads only account-safe conversation feedback fields', () async {
    final session = testSession();
    http.Request? sent;
    final client = MockClient((request) async {
      sent = request;
      return http.Response(
        jsonEncode({
          'messageId': 'message/1',
          'feedback': 1,
          'updatedAt': '2026-08-09T00:00:00.000Z',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final service = ConversationFeedbackService(
      getSession: () => session,
      refreshSession: () async => session,
      client: client,
    );

    await service.submit(
      messageId: 'message/1',
      threadId: 'thread-1',
      feedback: 1,
      retrievalLogId: 'log-1',
      method: 'vector',
      isNoResult: false,
    );

    expect(sent?.method, 'PUT');
    expect(sent?.url.path, '/feedback/conversations/message%2F1');
    final body = jsonDecode(sent!.body) as Map<String, dynamic>;
    expect(body, {
      'threadId': 'thread-1',
      'feedback': 1,
      'retrievalLogId': 'log-1',
      'method': 'vector',
      'isNoResult': false,
    });
    expect(body.containsKey('query'), isFalse);
    expect(body.containsKey('answer'), isFalse);
    service.dispose();
  });

  test('does not upload invalid feedback values', () async {
    var requests = 0;
    final service = ConversationFeedbackService(
      getSession: testSession,
      refreshSession: () async => testSession(),
      client: MockClient((_) async {
        requests++;
        return http.Response('', 200);
      }),
    );

    await service.submit(
      messageId: 'message-1',
      threadId: 'thread-1',
      feedback: 0,
    );

    expect(requests, 0);
    service.dispose();
  });
}
