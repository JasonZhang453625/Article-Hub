import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';
import 'package:http/http.dart' as http;

/// Result of an embedding API call.
class EmbeddingResult {
  final List<double> vector;
  final String model;
  final int tokenCount;

  const EmbeddingResult({
    required this.vector,
    required this.model,
    this.tokenCount = 0,
  });
}

/// Calls an OpenAI-compatible embeddings endpoint to convert text into vectors.
class EmbeddingService {
  final String baseUrl;
  final String apiKey;
  final String model;
  final Duration timeout;

  EmbeddingService({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.timeout = const Duration(seconds: 15),
  });

  bool get isConfigured =>
      baseUrl.trim().isNotEmpty && apiKey.trim().isNotEmpty && model.trim().isNotEmpty;

  Uri _embeddingsUri() {
    var base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (!base.endsWith('/v1') && !base.contains('/v1/')) {
      base = '$base/v1';
    }
    return Uri.parse('$base/embeddings');
  }

  /// Embed a single text string. Returns null on failure.
  Future<EmbeddingResult?> embed(String text) async {
    if (!isConfigured) return null;
    try {
      final uri = _embeddingsUri();
      final body = jsonEncode({
        'model': model,
        'input': text,
      });

      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: body,
          )
          .timeout(timeout);

      if (response.statusCode != 200) {
        developer.log(
          'embedding failed: ${response.statusCode}',
          name: 'article_hub.embedding',
        );
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final data = json['data'] as List?;
      if (data == null || data.isEmpty) return null;

      final embedding = data[0]['embedding'] as List?;
      if (embedding == null) return null;

      final vector = embedding.map((e) => (e as num).toDouble()).toList();
      final usage = json['usage'] as Map<String, dynamic>?;
      final tokenCount = usage?['total_tokens'] as int? ?? 0;

      return EmbeddingResult(
        vector: vector,
        model: model,
        tokenCount: tokenCount,
      );
    } catch (e, st) {
      developer.log(
        'embedding error',
        name: 'article_hub.embedding',
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

  /// Embed multiple texts in a single API call. Returns a list parallel to
  /// [texts] — a null entry means that text failed.
  /// This is far more efficient than calling [embed] in a loop because it
  /// avoids N TLS handshakes and HTTP round-trips.
  Future<List<EmbeddingResult?>> embedBatch(List<String> texts) async {
    if (!isConfigured || texts.isEmpty) return List.filled(texts.length, null);
    try {
      final uri = _embeddingsUri();
      final body = jsonEncode({
        'model': model,
        'input': texts,
      });

      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: body,
          )
          .timeout(Duration(seconds: timeout.inSeconds * 2));

      if (response.statusCode != 200) {
        developer.log(
          'batch embedding failed: ${response.statusCode}',
          name: 'article_hub.embedding',
        );
        return List.filled(texts.length, null);
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final dataList = json['data'] as List?;
      if (dataList == null || dataList.isEmpty) {
        return List.filled(texts.length, null);
      }

      final modelUsed = json['model'] as String? ?? model;
      final usage = json['usage'] as Map<String, dynamic>?;
      final totalTokens = usage?['total_tokens'] as int? ?? 0;

      // Build index → result map from the response.
      final results = <int, EmbeddingResult>{};
      for (final item in dataList) {
        final idx = item['index'] as int;
        final raw = item['embedding'] as List?;
        if (raw == null) continue;
        final vector = raw.map((e) => (e as num).toDouble()).toList();
        results[idx] = EmbeddingResult(
          vector: vector,
          model: modelUsed,
          tokenCount: totalTokens ~/ texts.length,
        );
      }

      // Map back in the same order as [texts].
      return [
        for (int i = 0; i < texts.length; i++) results[i],
      ];
    } catch (e, st) {
      developer.log(
        'batch embedding error',
        name: 'article_hub.embedding',
        error: e,
        stackTrace: st,
      );
      return List.filled(texts.length, null);
    }
  }

  /// Test the embedding endpoint. Returns true if a valid vector is returned.
  Future<bool> testConnection() async {
    final result = await embed('test connection');
    return result != null && result.vector.isNotEmpty;
  }

  void dispose() {}
}

/// Compute cosine similarity between two vectors.
double cosineSimilarity(List<double> a, List<double> b) {
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

/// Compute a simple content fingerprint (hash of the embedding input text).
/// Used to detect whether an article's index entry is stale.
int contentFingerprint(String title, String summary, List<String> tags) {
  final input = '$title||$summary||${tags.join(",")}';
  return input.hashCode;
}
