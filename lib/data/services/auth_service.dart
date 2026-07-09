import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../../config/backend_config.dart';

class AuthService {
  static const String _boxName = 'auth_session';
  static const String _sessionKey = 'session';

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

  Future<AuthSession?> loadSession() async {
    final box = await _sessionBox();
    final raw = box.get(_sessionKey);
    if (raw is! Map) return null;
    return AuthSession.fromJson(Map<String, dynamic>.from(raw));
  }

  Future<void> sendOtp(String email) async {
    if (!BackendConfig.isConfigured) throw BackendNotConfiguredException();

    final response = await http
        .post(
          BackendConfig.uri('/auth/request-otp'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'email': email.trim(), 'purpose': 'login'}),
        )
        .timeout(const Duration(seconds: 20));
    _throwIfFailed(response);
  }

  Future<AuthSession> verifyOtp(String email, String token) async {
    if (!BackendConfig.isConfigured) throw BackendNotConfiguredException();

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
    await _saveSession(session);
    return session;
  }

  Future<AuthSession> refresh(AuthSession session) async {
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
    await _saveSession(refreshed);
    return refreshed;
  }

  Future<AuthSession?> getMe(AuthSession session) async {
    final response = await _authorizedGet('/me', session);
    if (response.statusCode == 401) {
      final refreshed = await refresh(session);
      final retry = await _authorizedGet('/me', refreshed);
      _throwIfFailed(retry);
      return _mergeMe(refreshed, _decodeObject(retry));
    }
    _throwIfFailed(response);
    return _mergeMe(session, _decodeObject(response));
  }

  Future<void> signOut(AuthSession? session) async {
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
    final box = await _sessionBox();
    await box.delete(_sessionKey);
  }

  Future<void> _saveSession(AuthSession session) async {
    final box = await _sessionBox();
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

  AuthSession _mergeMe(AuthSession session, Map<String, dynamic> json) {
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
    unawaited(_saveSession(merged));
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
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) {
        message = (decoded['message'] ?? decoded['error'] ?? message)
            .toString();
      }
    } catch (_) {
      if (response.body.isNotEmpty) message = response.body;
    }
    throw AuthApiException(message, statusCode: response.statusCode);
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
    return AuthSession(
      accessToken: json['accessToken'] as String,
      refreshToken: json['refreshToken'] as String,
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
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      refreshTokenExpiresAt:
          refreshTokenExpiresAt ?? this.refreshTokenExpiresAt,
      user: user ?? this.user,
      device: device ?? this.device,
    );
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

  const AuthApiException(this.message, {this.statusCode});

  @override
  String toString() => message;
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
