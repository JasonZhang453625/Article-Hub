import '../../shared/utils/app_version.dart';

class AppUpdateManifest {
  final int schemaVersion;
  final String platform;
  final String channel;
  final String version;
  final int versionCode;
  final DateTime? publishedAt;
  final int size;
  final String sha256;
  final List<String> releaseNotes;
  final bool mandatory;
  final Uri serverUrl;
  final Uri githubUrl;

  const AppUpdateManifest({
    required this.schemaVersion,
    required this.platform,
    required this.channel,
    required this.version,
    required this.versionCode,
    required this.publishedAt,
    required this.size,
    required this.sha256,
    required this.releaseNotes,
    required this.mandatory,
    required this.serverUrl,
    required this.githubUrl,
  });

  factory AppUpdateManifest.fromJson(Map<String, dynamic> json) {
    final version = _requiredString(json, 'version');
    final parsedVersion = AppVersion.parse(version);
    final mappedVersionCode = parsedVersion.versionCode;
    final rawVersionCode = json['versionCode'];
    final versionCode = rawVersionCode is num
        ? rawVersionCode.toInt()
        : mappedVersionCode;
    if (versionCode != mappedVersionCode) {
      throw const FormatException(
        'Update manifest versionCode does not match the version mapping',
      );
    }

    final sha256 = _requiredString(json, 'sha256').toLowerCase();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw const FormatException('Invalid update manifest SHA-256');
    }

    final sizeValue = json['size'];
    if (sizeValue is! num || sizeValue.toInt() <= 0) {
      throw const FormatException('Invalid update manifest file size');
    }

    final serverUrl = _requiredHttpsUri(json, 'serverUrl');
    final githubUrl = _requiredHttpsUri(json, 'githubUrl');
    final notesValue = json['releaseNotes'];
    final releaseNotes = notesValue is List
        ? notesValue
              .whereType<String>()
              .map((note) => note.trim())
              .where((note) => note.isNotEmpty)
              .toList(growable: false)
        : const <String>[];

    final publishedAtValue = json['publishedAt'];
    return AppUpdateManifest(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
      platform: (json['platform'] as String?)?.trim() ?? 'android',
      channel: (json['channel'] as String?)?.trim() ?? 'stable',
      version: version,
      versionCode: versionCode,
      publishedAt: publishedAtValue is String
          ? DateTime.tryParse(publishedAtValue)
          : null,
      size: sizeValue.toInt(),
      sha256: sha256,
      releaseNotes: releaseNotes,
      mandatory: json['mandatory'] == true,
      serverUrl: serverUrl,
      githubUrl: githubUrl,
    );
  }

  List<Uri> get downloadUrls =>
      serverUrl == githubUrl ? <Uri>[serverUrl] : <Uri>[serverUrl, githubUrl];

  static String _requiredString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('Missing update manifest field: $key');
    }
    return value.trim();
  }

  static Uri _requiredHttpsUri(Map<String, dynamic> json, String key) {
    final value = Uri.tryParse(_requiredString(json, key));
    if (value == null || value.scheme != 'https' || value.host.isEmpty) {
      throw FormatException('Invalid HTTPS update URL: $key');
    }
    return value;
  }
}

class AppUpdateCheck {
  final String currentVersion;
  final int currentVersionCode;
  final AppUpdateManifest manifest;

  const AppUpdateCheck({
    required this.currentVersion,
    required this.currentVersionCode,
    required this.manifest,
  });

  bool get updateAvailable {
    final remote = AppVersion.parse(manifest.version);
    final current = AppVersion.parse(currentVersion);
    final versionComparison = remote.compareTo(current);
    if (versionComparison != 0) return versionComparison > 0;
    return manifest.versionCode > currentVersionCode;
  }
}
