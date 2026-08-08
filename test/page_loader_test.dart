import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/services/page_loader.dart';

void main() {
  group('ResilientPageLoader', () {
    test('HTTP 200 with usable content does not start fallback', () async {
      final primary = _FakeLoader(page: _usablePage(PageLoadSource.http));
      final fallback = _FakeLoader(page: _usablePage(PageLoadSource.webView));
      final loader = ResilientPageLoader(
        primary: primary,
        fallback: fallback,
        ownsLoaders: false,
      );

      final result = await loader.fetch('https://example.com/article');

      expect(result?.source, PageLoadSource.http);
      expect(primary.fetchCount, 1);
      expect(fallback.fetchCount, 0);
    });

    test('HTTP failure starts WebView fallback', () async {
      final primary = _FakeLoader();
      final fallback = _FakeLoader(page: _usablePage(PageLoadSource.webView));
      final loader = ResilientPageLoader(
        primary: primary,
        fallback: fallback,
        ownsLoaders: false,
      );

      final result = await loader.fetch('https://example.com/article');

      expect(result?.source, PageLoadSource.webView);
      expect(primary.fetchCount, 1);
      expect(fallback.fetchCount, 1);
    });

    test('HTTP verification page is rejected and falls back', () async {
      final primary = _FakeLoader(page: _verificationPage());
      final fallback = _FakeLoader(page: _usablePage(PageLoadSource.webView));
      final loader = ResilientPageLoader(
        primary: primary,
        fallback: fallback,
        ownsLoaders: false,
      );

      final result = await loader.fetch('https://example.com/article');

      expect(result?.source, PageLoadSource.webView);
      expect(fallback.fetchCount, 1);
    });

    test('X long-article preview is rejected and falls back', () async {
      final primary = _FakeLoader(
        page: _xLongArticlePreview(PageLoadSource.http),
      );
      final fallback = _FakeLoader(
        page: _xCompleteLongArticle(PageLoadSource.webView),
      );
      final loader = ResilientPageLoader(
        primary: primary,
        fallback: fallback,
        ownsLoaders: false,
      );

      final result = await loader.fetch(
        'https://x.com/i/status/2048757569775378858',
      );

      expect(result?.source, PageLoadSource.webView);
      expect(fallback.fetchCount, 1);
    });

    test('X login shell without the target post falls back', () async {
      final primary = _FakeLoader(page: _xLoginShell(PageLoadSource.http));
      final fallback = _FakeLoader(
        page: _xCompleteLongArticle(PageLoadSource.webView),
      );
      final loader = ResilientPageLoader(
        primary: primary,
        fallback: fallback,
        ownsLoaders: false,
      );

      final result = await loader.fetch(
        'https://x.com/i/status/2048757569775378858',
      );

      expect(result?.source, PageLoadSource.webView);
      expect(fallback.fetchCount, 1);
    });

    test('complete X long article does not start fallback', () async {
      final primary = _FakeLoader(
        page: _xCompleteLongArticle(PageLoadSource.http),
      );
      final fallback = _FakeLoader(page: _usablePage(PageLoadSource.webView));
      final loader = ResilientPageLoader(
        primary: primary,
        fallback: fallback,
        ownsLoaders: false,
      );

      final result = await loader.fetch(
        'https://x.com/i/status/2048757569775378858',
      );

      expect(result?.source, PageLoadSource.http);
      expect(fallback.fetchCount, 0);
    });

    test('current X target metadata accepts a short original post', () async {
      final primary = _FakeLoader(
        page: _xCurrentServerRenderedPost(PageLoadSource.http),
      );
      final fallback = _FakeLoader(page: _usablePage(PageLoadSource.webView));
      final loader = ResilientPageLoader(
        primary: primary,
        fallback: fallback,
        ownsLoaders: false,
      );

      final result = await loader.fetch(
        'https://x.com/author/status/2048757569775378858',
      );

      expect(result?.source, PageLoadSource.http);
      expect(fallback.fetchCount, 0);
    });

    test(
      'incomplete X long article remains a failure after fallback',
      () async {
        final loader = ResilientPageLoader(
          primary: _FakeLoader(page: _xLongArticlePreview(PageLoadSource.http)),
          fallback: _FakeLoader(
            page: _xLongArticlePreview(PageLoadSource.webView),
          ),
          ownsLoaders: false,
        );

        expect(
          await loader.fetch('https://x.com/i/status/2048757569775378858'),
          isNull,
        );
      },
    );

    test('WebView verification or short page returns failure', () async {
      final verificationFallback = ResilientPageLoader(
        primary: _FakeLoader(),
        fallback: _FakeLoader(page: _verificationPage()),
        ownsLoaders: false,
      );
      final shortFallback = ResilientPageLoader(
        primary: _FakeLoader(),
        fallback: _FakeLoader(
          page: const FetchedPage(
            statusCode: 200,
            contentType: 'text/html',
            body: '<html><body>too short</body></html>',
            finalUrl: 'https://example.com/short',
            source: PageLoadSource.webView,
          ),
        ),
        ownsLoaders: false,
      );

      expect(
        await verificationFallback.fetch('https://example.com/verify'),
        isNull,
      );
      expect(await shortFallback.fetch('https://example.com/short'), isNull);
    });

    test('HTTP and WebView failures return null', () async {
      final loader = ResilientPageLoader(
        primary: _FakeLoader(),
        fallback: _FakeLoader(),
        ownsLoaders: false,
      );

      expect(await loader.fetch('https://example.com/fail'), isNull);
    });
  });

  test('SerialPageLoadCoordinator allows only one active operation', () async {
    final coordinator = SerialPageLoadCoordinator();
    var active = 0;
    var maxActive = 0;

    Future<void> operation() async {
      active++;
      if (active > maxActive) maxActive = active;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      active--;
    }

    await Future.wait([
      coordinator.run(operation),
      coordinator.run(operation),
      coordinator.run(operation),
    ]);

    expect(maxActive, 1);
  });

  test(
    'SerialPageLoadCoordinator releases the queue after a timeout',
    () async {
      final coordinator = SerialPageLoadCoordinator();
      final neverCompletes = Completer<void>();
      var secondOperationRan = false;

      final stalled = coordinator.run(
        () => neverCompletes.future,
        timeout: const Duration(milliseconds: 20),
      );
      final next = coordinator.run(() async {
        secondOperationRan = true;
      });

      await expectLater(stalled, throwsA(isA<TimeoutException>()));
      await next.timeout(const Duration(seconds: 1));
      expect(secondOperationRan, isTrue);
    },
  );
}

FetchedPage _usablePage(PageLoadSource source) {
  final text = List.filled(
    8,
    'This is meaningful article text with enough length for validation.',
  ).join(' ');
  return FetchedPage(
    statusCode: 200,
    contentType: 'text/html; charset=utf-8',
    body:
        '<html><head><title>Article</title></head>'
        '<body><article>$text</article></body></html>',
    finalUrl: 'https://example.com/final',
    source: source,
  );
}

FetchedPage _verificationPage() {
  return const FetchedPage(
    statusCode: 200,
    contentType: 'text/html',
    body:
        '<html><head><title>安全验证</title></head>'
        '<body>请输入验证码后继续访问</body></html>',
    finalUrl: 'https://example.com/verify',
    source: PageLoadSource.http,
  );
}

FetchedPage _xLongArticlePreview(PageLoadSource source) {
  final noise = List.filled(
    12,
    'Log in recommendations trending navigation account controls.',
  ).join(' ');
  return FetchedPage(
    statusCode: 200,
    contentType: 'text/html; charset=utf-8',
    body:
        '<html><body><article>'
        '<a href="/author/status/2048757569775378858">Permalink</a>'
        '<img alt="Article cover image" src="cover.jpg">'
        '<h1>Long article title</h1>'
        '<p>Only the logged-out preview is available.</p>'
        '</article><aside>$noise</aside></body></html>',
    finalUrl: 'https://x.com/author/status/2048757569775378858',
    source: source,
  );
}

FetchedPage _xLoginShell(PageLoadSource source) {
  final noise = List.filled(
    12,
    'Log in recommendations trending navigation account controls.',
  ).join(' ');
  return FetchedPage(
    statusCode: 200,
    contentType: 'text/html; charset=utf-8',
    body: '<html><body><main>$noise</main></body></html>',
    finalUrl: 'https://x.com/i/status/2048757569775378858',
    source: source,
  );
}

FetchedPage _xCurrentServerRenderedPost(PageLoadSource source) {
  return FetchedPage(
    statusCode: 200,
    contentType: 'text/html; charset=utf-8',
    body: '''<html><body><article data-tweet-id="2048757569775378858"
      itemid="https://x.com/i/status/2048757569775378858">
      <meta content="2048757569775378858" itemprop="identifier">
      <meta content="A short original post" itemprop="articleBody">
      <div>A short original post</div>
    </article></body></html>''',
    finalUrl: 'https://x.com/author/status/2048757569775378858',
    source: source,
  );
}

FetchedPage _xCompleteLongArticle(PageLoadSource source) {
  final paragraph = List.filled(
    4,
    'Complete long-form article paragraph with meaningful source content.',
  ).join(' ');
  return FetchedPage(
    statusCode: 200,
    contentType: 'text/html; charset=utf-8',
    body:
        '<html><body><article>'
        '<a href="/author/status/2048757569775378858">Permalink</a>'
        '<h1>Long article title</h1>'
        '<div class="x-article-body">'
        '<p>Opening $paragraph</p>'
        '<p>Middle $paragraph</p>'
        '<p>Closing $paragraph</p>'
        '</div></article></body></html>',
    finalUrl: 'https://x.com/author/status/2048757569775378858',
    source: source,
  );
}

class _FakeLoader implements PageLoader {
  final FetchedPage? page;
  int fetchCount = 0;

  _FakeLoader({this.page});

  @override
  Future<FetchedPage?> fetch(String url) async {
    fetchCount++;
    return page;
  }

  @override
  void dispose() {}
}
