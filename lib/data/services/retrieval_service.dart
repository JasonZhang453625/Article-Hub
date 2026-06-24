import 'dart:developer' as developer;
import '../models/passage.dart';
import 'embedding_service.dart';
import 'index_service.dart';

/// The result of a retrieval operation.
class RetrievalResult {
  final List<Article> articles;
  final RetrievalMethod method;
  final Duration duration;
  final List<String> candidateIds;

  const RetrievalResult({
    required this.articles,
    required this.method,
    required this.duration,
    this.candidateIds = const [],
  });
}

enum RetrievalMethod { vector, keyword, none }

/// Retrieves relevant articles from the knowledge base.
///
/// Prefers vector similarity search when embeddings are available;
/// falls back to keyword search on title, summary, and tags.
class RetrievalService {
  final EmbeddingService _embedding;
  final IndexService _index;
  final double _minRelevance;
  final int _topK;

  RetrievalService({
    required EmbeddingService embedding,
    required IndexService index,
    double minRelevance = 0.3,
    int topK = 5,
  })  : _embedding = embedding,
        _index = index,
        _minRelevance = minRelevance,
        _topK = topK;

  /// Retrieve articles relevant to [query].
  ///
  /// [articles] is the full knowledge base (completed articles only).
  Future<RetrievalResult> retrieve(
      String query, List<Article> articles) async {
    final stopwatch = Stopwatch()..start();

    // Try vector retrieval first.
    if (_embedding.isConfigured) {
      try {
        final result = await _vectorRetrieve(query, articles);
        if (result != null && result.isNotEmpty) {
          stopwatch.stop();
          return RetrievalResult(
            articles: result,
            method: RetrievalMethod.vector,
            duration: stopwatch.elapsed,
            candidateIds: result.map((a) => a.id).toList(),
          );
        }
      } catch (e) {
        developer.log('vector retrieval failed: $e',
            name: 'article_hub.retrieval');
      }
    }

    // Fall back to keyword retrieval.
    final result = _keywordRetrieve(query, articles);
    stopwatch.stop();
    return RetrievalResult(
      articles: result,
      method: result.isEmpty ? RetrievalMethod.none : RetrievalMethod.keyword,
      duration: stopwatch.elapsed,
      candidateIds: result.map((a) => a.id).toList(),
    );
  }

  /// Vector similarity retrieval.
  Future<List<Article>?> _vectorRetrieve(
      String query, List<Article> articles) async {
    final records = await _index.getAll();
    if (records.isEmpty) return null;

    final queryEmbedding = await _embedding.embed(query);
    if (queryEmbedding == null) return null;

    // Build article lookup map.
    final articleMap = {for (final a in articles) a.id: a};

    // Score each indexed article.
    final scored = <({String id, double score})>[];
    for (final record in records) {
      if (!articleMap.containsKey(record.articleId)) continue;
      // Skip records indexed with a different embedding model — their
      // vectors live in an incompatible space and cosine similarity is
      // meaningless. The stale entries will be cleaned up on next rebuild.
      if (record.model != _embedding.model) continue;
      final score = cosineSimilarity(queryEmbedding.vector, record.vector);
      if (score >= _minRelevance) {
        scored.add((id: record.articleId, score: score));
      }
    }

    if (scored.isEmpty) return [];

    // Sort by score descending, take top-k.
    scored.sort((a, b) => b.score.compareTo(a.score));
    final topIds = scored.take(_topK).map((s) => s.id).toList();

    return topIds
        .map((id) => articleMap[id])
        .where((a) => a != null)
        .cast<Article>()
        .toList();
  }

  /// Keyword-based retrieval on title, summary, and tags.
  List<Article> _keywordRetrieve(String query, List<Article> articles) {
    final lower = query.toLowerCase();
    final words = lower.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return [];

    final scored = <({Article article, int score})>[];
    for (final article in articles) {
      int score = 0;
      final titleLower = article.title.toLowerCase();
      final summaryLower = (article.summary ?? '').toLowerCase();
      final tagsLower = article.tags.map((t) => t.toLowerCase()).toList();

      for (final word in words) {
        if (titleLower.contains(word)) score += 3;
        if (summaryLower.contains(word)) score += 2;
        if (tagsLower.any((t) => t.contains(word))) score += 2;
      }

      if (score > 0) {
        scored.add((article: article, score: score));
      }
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(_topK).map((s) => s.article).toList();
  }
}
