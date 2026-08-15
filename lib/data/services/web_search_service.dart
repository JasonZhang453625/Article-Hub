import 'dart:convert';
import 'dart:developer' as developer;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

import '../../config/backend_config.dart';
import 'auth_service.dart';

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

abstract interface class WebSearchGateway {
  bool get isConfigured;
  String? get lastError;

  Future<List<WebSearchResult>> search(String query, {int topK = 5});

  void dispose();
}

class WebSearchException implements Exception {
  final String code;
  final String message;
  final int? statusCode;
  final bool retryable;

  const WebSearchException({
    required this.code,
    required this.message,
    this.statusCode,
    this.retryable = false,
  });

  bool get isDailyQuotaExceeded =>
      statusCode == 429 && code == 'daily_quota_exceeded';

  @override
  String toString() => message;
}

/// Parses the `results` array of a Tavily `/search` response.
/// Pure and unit-testable.
List<WebSearchResult> parseTavilyResults(Map<String, dynamic> json) {
  final rawResults = json['results'];
  if (rawResults is! List) return const [];
  final results = <WebSearchResult>[];
  for (final raw in rawResults.take(10)) {
    if (raw is! Map) continue;
    final title = _boundedText(raw['title'], maxRunes: 300);
    final url = raw['url'] is String ? (raw['url'] as String).trim() : '';
    final content = _boundedText(raw['content'], maxRunes: 12000);
    if (!_isSafeWebResultUrl(url)) continue;
    results.add(
      WebSearchResult(
        title: title,
        url: url,
        content: content,
        score: _boundedScore(raw['score']),
      ),
    );
  }
  return results;
}

String _boundedText(Object? value, {required int maxRunes}) {
  if (value is! String) return '';
  final trimmed = value.trim();
  return String.fromCharCodes(trimmed.runes.take(maxRunes)).trimRight();
}

double _boundedScore(Object? value) {
  if (value is! num) return 0;
  final score = value.toDouble();
  if (!score.isFinite) return 0;
  return score.clamp(0.0, 1.0).toDouble();
}

bool _isSafeWebResultUrl(String value) {
  if (value.isEmpty || value.length > 2048) return false;
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasAuthority) return false;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return false;
  if (uri.userInfo.isNotEmpty || uri.authority.contains('@')) return false;
  if (uri.authority.startsWith('[')) return false;

  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.+$'), '');
  if (host.isEmpty ||
      host == 'localhost' ||
      host.endsWith('.localhost') ||
      host == 'local' ||
      host.endsWith('.local') ||
      host == 'internal' ||
      host.endsWith('.internal') ||
      _isIpLiteral(host)) {
    return false;
  }
  return true;
}

bool _isIpLiteral(String host) {
  if (host.contains(':')) return true;
  final parts = host.split('.');
  if (parts.length > 4) return false;
  return parts.every(
    (part) =>
        RegExp(r'^\d+$').hasMatch(part) ||
        RegExp(r'^0x[0-9a-f]+$').hasMatch(part),
  );
}

/// Keeps Tavily queries within its recommended 400-character limit while
/// preserving Unicode scalar values (so an emoji is never cut in half).
String normalizeWebSearchQuery(String query, {int maxCharacters = 400}) {
  final trimmed = query.trim();
  if (maxCharacters <= 0 || trimmed.isEmpty) return '';
  final runes = trimmed.runes;
  if (runes.length <= maxCharacters) return trimmed;
  return String.fromCharCodes(runes.take(maxCharacters)).trimRight();
}

/// Local cache of web search responses, keyed by account/provider namespace
/// and normalized query.
///
/// Stored in a dedicated Hive box (`web_search_cache`). Entries expire after
/// [ttl] so repeat questions are instant and free while stale results
/// eventually refresh. Also serves as an offline fallback when the network
/// call fails.
class WebSearchCache {
  static const String boxName = 'web_search_cache';
  static const Duration defaultTtl = Duration(hours: 24);
  static const String _namespaceMigrationKey =
      '__meta__:namespace-cache-v1-migrated';

  final Duration ttl;
  final String namespace;
  Box<Map>? _box;

  WebSearchCache({this.ttl = defaultTtl, this.namespace = 'local'});

  Future<Box<Map>> _openBox() async {
    final existing = _box;
    if (existing != null) return existing;
    final box = await Hive.openBox<Map>(boxName);
    final migration = box.get(_namespaceMigrationKey);
    if (migration?['complete'] != true) {
      // Legacy entries used only the normalized query as their key, so their
      // account/provider owner cannot be recovered safely. This is a cache:
      // discard it once instead of risking cross-account stale results.
      await box.clear();
      await box.put(_namespaceMigrationKey, {'complete': true});
    }
    _box = box;
    return box;
  }

  String _key(String query) =>
      '${namespace.trim().isEmpty ? 'local' : namespace.trim()}|'
      '${query.trim().toLowerCase()}';

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
    await box.put(_namespaceMigrationKey, {'complete': true});
  }

  void dispose() {}
}

/// Searches the web through the Tavily API (BYOK).
///
/// Follows the same contract as [EmbeddingService]: returns an empty list on
/// failure instead of throwing, so the RAG pipeline can degrade gracefully to
/// local-only answers. Successful responses are cached locally so repeat
/// questions are instant and free.
class WebSearchService implements WebSearchGateway {
  static const String _endpoint = 'https://api.tavily.com/search';

  final String apiKey;
  final Duration timeout;
  final WebSearchCache cache;

  @override
  String? lastError;

  WebSearchService({
    required this.apiKey,
    this.timeout = const Duration(seconds: 15),
    WebSearchCache? cache,
  }) : cache = cache ?? WebSearchCache();

  @override
  bool get isConfigured => apiKey.trim().isNotEmpty;

  /// Searches the web for [query], returning the top [topK] results.
  ///
  /// Order of resolution:
  /// 1. Fresh local cache hit → return instantly (free, offline-safe).
  /// 2. Live Tavily call → cache the response, return results.
  /// 3. Live call failed → stale cache (if any) as a graceful fallback.
  /// 4. Nothing anywhere → empty list (caller falls back to local only).
  @override
  Future<List<WebSearchResult>> search(String query, {int topK = 5}) async {
    lastError = null;
    final trimmed = normalizeWebSearchQuery(query);
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
      lastError = e.toString();
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

  @override
  void dispose() {}
}

/// Account-hosted Tavily gateway. The app sends only the query and account
/// access token; the backend owns the Tavily credential and daily quota.
class HostedWebSearchService implements WebSearchGateway {
  final http.Client _client;
  final AuthSession? Function() _getSession;
  final Future<AuthSession?> Function() _refreshSession;
  final Duration timeout;
  final WebSearchCache cache;

  @override
  String? lastError;

  HostedWebSearchService({
    http.Client? client,
    required AuthSession? Function() getSession,
    required Future<AuthSession?> Function() refreshSession,
    this.timeout = const Duration(seconds: 15),
    WebSearchCache? cache,
  }) : _client = client ?? http.Client(),
       _getSession = getSession,
       _refreshSession = refreshSession,
       cache = cache ?? WebSearchCache();

  @override
  bool get isConfigured => BackendConfig.isConfigured && _getSession() != null;

  @override
  Future<List<WebSearchResult>> search(String query, {int topK = 5}) async {
    lastError = null;
    final normalized = normalizeWebSearchQuery(query);
    if (normalized.isEmpty) return const [];

    final fresh = await cache.get(normalized);
    if (fresh != null && fresh.isNotEmpty) {
      return fresh.take(topK).toList(growable: false);
    }

    try {
      var session = await _usableSession();
      if (session == null) {
        throw const WebSearchException(
          code: 'login_required',
          message: 'Sign in to use hosted web search.',
          statusCode: 401,
        );
      }
      var response = await _searchLive(
        normalized,
        topK: topK,
        session: session,
      );
      if (response.statusCode == 401) {
        session = await _refreshSession();
        if (session == null) {
          throw const WebSearchException(
            code: 'login_required',
            message: 'Your session has expired. Sign in again.',
            statusCode: 401,
          );
        }
        response = await _searchLive(normalized, topK: topK, session: session);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _decodeError(response);
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Unexpected hosted web-search response');
      }
      final results = parseTavilyResults(decoded);
      if (results.isNotEmpty) await cache.put(normalized, results);
      return results.take(topK).toList(growable: false);
    } on WebSearchException catch (error) {
      lastError = error.message;
      if (error.isDailyQuotaExceeded) rethrow;
      final stale = await cache.getStale(normalized);
      return stale?.take(topK).toList(growable: false) ?? const [];
    } catch (error) {
      lastError = error.toString();
      final stale = await cache.getStale(normalized);
      return stale?.take(topK).toList(growable: false) ?? const [];
    }
  }

  Future<AuthSession?> _usableSession() async {
    final session = _getSession();
    if (session == null) return null;
    if (session.hasValidAccessToken) return session;
    return _refreshSession();
  }

  Future<http.Response> _searchLive(
    String query, {
    required int topK,
    required AuthSession session,
  }) {
    return _client
        .post(
          BackendConfig.uri('/ai/web-search'),
          headers: {
            'Authorization': 'Bearer ${session.accessToken}',
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode({'query': query, 'max_results': topK.clamp(1, 5)}),
        )
        .timeout(timeout);
  }

  WebSearchException _decodeError(http.Response response) {
    var code = response.statusCode == 429
        ? 'rate_limited'
        : 'web_search_failed';
    var message = 'Web search failed.';
    var retryable = response.statusCode == 429 || response.statusCode >= 500;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map) {
          if (error['code'] is String) code = error['code'] as String;
          if (error['message'] is String) message = error['message'] as String;
          if (error['retryable'] is bool) {
            retryable = error['retryable'] as bool;
          }
        }
      }
    } catch (_) {}
    return WebSearchException(
      code: code,
      message: message,
      statusCode: response.statusCode,
      retryable: retryable,
    );
  }

  @override
  void dispose() => _client.close();
}
