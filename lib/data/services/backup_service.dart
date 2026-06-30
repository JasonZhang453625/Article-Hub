import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'backup_data.dart';

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

class BackupService {
  final List<dynamic> Function() _getAllArticles;
  final Future<int> Function(Iterable<dynamic>) _importArticles;
  final List<dynamic> Function() _getFilterGroups;
  final Future<int> Function(Iterable<dynamic>) _importFilterGroups;
  final Future<void> Function(dynamic) _addFolder;
  final Future<void> Function(dynamic) _replaceSettings;
  final List<dynamic> Function() _getFolders;
  final dynamic Function() _getSettings;

  BackupService({
    required List<dynamic> Function() getAllArticles,
    required Future<int> Function(Iterable<dynamic>) importArticles,
    required List<dynamic> Function() getFilterGroups,
    required Future<int> Function(Iterable<dynamic>) importFilterGroups,
    required Future<void> Function(dynamic) addFolder,
    required Future<void> Function(dynamic) replaceSettings,
    required List<dynamic> Function() getFolders,
    required dynamic Function() getSettings,
  })  : _getAllArticles = getAllArticles,
        _importArticles = importArticles,
        _getFilterGroups = getFilterGroups,
        _importFilterGroups = importFilterGroups,
        _addFolder = addFolder,
        _replaceSettings = replaceSettings,
        _getFolders = getFolders,
        _getSettings = getSettings;

  Future<ShareResultStatus> exportBackup() async {
    final articles = _getAllArticles();
    final filterGroups = _getFilterGroups();
    final folders = _getFolders();
    final settings = _getSettings();

    final backup = BackupData.create(
      articles: articles.cast(),
      filterGroups: filterGroups.cast(),
      folders: folders.cast(),
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

  Future<ImportResult?> importBackupFromFile(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) return null;

    final contents = await file.readAsString();
    return _import(contents);
  }

  Future<ImportResult?> importBackup() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return null;

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

    return _import(contents);
  }

  Future<ImportResult> _import(String contents) async {
    final backup = BackupData.fromJsonString(contents);

    final articleCount = await _importArticles(backup.articles);
    final groupCount = await _importFilterGroups(backup.filterGroups);

    int folderCount = 0;
    if (backup.folders.isNotEmpty) {
      for (final folder in backup.folders) {
        await _addFolder(folder);
        folderCount++;
      }
    }

    final settings = backup.settings;
    if (settings != null) {
      await _replaceSettings(settings);
    }

    return ImportResult(
      articles: articleCount,
      filterGroups: groupCount,
      folders: folderCount,
      settingsImported: settings != null,
    );
  }
}
