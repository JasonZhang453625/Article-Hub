import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../models/app_update_manifest.dart';
import '../../shared/utils/app_version.dart';

abstract class AppUpdateChecker {
  Future<AppUpdateCheck> check();
}

class AppUpdateService implements AppUpdateChecker {
  static final Uri primaryManifestUrl = Uri.parse(
    'https://api.memora.wang/downloads/android/latest.json',
  );
  static final Uri fallbackManifestUrl = Uri.parse(
    'https://github.com/JasonZhang453625/Article-Hub/'
    'releases/latest/download/latest.json',
  );

  final http.Client _client;
  final bool _ownsClient;
  final Future<PackageInfo> Function() _loadPackageInfo;
  final List<Uri> manifestUrls;
  final Duration timeout;

  AppUpdateService({
    http.Client? client,
    Future<PackageInfo> Function()? loadPackageInfo,
    List<Uri>? manifestUrls,
    this.timeout = const Duration(seconds: 12),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _loadPackageInfo = loadPackageInfo ?? PackageInfo.fromPlatform,
       manifestUrls =
           manifestUrls ?? <Uri>[primaryManifestUrl, fallbackManifestUrl];

  @override
  Future<AppUpdateCheck> check() async {
    final packageInfo = await _loadPackageInfo();
    Object? lastError;
    for (final url in manifestUrls) {
      try {
        final response = await _client
            .get(
              url,
              headers: const {
                'Accept': 'application/json',
                'Cache-Control': 'no-cache',
              },
            )
            .timeout(timeout);
        if (response.statusCode != 200) {
          throw AppUpdateException('manifest-http-${response.statusCode}');
        }
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Update manifest must be an object');
        }
        final manifest = AppUpdateManifest.fromJson(decoded);
        if (manifest.platform != 'android' || manifest.channel != 'stable') {
          throw const FormatException('Unsupported update manifest channel');
        }
        final parsedBuildNumber = int.tryParse(packageInfo.buildNumber.trim());
        final currentVersionCode =
            parsedBuildNumber ??
            AppVersion.parse(packageInfo.version).versionCode;
        return AppUpdateCheck(
          currentVersion: packageInfo.version,
          currentVersionCode: currentVersionCode,
          manifest: manifest,
        );
      } catch (error) {
        lastError = error;
      }
    }
    throw AppUpdateException('manifest-unavailable', cause: lastError);
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}

class AppUpdateException implements Exception {
  final String code;
  final Object? cause;

  const AppUpdateException(this.code, {this.cause});

  @override
  String toString() => 'AppUpdateException($code)';
}
