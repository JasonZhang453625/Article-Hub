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
/// Returns the number of articles indexed.
Future<int> rebuildIndex({
  required List<Article> articles,
  required EmbeddingService embedding,
  required IndexService index,
}) async {
  await index.clear();
  int count = 0;

  for (final article in articles) {
    if (article.processingStatus != ProcessingStatus.completed) continue;
    if (article.summary == null || article.summary!.isEmpty) continue;

    final input = IndexService.buildEmbeddingInput(article);
    final result = await embedding.embed(input);
    if (result == null) continue;

    await index.put(IndexRecord(
      articleId: article.id,
      model: result.model,
      fingerprint: contentFingerprint(
          article.title, article.summary!, article.tags),
      vector: result.vector,
    ));
    count++;
  }

  developer.log('rebuilt index: $count articles', name: 'article_hub.index');
  return count;
}
