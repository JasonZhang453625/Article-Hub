/// Central policy for data that may cross or support the account-sync
/// boundary.
///
/// Provider credentials remain device-local. Explicit local backups use a
/// separate serialization path and are intentionally outside this policy.
class SyncPayloadPolicy {
  static const String appSettingsCollection = 'app_settings';

  static const Set<String> providerSecretKeys = {
    'aiApiKey',
    'chatAiApiKey',
    'imageAiApiKey',
    'embeddingApiKey',
    'tavilyApiKey',
  };

  const SyncPayloadPolicy._();

  static Map<String, dynamic>? sanitize(
    String collection,
    Map<String, dynamic>? payload,
  ) {
    if (payload == null) return null;
    if (collection != appSettingsCollection) {
      return Map<String, dynamic>.from(payload);
    }
    return _sanitizeMap(payload);
  }

  static bool containsSecrets(
    String collection,
    Map<String, dynamic>? payload,
  ) {
    if (collection != appSettingsCollection || payload == null) return false;
    return _containsSecrets(payload);
  }

  static List<String> sanitizeChangedPaths(
    String collection,
    Iterable<String> paths,
  ) {
    if (collection != appSettingsCollection) return List.of(paths);
    return paths
        .where(
          (path) => !providerSecretKeys.any((key) => _hasPathKey(path, key)),
        )
        .toList(growable: false);
  }

  static Map<String, dynamic> _sanitizeMap(Map<dynamic, dynamic> value) {
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String || providerSecretKeys.contains(key)) continue;
      result[key] = _sanitizeValue(entry.value);
    }
    return result;
  }

  static dynamic _sanitizeValue(dynamic value) {
    if (value is Map) return _sanitizeMap(value);
    if (value is List) {
      return value.map<dynamic>(_sanitizeValue).toList(growable: false);
    }
    return value;
  }

  static bool _containsSecrets(dynamic value) {
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key is String && providerSecretKeys.contains(entry.key)) {
          return true;
        }
        if (_containsSecrets(entry.value)) return true;
      }
    } else if (value is List) {
      return value.any(_containsSecrets);
    }
    return false;
  }

  static bool _hasPathKey(String path, String key) {
    return path.split(RegExp(r'[^A-Za-z0-9_]')).contains(key);
  }
}
