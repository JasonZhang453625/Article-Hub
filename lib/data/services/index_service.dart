import 'dart:developer' as developer;
import 'package:hive_flutter/hive_flutter.dart';
import '../models/passage.dart';
import 'embedding_service.dart';

/// A single entry in the local vector index. Stored in a separate Hive box,
/// never exported to JSON backup.
class IndexRecord {
  final String articleId;
  final String model;
  final int fingerprint;
  final List<double> vector;

  const IndexRecord({
    required this.articleId,
    required this.model,
    required this.fingerprint,
    required this.vector,
  });
}

class IndexRecordAdapter extends TypeAdapter<IndexRecord> {
  @override
  final int typeId = 6; // Unique typeId not used by other adapters

  @override
  IndexRecord read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (int i = 0; i < numOfFields; i++) {
      fields[reader.readByte()] = reader.read();
    }
    return IndexRecord(
      articleId: fields[0] as String,
      model: fields[1] as String,
      fingerprint: fields[2] as int,
      vector: (fields[3] as List).cast<double>(),
    );
  }

  @override
  void write(BinaryWriter writer, IndexRecord obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.articleId)
      ..writeByte(1)
      ..write(obj.model)
      ..writeByte(2)
      ..write(obj.fingerprint)
      ..writeByte(3)
      ..write(obj.vector);
  }
}

/// Manages the local vector index stored in Hive.
class IndexService {
  static const String _boxName = 'vector_index';
  Box<IndexRecord>? _box;

  Future<Box<IndexRecord>> _openBox() async {
    if (!Hive.isAdapterRegistered(IndexRecordAdapter().typeId)) {
      Hive.registerAdapter(IndexRecordAdapter());
    }
    _box ??= await Hive.openBox<IndexRecord>(_boxName);
    return _box!;
  }

  /// Public accessor for the underlying Hive box. Used by providers that
  /// need to listen for mutations (e.g. `box.watch()` for live UI updates).
  Future<Box<IndexRecord>> openBox() => _openBox();

  /// Get all index records.
  Future<List<IndexRecord>> getAll() async {
    final box = await _openBox();
    return box.values.toList();
  }

  /// Get the index record for a specific article.
  Future<IndexRecord?> get(String articleId) async {
    final box = await _openBox();
    return box.get(articleId);
  }

  /// Add or update an index record.
  Future<void> put(IndexRecord record) async {
    final box = await _openBox();
    await box.put(record.articleId, record);
  }

  /// Delete an index record.
  Future<void> delete(String articleId) async {
    final box = await _openBox();
    await box.delete(articleId);
  }

  /// Remove all index records whose articleId is not in [validIds].
  /// Returns the number of orphaned records removed.
  Future<int> removeOrphans(Set<String> validIds) async {
    final box = await _openBox();
    final orphans =
        box.keys.where((key) => !validIds.contains(key)).toList();
    for (final key in orphans) {
      await box.delete(key);
    }
    return orphans.length;
  }

  /// Delete all index entries.
  Future<void> clear() async {
    final box = await _openBox();
    await box.clear();
  }

  /// Number of indexed records.
  Future<int> count() async {
    final box = await _openBox();
    return box.length;
  }

  /// Build the embedding input text for an article: title + summary + tags.
  static String buildEmbeddingInput(Article article) {
    final parts = <String>[
      article.title,
      article.summary ?? '',
      article.tags.join(', '),
    ];
    return parts.where((p) => p.isNotEmpty).join('\n');
  }

  void dispose() {}
}

/// Rebuilds the index for all completed articles.
/// Skips articles whose fingerprint and model already match the existing
/// record, so switching embedding model or editing content triggers a
/// fresh vector while leaving unchanged articles untouched.
/// Returns the number of (newly) indexed articles.
Future<int> rebuildIndex({
  required List<Article> articles,
  required EmbeddingService embedding,
  required IndexService index,
}) async {
  final existingRecords = {for (final r in await index.getAll()) r.articleId: r};
  int count = 0;

  // Collect articles that need a fresh embedding so we can batch them.
  final toEmbed = <_IndexCandidate>[];
  for (final article in articles) {
    if (article.processingStatus != ProcessingStatus.completed) continue;
    if (article.summary == null || article.summary!.isEmpty) continue;

    final currentFp = contentFingerprint(
        article.title, article.summary!, article.tags);
    final existing = existingRecords[article.id];

    // Skip if the content fingerprint and embedding model are unchanged.
    if (existing != null &&
        existing.fingerprint == currentFp &&
        existing.model == embedding.model) {
      count++;
      continue;
    }

    toEmbed.add(_IndexCandidate(
      article: article,
      fingerprint: currentFp,
      input: IndexService.buildEmbeddingInput(article),
    ));
  }

  // Batch-send embeddings — far fewer HTTP round-trips.
  const batchSize = 20;
  for (int i = 0; i < toEmbed.length; i += batchSize) {
    final batch = toEmbed.sublist(i, (i + batchSize).clamp(0, toEmbed.length));
    final inputs = batch.map((c) => c.input).toList();
    final results = await embedding.embedBatch(inputs);

    for (int j = 0; j < batch.length; j++) {
      final result = results[j];
      if (result == null) continue;
      final candidate = batch[j];
      await index.put(IndexRecord(
        articleId: candidate.article.id,
        model: result.model,
        fingerprint: candidate.fingerprint,
        vector: result.vector,
      ));
      count++;
    }
  }

  // Clean up orphans — articles that were deleted or are no longer completed.
  final validIds = articles
      .where((a) =>
          a.processingStatus == ProcessingStatus.completed &&
          a.summary != null &&
          a.summary!.isNotEmpty)
      .map((a) => a.id)
      .toSet();
  final removedOrphans = await index.removeOrphans(validIds);
  if (removedOrphans > 0) {
    developer.log('removed $removedOrphans orphaned index records',
        name: 'memora.index');
  }

  developer.log('rebuilt index: $count articles', name: 'memora.index');
  return count;
}

class _IndexCandidate {
  final Article article;
  final int fingerprint;
  final String input;
  const _IndexCandidate({
    required this.article,
    required this.fingerprint,
    required this.input,
  });
}
