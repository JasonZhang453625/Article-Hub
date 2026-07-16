import 'dart:isolate';
import 'dart:math';

/// Output of a background Isolate retrieval computation.
///
/// All fields are cross-isolate safe (String / List of String only).
class RetrievalComputeOutput {
  final List<String> resultIds;
  final String method;
  final List<String> candidateIds;

  const RetrievalComputeOutput({
    required this.resultIds,
    required this.method,
    required this.candidateIds,
  });
}

/// Runs retrieval computation in a background Isolate to avoid janking the UI.
///
/// Network I/O (query embedding API call) and Hive reads happen on the main
/// thread. All CPU work — cosine similarity loop, keyword scoring, RRF
/// fusion — executes in the spawned Isolate.
///
/// All parameters use only cross-isolate-safe types (String, int, double,
/// bool, null, and nested Lists/Maps thereof). Custom objects are not
/// supported across Isolate boundaries.
Future<RetrievalComputeOutput> runRetrievalInIsolate({
  required String query,
  required List<double> queryVector,
  required String embeddingModel,
  required List<Map<String, dynamic>> records,
  required List<Map<String, dynamic>> articles,
  double minRelevance = 0.3,
  int topK = 5,
}) {
  assert(
    records.every((m) =>
        m['articleId'] is String &&
        m['model'] is String &&
        m['vector'] is List<double>),
    'records must have articleId (String), model (String), vector (List<double>)',
  );
  assert(
    articles.every((m) =>
        m['id'] is String &&
        m['title'] is String &&
        (m['summary'] is String) &&
        m['tags'] is List),
    'articles must have id, title, summary (String), tags (List)',
  );

  final input = {
    'query': query,
    'queryVector': queryVector,
    'embeddingModel': embeddingModel,
    'records': records,
    'articles': articles,
    'minRelevance': minRelevance,
    'topK': topK,
  };

  return Isolate.run(() => _runRetrievalCompute(input));
}

RetrievalComputeOutput _runRetrievalCompute(Map<String, dynamic> input) {
  final query = input['query'] as String;
  final queryVector = (input['queryVector'] as List).cast<double>();
  final embeddingModel = input['embeddingModel'] as String;
  final records = (input['records'] as List).cast<Map<String, dynamic>>();
  final articles = (input['articles'] as List).cast<Map<String, dynamic>>();
  final minRelevance = input['minRelevance'] as double;
  final topK = input['topK'] as int;

  final keywordRanked =
      _keywordRetrieve(query, articles, topK);

  final vectorRanked = _vectorRetrieve(
    queryVector,
    embeddingModel,
    records,
    articles,
    minRelevance,
    topK,
  );

  if (vectorRanked.isEmpty && keywordRanked.isEmpty) {
    return const RetrievalComputeOutput(
      resultIds: [],
      method: 'none',
      candidateIds: [],
    );
  }

  if (vectorRanked.isEmpty) {
    final ids = keywordRanked.map((s) => s.first as String).toList();
    return RetrievalComputeOutput(
      resultIds: ids,
      method: 'keyword',
      candidateIds: ids,
    );
  }

  if (keywordRanked.isEmpty) {
    final ids = vectorRanked.map((s) => s.first as String).toList();
    return RetrievalComputeOutput(
      resultIds: ids,
      method: 'vector',
      candidateIds: ids,
    );
  }

  final fused = _rrfFuseIds(vectorRanked, keywordRanked, topK);
  return RetrievalComputeOutput(
    resultIds: fused,
    method: 'hybrid',
    candidateIds: fused,
  );
}

List<List<Object>> _vectorRetrieve(
  List<double> queryVector,
  String embeddingModel,
  List<Map<String, dynamic>> records,
  List<Map<String, dynamic>> articles,
  double minRelevance,
  int topK,
) {
  final articleIds = articles.map((a) => a['id'] as String).toSet();
  final scored = <List<Object>>[];
  for (final record in records) {
    final articleId = record['articleId'] as String;
    final model = record['model'] as String;
    if (!articleIds.contains(articleId)) continue;
    if (model != embeddingModel) continue;
    final vector = (record['vector'] as List).cast<double>();
    final score = _cosineSimilarity(queryVector, vector);
    if (score >= minRelevance) {
      scored.add([articleId, score]);
    }
  }
  if (scored.isEmpty) return [];
  scored.sort((a, b) => (b[1] as double).compareTo(a[1] as double));
  return scored.take(topK).toList();
}

List<List<Object>> _keywordRetrieve(
  String query,
  List<Map<String, dynamic>> articles,
  int topK,
) {
  final lower = query.toLowerCase();
  final words =
      lower.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return [];

  final scored = <List<Object>>[];
  for (final article in articles) {
    int score = 0;
    final titleLower = (article['title'] as String).toLowerCase();
    final summaryLower = (article['summary'] as String).toLowerCase();
    final tags = (article['tags'] as List).cast<String>();
    final tagsLower = tags.map((t) => t.toLowerCase()).toList();

    for (final word in words) {
      if (titleLower.contains(word)) score += 3;
      if (summaryLower.contains(word)) score += 2;
      if (tagsLower.any((t) => t.contains(word))) score += 2;
    }

    if (score > 0) {
      scored.add([article['id'] as String, score.toDouble()]);
    }
  }

  scored.sort((a, b) => (b[1] as double).compareTo(a[1] as double));
  return scored.take(topK).toList();
}

List<String> _rrfFuseIds(
  List<List<Object>> vectorRanked,
  List<List<Object>> keywordRanked,
  int topK,
) {
  const k = 60;
  final scores = <String, double>{};
  final seen = <String>{};

  for (int i = 0; i < vectorRanked.length; i++) {
    final id = vectorRanked[i][0] as String;
    scores[id] = (scores[id] ?? 0) + 1 / (k + i);
    seen.add(id);
  }

  for (int i = 0; i < keywordRanked.length; i++) {
    final id = keywordRanked[i][0] as String;
    scores[id] = (scores[id] ?? 0) + 1 / (k + i);
    seen.add(id);
  }

  final fused = seen.toList()
    ..sort((a, b) => (scores[b] ?? 0).compareTo(scores[a] ?? 0));

  return fused.take(topK).toList();
}

double _cosineSimilarity(List<double> a, List<double> b) {
  if (a.length != b.length) return 0.0;
  double dot = 0, normA = 0, normB = 0;
  for (int i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  if (normA == 0 || normB == 0) return 0.0;
  return dot / (sqrt(normA) * sqrt(normB));
}
