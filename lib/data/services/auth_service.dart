import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../../config/backend_config.dart';

final RegExp _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

String _normalizeAccessToken(String value) {
  var token = value.trim();
  token = token.replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '');
  token = token.trim();
  if (token.isEmpty) throw const FormatException('Empty access token.');
  return token;
}

class AuthService {
  static const String _boxName = 'auth_session';
  static const String _sessionKey = 'session';

  // Refresh-token rotation makes a refresh token single-use on many
  // backends. Keep concurrent callers on the same refresh operation so a
  // cold-start validation and an automatic sync cannot invalidate each
  // other's token.
  Future<AuthSession>? _refreshInFlight;
  String? _refreshTokenInFlight;
  int _sessionGeneration = 0;

  Box<dynamic>? _box;

  Future<Box<dynamic>> _sessionBox() async {
    try {
      await Hive.initFlutter();
    } catch (_) {
      // Hive may already be initialized by the app repository providers.
    }
    return _box ??= await Hive.openBox<dynamic>(_boxName);
  }

  bool get isAvailable => BackendConfig.isConfigured;

  static bool isSessionRejected(AuthApiException error) {
    final code = error.code?.trim().toUpperCase();
    if (code != null && _terminalSessionErrorCodes.contains(code)) {
      return true;
    }

    // Older backend versions may not return a structured error code. Accept
    // only an explicitly token/session-related terminal message in that case;
    // never treat an unrelated 400/403 as a logout instruction.
    final message = error.message.toLowerCase();
    final mentionsAuth =
        message.contains('token') || message.contains('session');
    final mentionsTerminalState = RegExp(
      r'\b(expired|invalid|revoked|revocation|not found)\b',
    ).hasMatch(message);
    final statusCode = error.statusCode;
    if ((statusCode == 400 || statusCode == 403) &&
        mentionsAuth &&
        mentionsTerminalState &&
        message != 'invalid server session response.') {
      return true;
    }

    // A refresh request that receives 401 has been rejected by the auth
    // server. Other 4xx responses are deliberately kept retryable: a generic
    // 400/403 can be caused by a deploy, proxy, or device-policy issue and
    // must not silently log the user out.
    return error.statusCode == 401;
  }

  static const Set<String> _terminalSessionErrorCodes = {
    'DEVICE_REVOKED',
    'INVALID_REFRESH_TOKEN',
    'INVALID_SESSION',
    'REFRESH_TOKEN_EXPIRED',
    'REFRESH_TOKEN_REVOKED',
    'SESSION_EXPIRED',
    'SESSION_REVOKED',
  };

  Future<AuthSession?> loadSession() async {
    final box = await _sessionBox();
    final raw = box.get(_sessionKey);
    if (raw is! Map) return null;
    try {
      return AuthSession.fromJson(Map<String, dynamic>.from(raw));
    } catch (_) {
      // A session written by an older build must not poison every future
      // startup. The user's articles remain in their other Hive boxes.
      await clearLocalSession();
      return null;
    }
  }

  Future<void> sendOtp(String email) async {
    if (!BackendConfig.isConfigured) throw BackendNotConfiguredException();

    final uri = BackendConfig.uri('/auth/request-otp');
    debugPrint('[Auth] sendOtp -> $uri');
    try {
      final response = await http
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'email': email.trim(), 'purpose': 'login'}),
          )
          .timeout(const Duration(seconds: 20));
      _throwIfFailed(response);
    } catch (e, st) {
      debugPrint('[Auth] sendOtp ERROR: $e\n$st');
      rethrow;
    }
  }

  Future<AuthSession> verifyOtp(String email, String token) async {
    if (!BackendConfig.isConfigured) throw BackendNotConfiguredException();
    final generation = _beginSessionChange();

    final device = await _deviceInfo();
    final response = await http
        .post(
          BackendConfig.uri('/auth/verify-otp'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'email': email.trim(),
            'otp': token.replaceAll(RegExp(r'\s+'), ''),
            'deviceName': device.name,
            'platform': device.platform,
            'appVersion': device.appVersion,
          }),
        )
        .timeout(const Duration(seconds: 20));
    _throwIfFailed(response);

    final session = AuthSession.fromJson(_decodeObject(response));
    _ensureUsableSession(session);
    await _saveSession(session, expectedGeneration: generation);
    return session;
  }

  Future<AuthSession> refresh(AuthSession session) {
    final generation = _sessionGeneration;
    final refreshToken = session.refreshToken;
    final inFlight = _refreshInFlight;
    if (inFlight != null && _refreshTokenInFlight == refreshToken) {
      return inFlight;
    }

    late final Future<AuthSession> tracked;
    tracked = _refreshOnce(session, generation).whenComplete(() {
      if (identical(_refreshInFlight, tracked)) {
        _refreshInFlight = null;
        _refreshTokenInFlight = null;
      }
    });
    _refreshInFlight = tracked;
    _refreshTokenInFlight = refreshToken;
    return tracked;
  }

  Future<AuthSession> _refreshOnce(AuthSession session, int generation) async {
    final response = await http
        .post(
          BackendConfig.uri('/auth/refresh'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'refreshToken': session.refreshToken}),
        )
        .timeout(const Duration(seconds: 20));
    _throwIfFailed(response);

    final json = _decodeObject(response);
    final refreshed = session.copyWith(
      accessToken: json['accessToken'] as String,
      refreshToken: json['refreshToken'] as String,
      refreshTokenExpiresAt: json['refreshTokenExpiresAt'] as String?,
    );
    _ensureUsableSession(refreshed);
    await _replaceSession(refreshed, expectedGeneration: generation);
    return refreshed;
  }

  Future<AuthSession?> getMe(AuthSession session) async {
    var generation = _sessionGeneration;
    var current = session;
    // Avoid sending an obviously stale token from an older client build. A
    // valid refresh token can still recover the session without a full login.
    if (!current.hasValidAccessToken) {
      current = await refresh(current);
      generation += 1;
    }

    final response = await _authorizedGet('/me', current);
    if (response.statusCode == 401) {
      final refreshed = await refresh(current);
      generation += 1;
      final retry = await _authorizedGet('/me', refreshed);
      _throwIfFailed(retry);
      return _mergeMe(
        refreshed,
        _decodeObject(retry),
        expectedGeneration: generation,
      );
    }
    _throwIfFailed(response);
    return _mergeMe(
      current,
      _decodeObject(response),
      expectedGeneration: generation,
    );
  }

  Future<void> clearLocalSession() async {
    _beginSessionChange();
    final box = await _sessionBox();
    await box.delete(_sessionKey);
  }

  Future<void> signOut(AuthSession? session) async {
    // Invalidate local credentials before the network request. Any refresh or
    // /me request that finishes later observes a stale generation and cannot
    // write its session back to Hive.
    await clearLocalSession();
    if (session != null) {
      try {
        await http
            .post(
              BackendConfig.uri('/auth/logout'),
              headers: {
                'Authorization': 'Bearer ${session.accessToken}',
                'Content-Type': 'application/json',
              },
              body: '{}',
            )
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        // Local sign-out should still succeed when the network is unavailable.
      }
    }
  }

  int _beginSessionChange() {
    _sessionGeneration += 1;
    _refreshInFlight = null;
    _refreshTokenInFlight = null;
    return _sessionGeneration;
  }

  Future<void> _saveSession(
    AuthSession session, {
    int? expectedGeneration,
  }) async {
    final box = await _sessionBox();
    if (expectedGeneration != null &&
        expectedGeneration != _sessionGeneration) {
      throw const AuthSessionChangedException();
    }
    await box.put(_sessionKey, session.toJson());
  }

  Future<void> _replaceSession(
    AuthSession session, {
    required int expectedGeneration,
  }) async {
    final box = await _sessionBox();
    if (expectedGeneration != _sessionGeneration) {
      throw const AuthSessionChangedException();
    }

    // Token rotation creates a new session generation. Older /me responses
    // can still update the UI if left unchecked, so invalidate them before the
    // replacement reaches persistent storage.
    _sessionGeneration += 1;
    await box.put(_sessionKey, session.toJson());
  }

  Future<http.Response> _authorizedGet(String path, AuthSession session) {
    return http
        .get(
          BackendConfig.uri(path),
          headers: {'Authorization': 'Bearer ${session.accessToken}'},
        )
        .timeout(const Duration(seconds: 20));
  }

  Future<AuthSession> _mergeMe(
    AuthSession session,
    Map<String, dynamic> json, {
    required int expectedGeneration,
  }) async {
    final userJson = json['user'];
    final deviceJson = json['device'];
    final merged = session.copyWith(
      user: userJson is Map
          ? AuthUser.fromJson(Map<String, dynamic>.from(userJson))
          : session.user,
      device: deviceJson is Map
          ? AuthDevice.fromJson(Map<String, dynamic>.from(deviceJson))
          : session.device,
    );
    await _saveSession(merged, expectedGeneration: expectedGeneration);
    return merged;
  }

  Map<String, dynamic> _decodeObject(http.Response response) {
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is Map<String, dynamic>) return decoded;
    throw const AuthApiException('Invalid server response.');
  }

  void _throwIfFailed(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;

    var message = 'Request failed with status ${response.statusCode}.';
    String? code;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) {
        message = (decoded['message'] ?? decoded['error'] ?? message)
            .toString();
        final rawCode =
            decoded['code'] ??
            decoded['errorCode'] ??
            (decoded['error'] is String ? decoded['error'] : null);
        if (rawCode is String && rawCode.trim().isNotEmpty) {
          code = rawCode.trim();
        }
      }
    } catch (_) {
      if (response.body.isNotEmpty) message = response.body;
    }
    throw AuthApiException(
      message,
      statusCode: response.statusCode,
      code: code,
    );
  }

  void _ensureUsableSession(AuthSession session) {
    if (!session.hasValidAccessToken || session.refreshToken.isEmpty) {
      throw const AuthApiException('Invalid server session response.');
    }
  }

  Future<_DeviceInfo> _deviceInfo() async {
    final package = await PackageInfo.fromPlatform();
    return _DeviceInfo(
      name: _deviceName(),
      platform: _platformName(),
      appVersion: package.version,
    );
  }

  String _platformName() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  }

  String _deviceName() {
    if (kIsWeb) return 'Memora Web';
    return 'Memora ${_platformName()}';
  }
}

class AuthSession {
  final String accessToken;
  final String refreshToken;
  final String? refreshTokenExpiresAt;
  final AuthUser user;
  final AuthDevice device;

  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.refreshTokenExpiresAt,
    required this.user,
    required this.device,
  });

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    final rawAccessToken = json['accessToken'];
    final rawRefreshToken = json['refreshToken'];
    if (rawAccessToken is! String ||
        rawRefreshToken is! String ||
        rawRefreshToken.trim().isEmpty) {
      throw const FormatException('Invalid auth session tokens.');
    }

    return AuthSession(
      accessToken: _normalizeAccessToken(rawAccessToken),
      refreshToken: rawRefreshToken.trim(),
      refreshTokenExpiresAt: json['refreshTokenExpiresAt'] as String?,
      user: AuthUser.fromJson(Map<String, dynamic>.from(json['user'] as Map)),
      device: AuthDevice.fromJson(
        Map<String, dynamic>.from(json['device'] as Map),
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'refreshTokenExpiresAt': refreshTokenExpiresAt,
      'user': user.toJson(),
      'device': device.toJson(),
    };
  }

  AuthSession copyWith({
    String? accessToken,
    String? refreshToken,
    String? refreshTokenExpiresAt,
    AuthUser? user,
    AuthDevice? device,
  }) {
    return AuthSession(
      accessToken: accessToken == null
          ? this.accessToken
          : _normalizeAccessToken(accessToken),
      refreshToken: refreshToken == null
          ? this.refreshToken
          : refreshToken.trim(),
      refreshTokenExpiresAt:
          refreshTokenExpiresAt ?? this.refreshTokenExpiresAt,
      user: user ?? this.user,
      device: device ?? this.device,
    );
  }

  /// Checks only the JWT shape and the UUID claims required by the backend.
  /// Signature verification remains the server's responsibility.
  bool get hasValidAccessToken {
    final parts = accessToken.split('.');
    if (parts.length != 3) return false;

    try {
      final decoded = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (decoded is! Map) return false;
      final claims = Map<String, dynamic>.from(decoded);
      final sessionId = claims['sessionId'];
      final deviceId = claims['deviceId'];
      return sessionId is String &&
          deviceId is String &&
          _uuidPattern.hasMatch(sessionId) &&
          _uuidPattern.hasMatch(deviceId);
    } catch (_) {
      return false;
    }
  }
}

class AuthUser {
  final String id;
  final String email;
  final String? displayName;
  final String status;
  final String plan;
  final String storageUsedBytes;

  const AuthUser({
    required this.id,
    required this.email,
    required this.displayName,
    required this.status,
    required this.plan,
    required this.storageUsedBytes,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      id: json['id'] as String,
      email: json['email'] as String,
      displayName: json['displayName'] as String?,
      status: (json['status'] ?? 'active').toString(),
      plan: (json['plan'] ?? 'free').toString(),
      storageUsedBytes: (json['storageUsedBytes'] ?? '0').toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      'displayName': displayName,
      'status': status,
      'plan': plan,
      'storageUsedBytes': storageUsedBytes,
    };
  }
}

class AuthDevice {
  final String id;
  final String userId;
  final String deviceName;
  final String platform;
  final String? appVersion;

  const AuthDevice({
    required this.id,
    required this.userId,
    required this.deviceName,
    required this.platform,
    required this.appVersion,
  });

  factory AuthDevice.fromJson(Map<String, dynamic> json) {
    return AuthDevice(
      id: json['id'] as String,
      userId: json['userId'] as String,
      deviceName: (json['deviceName'] ?? '').toString(),
      platform: (json['platform'] ?? '').toString(),
      appVersion: json['appVersion'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'userId': userId,
      'deviceName': deviceName,
      'platform': platform,
      'appVersion': appVersion,
    };
  }
}

class AuthApiException implements Exception {
  final String message;
  final int? statusCode;
  final String? code;

  const AuthApiException(this.message, {this.statusCode, this.code});

  @override
  String toString() => message;
}

class AuthSessionChangedException implements Exception {
  const AuthSessionChangedException();

  @override
  String toString() => 'The active auth session changed.';
}

class BackendNotConfiguredException implements Exception {
  @override
  String toString() => 'Memora backend is not configured';
}

class _DeviceInfo {
  final String name;
  final String platform;
  final String appVersion;

  const _DeviceInfo({
    required this.name,
    required this.platform,
    required this.appVersion,
  });
}
