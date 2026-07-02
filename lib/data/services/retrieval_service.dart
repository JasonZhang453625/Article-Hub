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

enum RetrievalMethod { vector, keyword, hybrid, none }

/// Retrieves relevant articles from the knowledge base using hybrid search.
///
/// When embeddings are configured, vector and keyword retrieval run in
/// parallel and results are fused via Reciprocal Rank Fusion (RRF).
/// Falls back to pure keyword when embeddings are unavailable.
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

    // Run keyword synchronously; it's cheap and requires no I/O.
    final keywordResults = _keywordRetrieve(query, articles);

    // Try vector retrieval in parallel.
    List<Article>? vectorResults;
    if (_embedding.isConfigured) {
      try {
        vectorResults = await _vectorRetrieve(query, articles);
      } catch (e) {
        developer.log('vector retrieval failed: $e',
            name: 'memora.retrieval');
      }
    }

    stopwatch.stop();

    // Neither method found anything.
    if ((vectorResults == null || vectorResults.isEmpty) && keywordResults.isEmpty) {
      return RetrievalResult(
        articles: [],
        method: RetrievalMethod.none,
        duration: stopwatch.elapsed,
      );
    }

    // Only keyword had results.
    if (vectorResults == null || vectorResults.isEmpty) {
      return RetrievalResult(
        articles: keywordResults,
        method: RetrievalMethod.keyword,
        duration: stopwatch.elapsed,
        candidateIds: keywordResults.map((a) => a.id).toList(),
      );
    }

    // Only vector had results.
    if (keywordResults.isEmpty) {
      return RetrievalResult(
        articles: vectorResults,
        method: RetrievalMethod.vector,
        duration: stopwatch.elapsed,
        candidateIds: vectorResults.map((a) => a.id).toList(),
      );
    }

    // Both methods produced results — fuse via RRF.
    final fused = rrfFuse(vectorResults, keywordResults, topK: _topK);
    return RetrievalResult(
      articles: fused,
      method: RetrievalMethod.hybrid,
      duration: stopwatch.elapsed,
      candidateIds: fused.map((a) => a.id).toList(),
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

/// Fuse vector and keyword rankings via Reciprocal Rank Fusion (RRF).
///
/// RRF sums 1/(k + rank) for each article across both result lists, where
/// k=60 dampens extreme rank differences. Articles appearing in both lists
/// naturally get score-boosted without arbitrary weighting.
List<Article> rrfFuse(
    List<Article> vectorResults, List<Article> keywordResults,
    {int topK = 5}) {
  const k = 60;
  final scores = <String, double>{};

  for (int i = 0; i < vectorResults.length; i++) {
    final id = vectorResults[i].id;
    scores[id] = (scores[id] ?? 0) + 1 / (k + i);
  }

  for (int i = 0; i < keywordResults.length; i++) {
    final id = keywordResults[i].id;
    scores[id] = (scores[id] ?? 0) + 1 / (k + i);
  }

  // Build a merged set of unique articles keyed by id.
  final seen = <String, Article>{};
  for (final a in vectorResults) {
    seen[a.id] = a;
  }
  for (final a in keywordResults) {
    seen.putIfAbsent(a.id, () => a);
  }

  final fused = seen.values.toList()
    ..sort((a, b) => (scores[b.id] ?? 0).compareTo(scores[a.id] ?? 0));

  return fused.take(topK).toList();
}
