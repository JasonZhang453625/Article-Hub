import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:memora/data/models/folder.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/settings.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/data/repositories/article_repository.dart';
import 'package:memora/data/services/content_extractor.dart';
import 'package:memora/data/services/http_client.dart';
import 'package:memora/data/services/metadata_service.dart';
import 'package:memora/data/services/processing_pipeline.dart';
import 'package:memora/shared/providers/passage_providers.dart';

/// Helper to create an [AppHttpClient] backed by a [MockClient].
AppHttpClient mockHttp(Future<http.Response> Function(http.Request) handler) {
  return AppHttpClient(client: MockClient(handler));
}

/// Phase 1.4 service tests for [ProcessingPipeline].
///
/// Covers per-stage success/failure outcomes without hitting the network or
/// real Hive. Writes go through [ArticlesNotifier] backed by an in-memory
/// repository wired in via [ProviderContainer] overrides.
///
/// The AI summary success path requires HTTP-level stubbing of chat
/// completions and is intentionally out of scope here. The failure branch
/// ("AI not configured") is the deterministic, user-visible one and is
/// what these tests lock down.
void main() {
  late _InMemoryArticleRepository repo;
  late ProviderContainer container;

  setUp(() {
    repo = _InMemoryArticleRepository();
    container = ProviderContainer(overrides: [
      hiveInitProvider.overrideWith((ref) async {}),
      articleRepositoryProvider.overrideWith((ref) async => repo),
    ]);
  });

  tearDown(() => container.dispose());

  Article seedArticle({String id = 'p1'}) => Article(
        id: id,
        url: 'https://example.com/post',
        title: 'placeholder',
        source: SourcePlatform.web,
        processingStatus: ProcessingStatus.pending,
      );

  Future<ArticlesNotifier> seedAndGetNotifier(Article seed) async {
    await repo.add(seed);
    final notifier = container.read(articlesProvider.notifier);
    await container.read(articleRepositoryProvider.future);
    return notifier;
  }

  http.Response htmlResponse(String body) => http.Response(
        body,
        200,
        headers: {'content-type': 'text/html'},
      );

  group('Stage 1: metadata', () {
    test('success applies og:title and og:image to the article', () async {
      const html = '<html><head>'
          '<meta property="og:title" content="Real Title" />'
          '<meta property="og:image" content="https://cdn.example.com/c.png" />'
          '</head></html>';
      final notifier = await seedAndGetNotifier(seedArticle());
      final pipeline = ProcessingPipeline(
        articles: notifier,
        getSettings: () => null,
        getFolders: () => const <Folder>[],
        metadata: MetadataService(
          http: mockHttp((_) async => htmlResponse(html)),
        ),
        extractor: ContentExtractor(
          http: mockHttp(
              (_) async => htmlResponse('<html><body><p>body</p></body></html>')),
        ),
      );

      final result = await pipeline.process(seedArticle());
      expect(result, isNotNull);
      expect(result!.title, 'Real Title');
      expect(result.coverImageUrl, 'https://cdn.example.com/c.png');
    });

    test('network failure during metadata is non-fatal', () async {
      // MetadataService swallows network errors and returns empty metadata,
      // so the placeholder title survives and the pipeline proceeds to the
      // content stage (where it fails — that is the observable outcome).
      final notifier = await seedAndGetNotifier(seedArticle());
      final pipeline = ProcessingPipeline(
        articles: notifier,
        getSettings: () => null,
        getFolders: () => const <Folder>[],
        metadata: MetadataService(
          http: mockHttp((_) async => throw Exception('dns failure')),
        ),
        extractor: ContentExtractor(
          http: mockHttp((_) async => http.Response('boom', 500)),
        ),
      );

      final result = await pipeline.process(seedArticle());
      expect(result, isNotNull);
      expect(result!.title, 'placeholder');
      expect(result.processingStatus, ProcessingStatus.failed);
      expect(result.processingError, startsWith('content:'));
    });
  });

  group('Stage 2: content extraction', () {
    test('HTTP non-200 marks the article failed at content stage', () async {
      final notifier = await seedAndGetNotifier(seedArticle());
      final pipeline = ProcessingPipeline(
        articles: notifier,
        getSettings: () => null,
        getFolders: () => const <Folder>[],
        metadata: MetadataService(
          http: mockHttp((_) async =>
              htmlResponse('<html><head><title>X</title></head></html>')),
        ),
        extractor: ContentExtractor(
          http: mockHttp((_) async => http.Response('nope', 500)),
        ),
      );

      final result = await pipeline.process(seedArticle());
      expect(result, isNotNull);
      expect(result!.processingStatus, ProcessingStatus.failed);
      expect(result.processingError, startsWith('content:'));
      expect(result.lastProcessedAt, isNotNull);
    });

    test('empty body marks the article failed at content stage', () async {
      final notifier = await seedAndGetNotifier(seedArticle());
      final pipeline = ProcessingPipeline(
        articles: notifier,
        getSettings: () => null,
        getFolders: () => const <Folder>[],
        metadata: MetadataService(
          http: mockHttp((_) async =>
              htmlResponse('<html><head><title>X</title></head></html>')),
        ),
        extractor: ContentExtractor(
          http: mockHttp(
              (_) async => htmlResponse('<html><body></body></html>')),
        ),
      );

      final result = await pipeline.process(seedArticle());
      expect(result, isNotNull);
      expect(result!.processingStatus, ProcessingStatus.failed);
      expect(result.processingError, contains('content:'));
    });
  });

  group('Stage 3: AI summary', () {
    test('failure when AI is not configured (empty base URL / key)', () async {
      final notifier = await seedAndGetNotifier(seedArticle());
      final pipeline = ProcessingPipeline(
        articles: notifier,
        getSettings: () => AppSettings(aiBaseUrl: '', aiApiKey: ''),
        getFolders: () => const <Folder>[],
        metadata: MetadataService(
          http: mockHttp((_) async => htmlResponse(
                '<html><head><title>X</title></head>'
                '<body><article>$_longArticleText</article></body></html>',
              )),
        ),
        extractor: ContentExtractor(
          http: mockHttp((_) async => htmlResponse(_longArticleHtml)),
        ),
      );

      final result = await pipeline.process(seedArticle());
      expect(result, isNotNull);
      expect(result!.processingStatus, ProcessingStatus.failed);
      expect(result.processingError, startsWith('summary:'));
      expect(result.processingError, contains('not configured'));
    });
  });

  group('Retry semantics', () {
    test('retry bumps retryCount and re-runs from scratch', () async {
      final notifier = await seedAndGetNotifier(seedArticle());
      final pipeline = ProcessingPipeline(
        articles: notifier,
        getSettings: () => null,
        getFolders: () => const <Folder>[],
        metadata: MetadataService(
          http: mockHttp((_) async =>
              htmlResponse('<html><head><title>X</title></head></html>')),
        ),
        extractor: ContentExtractor(
          http: mockHttp((_) async => http.Response('nope', 500)),
        ),
      );

      final failed = await pipeline.process(seedArticle());
      expect(failed!.processingStatus, ProcessingStatus.failed);
      expect(failed.retryCount, 0);

      final retried = await pipeline.retry(failed);
      expect(retried, isNotNull);
      expect(retried!.retryCount, 1);
      expect(retried.processingStatus, ProcessingStatus.failed);
      expect(retried.processingError, startsWith('content:'));
    });
  });

  group('Stage 4 & 5: tags and folder suggestion are non-fatal', () {
    test(
        'failed summary short-circuits the pipeline — no tags or folder suggestion',
        () async {
      // When the summary stage fails the pipeline returns immediately;
      // tags and folder suggestion never run, so neither field is written.
      final notifier = await seedAndGetNotifier(seedArticle());
      final pipeline = ProcessingPipeline(
        articles: notifier,
        getSettings: () => AppSettings(aiBaseUrl: '', aiApiKey: ''),
        getFolders: () => const <Folder>[],
        metadata: MetadataService(
          http: mockHttp((_) async => htmlResponse(
                '<html><head><title>X</title></head>'
                '<body><article>$_longArticleText</article></body></html>',
              )),
        ),
        extractor: ContentExtractor(
          http: mockHttp((_) async => htmlResponse(_longArticleHtml)),
        ),
      );

      final result = await pipeline.process(seedArticle());
      expect(result!.processingStatus, ProcessingStatus.failed);
      expect(result.tags, isEmpty);
      expect(result.suggestedFolderId, isNull);
    });
  });

  group('Shared resilient page load', () {
    test('metadata and content stages reuse one fetched page', () async {
      final notifier = await seedAndGetNotifier(seedArticle());
      final loader = _CountingPageLoader(
        FetchedPage(
          statusCode: 200,
          contentType: 'text/html',
          body: '<html><head><title>One Fetch</title></head>'
              '<body><article>$_longArticleText</article></body></html>',
          finalUrl: 'https://example.com/final',
          source: PageLoadSource.webView,
        ),
      );
      final pipeline = ProcessingPipeline(
        articles: notifier,
        getSettings: () => AppSettings(aiBaseUrl: '', aiApiKey: ''),
        getFolders: () => const <Folder>[],
        metadata: MetadataService(loader: loader, ownsLoader: false),
        extractor: ContentExtractor(loader: loader, ownsLoader: false),
      );

      final result = await pipeline.process(seedArticle());

      expect(loader.fetchCount, 1);
      expect(result!.title, 'One Fetch');
      expect(result.processingError, startsWith('summary:'));
      pipeline.dispose();
      loader.dispose();
    });

    test('verification page fails before the MiMo stage', () async {
      final notifier = await seedAndGetNotifier(seedArticle());
      final loader = _CountingPageLoader(
        const FetchedPage(
          statusCode: 200,
          contentType: 'text/html',
          body: '<html><head><title>安全验证</title></head>'
              '<body>请输入验证码后继续访问</body></html>',
          finalUrl: 'https://example.com/verify',
          source: PageLoadSource.webView,
        ),
      );
      final pipeline = ProcessingPipeline(
        articles: notifier,
        getSettings: () => AppSettings(
          aiBaseUrl: 'https://should-not-be-called.example/v1',
          aiApiKey: 'unused',
        ),
        getFolders: () => const <Folder>[],
        metadata: MetadataService(loader: loader, ownsLoader: false),
        extractor: ContentExtractor(loader: loader, ownsLoader: false),
      );

      final result = await pipeline.process(seedArticle());

      expect(loader.fetchCount, 1);
      expect(result!.processingError, startsWith('content:'));
      pipeline.dispose();
      loader.dispose();
    });
  });
}

/// Tiny in-memory [ArticleRepository] for service-level tests — no Hive.
class _InMemoryArticleRepository implements ArticleRepository {
  final List<Article> _articles = [];

  @override
  Future<void> init() async {}

  @override
  List<Article> getAll() => List<Article>.of(_articles)
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  Article? getById(String id) {
    for (final a in _articles) {
      if (a.id == id) return a;
    }
    return null;
  }

  @override
  Future<void> add(Article article) async => _articles.add(article);

  @override
  Future<int> importAll(Iterable<Article> articles) async {
    _articles.addAll(articles);
    return articles.length;
  }

  @override
  Future<void> update(Article article) async {
    final i = _articles.indexWhere((a) => a.id == article.id);
    if (i >= 0) {
      _articles[i] = article;
    } else {
      _articles.add(article);
    }
  }

  @override
  Future<void> delete(String id) async =>
      _articles.removeWhere((a) => a.id == id);

  @override
  List<Article> search(String query) => getAll();

  @override
  List<Article> filterBySource(String sourceName) => getAll();

  @override
  Future<void> unsetFolder(String folderId) async {}

  @override
  Future<void> unsetFolderBatch(String folderId) async {}
}

/// HTML body whose <article> text exceeds 200 chars so [ContentExtractor]
/// returns a real (non-null) string and the pipeline advances to the summary
/// stage. The repetition is intentional — it's the deterministic way to clear
/// the extractor's length threshold without writing fake prose.
const String _longArticleText =
    'This is a sufficiently long article body for the content extractor to '
    'consider it real prose. It needs to exceed two hundred characters so '
    'the extractor returns a non-null string and the pipeline proceeds past '
    'the content stage into the summary stage, where we assert the AI-not-'
    'configured failure. Padding padding padding padding padding padding.';

const String _longArticleHtml =
    '<html><body><article>$_longArticleText</article></body></html>';

class _CountingPageLoader implements PageLoader {
  final FetchedPage? page;
  int fetchCount = 0;
  bool disposed = false;

  _CountingPageLoader(this.page);

  @override
  Future<FetchedPage?> fetch(String url) async {
    fetchCount++;
    return page;
  }

  @override
  void dispose() {
    disposed = true;
  }
}
