import '../models/memory_document.dart';
import '../models/passage.dart';
import 'rag_citation.dart';

class RagEvidence {
  final String text;
  final double score;
  final int sourceOrder;

  const RagEvidence({
    required this.text,
    required this.score,
    required this.sourceOrder,
  });
}

class RagRankedArticle {
  final Article article;
  final double score;
  final int originalRank;
  final List<RagEvidence> evidence;

  const RagRankedArticle({
    required this.article,
    required this.score,
    required this.originalRank,
    required this.evidence,
  });
}

class RagContextPackage {
  final String text;
  final List<Article> articles;
  final Map<String, String> citationMap;
  final int estimatedTokens;

  const RagContextPackage({
    required this.text,
    required this.articles,
    required this.citationMap,
    required this.estimatedTokens,
  });
}

/// Reorders retrieved articles and their evidence units using deterministic,
/// local lexical relevance. The original retrieval rank remains a tie-breaker.
class RagEvidenceReranker {
  const RagEvidenceReranker();

  List<RagRankedArticle> rerank(String query, List<Article> candidates) {
    final terms = _terms(query);
    final normalizedQuery = _compact(query);
    final ranked = <RagRankedArticle>[];

    for (
      var articleIndex = 0;
      articleIndex < candidates.length;
      articleIndex++
    ) {
      final article = candidates[articleIndex];
      final seeds = _evidenceSeeds(article);
      final evidence = <RagEvidence>[];
      for (
        var evidenceIndex = 0;
        evidenceIndex < seeds.length;
        evidenceIndex++
      ) {
        evidence.add(
          RagEvidence(
            text: seeds[evidenceIndex],
            score: _score(seeds[evidenceIndex], terms, normalizedQuery),
            sourceOrder: evidenceIndex,
          ),
        );
      }
      evidence.sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        return byScore != 0 ? byScore : a.sourceOrder.compareTo(b.sourceOrder);
      });

      final titleScore = _score(article.title, terms, normalizedQuery) * 3;
      final tagScore =
          _score(article.tags.join(' '), terms, normalizedQuery) * 2;
      final evidenceScore = evidence.isEmpty ? 0.0 : evidence.first.score;
      final rankTieBreaker = 1 / (articleIndex + 1);
      ranked.add(
        RagRankedArticle(
          article: article,
          score: titleScore + tagScore + evidenceScore + rankTieBreaker,
          originalRank: articleIndex,
          evidence: List.unmodifiable(evidence),
        ),
      );
    }

    ranked.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.originalRank.compareTo(b.originalRank);
    });
    return List.unmodifiable(ranked);
  }
}

/// Packs reranked evidence into a single bounded context shared by all
/// candidates. This replaces fixed per-article character truncation.
class RagContextBuilder {
  final RagEvidenceReranker reranker;
  final int maxArticles;
  final int maxEvidencePerArticle;

  const RagContextBuilder({
    this.reranker = const RagEvidenceReranker(),
    this.maxArticles = 5,
    this.maxEvidencePerArticle = 4,
  });

  RagContextPackage build({
    required String query,
    required List<Article> candidates,
    int tokenBudget = 2200,
  }) {
    if (tokenBudget <= 0 || candidates.isEmpty) {
      return const RagContextPackage(
        text: '',
        articles: [],
        citationMap: {},
        estimatedTokens: 0,
      );
    }

    final ranked = reranker.rerank(query, candidates);
    final selected = <_SelectedArticle>[];
    var usedTokens = 0;

    for (final item in ranked.take(maxArticles)) {
      if (item.evidence.isEmpty) continue;
      final citationNumber = selected.length + 1;
      final header = _header(citationNumber, item.article);
      final headerTokens = estimateTokens(header);
      final linePrefixTokens = estimateTokens('- ');
      final remaining =
          tokenBudget - usedTokens - headerTokens - linePrefixTokens;
      if (remaining <= 0) break;

      var bestText = item.evidence.first.text;
      if (estimateTokens(bestText) > remaining) {
        bestText = _truncateToTokens(bestText, remaining);
      }
      if (bestText.trim().isEmpty) continue;

      final evidenceTokens = estimateTokens('- $bestText\n');
      final total = headerTokens + evidenceTokens;
      if (usedTokens + total > tokenBudget) continue;
      selected.add(
        _SelectedArticle(
          ranked: item,
          evidence: [item.evidence.first],
          renderedEvidence: [bestText],
        ),
      );
      usedTokens += total;
    }

    final extras = <_ExtraEvidence>[];
    for (
      var selectedIndex = 0;
      selectedIndex < selected.length;
      selectedIndex++
    ) {
      final evidence = selected[selectedIndex].ranked.evidence;
      for (
        var evidenceIndex = 1;
        evidenceIndex < evidence.length &&
            evidenceIndex < maxEvidencePerArticle;
        evidenceIndex++
      ) {
        extras.add(
          _ExtraEvidence(
            selectedIndex: selectedIndex,
            evidence: evidence[evidenceIndex],
          ),
        );
      }
    }
    extras.sort((a, b) => b.evidence.score.compareTo(a.evidence.score));

    for (final extra in extras) {
      final text = extra.evidence.text;
      final tokens = estimateTokens('- $text\n');
      if (usedTokens + tokens > tokenBudget) continue;
      final target = selected[extra.selectedIndex];
      target.evidence.add(extra.evidence);
      target.renderedEvidence.add(text);
      usedTokens += tokens;
    }

    final buffer = StringBuffer();
    for (var i = 0; i < selected.length; i++) {
      final item = selected[i];
      buffer.write(_header(i + 1, item.ranked.article));
      for (final evidence in item.renderedEvidence) {
        buffer.writeln('- $evidence');
      }
      buffer.writeln();
    }
    final rendered = buffer.toString().trim();
    final articles = selected.map((item) => item.ranked.article).toList();

    return RagContextPackage(
      text: rendered,
      articles: List.unmodifiable(articles),
      citationMap: buildCitationMap(
        articles.map((article) => article.id).toList(),
      ),
      estimatedTokens: estimateTokens(rendered),
    );
  }

  static int estimateTokens(String text) => _estimateTokens(text);
}

class _SelectedArticle {
  final RagRankedArticle ranked;
  final List<RagEvidence> evidence;
  final List<String> renderedEvidence;

  _SelectedArticle({
    required this.ranked,
    required this.evidence,
    required this.renderedEvidence,
  });
}

class _ExtraEvidence {
  final int selectedIndex;
  final RagEvidence evidence;

  const _ExtraEvidence({required this.selectedIndex, required this.evidence});
}

String _header(int citationNumber, Article article) {
  final tags = article.tags.isEmpty ? '' : '\nTags: ${article.tags.join(', ')}';
  return '[$citationNumber] ${article.title}$tags\nEvidence:\n';
}

List<String> _evidenceSeeds(Article article) {
  final memory = article.memory;
  if (memory?.kind == MemoryKind.aiMemory) {
    return [
      if (memory!.overview.trim().isNotEmpty) memory.overview.trim(),
      for (final point in [
        ...memory.keyPoints,
      ]..sort((a, b) => a.order.compareTo(b.order)))
        if (point.content.trim().isNotEmpty)
          point.topic.trim().isEmpty
              ? point.content.trim()
              : '${point.topic.trim()}: ${point.content.trim()}',
      if (memory.conclusion.trim().isNotEmpty) memory.conclusion.trim(),
    ];
  }

  return _chunkLegacyText(article.retrievalText);
}

List<String> _chunkLegacyText(String text) {
  final chunks = <String>[];
  for (final paragraph in text.split(RegExp(r'\n+'))) {
    final trimmed = paragraph.trim();
    if (trimmed.isEmpty) continue;
    const maxChars = 360;
    const overlap = 40;
    if (trimmed.length <= maxChars) {
      chunks.add(trimmed);
      continue;
    }
    var start = 0;
    while (start < trimmed.length) {
      final end = (start + maxChars).clamp(0, trimmed.length);
      chunks.add(trimmed.substring(start, end).trim());
      if (end >= trimmed.length) break;
      start = end - overlap;
    }
  }
  return chunks;
}

double _score(String text, Set<String> queryTerms, String normalizedQuery) {
  if (text.trim().isEmpty) return 0;
  final lower = text.toLowerCase();
  var score = 0.0;
  for (final term in queryTerms) {
    if (lower.contains(term)) {
      score += term.runes.length > 1 ? 2 : 0.5;
    }
  }
  if (normalizedQuery.runes.length >= 3 &&
      _compact(text).contains(normalizedQuery)) {
    score += 8;
  }
  return score;
}

Set<String> _terms(String text) {
  final lower = text.toLowerCase();
  final terms = <String>{};
  const englishStopwords = {
    'the',
    'a',
    'an',
    'is',
    'are',
    'of',
    'to',
    'and',
    'or',
    'how',
    'what',
    'does',
  };
  for (final match in RegExp(r'[a-z0-9_\-]+').allMatches(lower)) {
    final word = match.group(0)!;
    if (word.length > 1 && !englishStopwords.contains(word)) terms.add(word);
  }

  const cjkStopwords = {'的', '了', '是', '有', '和', '与', '在', '吗', '呢', '么'};
  final cjk = lower.runes.where(_isCjk).map(String.fromCharCode).toList();
  for (var i = 0; i < cjk.length; i++) {
    final character = cjk[i];
    if (!cjkStopwords.contains(character)) terms.add(character);
    if (i + 1 < cjk.length) {
      final pair = '$character${cjk[i + 1]}';
      if (!cjkStopwords.contains(character) &&
          !cjkStopwords.contains(cjk[i + 1])) {
        terms.add(pair);
      }
    }
  }
  return terms;
}

String _compact(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), '')
    .replaceAll(RegExp(r'[^a-z0-9\u3400-\u9fff]'), '');

bool _isCjk(int rune) =>
    (rune >= 0x3400 && rune <= 0x4DBF) || (rune >= 0x4E00 && rune <= 0x9FFF);

int _estimateTokens(String text) {
  var cjkTokens = 0;
  var otherCharacters = 0;
  for (final rune in text.runes) {
    if (_isCjk(rune)) {
      cjkTokens++;
    } else if (!RegExp(r'\s').hasMatch(String.fromCharCode(rune))) {
      otherCharacters++;
    }
  }
  if (cjkTokens == 0 && otherCharacters == 0) return 0;
  return cjkTokens + ((otherCharacters + 3) ~/ 4);
}

String _truncateToTokens(String text, int tokenBudget) {
  if (tokenBudget <= 0) return '';
  final runes = text.runes.toList();
  var low = 0;
  var high = runes.length;
  while (low < high) {
    final middle = (low + high + 1) ~/ 2;
    final candidate = String.fromCharCodes(runes.take(middle));
    if (_estimateTokens(candidate) <= tokenBudget) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  return String.fromCharCodes(runes.take(low)).trim();
}
