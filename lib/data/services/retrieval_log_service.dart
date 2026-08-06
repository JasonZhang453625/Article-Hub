import 'dart:developer' as developer;
import 'package:hive_flutter/hive_flutter.dart';

/// A single retrieval log entry recorded locally after each RAG query.
class RetrievalLog {
  final String id;
  final String query;
  final String? rewrittenQuery;
  final String method; // vector, keyword, none, web
  final List<String> candidateIds;
  final List<String> citedIds;
  final int durationMs;
  final DateTime timestamp;
  final int? feedback; // null = not rated, 1 = useful, -1 = not useful
  final List<String> clickedCitationIds;

  /// Web URLs offered to the model in a web-fallback turn.
  final List<String> webCandidateUrls;

  /// Web URLs the model actually cited (via `[wN]`).
  final List<String> webCitedUrls;

  RetrievalLog({
    required this.id,
    required this.query,
    this.rewrittenQuery,
    required this.method,
    required this.candidateIds,
    this.citedIds = const [],
    required this.durationMs,
    DateTime? timestamp,
    this.feedback,
    this.clickedCitationIds = const [],
    this.webCandidateUrls = const [],
    this.webCitedUrls = const [],
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toMap() => {
    'id': id,
    'query': query,
    'rewrittenQuery': rewrittenQuery,
    'method': method,
    'candidateIds': candidateIds,
    'citedIds': citedIds,
    'durationMs': durationMs,
    'timestamp': timestamp.toIso8601String(),
    'feedback': feedback,
    'clickedCitationIds': clickedCitationIds,
    'webCandidateUrls': webCandidateUrls,
    'webCitedUrls': webCitedUrls,
  };

  factory RetrievalLog.fromMap(Map<dynamic, dynamic> map) {
    return RetrievalLog(
      id: map['id'] as String,
      query: map['query'] as String,
      rewrittenQuery: map['rewrittenQuery'] as String?,
      method: map['method'] as String,
      candidateIds: (map['candidateIds'] as List).cast<String>(),
      citedIds: (map['citedIds'] as List?)?.cast<String>() ?? const [],
      durationMs: map['durationMs'] as int,
      timestamp: DateTime.parse(map['timestamp'] as String),
      feedback: map['feedback'] as int?,
      clickedCitationIds:
          (map['clickedCitationIds'] as List?)?.cast<String>() ?? const [],
      webCandidateUrls:
          (map['webCandidateUrls'] as List?)?.cast<String>() ?? const [],
      webCitedUrls: (map['webCitedUrls'] as List?)?.cast<String>() ?? const [],
    );
  }

  RetrievalLog copyWith({
    int? feedback,
    List<String>? clickedCitationIds,
    List<String>? citedIds,
    List<String>? webCitedUrls,
  }) {
    return RetrievalLog(
      id: id,
      query: query,
      rewrittenQuery: rewrittenQuery,
      method: method,
      candidateIds: candidateIds,
      citedIds: citedIds ?? this.citedIds,
      durationMs: durationMs,
      timestamp: timestamp,
      feedback: feedback ?? this.feedback,
      clickedCitationIds: clickedCitationIds ?? this.clickedCitationIds,
      webCandidateUrls: webCandidateUrls,
      webCitedUrls: webCitedUrls ?? this.webCitedUrls,
    );
  }
}

/// Manages local-only retrieval logs for analytics and quality tracking.
class RetrievalLogService {
  static const String _boxName = 'retrieval_logs';
  Box<Map>? _box;

  Future<Box<Map>> _openBox() async {
    _box ??= await Hive.openBox<Map>(_boxName);
    return _box!;
  }

  Future<void> save(RetrievalLog log) async {
    final box = await _openBox();
    await box.put(log.id, log.toMap());
    developer.log(
      'retrieval log saved: ${log.method} ${log.candidateIds.length} candidates',
      name: 'memora.retrieval_log',
    );
  }

  Future<void> updateFeedback(String logId, int feedback) async {
    final box = await _openBox();
    final raw = box.get(logId);
    if (raw == null) return;
    final log = RetrievalLog.fromMap(raw);
    await box.put(logId, log.copyWith(feedback: feedback).toMap());
  }

  Future<void> recordCitationClick(String logId, String articleId) async {
    final box = await _openBox();
    final raw = box.get(logId);
    if (raw == null) return;
    final log = RetrievalLog.fromMap(raw);
    if (log.clickedCitationIds.contains(articleId)) return;
    await box.put(
      logId,
      log
          .copyWith(clickedCitationIds: [...log.clickedCitationIds, articleId])
          .toMap(),
    );
  }

  Future<List<RetrievalLog>> getAll() async {
    final box = await _openBox();
    return box.values.map((raw) => RetrievalLog.fromMap(raw)).toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  }

  /// Returns basic stats for the quality dashboard.
  Future<({int total, int useful, int notUseful, int noResult})>
  getStats() async {
    final logs = await getAll();
    int useful = 0, notUseful = 0, noResult = 0;
    for (final log in logs) {
      if (log.method == 'none') noResult++;
      if (log.feedback == 1) useful++;
      if (log.feedback == -1) notUseful++;
    }
    return (
      total: logs.length,
      useful: useful,
      notUseful: notUseful,
      noResult: noResult,
    );
  }

  Future<void> clear() async {
    final box = await _openBox();
    await box.clear();
  }

  void dispose() {}
}
