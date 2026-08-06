import 'dart:convert';
import 'dart:developer' as developer;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

/// A single web search hit returned by the search backend.
class WebSearchResult {
  final String title;
  final String url;
  final String content;
  final double score;

  const WebSearchResult({
    required this.title,
    required this.url,
    required this.content,
    this.score = 0,
  });

  Map<String, dynamic> toMap() => {
    'title': title,
    'url': url,
    'content': content,
    'score': score,
  };

  factory WebSearchResult.fromMap(Map<dynamic, dynamic> map) {
    return WebSearchResult(
      title: map['title'] as String? ?? '',
      url: map['url'] as String? ?? '',
      content: map['content'] as String? ?? '',
      score: (map['score'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// Parses the `results` array of a Tavily `/search` response.
/// Pure and unit-testable.
List<WebSearchResult> parseTavilyResults(Map<String, dynamic> json) {
  final rawResults = json['results'];
  if (rawResults is! List) return const [];
  final results = <WebSearchResult>[];
  for (final raw in rawResults) {
    if (raw is! Map) continue;
    final title = (raw['title'] as String?)?.trim() ?? '';
    final url = (raw['url'] as String?)?.trim() ?? '';
    final content = (raw['content'] as String?)?.trim() ?? '';
    if (url.isEmpty) continue;
    results.add(
      WebSearchResult(
        title: title,
        url: url,
        content: content,
        score: (raw['score'] as num?)?.toDouble() ?? 0,
      ),
    );
  }
  return results;
}

/// Local cache of web search responses, keyed by normalized query.
///
/// Stored in a dedicated Hive box (`web_search_cache`). Entries expire after
/// [ttl] so repeat questions are instant and free while stale results
/// eventually refresh. Also serves as an offline fallback when the network
/// call fails.
class WebSearchCache {
  static const String boxName = 'web_search_cache';
  static const Duration defaultTtl = Duration(hours: 24);

  final Duration ttl;
  Box<Map>? _box;

  WebSearchCache({this.ttl = defaultTtl});

  Future<Box<Map>> _openBox() async {
    _box ??= await Hive.openBox<Map>(boxName);
    return _box!;
  }

  String _key(String query) => query.trim().toLowerCase();

  /// Returns cached results for [query] if fresh, otherwise null.
  Future<List<WebSearchResult>?> get(String query) async {
    try {
      final box = await _openBox();
      final entry = box.get(_key(query));
      if (entry is! Map) return null;
      final fetchedAt = entry['fetchedAt'] as int? ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - fetchedAt >
          ttl.inMilliseconds) {
        return null;
      }
      final raw = entry['results'];
      if (raw is! List) return null;
      return raw
          .whereType<Map>()
          .map(WebSearchResult.fromMap)
          .toList(growable: false);
    } catch (e) {
      developer.log('web search cache read failed: $e', name: 'memora.web');
      return null;
    }
  }

  /// Returns any cached results for [query] regardless of age (offline
  /// fallback), or null when nothing was ever cached.
  Future<List<WebSearchResult>?> getStale(String query) async {
    try {
      final box = await _openBox();
      final entry = box.get(_key(query));
      if (entry is! Map) return null;
      final raw = entry['results'];
      if (raw is! List) return null;
      return raw
          .whereType<Map>()
          .map(WebSearchResult.fromMap)
          .toList(growable: false);
    } catch (_) {
      return null;
    }
  }

  Future<void> put(String query, List<WebSearchResult> results) async {
    try {
      final box = await _openBox();
      await box.put(_key(query), {
        'results': results.map((r) => r.toMap()).toList(),
        'fetchedAt': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      developer.log('web search cache write failed: $e', name: 'memora.web');
    }
  }

  Future<void> clear() async {
    final box = await _openBox();
    await box.clear();
  }

  void dispose() {}
}

/// Searches the web through the Tavily API (BYOK).
///
/// Follows the same contract as [EmbeddingService]: returns an empty list on
/// failure instead of throwing, so the RAG pipeline can degrade gracefully to
/// local-only answers. Successful responses are cached locally so repeat
/// questions are instant and free.
class WebSearchService {
  static const String _endpoint = 'https://api.tavily.com/search';

  final String apiKey;
  final Duration timeout;
  final WebSearchCache cache;

  WebSearchService({
    required this.apiKey,
    this.timeout = const Duration(seconds: 15),
    WebSearchCache? cache,
  }) : cache = cache ?? WebSearchCache();

  bool get isConfigured => apiKey.trim().isNotEmpty;

  /// Searches the web for [query], returning the top [topK] results.
  ///
  /// Order of resolution:
  /// 1. Fresh local cache hit → return instantly (free, offline-safe).
  /// 2. Live Tavily call → cache the response, return results.
  /// 3. Live call failed → stale cache (if any) as a graceful fallback.
  /// 4. Nothing anywhere → empty list (caller falls back to local only).
  Future<List<WebSearchResult>> search(
    String query, {
    int topK = 5,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty || !isConfigured) return const [];

    final fresh = await cache.get(trimmed);
    if (fresh != null && fresh.isNotEmpty) {
      developer.log(
        'web search cache hit: "$trimmed" (${fresh.length} results)',
        name: 'memora.web',
      );
      return fresh.take(topK).toList();
    }

    try {
      final results = await _searchLive(trimmed, topK: topK);
      if (results.isNotEmpty) {
        await cache.put(trimmed, results);
      }
      return results;
    } catch (e) {
      developer.log('web search failed, trying cache: $e', name: 'memora.web');
      final stale = await cache.getStale(trimmed);
      if (stale != null && stale.isNotEmpty) {
        return stale.take(topK).toList();
      }
      return const [];
    }
  }

  Future<List<WebSearchResult>> _searchLive(
    String query, {
    required int topK,
  }) async {
    final uri = Uri.parse(_endpoint);
    final body = jsonEncode({
      'query': query,
      'max_results': topK,
      'search_depth': 'basic',
      'include_answer': false,
      'include_raw_content': false,
    });
    final response = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${apiKey.trim()}',
          },
          body: body,
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      developer.log(
        'tavily error: HTTP ${response.statusCode}',
        name: 'memora.web',
      );
      throw Exception('Tavily HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Unexpected Tavily response shape');
    }
    final results = parseTavilyResults(decoded);
    developer.log(
      'web search live: "$query" → ${results.length} results',
      name: 'memora.web',
    );
    return results;
  }

  void dispose() {}
}
