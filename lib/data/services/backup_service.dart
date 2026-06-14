import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/settings.dart';
import 'backup_data.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/filter_providers.dart';
import '../../shared/providers/settings_providers.dart';

/// Result of an import operation, for surfacing a summary to the user.
class ImportResult {
  final int articles;
  final int filterGroups;
  final int folders;
  final bool settingsImported;

  const ImportResult({
    required this.articles,
    required this.filterGroups,
    required this.folders,
    required this.settingsImported,
  });
}

/// Orchestrates full-data backup export (share a JSON file) and import (pick a
/// JSON file and merge it in). Reads/writes go through the existing providers
/// so state stays consistent.
class BackupService {
  final Ref _ref;

  BackupService(this._ref);

  /// Gathers all data and shares it as a timestamped JSON file. Returns the
  /// share result status.
  Future<ShareResultStatus> exportBackup() async {
    final repo = await _ref.read(articleRepositoryProvider.future);
    final articles = repo.getAll();
    final filterGroups = _ref.read(filterGroupsProvider).valueOrNull ?? [];
    final folders = _ref.read(foldersProvider).valueOrNull ?? [];
    final settings = _ref.read(settingsProvider).valueOrNull;

    final backup = BackupData.create(
      articles: articles,
      filterGroups: filterGroups,
      folders: folders,
      settings: settings,
    );

    final timestamp = DateFormat('yyyyMMdd-HHmmss').format(DateTime.now());
    final fileName = 'article-hub-backup-$timestamp.json';

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(backup.toJsonString());

    final result = await Share.shareXFiles(
      [XFile(file.path, mimeType: 'application/json', name: fileName)],
      subject: 'Article-Hub backup',
    );
    return result.status;
  }

  /// Lets the user pick a backup JSON file and merges it into current data.
  /// Returns null if the user cancelled, otherwise an [ImportResult].
  /// Throws [FormatException] if the chosen file is not a valid backup.
  Future<ImportResult?> importBackup() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) {
      return null; // cancelled
    }

    final file = picked.files.first;
    String contents;
    final bytes = file.bytes;
    if (bytes != null) {
      contents = utf8.decode(bytes);
    } else if (file.path != null) {
      contents = await File(file.path!).readAsString();
    } else {
      throw const FormatException('Could not read the selected file');
    }

    final backup = BackupData.fromJsonString(contents);

    final articleCount =
        await _ref.read(articlesProvider.notifier).importAll(backup.articles);
    final groupCount = await _ref
        .read(filterGroupsProvider.notifier)
        .importAll(backup.filterGroups);

    int folderCount = 0;
    if (backup.folders.isNotEmpty) {
      for (final folder in backup.folders) {
        await _ref.read(foldersProvider.notifier).add(folder);
        folderCount++;
      }
    }

    final AppSettings? settings = backup.settings;
    if (settings != null) {
      await _ref.read(settingsProvider.notifier).replaceWith(settings);
    }

    return ImportResult(
      articles: articleCount,
      filterGroups: groupCount,
      folders: folderCount,
      settingsImported: settings != null,
    );
  }
}

final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(ref);
});
