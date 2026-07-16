import 'dart:convert';

import '../models/passage.dart';
import '../models/filter_group.dart';
import '../models/folder.dart';
import '../models/settings.dart';

/// Current backup file schema version. Bump when the on-disk format changes in
/// a way that needs migration on import.
const int kBackupSchemaVersion = 3;

/// An in-memory representation of a full app backup: every article, filter
/// group, folders, and the app settings. Pure data + (de)serialization, no
/// Flutter or I/O dependencies so it can be unit-tested directly.
class BackupData {
  final int schemaVersion;
  final DateTime exportedAt;
  final List<Article> articles;
  final List<FilterGroup> filterGroups;
  final List<Folder> folders;
  final AppSettings? settings;

  const BackupData({
    required this.schemaVersion,
    required this.exportedAt,
    required this.articles,
    required this.filterGroups,
    required this.folders,
    required this.settings,
  });

  BackupData.create({
    required this.articles,
    required this.filterGroups,
    required this.folders,
    required this.settings,
  })  : schemaVersion = kBackupSchemaVersion,
        exportedAt = DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'exportedAt': exportedAt.toIso8601String(),
      'app': 'memora',
      'articles': articles.map((a) => a.toJson()).toList(),
      'filterGroups': filterGroups.map((g) => g.toJson()).toList(),
      'folders': folders.map((f) => f.toJson()).toList(),
      'settings': settings?.toJson(),
    };
  }

  /// Serializes the backup to a pretty-printed JSON string.
  String toJsonString() {
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }

  /// Parses a backup from a JSON string. Throws [FormatException] if the
  /// payload is not a valid Memora backup. Individual malformed entries
  /// are skipped rather than failing the whole import.
  factory BackupData.fromJsonString(String source) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(source);
    } catch (_) {
      throw const FormatException('File is not valid JSON');
    }

    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Backup root must be a JSON object');
    }

    // Accept backups from both Memora and the legacy Article-Hub name.
    final appName = decoded['app'];
    if (appName != null &&
        appName is String &&
        appName != 'memora' &&
        appName != 'article-hub') {
      throw const FormatException('Unrecognized backup source');
    }

    final rawArticles = decoded['articles'];
    final rawGroups = decoded['filterGroups'];
    if (rawArticles is! List && rawGroups is! List) {
      throw const FormatException('Backup has no articles or filter groups');
    }

    final articles = <Article>[];
    if (rawArticles is List) {
      for (final item in rawArticles) {
        if (item is Map<String, dynamic>) {
          try {
            articles.add(Article.fromJson(item));
          } catch (_) {
            // Skip malformed entries, keep importing the rest.
          }
        }
      }
    }

    final filterGroups = <FilterGroup>[];
    if (rawGroups is List) {
      for (final item in rawGroups) {
        if (item is Map<String, dynamic>) {
          try {
            filterGroups.add(FilterGroup.fromJson(item));
          } catch (_) {
            // Skip malformed entries.
          }
        }
      }
    }

    final folders = <Folder>[];
    final rawFolders = decoded['folders'];
    if (rawFolders is List) {
      for (final item in rawFolders) {
        if (item is Map<String, dynamic>) {
          try {
            folders.add(Folder.fromJson(item));
          } catch (_) {
            // Skip malformed entries.
          }
        }
      }
    }

    AppSettings? settings;
    final rawSettings = decoded['settings'];
    if (rawSettings is Map<String, dynamic>) {
      try {
        settings = AppSettings.fromJson(rawSettings);
      } catch (_) {
        settings = null;
      }
    }

    final versionValue = decoded['schemaVersion'];
    final exportedAtValue = decoded['exportedAt'];

    return BackupData(
      schemaVersion:
          versionValue is num ? versionValue.toInt() : kBackupSchemaVersion,
      exportedAt: exportedAtValue is String
          ? (DateTime.tryParse(exportedAtValue) ?? DateTime.now())
          : DateTime.now(),
      articles: articles,
      filterGroups: filterGroups,
      folders: folders,
      settings: settings,
    );
  }
}
