import 'dart:convert';

import '../models/memory_document.dart';
import '../models/passage.dart';
import 'agent_client_tool_api.dart';
import 'agent_client_tool_store.dart';
import 'hosted_ai_capabilities.dart';
import 'rag_context_builder.dart';
import 'retrieval_service.dart';

class AgentClientToolBudgetExhausted implements Exception {
  const AgentClientToolBudgetExhausted();

  @override
  String toString() => 'Client-tool run result budget is exhausted.';
}

class AgentClientToolExecutor {
  static const int localMaxResults = 5;
  static const int localMaxSnippetsPerResult = 2;
  static const int localMaxResultBytes = 16 * 1024;
  static const int localMaxResultTokens = 1200;
  static const int localMaxReadResultBytes = 24 * 1024;
  static const int localMaxReadResultTokens = 4000;
  static const int localMaxReadSections = 12;

  final RetrievalService _retrieval;
  final AgentClientToolStore _store;
  final RagEvidenceReranker _reranker;

  const AgentClientToolExecutor({
    required RetrievalService retrieval,
    required AgentClientToolStore store,
    RagEvidenceReranker reranker = const RagEvidenceReranker(),
  }) : _retrieval = retrieval,
       _store = store,
       _reranker = reranker;

  Future<Map<String, dynamic>> execute({
    required AgentToolRunBinding binding,
    required AgentClientToolCall call,
    required List<Article> articles,
    required HostedAgentClientToolsCapabilities capabilities,
    AgentToolGenerationGuard? guard,
  }) {
    final eligible = articles
        .where(
          (article) =>
              article.processingStatus == ProcessingStatus.completed &&
              article.hasMemory,
        )
        .toList(growable: false);
    return switch (call.tool) {
      'local_search' => _localSearch(
        binding: binding,
        query: call.arguments['query'] as String,
        articles: eligible,
        limits: capabilities.localSearch,
        remainingResultBytes: call.remainingResultBytes,
        guard: guard,
      ),
      'read_article' => _readArticle(
        binding: binding,
        articleRef: call.arguments['article_ref'] as String,
        articles: eligible,
        limits: capabilities.readArticle,
        remainingResultBytes: call.remainingResultBytes,
        guard: guard,
      ),
      _ => throw const FormatException('Unsupported client tool.'),
    };
  }

  Future<Map<String, dynamic>> _localSearch({
    required AgentToolRunBinding binding,
    required String query,
    required List<Article> articles,
    required HostedAgentLocalSearchLimits limits,
    required int remainingResultBytes,
    required AgentToolGenerationGuard? guard,
  }) async {
    final maxResults = _min(limits.maxResults, localMaxResults);
    final maxSnippets = _min(
      limits.maxSnippetsPerResult,
      localMaxSnippetsPerResult,
    );
    final maxBytes = _min(
      _min(limits.maxResultBytes, localMaxResultBytes),
      remainingResultBytes,
    );
    final maxTokens = _min(limits.maxResultTokens, localMaxResultTokens);
    final empty = _emptySearchResult();
    if (!_fits(empty, maxBytes, maxTokens)) {
      throw const AgentClientToolBudgetExhausted();
    }
    if (articles.isEmpty) return empty;

    guard?.call();
    final retrieved = await _retrieval.retrieveLocalOnly(
      query.trim(),
      articles,
    );
    guard?.call();
    final ranked = _reranker.rerank(query, retrieved.articles);
    final results = <Map<String, dynamic>>[];
    var truncated = ranked.length > maxResults;
    for (final rankedArticle in ranked.take(maxResults)) {
      final article = rankedArticle.article;
      final title = _safeTitle(article);
      guard?.call();
      final reference = await _store.createArticleReference(
        binding: binding,
        articleId: article.id,
        title: title,
      );
      guard?.call();
      final snippets = <Map<String, dynamic>>[];
      final evidence = rankedArticle.evidence
          .where((item) => item.text.trim().isNotEmpty)
          .take(maxSnippets);
      for (final item in evidence) {
        final text = _sanitizeEvidence(item.text, article: article);
        if (text.isEmpty) continue;
        snippets.add({
          'kind': _safeKind(item.label, fallback: 'excerpt'),
          'text': _truncateRunes(text, 4000),
        });
      }
      if (snippets.isEmpty) continue;
      results.add({
        'article_ref': reference.articleRef,
        'title': _truncateRunes(title, 500),
        'snippets': snippets,
      });
    }

    Map<String, dynamic> result() => {
      'schemaVersion': 1,
      'status': results.isEmpty ? 'empty' : 'ok',
      'results': results,
      'truncated': truncated,
    };

    while (results.isNotEmpty && !_fits(result(), maxBytes, maxTokens)) {
      final snippets = results.last['snippets'] as List<Map<String, dynamic>>;
      if (snippets.length > 1) {
        snippets.removeLast();
        truncated = true;
        continue;
      }
      final text = snippets.first['text'] as String;
      final shortened = _shrinkToFit(text, (candidate) {
        snippets.first['text'] = candidate;
        return _fits(result(), maxBytes, maxTokens);
      });
      snippets.first['text'] = shortened;
      if (shortened.isNotEmpty && _fits(result(), maxBytes, maxTokens)) {
        truncated = true;
        break;
      }
      results.removeLast();
      truncated = true;
    }
    return result();
  }

  Future<Map<String, dynamic>> _readArticle({
    required AgentToolRunBinding binding,
    required String articleRef,
    required List<Article> articles,
    required HostedAgentClientToolResultLimits limits,
    required int remainingResultBytes,
    required AgentToolGenerationGuard? guard,
  }) async {
    final maxBytes = _min(
      _min(limits.maxResultBytes, localMaxReadResultBytes),
      remainingResultBytes,
    );
    final maxTokens = _min(limits.maxResultTokens, localMaxReadResultTokens);
    Map<String, dynamic> notFound({bool truncated = false}) => {
      'schemaVersion': 1,
      'status': 'not_found',
      'article_ref': articleRef,
      'title': '',
      'sections': <Map<String, dynamic>>[],
      'truncated': truncated,
    };
    if (!_fits(notFound(), maxBytes, maxTokens)) {
      throw const AgentClientToolBudgetExhausted();
    }
    guard?.call();
    final reference = await _store.resolveArticleReference(
      binding: binding,
      articleRef: articleRef,
    );
    guard?.call();
    final article = reference == null
        ? null
        : articles.where((item) => item.id == reference.articleId).firstOrNull;
    if (article == null) {
      return notFound();
    }

    final allSections = _sections(article);
    final sections = allSections.take(localMaxReadSections).toList();
    var truncated = allSections.length > sections.length;
    Map<String, dynamic> result() => {
      'schemaVersion': 1,
      'status': 'ok',
      'article_ref': articleRef,
      'title': _truncateRunes(_safeTitle(article), 500),
      'sections': sections,
      'truncated': truncated,
    };

    while (sections.isNotEmpty && !_fits(result(), maxBytes, maxTokens)) {
      final text = sections.last['text'] as String;
      final shortened = _shrinkToFit(text, (candidate) {
        sections.last['text'] = candidate;
        return _fits(result(), maxBytes, maxTokens);
      });
      sections.last['text'] = shortened;
      if (shortened.isNotEmpty && _fits(result(), maxBytes, maxTokens)) {
        truncated = true;
        break;
      }
      sections.removeLast();
      truncated = true;
    }
    if (sections.isEmpty) {
      return notFound(truncated: true);
    }
    return result();
  }

  List<Map<String, dynamic>> _sections(Article article) {
    final memory = article.memory;
    final result = <Map<String, dynamic>>[];
    if (memory?.kind == MemoryKind.aiMemory) {
      final overview = _sanitizeEvidence(memory!.overview, article: article);
      if (overview.isNotEmpty) {
        result.add({
          'kind': 'overview',
          'text': _truncateRunes(overview, 8000),
        });
      }
      final points = [...memory.keyPoints]
        ..sort((a, b) => a.order.compareTo(b.order));
      for (final point in points) {
        final text = _sanitizeEvidence(point.content, article: article);
        if (text.isEmpty) continue;
        final topic = _sanitizeEvidence(point.topic, article: article);
        result.add({
          'kind': 'key_point',
          if (topic.isNotEmpty) 'topic': _truncateRunes(topic, 500),
          'text': _truncateRunes(text, 8000),
        });
      }
      final conclusion = _sanitizeEvidence(memory.conclusion, article: article);
      if (conclusion.isNotEmpty) {
        result.add({
          'kind': 'conclusion',
          'text': _truncateRunes(conclusion, 8000),
        });
      }
      return result;
    }

    final text = _sanitizeEvidence(article.retrievalText, article: article);
    for (final chunk in _boundedChunks(text, 1800)) {
      if (chunk.isNotEmpty) {
        result.add({'kind': 'excerpt', 'text': chunk});
      }
    }
    return result;
  }

  static Map<String, dynamic> _emptySearchResult() => {
    'schemaVersion': 1,
    'status': 'empty',
    'results': <Map<String, dynamic>>[],
    'truncated': false,
  };

  static String _safeTitle(Article article) {
    final title = article.title.trim();
    if (title.isEmpty || _looksLikeUrl(title) || title == article.url.trim()) {
      return 'Saved article';
    }
    final sanitized = _sanitizeEvidence(title, article: article);
    return sanitized.isEmpty ? 'Saved article' : sanitized;
  }

  static String _sanitizeEvidence(String value, {required Article article}) {
    var text = value.trim();
    for (final secret in [
      article.id,
      article.url,
      article.localFilePath ?? '',
    ]) {
      if (secret.trim().isNotEmpty) {
        text = text.replaceAll(secret, '[redacted]');
      }
    }
    text = text
        .replaceAll(
          RegExp(r'https?://[^\s<>()]+', caseSensitive: false),
          '[url]',
        )
        .replaceAll(
          RegExp(r'(?:file|content)://[^\s<>()]+', caseSensitive: false),
          '[local-path]',
        )
        .replaceAll(RegExp(r'\b[A-Za-z]:\\[^\r\n\t]+'), '[local-path]')
        .replaceAll(RegExp(r'(?<!\w)/(?:[^\s/]+/)+[^\s]+'), '[local-path]')
        .replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]'), ' ')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    return text;
  }

  static bool _fits(Map<String, dynamic> value, int maxBytes, int maxTokens) {
    final encoded = jsonEncode(value);
    return utf8.encode(encoded).length <= maxBytes &&
        RagContextBuilder.estimateTokens(encoded) <= maxTokens;
  }

  static String _shrinkToFit(
    String value,
    bool Function(String candidate) fits,
  ) {
    final runes = value.runes.toList(growable: false);
    var low = 0;
    var high = runes.length;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      final candidate = String.fromCharCodes(runes.take(middle)).trim();
      if (candidate.isNotEmpty && fits(candidate)) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return String.fromCharCodes(runes.take(low)).trim();
  }

  static List<String> _boundedChunks(String text, int maxRunes) {
    final runes = text.runes.toList(growable: false);
    final chunks = <String>[];
    for (var start = 0; start < runes.length; start += maxRunes) {
      chunks.add(String.fromCharCodes(runes.skip(start).take(maxRunes)).trim());
    }
    return chunks;
  }

  static String _safeKind(String label, {required String fallback}) {
    final normalized = switch (label.trim()) {
      '概述' => 'overview',
      '要点' => 'key_point',
      '结论' => 'conclusion',
      final value when RegExp(r'^[A-Za-z0-9_-]{1,32}$').hasMatch(value) =>
        value,
      _ => fallback,
    };
    return normalized;
  }

  static bool _looksLikeUrl(String value) =>
      Uri.tryParse(value)?.hasAbsolutePath == true &&
      (value.startsWith('http://') || value.startsWith('https://'));

  static String _truncateRunes(String value, int maxRunes) {
    final runes = value.runes.toList(growable: false);
    if (runes.length <= maxRunes) return value;
    return String.fromCharCodes(runes.take(maxRunes)).trim();
  }

  static int _min(int first, int second) => first < second ? first : second;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
