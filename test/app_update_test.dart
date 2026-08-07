import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:memora/data/models/app_update_manifest.dart';
import 'package:memora/data/services/app_update_platform.dart';
import 'package:memora/data/services/app_update_service.dart';
import 'package:memora/shared/providers/app_update_provider.dart';
import 'package:memora/shared/utils/app_version.dart';

void main() {
  group('release version mapping', () {
    test('maps 2.1.8 to Android versionCode 20108', () {
      expect(AppVersion.parse('2.1.8').versionCode, 20108);
    });

    test('rejects ambiguous three-digit minor or patch components', () {
      expect(() => AppVersion.parse('2.1.100').versionCode, throwsStateError);
    });
  });

  group('update manifest', () {
    test('parses the release contract', () {
      final manifest = AppUpdateManifest.fromJson(_manifestJson());

      expect(manifest.version, '2.1.8');
      expect(manifest.versionCode, 20108);
      expect(manifest.releaseNotes, ['In-app updates']);
      expect(manifest.downloadUrls, hasLength(2));
    });

    test('rejects a versionCode that does not match the version', () {
      expect(
        () => AppUpdateManifest.fromJson(_manifestJson()..['versionCode'] = 2),
        throwsFormatException,
      );
    });

    test('compares both the visible version and versionCode', () {
      final manifest = AppUpdateManifest.fromJson(_manifestJson());
      expect(
        AppUpdateCheck(
          currentVersion: '2.1.7',
          currentVersionCode: 20107,
          manifest: manifest,
        ).updateAvailable,
        isTrue,
      );
      expect(
        AppUpdateCheck(
          currentVersion: '2.1.8',
          currentVersionCode: 20108,
          manifest: manifest,
        ).updateAvailable,
        isFalse,
      );
    });
  });

  test('update service falls back to the GitHub manifest', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      if (requests == 1) return http.Response('unavailable', 503);
      return http.Response(
        jsonEncode(_manifestJson()),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final service = AppUpdateService(
      client: client,
      loadPackageInfo: () async => PackageInfo(
        appName: 'Memora',
        packageName: 'com.passagesapp.passages_aggregation_app',
        version: '2.1.7',
        buildNumber: '20107',
      ),
      manifestUrls: [
        Uri.parse('https://primary.example/latest.json'),
        Uri.parse('https://fallback.example/latest.json'),
      ],
    );

    final check = await service.check();

    expect(requests, 2);
    expect(check.updateAvailable, isTrue);
    expect(check.manifest.versionCode, 20108);
  });

  test('controller downloads, verifies, and starts installation', () async {
    final manifest = AppUpdateManifest.fromJson(_manifestJson());
    final platform = _FakeUpdatePlatform();
    final controller = AppUpdateController(
      checker: _FakeUpdateChecker(
        AppUpdateCheck(
          currentVersion: '2.1.7',
          currentVersionCode: 20107,
          manifest: manifest,
        ),
      ),
      platform: platform,
      pollInterval: Duration.zero,
    );

    expect((await controller.checkForUpdate()).phase, AppUpdatePhase.available);
    await controller.startUpdate();

    expect(platform.verified, isTrue);
    expect(platform.installed, isTrue);
    expect(controller.state.phase, AppUpdatePhase.installing);
  });

  test(
    'controller falls back when the primary APK fails verification',
    () async {
      final manifest = AppUpdateManifest.fromJson(_manifestJson());
      final platform = _FakeUpdatePlatform(failedVerifications: 1);
      final controller = AppUpdateController(
        checker: _FakeUpdateChecker(
          AppUpdateCheck(
            currentVersion: '2.1.7',
            currentVersionCode: 20107,
            manifest: manifest,
          ),
        ),
        platform: platform,
        pollInterval: Duration.zero,
      );

      await controller.checkForUpdate();
      await controller.startUpdate();

      expect(platform.enqueuedUrls, manifest.downloadUrls);
      expect(platform.verificationAttempts, 2);
      expect(platform.installed, isTrue);
    },
  );

  test(
    'controller resumes installation after unknown-source permission',
    () async {
      final manifest = AppUpdateManifest.fromJson(_manifestJson());
      final platform = _FakeUpdatePlatform(canInstall: false);
      final controller = AppUpdateController(
        checker: _FakeUpdateChecker(
          AppUpdateCheck(
            currentVersion: '2.1.7',
            currentVersionCode: 20107,
            manifest: manifest,
          ),
        ),
        platform: platform,
        pollInterval: Duration.zero,
      );

      await controller.checkForUpdate();
      await controller.startUpdate();
      expect(controller.state.phase, AppUpdatePhase.awaitingInstallPermission);

      platform.canInstall = true;
      await controller.handleAppResumed();
      expect(platform.installed, isTrue);
    },
  );

  test(
    'controller can retry after the system installer is dismissed',
    () async {
      final manifest = AppUpdateManifest.fromJson(_manifestJson());
      final platform = _FakeUpdatePlatform();
      final controller = AppUpdateController(
        checker: _FakeUpdateChecker(
          AppUpdateCheck(
            currentVersion: '2.1.7',
            currentVersionCode: 20107,
            manifest: manifest,
          ),
        ),
        platform: platform,
        pollInterval: Duration.zero,
      );

      await controller.checkForUpdate();
      await controller.startUpdate();
      expect(controller.state.phase, AppUpdatePhase.installing);

      await controller.handleAppResumed();
      expect(controller.state.phase, AppUpdatePhase.available);
    },
  );
}

Map<String, dynamic> _manifestJson() => {
  'schemaVersion': 1,
  'platform': 'android',
  'channel': 'stable',
  'version': '2.1.8',
  'versionCode': 20108,
  'publishedAt': '2026-08-08T00:00:00Z',
  'size': 100,
  'sha256': 'a' * 64,
  'releaseNotes': ['In-app updates'],
  'mandatory': false,
  'serverUrl': 'https://primary.example/Memora-v2.1.8.apk',
  'githubUrl': 'https://fallback.example/app-release.apk',
};

class _FakeUpdateChecker implements AppUpdateChecker {
  final AppUpdateCheck result;

  _FakeUpdateChecker(this.result);

  @override
  Future<AppUpdateCheck> check() async => result;
}

class _FakeUpdatePlatform implements AppUpdatePlatform {
  bool canInstall;
  int failedVerifications;
  bool verified = false;
  bool installed = false;
  int verificationAttempts = 0;
  final List<Uri> enqueuedUrls = [];

  _FakeUpdatePlatform({this.canInstall = true, this.failedVerifications = 0});

  @override
  bool get isSupported => true;

  @override
  Future<void> cancelDownload(int id) async {}

  @override
  Future<bool> canRequestPackageInstalls() async => canInstall;

  @override
  Future<AppUpdateDownload> enqueueDownload(
    AppUpdateManifest manifest,
    Uri url,
  ) async {
    enqueuedUrls.add(url);
    return const AppUpdateDownload(id: 1, filePath: '/updates/memora.apk');
  }

  @override
  Future<void> installUpdate(String filePath) async {
    installed = true;
  }

  @override
  Future<void> openInstallPermissionSettings() async {}

  @override
  Future<AppUpdateDownloadSnapshot> queryDownload(int id) async {
    return const AppUpdateDownloadSnapshot(
      status: AppUpdateDownloadStatus.successful,
      downloadedBytes: 100,
      totalBytes: 100,
    );
  }

  @override
  Future<void> verifyUpdate(AppUpdateManifest manifest, String filePath) async {
    verificationAttempts++;
    if (failedVerifications > 0) {
      failedVerifications--;
      throw StateError('corrupt APK');
    }
    verified = true;
  }
}
