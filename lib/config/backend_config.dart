import 'package:flutter/foundation.dart';

class BackendConfig {
  static const String baseUrl = String.fromEnvironment(
    'MEMORA_API_BASE_URL',
    defaultValue: 'https://api.memora.wang',
  );

  static bool get isConfigured => baseUrl.trim().isNotEmpty;

  static Uri uri(String path) {
    final normalizedBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$normalizedBase$normalizedPath');
  }

  static void validate() {
    if (!isConfigured && kDebugMode) {
      debugPrint(
        'Memora backend not configured. Set MEMORA_API_BASE_URL via --dart-define.',
      );
    }
  }
}
