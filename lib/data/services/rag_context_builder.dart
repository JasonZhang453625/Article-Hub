import '../models/memory_document.dart';
import '../models/passage.dart';
import 'rag_citation.dart';

class RagEvidence {
  final String text;

  /// Evidence type label rendered as `[label] text`: 概述 / 要点 / 结论.
  /// Empty for legacy full-text chunks, which are rendered without a prefix.
  final String label;
  final double score;
  final int sourceOrder;

  const RagEvidence({
    required this.text,
    this.label = '',
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
            text: seeds[evidenceIndex].text,
            label: seeds[evidenceIndex].label,
            score: _score(seeds[evidenceIndex].text, terms, normalizedQuery),
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

      final evidence = item.evidence.first;
      final labelPrefix = _labelPrefix(evidence.label);
      var bestText = evidence.text;
      if (estimateTokens(evidence.text) > remaining) {
        bestText = _truncateToTokens(
          evidence.text,
          remaining - estimateTokens(labelPrefix),
        );
      }
      final renderedText = labelPrefix + bestText;
      if (renderedText.trim().isEmpty) continue;

      final evidenceTokens = estimateTokens('- $renderedText\n');
      final total = headerTokens + evidenceTokens;
      if (usedTokens + total > tokenBudget) continue;
      selected.add(
        _SelectedArticle(
          ranked: item,
          evidence: [evidence],
          renderedEvidence: [renderedText],
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
      final text = _labelPrefix(extra.evidence.label) + extra.evidence.text;
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

/// A candidate evidence seed before lexical scoring.
class _Seed {
  final String label;
  final String text;

  const _Seed(this.label, this.text);
}

String _labelPrefix(String label) => label.isEmpty ? '' : '[$label] ';

List<_Seed> _evidenceSeeds(Article article) {
  final memory = article.memory;
  if (memory?.kind == MemoryKind.aiMemory) {
    return [
      if (memory!.overview.trim().isNotEmpty)
        _Seed('概述', memory.overview.trim()),
      for (final point in [
        ...memory.keyPoints,
      ]..sort((a, b) => a.order.compareTo(b.order)))
        if (point.content.trim().isNotEmpty)
          _Seed(
            '要点',
            point.topic.trim().isEmpty
                ? point.content.trim()
                : '${point.topic.trim()}: ${point.content.trim()}',
          ),
      if (memory.conclusion.trim().isNotEmpty)
        _Seed('结论', memory.conclusion.trim()),
    ];
  }

  return _chunkLegacyText(
    article.retrievalText,
  ).map((chunk) => _Seed('', chunk)).toList();
}

/// Splits legacy full text into bounded chunks, preferring sentence
/// boundaries over hard character cuts.
List<String> _chunkLegacyText(String text) {
  const maxChars = 360;
  final chunks = <String>[];
  for (final paragraph in text.split(RegExp(r'\n+'))) {
    final trimmed = paragraph.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.length <= maxChars) {
      chunks.add(trimmed);
      continue;
    }

    final sentences = _splitSentences(trimmed);
    var current = <String>[];
    var currentLength = 0;
    for (final sentence in sentences) {
      if (sentence.length > maxChars) {
        // No sentence boundary nearby — hard-split the oversized sentence.
        if (current.isNotEmpty) {
          chunks.add(current.join(' '));
          current = <String>[];
          currentLength = 0;
        }
        for (var start = 0; start < sentence.length; start += maxChars) {
          final end = (start + maxChars).clamp(0, sentence.length);
          chunks.add(sentence.substring(start, end).trim());
        }
        continue;
      }
      final addLength = sentence.length + (current.isEmpty ? 0 : 1);
      if (current.isNotEmpty && currentLength + addLength > maxChars) {
        chunks.add(current.join(' '));
        current = [sentence];
        currentLength = sentence.length;
      } else {
        current.add(sentence);
        currentLength += addLength;
      }
    }
    if (current.isNotEmpty) chunks.add(current.join(' '));
  }
  return chunks;
}

/// Splits text on Chinese/English sentence terminators, keeping the
/// terminator attached to its sentence.
List<String> _splitSentences(String text) {
  final sentences = <String>[];
  var start = 0;
  for (final match in RegExp(r'[。！？!?\.]+').allMatches(text)) {
    final sentence = text.substring(start, match.end).trim();
    if (sentence.isNotEmpty) sentences.add(sentence);
    start = match.end;
  }
  final tail = text.substring(start).trim();
  if (tail.isNotEmpty) sentences.add(tail);
  return sentences;
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
