import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/app_update_manifest.dart';

enum AppUpdateDownloadStatus { pending, running, paused, successful, failed }

class AppUpdateDownload {
  final int id;
  final String filePath;

  const AppUpdateDownload({required this.id, required this.filePath});
}

class AppUpdateDownloadSnapshot {
  final AppUpdateDownloadStatus status;
  final int downloadedBytes;
  final int totalBytes;
  final int? reason;

  const AppUpdateDownloadSnapshot({
    required this.status,
    required this.downloadedBytes,
    required this.totalBytes,
    this.reason,
  });

  double? get progress {
    if (totalBytes <= 0) return null;
    return (downloadedBytes / totalBytes).clamp(0, 1);
  }
}

abstract class AppUpdatePlatform {
  bool get isSupported;

  Future<AppUpdateDownload> enqueueDownload(
    AppUpdateManifest manifest,
    Uri url,
  );

  Future<AppUpdateDownloadSnapshot> queryDownload(int id);

  Future<void> cancelDownload(int id);

  Future<void> verifyUpdate(AppUpdateManifest manifest, String filePath);

  Future<bool> canRequestPackageInstalls();

  Future<void> openInstallPermissionSettings();

  Future<void> installUpdate(String filePath);
}

class MethodChannelAppUpdatePlatform implements AppUpdatePlatform {
  static const MethodChannel _channel = MethodChannel('app.memora/update');

  @override
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<AppUpdateDownload> enqueueDownload(
    AppUpdateManifest manifest,
    Uri url,
  ) async {
    _ensureSupported();
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'enqueueDownload',
      {'url': url.toString(), 'version': manifest.version},
    );
    final id = result?['id'];
    final filePath = result?['filePath'];
    if (id is! int || filePath is! String || filePath.isEmpty) {
      throw PlatformException(
        code: 'INVALID_DOWNLOAD',
        message: 'Android returned an invalid download record',
      );
    }
    return AppUpdateDownload(id: id, filePath: filePath);
  }

  @override
  Future<AppUpdateDownloadSnapshot> queryDownload(int id) async {
    _ensureSupported();
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'queryDownload',
      {'id': id},
    );
    final statusName = result?['status'] as String?;
    final status = AppUpdateDownloadStatus.values.firstWhere(
      (value) => value.name == statusName,
      orElse: () => AppUpdateDownloadStatus.failed,
    );
    return AppUpdateDownloadSnapshot(
      status: status,
      downloadedBytes: (result?['downloadedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (result?['totalBytes'] as num?)?.toInt() ?? -1,
      reason: (result?['reason'] as num?)?.toInt(),
    );
  }

  @override
  Future<void> cancelDownload(int id) async {
    _ensureSupported();
    await _channel.invokeMethod<void>('cancelDownload', {'id': id});
  }

  @override
  Future<void> verifyUpdate(AppUpdateManifest manifest, String filePath) async {
    _ensureSupported();
    await _channel.invokeMethod<void>('verifyUpdate', {
      'filePath': filePath,
      'expectedVersionCode': manifest.versionCode,
      'expectedSize': manifest.size,
      'expectedSha256': manifest.sha256,
    });
  }

  @override
  Future<bool> canRequestPackageInstalls() async {
    _ensureSupported();
    return await _channel.invokeMethod<bool>('canRequestPackageInstalls') ??
        false;
  }

  @override
  Future<void> openInstallPermissionSettings() async {
    _ensureSupported();
    await _channel.invokeMethod<void>('openInstallPermissionSettings');
  }

  @override
  Future<void> installUpdate(String filePath) async {
    _ensureSupported();
    await _channel.invokeMethod<void>('installUpdate', {'filePath': filePath});
  }

  void _ensureSupported() {
    if (!isSupported) {
      throw PlatformException(
        code: 'UNSUPPORTED_PLATFORM',
        message: 'Direct app updates are only supported on Android',
      );
    }
  }
}
