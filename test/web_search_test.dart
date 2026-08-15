import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memora/data/services/auth_service.dart';
import 'package:memora/data/services/rag_citation.dart';
import 'package:memora/data/services/web_search_service.dart';

/// Pure unit coverage for the web-search building blocks: Tavily response
/// parsing and `[wN]` URL citation validation.
void main() {
  group('normalizeWebSearchQuery', () {
    test('trims and limits Tavily queries to 400 Unicode characters', () {
      final query = '  ${List.filled(399, '问').join()}😀extra  ';
      final normalized = normalizeWebSearchQuery(query);

      expect(normalized.runes.length, 400);
      expect(normalized.endsWith('😀'), isTrue);
    });

    test('leaves short queries unchanged', () {
      expect(
        normalizeWebSearchQuery('  current Flutter version  '),
        'current Flutter version',
      );
    });
  });

  group('WebSearchCache account isolation', () {
    late Directory tempDir;

    setUp(() async {
      await Hive.close();
      tempDir = await Directory.systemTemp.createTemp('memora-web-cache-test-');
      Hive.init(tempDir.path);
    });

    tearDown(() async {
      await Hive.close();
      await tempDir.delete(recursive: true);
    });

    test('does not return another account namespace results', () async {
      final accountA = WebSearchCache(namespace: 'hosted:account-a');
      final accountB = WebSearchCache(namespace: 'hosted:account-b');
      const result = WebSearchResult(
        title: 'Private query result',
        url: 'https://example.com/account-a',
        content: 'Only account A searched for this.',
      );

      await accountA.put('same query', const [result]);

      expect(await accountA.get('same query'), hasLength(1));
      expect(await accountB.get('same query'), isNull);
      expect(await accountB.getStale('same query'), isNull);
    });

    test('clears legacy entries that have no account namespace', () async {
      final box = await Hive.openBox<Map>(WebSearchCache.boxName);
      await box.put('same query', {
        'results': [
          const WebSearchResult(
            title: 'Legacy result',
            url: 'https://example.com/legacy',
            content: 'Unknown account owner.',
          ).toMap(),
        ],
        'fetchedAt': DateTime.now().millisecondsSinceEpoch,
      });

      final cache = WebSearchCache(namespace: 'hosted:account-a');

      expect(await cache.get('same query'), isNull);
      expect(box.get('same query'), isNull);
    });
  });

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
      expect(
        results[0].content,
        'Logical replication replicates data changes.',
      );
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

    test('caps result count and Unicode text lengths', () {
      final results = parseTavilyResults({
        'results': List.generate(
          12,
          (index) => {
            'title': '${List.filled(300, '\u{95EE}').join()}\u{1F600}tail',
            'url': 'https://example.com/$index',
            'content': '${List.filled(12000, '\u{6587}').join()}\u{1F600}tail',
          },
        ),
      });

      expect(results, hasLength(10));
      expect(results.first.title.runes.length, 300);
      expect(results.first.content.runes.length, 12000);
    });

    test('accepts only public http or https URLs without user info', () {
      const urlPrefix = 'https://example.com/';
      final maxLengthUrl =
          '$urlPrefix${List.filled(2048 - urlPrefix.length, 'x').join()}';
      final tooLongUrl = '${maxLengthUrl}x';
      final results = parseTavilyResults({
        'results': [
          {'url': 'https://example.com/valid'},
          {'url': maxLengthUrl},
          {'url': 'ftp://example.com/file'},
          {'url': 'https://user:secret@example.com/private'},
          {'url': 'http://localhost/admin'},
          {'url': 'https://service.local/status'},
          {'url': 'https://service.internal/status'},
          {'url': 'https://127.0.0.1/private'},
          {'url': 'https://[::1]/private'},
          {'url': tooLongUrl},
        ],
      });

      expect(results.map((result) => result.url), [
        'https://example.com/valid',
        maxLengthUrl,
      ]);
    });

    test(
      'rejects numeric IP forms but accepts an ordinary single-label host',
      () {
        final results = parseTavilyResults({
          'results': [
            {'url': 'https://example/path'},
            {'url': 'http://2130706433/private'},
            {'url': 'http://0x7f000001/private'},
          ],
        });

        expect(results.map((result) => result.url), ['https://example/path']);
      },
    );

    test('normalizes scores to finite values in the zero-to-one range', () {
      final results = parseTavilyResults({
        'results': [
          {'url': 'https://example.com/high', 'score': 3},
          {'url': 'https://example.com/low', 'score': -2},
          {'url': 'https://example.com/nan', 'score': double.nan},
          {'url': 'https://example.com/infinity', 'score': double.infinity},
        ],
      });

      expect(results.map((result) => result.score), [1, 0, 0, 0]);
      expect(results.every((result) => result.score.isFinite), isTrue);
    });

    test('returns empty for malformed or missing results', () {
      expect(parseTavilyResults({}), isEmpty);
      expect(parseTavilyResults({'results': 'nope'}), isEmpty);
      expect(
        parseTavilyResults({
          'results': [42, null],
        }),
        isEmpty,
      );
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
        extractValidWebCitations(response: 'Cited [w1]', urls: const []),
        isEmpty,
      );
    });
  });

  group('HostedWebSearchService', () {
    test('uses the hosted web-search route without a Tavily key', () async {
      late Map<String, dynamic> body;
      final session = _session(_jwt());
      final service = HostedWebSearchService(
        client: MockClient((request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(request.url.path, '/ai/web-search');
          expect(
            request.headers['authorization'],
            'Bearer ${session.accessToken}',
          );
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'title': 'Result',
                  'url': 'https://example.com/result',
                  'content': 'Current information',
                  'score': 0.9,
                },
              ],
            }),
            200,
          );
        }),
        getSession: () => session,
        refreshSession: () async => null,
        cache: _NoopWebCache(),
      );

      final results = await service.search(' current info ', topK: 9);

      expect(body, {'query': 'current info', 'max_results': 5});
      expect(results.single.url, 'https://example.com/result');
      service.dispose();
    });

    test('daily web quota 429 is thrown for the RAG UI to display', () async {
      var calls = 0;
      final session = _session(_jwt());
      final service = HostedWebSearchService(
        client: MockClient((_) async {
          calls++;
          return http.Response(
            jsonEncode({
              'error': {
                'code': 'daily_quota_exceeded',
                'message': 'Daily web-search limit reached. Try tomorrow.',
              },
            }),
            429,
          );
        }),
        getSession: () => session,
        refreshSession: () async => null,
        cache: _NoopWebCache(),
      );

      await expectLater(
        service.search('question'),
        throwsA(
          isA<WebSearchException>()
              .having((error) => error.isDailyQuotaExceeded, 'quota', isTrue)
              .having(
                (error) => error.message,
                'message',
                contains('Try tomorrow'),
              ),
        ),
      );
      expect(calls, 1);
      service.dispose();
    });
  });
}

class _NoopWebCache extends WebSearchCache {
  @override
  Future<List<WebSearchResult>?> get(String query) async => null;

  @override
  Future<List<WebSearchResult>?> getStale(String query) async => null;

  @override
  Future<void> put(String query, List<WebSearchResult> results) async {}
}

AuthSession _session(String accessToken) => AuthSession(
  accessToken: accessToken,
  refreshToken: 'refresh-token',
  refreshTokenExpiresAt: null,
  user: const AuthUser(
    id: 'user-1',
    email: 'user@example.com',
    displayName: null,
    status: 'active',
    plan: 'free',
    storageUsedBytes: '0',
  ),
  device: const AuthDevice(
    id: 'device-1',
    userId: 'user-1',
    deviceName: 'test',
    platform: 'test',
    appVersion: '1.0.0',
  ),
);

String _jwt() {
  final payload = base64Url.encode(
    utf8.encode(
      jsonEncode({
        'sessionId': '11111111-1111-4111-8111-111111111111',
        'deviceId': '22222222-2222-4222-8222-222222222222',
      }),
    ),
  );
  return 'header.${payload.replaceAll('=', '')}.signature';
}
