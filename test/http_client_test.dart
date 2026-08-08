import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/services/content_extractor.dart';
import 'package:memora/data/services/http_client.dart';

void main() {
  test('uses Dart-supported gzip and decodes UTF-8 HTML', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = AppHttpClient();

    try {
      final fetchFuture = client.fetch(
        'http://${server.address.host}:${server.port}/article',
      );
      final request = await server.first;

      expect(request.headers.value(HttpHeaders.acceptEncodingHeader), 'gzip');

      const html =
          '<html><head><title>人工智能</title></head>'
          '<body><article>这是一段可正常读取的中文正文。</article></body></html>';
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..headers.set(HttpHeaders.contentEncodingHeader, 'gzip')
        ..add(gzip.encode(utf8.encode(html)));
      await request.response.close();

      final page = await fetchFuture;
      expect(page, isNotNull);
      expect(page!.body, contains('人工智能'));
      expect(page.body, contains('中文正文'));
    } finally {
      client.dispose();
      await server.close(force: true);
    }
  });

  test('prefers the verified Baidu Baike article container', () {
    const articleText =
        '人工智能是研究、开发用于模拟和扩展人类智能的理论与技术。'
        '这一正文重复足够多次，以越过正文提取器的最小长度限制。'
        '人工智能是研究、开发用于模拟和扩展人类智能的理论与技术。'
        '这一正文重复足够多次，以越过正文提取器的最小长度限制。'
        '人工智能是研究、开发用于模拟和扩展人类智能的理论与技术。'
        '这一正文重复足够多次，以越过正文提取器的最小长度限制。'
        '人工智能是研究、开发用于模拟和扩展人类智能的理论与技术。'
        '这一正文重复足够多次，以越过正文提取器的最小长度限制。';
    const page = FetchedPage(
      statusCode: 200,
      contentType: 'text/html; charset=utf-8',
      body:
          '<html><body>'
          '<div>页面导航和推荐内容不应进入摘要。</div>'
          '<div class="J-lemma-content">$articleText</div>'
          '<div>页面底部噪声不应进入摘要。</div>'
          '</body></html>',
      finalUrl: 'https://baike.baidu.com/item/test',
      source: PageLoadSource.http,
    );

    final extractor = ContentExtractor();
    try {
      final content = extractor.fromFetchedPage(page);
      expect(content, articleText);
      expect(content, isNot(contains('页面底部噪声')));
    } finally {
      extractor.dispose();
    }
  });

  test('extracts an X long article without page chrome or replies', () {
    const repeated =
        'This is meaningful long-form source content that must be retained. ';
    const page = FetchedPage(
      statusCode: 200,
      contentType: 'text/html; charset=utf-8',
      body:
          '<html><body>'
          '<aside>Log in to X and browse trending conversations.</aside>'
          '<main><article>'
          '<a href="/author/status/2048757569775378858">Permalink</a>'
          '<h1>Recursive systems explained</h1>'
          '<div class="x-article-body">'
          '<p>Opening $repeated$repeated</p>'
          '<p>Middle $repeated$repeated</p>'
          '<p>Closing $repeated$repeated</p>'
          '</div></article>'
          '<article><p>Reply noise $repeated$repeated$repeated</p></article>'
          '</main></body></html>',
      finalUrl: 'https://x.com/author/status/2048757569775378858',
      source: PageLoadSource.http,
    );

    final extractor = ContentExtractor();
    try {
      final content = extractor.fromFetchedPage(page);
      expect(content, startsWith('Recursive systems explained'));
      expect(content, contains('Opening'));
      expect(content, contains('Middle'));
      expect(content, contains('Closing'));
      expect(content, isNot(contains('Log in to X')));
      expect(content, isNot(contains('Reply noise')));
      expect(content, isNot(contains('Permalink')));
    } finally {
      extractor.dispose();
    }
  });

  test(
    'extracts a current server-rendered X post from structured metadata',
    () {
      const page = FetchedPage(
        statusCode: 200,
        contentType: 'text/html; charset=utf-8',
        body:
            '<html><body><article data-tweet-id="2048757569775378858">'
            '<meta content="2048757569775378858" itemprop="identifier">'
            '<meta content="A short original X post" itemprop="articleBody">'
            '<div>A short original X post</div>'
            '</article></body></html>',
        finalUrl: 'https://x.com/author/status/2048757569775378858',
        source: PageLoadSource.http,
      );

      final extractor = ContentExtractor();
      try {
        expect(extractor.fromFetchedPage(page), 'A short original X post');
      } finally {
        extractor.dispose();
      }
    },
  );

  test('does not extract an X long-article preview as full content', () {
    const page = FetchedPage(
      statusCode: 200,
      contentType: 'text/html; charset=utf-8',
      body:
          '<html><body><main><article>'
          '<a href="/author/status/2048757569775378858">Permalink</a>'
          '<img alt="Article cover image" src="cover.jpg">'
          '<h1>Recursive systems explained</h1>'
          '<p>Only a short preview.</p>'
          '</article></main>'
          '<aside>Log in recommendations trending navigation</aside>'
          '</body></html>',
      finalUrl: 'https://x.com/author/status/2048757569775378858',
      source: PageLoadSource.http,
    );

    final extractor = ContentExtractor();
    try {
      expect(extractor.fromFetchedPage(page), isNull);
    } finally {
      extractor.dispose();
    }
  });

  test('does not extract an X login shell without the target post', () {
    const page = FetchedPage(
      statusCode: 200,
      contentType: 'text/html; charset=utf-8',
      body:
          '<html><body><main>Log in to X. Trending conversations, '
          'recommendations, navigation, account controls, and more repeated '
          'page chrome that exceeds the generic minimum length.</main></body></html>',
      finalUrl: 'https://x.com/i/status/2048757569775378858',
      source: PageLoadSource.http,
    );

    final extractor = ContentExtractor();
    try {
      expect(extractor.fromFetchedPage(page), isNull);
    } finally {
      extractor.dispose();
    }
  });
}
