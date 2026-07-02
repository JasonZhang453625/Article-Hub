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
      final fetchFuture =
          client.fetch('http://${server.address.host}:${server.port}/article');
      final request = await server.first;

      expect(request.headers.value(HttpHeaders.acceptEncodingHeader), 'gzip');

      const html = '<html><head><title>人工智能</title></head>'
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
      body: '<html><body>'
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
}
