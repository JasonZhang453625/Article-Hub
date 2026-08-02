import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memora/config/backend_config.dart';
import 'package:memora/data/services/auth_service.dart';
import 'package:memora/shared/providers/auth_provider.dart';

void main() {
  test('uses the API subdomain by default and builds auth URLs', () {
    expect(BackendConfig.baseUrl, 'https://api.memora.wang');
    expect(
      BackendConfig.uri('/auth/request-otp').toString(),
      'https://api.memora.wang/auth/request-otp',
    );
  });

  test('normalizes a stored Bearer prefix and validates UUID claims', () {
    final token = _jwt(
      sessionId: '11111111-1111-1111-1111-111111111111',
      deviceId: '22222222-2222-2222-2222-222222222222',
    );

    final session = AuthSession.fromJson(_sessionJson('  Bearer $token  '));

    expect(session.accessToken, token);
    expect(session.hasValidAccessToken, isTrue);
  });

  test('rejects a JWT with legacy non-UUID session claims', () {
    final token = _jwt(
      sessionId: 'legacy-session-id',
      deviceId: '22222222-2222-2222-2222-222222222222',
    );

    final session = AuthSession.fromJson(_sessionJson(token));

    expect(session.hasValidAccessToken, isFalse);
  });

  test('rejects a non-JWT access token', () {
    final session = AuthSession.fromJson(_sessionJson('old-token-format'));

    expect(session.hasValidAccessToken, isFalse);
  });

  test('classifies rejected auth responses for local session cleanup', () {
    expect(
      AuthService.isSessionRejected(
        const AuthApiException(
          'Invalid or expired bearer token',
          statusCode: 401,
        ),
      ),
      isTrue,
    );
    expect(
      AuthService.isSessionRejected(
        const AuthApiException('Internal server error', statusCode: 500),
      ),
      isFalse,
    );
  });

  test(
    'clears a persisted session when startup validation returns 401',
    () async {
      final fake = _FakeAuthService(
        loadedSession: AuthSession.fromJson(_sessionJson('old-token-format')),
        getMeError: const AuthApiException(
          'Invalid or expired bearer token',
          statusCode: 401,
        ),
      );
      final controller = AuthController(fake);
      addTearDown(controller.dispose);

      await fake.getMeCalled.future;
      await fake.clearCalled.future;
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.valueOrNull, isNull);
      expect(fake.localSessionCleared, isTrue);
    },
  );
}

Map<String, dynamic> _sessionJson(String accessToken) {
  return {
    'accessToken': accessToken,
    'refreshToken': 'refresh-token',
    'refreshTokenExpiresAt': null,
    'user': {
      'id': 'user-id',
      'email': 'user@example.com',
      'displayName': null,
      'status': 'active',
      'plan': 'free',
      'storageUsedBytes': '0',
    },
    'device': {
      'id': 'device-id',
      'userId': 'user-id',
      'deviceName': 'Test device',
      'platform': 'test',
      'appVersion': '1.0.0',
    },
  };
}

String _jwt({required String sessionId, required String deviceId}) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

  return '${encode({'alg': 'none', 'typ': 'JWT'})}.${encode({'sessionId': sessionId, 'deviceId': deviceId})}.signature';
}

class _FakeAuthService extends AuthService {
  final AuthSession? loadedSession;
  final Object? getMeError;
  final getMeCalled = Completer<void>();
  final clearCalled = Completer<void>();
  bool localSessionCleared = false;

  _FakeAuthService({this.loadedSession, this.getMeError});

  @override
  Future<AuthSession?> loadSession() async => loadedSession;

  @override
  Future<AuthSession?> getMe(AuthSession session) async {
    if (!getMeCalled.isCompleted) getMeCalled.complete();
    if (getMeError != null) throw getMeError!;
    return session;
  }

  @override
  Future<void> clearLocalSession() async {
    localSessionCleared = true;
    if (!clearCalled.isCompleted) clearCalled.complete();
  }
}
