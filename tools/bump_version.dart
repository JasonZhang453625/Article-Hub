// ignore_for_file: avoid_print

import 'dart:io';

import 'package:memora/shared/utils/app_version.dart';

/// Increments the patch version in pubspec.yaml (e.g. 2.0.0 → 2.0.1) and
/// maps it to the Android versionCode (e.g. 2.1.8 -> 20108).
///
/// Usage:
///   dart run tools/bump_version.dart
///   flutter build apk --release
///
/// Call this before `flutter build` so every release build gets a unique
/// versionName and versionCode.
void main() {
  final pubspec = File('pubspec.yaml');
  final content = pubspec.readAsStringSync();

  // Match "version: X.Y.Z" optionally followed by "+N"
  final regex = RegExp(
    r'^version:\s*(\d+)\.(\d+)\.(\d+)(\+\d+)?',
    multiLine: true,
  );
  final match = regex.firstMatch(content);

  if (match == null) {
    stderr.writeln(
      'Error: Could not find "version: X.Y.Z[+N]" line in pubspec.yaml',
    );
    exit(1);
  }

  final major = int.parse(match.group(1)!);
  final minor = int.parse(match.group(2)!);
  final patch = int.parse(match.group(3)!);
  final currentVersion = AppVersion(major: major, minor: minor, patch: patch);
  final existingBuildNumber = match.group(4)?.substring(1);
  if (existingBuildNumber != null &&
      int.parse(existingBuildNumber) != currentVersion.versionCode) {
    stderr.writeln(
      'Error: build number $existingBuildNumber does not match '
      '$currentVersion -> ${currentVersion.versionCode}',
    );
    exit(1);
  }

  final nextVersion = AppVersion(major: major, minor: minor, patch: patch + 1);
  late final int nextBuildNumber;
  try {
    nextBuildNumber = nextVersion.versionCode;
  } on StateError catch (error) {
    stderr.writeln('Error: $error');
    exit(1);
  }
  final newVersion = '$nextVersion+$nextBuildNumber';

  final updated = content.replaceFirst(regex, 'version: $newVersion');
  pubspec.writeAsStringSync(updated);
  print('✅  $currentVersion → $newVersion');
  print('VERSION=$newVersion');

  _renameApkIfExists();
}

/// Renames [build/app/outputs/flutter-apk/app-release.apk] to
/// [Article-Hub.apk] if the source file exists. Silently skips otherwise.
void _renameApkIfExists() {
  final apkDir = Directory(
    'build${Platform.pathSeparator}app${Platform.pathSeparator}outputs${Platform.pathSeparator}flutter-apk',
  );
  final source = File('${apkDir.path}${Platform.pathSeparator}app-release.apk');
  if (!source.existsSync()) return;

  final target = File('${apkDir.path}${Platform.pathSeparator}Article-Hub.apk');
  // Remove old renamed APK so we don't leave stale artifacts
  if (target.existsSync()) target.deleteSync();
  source.renameSync(target.path);
  print('📦  Renamed APK → Article-Hub.apk');
}
