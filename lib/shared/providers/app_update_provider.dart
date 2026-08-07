import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../data/models/app_update_manifest.dart';
import '../../data/services/app_update_platform.dart';
import '../../data/services/app_update_service.dart';

final packageInfoProvider = FutureProvider<PackageInfo>((ref) {
  return PackageInfo.fromPlatform();
});

final appUpdateServiceProvider = Provider<AppUpdateService>((ref) {
  final service = AppUpdateService(
    loadPackageInfo: () => ref.read(packageInfoProvider.future),
  );
  ref.onDispose(service.dispose);
  return service;
});

final appUpdatePlatformProvider = Provider<AppUpdatePlatform>((ref) {
  return MethodChannelAppUpdatePlatform();
});

final appUpdateControllerProvider =
    StateNotifierProvider<AppUpdateController, AppUpdateState>((ref) {
      return AppUpdateController(
        checker: ref.read(appUpdateServiceProvider),
        platform: ref.read(appUpdatePlatformProvider),
      );
    });

enum AppUpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  verifying,
  awaitingInstallPermission,
  installing,
  failed,
}

class AppUpdateState {
  final AppUpdatePhase phase;
  final AppUpdateCheck? check;
  final double? downloadProgress;
  final String? errorCode;

  const AppUpdateState({
    this.phase = AppUpdatePhase.idle,
    this.check,
    this.downloadProgress,
    this.errorCode,
  });

  AppUpdateState copyWith({
    AppUpdatePhase? phase,
    AppUpdateCheck? check,
    double? downloadProgress,
    bool clearDownloadProgress = false,
    String? errorCode,
    bool clearError = false,
  }) {
    return AppUpdateState(
      phase: phase ?? this.phase,
      check: check ?? this.check,
      downloadProgress: clearDownloadProgress
          ? null
          : downloadProgress ?? this.downloadProgress,
      errorCode: clearError ? null : errorCode ?? this.errorCode,
    );
  }
}

class AppUpdateController extends StateNotifier<AppUpdateState> {
  final AppUpdateChecker _checker;
  final AppUpdatePlatform _platform;
  final Duration _pollInterval;
  bool _disposed = false;
  int? _activeDownloadId;
  String? _downloadedFilePath;

  AppUpdateController({
    required AppUpdateChecker checker,
    required AppUpdatePlatform platform,
    Duration pollInterval = const Duration(milliseconds: 500),
  }) : _checker = checker,
       _platform = platform,
       _pollInterval = pollInterval,
       super(const AppUpdateState());

  Future<AppUpdateState> checkForUpdate() async {
    if (!_platform.isSupported) {
      state = const AppUpdateState(
        phase: AppUpdatePhase.failed,
        errorCode: 'unsupported-platform',
      );
      return state;
    }
    state = const AppUpdateState(phase: AppUpdatePhase.checking);
    try {
      final check = await _checker.check();
      if (_disposed) return state;
      state = AppUpdateState(
        phase: check.updateAvailable
            ? AppUpdatePhase.available
            : AppUpdatePhase.upToDate,
        check: check,
      );
    } catch (_) {
      if (!_disposed) {
        state = const AppUpdateState(
          phase: AppUpdatePhase.failed,
          errorCode: 'check-failed',
        );
      }
    }
    return state;
  }

  Future<void> startUpdate() async {
    final check = state.check;
    if (check == null ||
        !check.updateAvailable ||
        state.phase == AppUpdatePhase.downloading ||
        state.phase == AppUpdatePhase.verifying ||
        state.phase == AppUpdatePhase.installing) {
      return;
    }

    Object? lastError;
    for (final url in check.manifest.downloadUrls) {
      if (_disposed) return;
      try {
        await _downloadAndInstall(check, url);
        return;
      } catch (error) {
        lastError = error;
        await _cancelActiveDownload();
      }
    }
    if (!_disposed) {
      final errorCode = lastError is AppUpdateException
          ? lastError.code
          : 'download-failed';
      state = state.copyWith(
        phase: AppUpdatePhase.failed,
        errorCode: errorCode,
        clearDownloadProgress: true,
      );
    }
    if (lastError == null) return;
  }

  Future<void> _downloadAndInstall(AppUpdateCheck check, Uri url) async {
    state = state.copyWith(
      phase: AppUpdatePhase.downloading,
      downloadProgress: 0,
      clearError: true,
    );
    final download = await _platform.enqueueDownload(check.manifest, url);
    _activeDownloadId = download.id;
    _downloadedFilePath = download.filePath;

    while (!_disposed) {
      final snapshot = await _platform.queryDownload(download.id);
      switch (snapshot.status) {
        case AppUpdateDownloadStatus.pending:
        case AppUpdateDownloadStatus.running:
        case AppUpdateDownloadStatus.paused:
          state = state.copyWith(
            phase: AppUpdatePhase.downloading,
            downloadProgress: snapshot.progress,
          );
          await Future<void>.delayed(_pollInterval);
          continue;
        case AppUpdateDownloadStatus.successful:
          _activeDownloadId = null;
          await _verifyAndInstall(check.manifest, download.filePath);
          return;
        case AppUpdateDownloadStatus.failed:
          throw StateError('download-failed-${snapshot.reason ?? 'unknown'}');
      }
    }
  }

  Future<void> _verifyAndInstall(
    AppUpdateManifest manifest,
    String filePath,
  ) async {
    state = state.copyWith(
      phase: AppUpdatePhase.verifying,
      clearDownloadProgress: true,
    );
    try {
      await _platform.verifyUpdate(manifest, filePath);
    } catch (error) {
      throw AppUpdateException('verification-failed', cause: error);
    }
    if (_disposed) return;
    try {
      if (await _platform.canRequestPackageInstalls()) {
        await _install(filePath);
      } else {
        state = state.copyWith(
          phase: AppUpdatePhase.awaitingInstallPermission,
          clearError: true,
        );
      }
    } catch (_) {
      if (!_disposed) {
        state = state.copyWith(
          phase: AppUpdatePhase.failed,
          errorCode: 'install-permission-check-failed',
        );
      }
    }
  }

  Future<void> requestInstallPermission() async {
    if (state.phase != AppUpdatePhase.awaitingInstallPermission) return;
    try {
      await _platform.openInstallPermissionSettings();
    } catch (_) {
      if (!_disposed) {
        state = state.copyWith(
          phase: AppUpdatePhase.failed,
          errorCode: 'permission-settings-failed',
        );
      }
    }
  }

  Future<void> handleAppResumed() async {
    if (state.phase == AppUpdatePhase.installing) {
      // A successful replacement terminates this process. Reaching this state
      // again means the system installer was dismissed or could not finish.
      state = state.copyWith(
        phase: AppUpdatePhase.available,
        errorCode: 'install-not-completed',
      );
      return;
    }
    final filePath = _downloadedFilePath;
    if (state.phase != AppUpdatePhase.awaitingInstallPermission ||
        filePath == null) {
      return;
    }
    try {
      if (await _platform.canRequestPackageInstalls()) {
        await _install(filePath);
      }
    } catch (_) {
      if (!_disposed) {
        state = state.copyWith(
          phase: AppUpdatePhase.failed,
          errorCode: 'install-permission-check-failed',
        );
      }
    }
  }

  Future<void> _install(String filePath) async {
    state = state.copyWith(phase: AppUpdatePhase.installing, clearError: true);
    try {
      await _platform.installUpdate(filePath);
    } catch (_) {
      if (!_disposed) {
        state = state.copyWith(
          phase: AppUpdatePhase.failed,
          errorCode: 'install-failed',
        );
      }
    }
  }

  Future<void> cancelUpdate() async {
    await _cancelActiveDownload();
    if (!_disposed) {
      state = AppUpdateState(phase: AppUpdatePhase.idle, check: state.check);
    }
  }

  Future<void> _cancelActiveDownload() async {
    final id = _activeDownloadId;
    _activeDownloadId = null;
    if (id != null) {
      try {
        await _platform.cancelDownload(id);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
