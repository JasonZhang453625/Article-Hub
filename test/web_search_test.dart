import 'package:flutter_test/flutter_test.dart';
import 'package:memora/data/services/rag_citation.dart';
import 'package:memora/data/services/web_search_service.dart';

/// Pure unit coverage for the web-search building blocks: Tavily response
/// parsing and `[wN]` URL citation validation.
void main() {
  group('parseTavilyResults', () {
    test('parses a valid results array in order', () {
      final results = parseTavilyResults({
        'query': 'postgres replication',
        'results': [
          {
            'title': 'Logical Replication',
            'url': 'https://postgresql.org/docs/logical-replication',
            'content': 'Logical replication replicates data changes.',
            'score': 0.9,
          },
          {
            'title': 'Streaming Replication',
            'url': 'https://wiki.postgresql.org/wiki/Streaming_Replication',
            'content': 'Streaming replication ships WAL records.',
          },
        ],
      });
      expect(results, hasLength(2));
      expect(results[0].title, 'Logical Replication');
      expect(results[0].url, 'https://postgresql.org/docs/logical-replication');
      expect(results[0].content, 'Logical replication replicates data changes.');
      expect(results[0].score, closeTo(0.9, 1e-9));
      expect(results[1].score, 0);
    });

    test('drops entries without a URL (unusable as citations)', () {
      final results = parseTavilyResults({
        'results': [
          {'title': 'No URL', 'content': 'useless'},
          {'title': 'Ok', 'url': 'https://example.com', 'content': 'fine'},
        ],
      });
      expect(results, hasLength(1));
      expect(results.single.url, 'https://example.com');
    });

    test('returns empty for malformed or missing results', () {
      expect(parseTavilyResults({}), isEmpty);
      expect(parseTavilyResults({'results': 'nope'}), isEmpty);
      expect(parseTavilyResults({'results': [42, null]}), isEmpty);
    });

    test('round-trips through the cache map format', () {
      const result = WebSearchResult(
        title: 'T',
        url: 'https://example.com',
        content: 'C',
        score: 0.5,
      );
      final restored = WebSearchResult.fromMap(result.toMap());
      expect(restored.title, 'T');
      expect(restored.url, 'https://example.com');
      expect(restored.content, 'C');
      expect(restored.score, closeTo(0.5, 1e-9));
    });
  });

  group('buildWebCitationMap', () {
    test('maps w1..wN to offered URLs in order', () {
      final map = buildWebCitationMap(['https://a.com', 'https://b.com']);
      expect(map['w1'], 'https://a.com');
      expect(map['w2'], 'https://b.com');
    });

    test('empty URL list yields empty map', () {
      expect(buildWebCitationMap([]), isEmpty);
    });
  });

  group('extractValidWebCitations', () {
    final urls = ['https://a.com', 'https://b.com', 'https://c.com'];

    test('extracts cited web URLs in candidate order', () {
      const response = 'Per [w2] and [w1] the claim holds.';
      expect(extractValidWebCitations(response: response, urls: urls), [
        'https://a.com',
        'https://b.com',
      ]);
    });

    test('ignores fabricated citation numbers outside the offered set', () {
      const response = 'See [w9] and [w3].';
      expect(extractValidWebCitations(response: response, urls: urls), [
        'https://c.com',
      ]);
    });

    test('a bare URL in the text is not a citation', () {
      const response = 'The source https://evil.com is irrelevant.';
      expect(extractValidWebCitations(response: response, urls: urls), isEmpty);
    });

    test('de-duplicates repeated citations', () {
      const response = 'Again [w1], still [w1], and [w2] again [w1].';
      expect(extractValidWebCitations(response: response, urls: urls), [
        'https://a.com',
        'https://b.com',
      ]);
    });

    test('returns empty when no URLs were offered', () {
      expect(
        extractValidWebCitations(
          response: 'Cited [w1]',
          urls: const [],
        ),
        isEmpty,
      );
    });
  });
}
