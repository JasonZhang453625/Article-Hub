import 'dart:developer' as developer;
import '../models/passage.dart';
import 'embedding_service.dart';
import 'index_service.dart';
import 'retrieval_isolate.dart';

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

typedef RetrievalComputeRunner =
    Future<RetrievalComputeOutput> Function({
      required String query,
      required List<double> queryVector,
      required String embeddingModel,
      required List<Map<String, dynamic>> records,
      required List<Map<String, dynamic>> articles,
      required double minRelevance,
      required int topK,
    });

/// Retrieves relevant articles from the knowledge base using hybrid search.
///
/// When embeddings are configured, vector and keyword retrieval run in
/// parallel inside a background Isolate after the network embedding call
/// completes. Results are fused via Reciprocal Rank Fusion (RRF).
/// Falls back to pure keyword when embeddings are unavailable.
class RetrievalService {
  final EmbeddingService _embedding;
  final IndexService _index;
  final double _minRelevance;
  final int _topK;
  final RetrievalComputeRunner _compute;

  RetrievalService({
    required EmbeddingService embedding,
    required IndexService index,
    double minRelevance = 0.3,
    int topK = 5,
    RetrievalComputeRunner? compute,
  }) : _embedding = embedding,
       _index = index,
       _minRelevance = minRelevance,
       _topK = topK,
       _compute = compute ?? runRetrievalInIsolate;

  /// Retrieve articles relevant to [query].
  ///
  /// Network I/O (embedding API call, Hive reads) stays on the main thread.
  /// CPU-heavy work (cosine similarity loop, keyword scoring, RRF fusion)
  /// is dispatched to a background Isolate to avoid janking the UI.
  ///
  /// [articles] is the full knowledge base (completed articles only).
  Future<RetrievalResult> retrieve(String query, List<Article> articles) async {
    final stopwatch = Stopwatch()..start();

    final articleMaps = articles
        .map(
          (a) => {
            'id': a.id,
            'title': a.title,
            'summary': a.retrievalText,
            'tags': a.tags,
          },
        )
        .toList();

    // Collect query embedding on the main thread (network I/O).
    List<double> queryVector = [];
    if (_embedding.isConfigured) {
      try {
        final result = await _embedding.embed(query);
        if (result != null) {
          queryVector = result.vector;
        }
      } catch (e) {
        developer.log('embedding failed: $e', name: 'memora.retrieval');
      }
    }

    // Pull index records (Hive I/O — fine on main thread).
    List<IndexRecord> records;
    try {
      records = await _index.getAll();
    } catch (error, stackTrace) {
      developer.log(
        'vector index read failed; falling back to keyword retrieval',
        name: 'memora.retrieval',
        error: error,
        stackTrace: stackTrace,
      );
      records = const [];
    }
    final recordMaps = records
        .map(
          (r) => {
            'articleId': r.articleId,
            'model': r.model,
            'vector': r.vector,
          },
        )
        .toList();

    // Dispatch CPU-heavy computation to a background Isolate. If isolate
    // startup or execution fails, keep a synchronous keyword-only fallback.
    RetrievalComputeOutput output;
    try {
      output = await _compute(
        query: query,
        queryVector: queryVector,
        embeddingModel: _embedding.model,
        records: recordMaps,
        articles: articleMaps,
        minRelevance: _minRelevance,
        topK: _topK,
      );
    } catch (error, stackTrace) {
      developer.log(
        'retrieval isolate failed; using in-process keyword retrieval',
        name: 'memora.retrieval',
        error: error,
        stackTrace: stackTrace,
      );
      output = runKeywordRetrievalInProcess(
        query: query,
        articles: articleMaps,
        topK: _topK,
      );
    }

    stopwatch.stop();

    final articleMap = {for (final a in articles) a.id: a};
    final resultArticles = output.resultIds
        .map((id) => articleMap[id])
        .where((a) => a != null)
        .cast<Article>()
        .toList();

    final method = switch (output.method) {
      'vector' => RetrievalMethod.vector,
      'keyword' => RetrievalMethod.keyword,
      'hybrid' => RetrievalMethod.hybrid,
      _ => RetrievalMethod.none,
    };

    return RetrievalResult(
      articles: resultArticles,
      method: method,
      duration: stopwatch.elapsed,
      candidateIds: output.candidateIds,
    );
  }
}

/// Fuse vector and keyword rankings via Reciprocal Rank Fusion (RRF).
///
/// RRF sums 1/(k + rank) for each article across both result lists, where
/// k=60 dampens extreme rank differences. Articles appearing in both lists
/// naturally get score-boosted without arbitrary weighting.
///
/// This is the synchronous, in-process variant suitable for tests or
/// UI-thread-safe workloads. The Isolate-based variant used by
/// [RetrievalService.retrieve] lives in `retrieval_isolate.dart`.
List<Article> rrfFuse(
  List<Article> vectorResults,
  List<Article> keywordResults, {
  int topK = 5,
}) {
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
