import 'package:hive/hive.dart';

import '../models/memory_document.dart';
import '../models/passage.dart';

class StorageMigrationResult {
  final int fromVersion;
  final int toVersion;
  final int migratedArticles;

  const StorageMigrationResult({
    required this.fromVersion,
    required this.toVersion,
    required this.migratedArticles,
  });
}

/// Runs local, idempotent data migrations after the article box is opened.
///
/// A version is recorded only after all writes finish. If the app closes during
/// migration, the next startup safely retries the remaining legacy records.
class StorageMigrationService {
  static const int currentVersion = 1;
  static const String stateBoxName = 'data_migrations';
  static const String _versionKey = 'article_storage_version';

  Future<StorageMigrationResult> migrate(Box<Article> articles) async {
    final state = await Hive.openBox<dynamic>(stateBoxName);
    final storedVersion = state.get(_versionKey);
    final fromVersion = storedVersion is int ? storedVersion : 0;
    if (fromVersion >= currentVersion) {
      return StorageMigrationResult(
        fromVersion: fromVersion,
        toVersion: currentVersion,
        migratedArticles: 0,
      );
    }

    final updates = <String, Article>{};
    for (final article in articles.values) {
      final legacySummary = article.summary;
      if (article.memory != null || legacySummary == null) continue;
      if (legacySummary.trim().isEmpty) continue;

      final memory = article.isFullText
          ? MemoryDocument.fullText(
              body: legacySummary,
              format: article.localMimeType == 'text/markdown'
                  ? 'markdown'
                  : 'plain',
            )
          : MemoryDocument.legacyMarkdown(body: legacySummary);
      updates[article.id] = article.copyWith(
        summary: Article.clearValue,
        memory: memory,
      );
    }

    if (updates.isNotEmpty) {
      await articles.putAll(updates);
    }
    await state.put(_versionKey, currentVersion);

    return StorageMigrationResult(
      fromVersion: fromVersion,
      toVersion: currentVersion,
      migratedArticles: updates.length,
    );
  }
}
