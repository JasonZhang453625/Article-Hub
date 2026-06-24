import 'package:flutter_test/flutter_test.dart';
import 'package:article_hub/data/services/rag_citation.dart';

/// Phase 3.4 adversarial tests: the model must never produce a citation that
/// points outside the candidate set or to a deleted article. The UI relies on
/// [extractValidCitations] to enforce this, so we attack it directly.
void main() {
  group('buildCitationMap', () {
    test('maps 1-based numbers to candidate IDs in order', () {
      final map = buildCitationMap(['a1', 'a2', 'a3']);
      expect(map['1'], 'a1');
      expect(map['2'], 'a2');
      expect(map['3'], 'a3');
    });

    test('empty candidate list yields empty map', () {
      expect(buildCitationMap([]), isEmpty);
    });
  });

  group('extractValidCitations: normal behavior', () {
    final citationMap = buildCitationMap(['a1', 'a2', 'a3']);
    final validIds = {'a1', 'a2', 'a3'};

    test('extracts cited article IDs from response', () {
      const response = 'Based on [1] and [3], the answer is yes.';
      final cited = extractValidCitations(
        response: response,
        citationMap: citationMap,
        validIds: validIds,
      );
      expect(cited, ['a1', 'a3']);
    });

    test('returns empty when no citations present', () {
      const response = 'I have no specific reference for this.';
      final cited = extractValidCitations(
        response: response,
        citationMap: citationMap,
        validIds: validIds,
      );
      expect(cited, isEmpty);
    });

    test('de-duplicates repeated citations', () {
      const response = 'See [1], and again [1], also [2] confirms [1].';
      final cited = extractValidCitations(
        response: response,
        citationMap: citationMap,
        validIds: validIds,
      );
      expect(cited, ['a1', 'a2']);
    });

    test('preserves candidate order regardless of mention order', () {
      const response = 'First [3], then [1].';
      final cited = extractValidCitations(
        response: response,
        citationMap: citationMap,
        validIds: validIds,
      );
      // Order follows citationMap (candidate order), not mention order.
      expect(cited, ['a1', 'a3']);
    });
  });

  group('extractValidCitations: adversarial cases', () {
    final citationMap = buildCitationMap(['a1', 'a2']);
    final validIds = {'a1', 'a2'};

    test('citation number beyond candidate count is ignored', () {
      // Model hallucinates [5] when only 2 candidates were offered.
      const response = 'According to [1] and [5], this is true.';
      final cited = extractValidCitations(
        response: response,
        citationMap: citationMap,
        validIds: validIds,
      );
      expect(cited, ['a1']);
      expect(cited.contains('a5'), isFalse);
    });

    test('citation [0] is ignored (numbers are 1-based)', () {
      const response = 'Reference [0] says so.';
      final cited = extractValidCitations(
        response: response,
        citationMap: citationMap,
        validIds: validIds,
      );
      expect(cited, isEmpty);
    });

    test('deleted article ID is filtered out even if cited', () {
      // a2 was deleted mid-session; only a1 remains valid.
      const response = 'Per [1] and [2], yes.';
      final cited = extractValidCitations(
        response: response,
        citationMap: citationMap,
        validIds: {'a1'}, // a2 no longer exists
      );
      expect(cited, ['a1']);
      expect(cited.contains('a2'), isFalse);
    });

    test('all citations invalid yields empty list', () {
      const response = 'Sources [3], [4], [5].';
      final cited = extractValidCitations(
        response: response,
        citationMap: citationMap,
        validIds: validIds,
      );
      expect(cited, isEmpty);
    });

    test('malformed citation markers are not matched', () {
      const response = 'See [a], [1.5], [ 1 ], and [[1]].';
      final cited = extractValidCitations(
        response: response,
        citationMap: citationMap,
        validIds: validIds,
      );
      // [[1]] contains [1] so a1 matches; the others don't.
      expect(cited, ['a1']);
    });

    test('empty candidate set never produces citations', () {
      const response = 'According to [1], [2], [3].';
      final cited = extractValidCitations(
        response: response,
        citationMap: buildCitationMap([]),
        validIds: {},
      );
      expect(cited, isEmpty);
    });
  });
}
