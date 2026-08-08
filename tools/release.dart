// One-shot release driver for Memora.
//
// Usage:
//   dart run tools/release.dart                  # bump patch, commit, tag, push
//   dart run tools/release.dart --no-push        # bump, commit, tag locally only
//   dart run tools/release.dart --message "..."  # override the commit subject
//
// The tool performs the deterministic release steps that used to be done by
// hand (or by an agent): verify a clean scope, bump pubspec version, create a
// conventional commit, tag it, and push. The CI workflow
// (.github/workflows/release.yml) then builds, tests, publishes, deploys to
// the China download source, and deploys the landing page automatically.
//
// Requirements:
//   - Must run from the repository root.
//   - Must run on the `main` branch.
//   - `git push` requires an authenticated remote (SSH).
//
// Exit codes:
//   0 success
//   1 any failure (already-printed reason)
//   2 nothing to release (no staged/unstaged app changes)

import 'dart:io';

import 'package:memora/shared/utils/app_version.dart';

const _coAuthorTrailer = 'Co-authored-by: CommandCodeBot <noreply@commandcode.ai>';

Future<void> main(List<String> args) async {
  final noPush = args.contains('--no-push');
  final includeAll = args.contains('--include-all');
  final message = _argValue(args, '--message');

  try {
    await _run(
      noPush: noPush,
      includeAll: includeAll,
      messageOverride: message,
    );
  } on _ReleaseError catch (e) {
    stderr.writeln('release: ${e.message}');
    exitCode = e.exitCode;
  }
}

class _ReleaseError implements Exception {
  final String message;
  final int exitCode;
  _ReleaseError(this.message, {this.exitCode = 1});
}

Future<void> _run({
  required bool noPush,
  required bool includeAll,
  String? messageOverride,
}) async {
  // ── Preflight ──────────────────────────────────────────────────────────
  final root = Directory.current;
  final pubspec = File('${root.path}${Platform.pathSeparator}pubspec.yaml');
  if (!pubspec.existsSync()) {
    throw _ReleaseError('run from the repository root (pubspec.yaml not found)');
  }

  final branch = (await _git('rev-parse', ['--abbrev-ref', 'HEAD'])).trim();
  if (branch != 'main') {
    throw _ReleaseError('must run on main (current: $branch)');
  }

  final status = await _git('status', ['--porcelain']);
  final lines = status
      .split('\n')
      .where((l) => l.trim().isNotEmpty)
      .map((l) => _porcelainPath(l))
      .toList();
  final hasUnrelated = lines.any(_isUnrelatedPath);
  if (hasUnrelated && !includeAll) {
    throw _ReleaseError(
      'unrelated worktree changes would be swept into the release; '
      'resolve scope first, or pass --include-all to exclude them '
      '(see SKILL.md)',
    );
  }
  if (hasUnrelated && includeAll) {
    stdout.writeln('note: --include-all — unrelated changes are excluded '
        'from the release commit');
  }
  if (lines.isEmpty) {
    throw _ReleaseError('nothing to release', exitCode: 2);
  }

  final appChanges = lines.where((l) => !_isUnrelatedPath(l)).toList();
  if (appChanges.isEmpty) {
    throw _ReleaseError('no app changes to release', exitCode: 2);
  }

  // ── Bump (reuse an intentional unpublished version) ────────────────────
  final current = _readVersion(pubspec);
  final currentTag = 'v$current';
  final currentTagged =
      (await _git('tag', ['--list', currentTag])).trim().isNotEmpty;
  late final AppVersion next;
  late final int nextCode;
  if (!currentTagged) {
    // pubspec already carries a version with no release tag — reuse it.
    next = current;
    nextCode = current.versionCode;
    stdout.writeln('reusing unpublished version $current');
  } else {
    next = AppVersion(
      major: current.major,
      minor: current.minor,
      patch: current.patch + 1,
    );
    nextCode = next.versionCode;
    _writePubspec(pubspec, '$next+$nextCode');
    stdout.writeln('version: $current → $next+$nextCode');
  }
  final versionName = next.toString();
  final versionFull = '$versionName+$nextCode';

  // ── Commit ─────────────────────────────────────────────────────────────
  final addPaths = [...appChanges, 'pubspec.yaml'];
  await _git('add', addPaths);
  final subject = messageOverride?.isNotEmpty == true
      ? messageOverride!
      : _defaultSubject(appChanges);
  final commitArgs = ['-m', subject, '-m', _coAuthorTrailer];
  await _git('commit', commitArgs);
  stdout.writeln('committed: $subject');

  // ── Tag ────────────────────────────────────────────────────────────────
  final tag = 'v$versionName';
  final localTag = await _git('tag', ['--list', tag]);
  if (localTag.trim().isNotEmpty) {
    throw _ReleaseError('tag $tag already exists locally — never retag');
  }
  await _git('tag', ['-a', tag, '-m', 'Release $versionName']);
  stdout.writeln('tagged: $tag');

  // ── Push ───────────────────────────────────────────────────────────────
  if (noPush) {
    stdout.writeln('--no-push: commit and tag created locally; push manually');
    return;
  }
  await _git('push', ['origin', 'HEAD']);
  await _git('push', ['origin', tag]);
  stdout.writeln('pushed main and $tag');

  stdout.writeln('VERSION=$versionFull');
  stdout.writeln('VERSION_NAME=$versionName');
  stdout.writeln('TAG=$tag');
  stdout.writeln('CI: waiting for .github/workflows/release.yml to pick up $tag');
}

String _defaultSubject(List<String> changedPaths) {
  // Derive a conventional subject from the changed paths.
  final hasFeature = changedPaths.any((f) => f.contains('/features/'));
  final hasFix = changedPaths.any(
    (f) => f.contains('/services/') || f.contains('_test.dart'),
  );
  final scope = changedPaths
      .map((f) => f.split('/').firstWhere(
            (p) => p.isNotEmpty,
            orElse: () => '',
          ))
      .toSet()
      .where((s) => s.isNotEmpty)
      .join(',');
  final type = hasFix ? 'fix' : (hasFeature ? 'feat' : 'chore');
  return '$type($scope): release iteration';
}

// ── Helpers ──────────────────────────────────────────────────────────────

AppVersion _readVersion(File pubspec) {
  final content = pubspec.readAsStringSync();
  final match = RegExp(
    r'^version:\s*(\d+)\.(\d+)\.(\d+)(\+\d+)?',
    multiLine: true,
  ).firstMatch(content);
  if (match == null) {
    throw _ReleaseError('no "version: X.Y.Z[+N]" in pubspec.yaml');
  }
  return AppVersion(
    major: int.parse(match.group(1)!),
    minor: int.parse(match.group(2)!),
    patch: int.parse(match.group(3)!),
  );
}

void _writePubspec(File pubspec, String version) {
  final content = pubspec.readAsStringSync();
  final updated = content.replaceFirst(
    RegExp(r'^version:\s*\d+\.\d+\.\d+(\+\d+)?', multiLine: true),
    'version: $version',
  );
  pubspec.writeAsStringSync(updated);
}

/// Strips the two-character status prefix (and possible C-style quotes) from
/// a `git status --porcelain` line, returning the raw path.
String _porcelainPath(String line) {
  var path = line.length >= 3 ? line.substring(3) : line;
  path = path.trim();
  if (path.startsWith('"') && path.endsWith('"') && path.length >= 2) {
    path = path.substring(1, path.length - 1);
  }
  return path;
}

bool _isUnrelatedPath(String path) {
  return path.startsWith('.commandcode/') ||
      path.startsWith('.playwright-cli/') ||
      path.startsWith('output/') ||
      path.startsWith('landing-page') ||
      path.startsWith('android/build/') ||
      path.startsWith('node_modules/') ||
      path.startsWith('.dart_tool/') ||
      path.startsWith('build/') ||
      path == '.git' ||
      path.startsWith('.git/') ||
      path == 'skills-lock.json' ||
      path.startsWith('_backend_staging/') ||
      path.endsWith('.lock');
}

Future<String> _git(String command, List<String> args) async {
  final result = await Process.run('git', [command, ...args]);
  if (result.exitCode != 0) {
    throw _ReleaseError(
      'git $command failed: ${(result.stderr as String).trim()}',
    );
  }
  return result.stdout as String;
}

String? _argValue(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index == -1 || index + 1 >= args.length) return null;
  return args[index + 1];
}
