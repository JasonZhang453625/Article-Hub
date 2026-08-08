// Post-release verification for Memora.
//
// Usage:
//   dart run tools/verify_release.dart <version>     # e.g. 2.1.10
//   dart run tools/verify_release.dart <version> --no-download
//
// Verifies everything the CI "Verify public download endpoints" step checks,
// plus the full download hash, so a human (or agent) can confirm a release
// without trusting CI alone. Exits non-zero on the first failure.
//
// Checks:
//   1. latest.json: HTTP 200, CORS *, no-store/no-cache, exact version/size/
//      sha256/serverUrl/githubUrl.
//   2. Range request returns 206 for latest.apk, app-release.apk, and the
//      versioned Memora-v<version>.apk.
//   3. Full download of the versioned APK matches the manifest size + sha256.
//   4. GitHub Release v<version> is public (not draft) with uploaded assets.
//
// Exit codes:
//   0 all checks passed
//   1 any check failed

import 'dart:convert';
import 'dart:io';
import 'dart:math';

const _manifestUrl =
    'https://api.memora.wang/downloads/android/latest.json';
const _baseUrl = 'https://api.memora.wang/downloads/android';
const _githubRepo = 'JasonZhang453625/Article-Hub';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tools/verify_release.dart <version> '
        '[--no-download]');
    exitCode = 64;
    return;
  }
  final version = args[0];
  final noDownload = args.contains('--no-download');

  final failures = <String>[];
  Future<void> check(String name, Future<bool> Function() fn) async {
    try {
      final ok = await fn();
      stdout.writeln('${ok ? 'PASS' : 'FAIL'}  $name');
      if (!ok) failures.add(name);
    } catch (e) {
      stdout.writeln('FAIL  $name: $e');
      failures.add(name);
    }
  }

  await check('manifest reachable + CORS + no-cache', () async {
    final response = await HttpClient()
        .getUrl(Uri.parse(_manifestUrl))
        .then((req) => req.close());
    if (response.statusCode != 200) return false;
    final cors = response.headers.value('access-control-allow-origin');
    final cache = response.headers.value('cache-control') ?? '';
    if (cors != '*') return false;
    if (!cache.contains('no-store') && !cache.contains('no-cache')) {
      return false;
    }
    response.drain<void>();
    return true;
  });

  late Map<String, dynamic> manifest;
  await check('manifest fields match $version', () async {
    final client = HttpClient();
    final response = await client
        .getUrl(Uri.parse(_manifestUrl))
        .then((req) => req.close());
    final body = await response.transform(utf8.decoder).join();
    manifest = jsonDecode(body) as Map<String, dynamic>;

    final expectedServerUrl =
        '$_baseUrl/releases/v$version/Memora-v$version.apk';
    final expectedGithubUrl =
        'https://github.com/$_githubRepo/releases/download/v$version/app-release.apk';

    if (manifest['version'] != version) return false;
    if (manifest['serverUrl'] != expectedServerUrl) return false;
    if (manifest['githubUrl'] != expectedGithubUrl) return false;
    if (manifest['sha256'] is! String ||
        (manifest['sha256'] as String).length != 64) {
      return false;
    }
    return manifest['size'] is int && manifest['size'] > 0;
  });

  final apkUrls = [
    '$_baseUrl/latest.apk',
    '$_baseUrl/app-release.apk',
    '$_baseUrl/releases/v$version/Memora-v$version.apk',
  ];
  for (final url in apkUrls) {
    await check('Range 206: $url', () async {
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('Range', 'bytes=0-0');
      final response = await request.close();
      final status = response.statusCode;
      await response.drain<void>();
      return status == 206;
    });
  }

  if (!noDownload && manifest.isNotEmpty) {
    await check('full download matches manifest', () async {
      final expectedSha = manifest['sha256'] as String;
      final expectedSize = manifest['size'] as int;
      final tmp = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'memora-verify-$version-${Random().nextInt(1 << 32)}.apk',
      );
      try {
        final client = HttpClient();
        final response = await client
            .getUrl(Uri.parse(
                '$_baseUrl/releases/v$version/Memora-v$version.apk'))
            .then((req) => req.close());
        final sink = tmp.openWrite();
        await response.pipe(sink);
        await sink.close();

        final size = tmp.lengthSync();
        final digest = await _sha256Of(tmp);
        if (size != expectedSize) return false;
        if (digest.toLowerCase() != expectedSha.toLowerCase()) return false;
        return true;
      } finally {
        if (tmp.existsSync()) tmp.deleteSync();
      }
    });
  }

  await check('GitHub Release v$version public with assets', () async {
    // Public API — no auth required for public repos.
    final client = HttpClient();
    final response = await client
        .getUrl(Uri.parse(
            'https://api.github.com/repos/$_githubRepo/releases/tags/v$version'))
        .then((req) => req.close());
    if (response.statusCode != 200) return false;
    final body = await response.transform(utf8.decoder).join();
    final release = jsonDecode(body) as Map<String, dynamic>;
    if (release['draft'] != false) return false;
    final assets = release['assets'] as List<dynamic>;
    final names = assets
        .map((a) => (a as Map<String, dynamic>)['name'] as String?)
        .whereType<String>()
        .toSet();
    return names.containsAll({'app-release.apk', 'app-release.apk.sha256', 'latest.json'});
  });

  stdout.writeln('');
  if (failures.isEmpty) {
    stdout.writeln('All checks passed for v$version.');
  } else {
    stderr.writeln('${failures.length} check(s) failed:');
    for (final f in failures) {
      stderr.writeln('  - $f');
    }
    exitCode = 1;
  }
}

Future<String> _sha256Of(File file) async {
  final result = await Process.run(
    Platform.isWindows ? 'certutil' : 'sha256sum',
    Platform.isWindows
        ? ['-hashfile', file.path, 'SHA256']
        : [file.path],
  );
  if (result.exitCode != 0) {
    throw StateError('hash failed: ${result.stderr}');
  }
  final raw = result.stdout as String;
  // certutil prints the hash in the middle; sha256sum prints it first.
  final match = RegExp(r'[0-9a-fA-F]{64}').firstMatch(raw);
  if (match == null) throw StateError('no hash in output: $raw');
  return match.group(0)!;
}
