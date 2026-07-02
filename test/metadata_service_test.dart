import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:memora/data/services/http_client.dart';
import 'package:memora/data/services/metadata_service.dart';

/// Helper to create an [AppHttpClient] backed by a [MockClient].
AppHttpClient mockHttp(Future<http.Response> Function(http.Request) handler) {
  return AppHttpClient(client: MockClient(handler));
}

/// Phase 1.4 unit tests for [parseHtmlMetadata] and [MetadataService.fetch].
///
/// Covers the precedence rules (og: > twitter: > <title>), relative-image URL
/// resolution against the page base, and the graceful-failure contract on
/// non-200 responses, non-HTML content types, and network errors.
void main() {
  group('parseHtmlMetadata: title precedence', () {
    test('prefers og:title over twitter:title and <title>', () {
      const html = '''
        <html><head>
          <title>Plain Title</title>
          <meta name="twitter:title" content="Twitter Title" />
          <meta property="og:title" content="OG Title" />
        </head><body></body></html>
      ''';
      final meta = parseHtmlMetadata(html, 'https://example.com/');
      expect(meta.title, 'OG Title');
    });

    test('falls back to twitter:title when og:title is missing', () {
      const html = '''
        <html><head>
          <title>Plain Title</title>
          <meta name="twitter:title" content="Twitter Title" />
        </head><body></body></html>
      ''';
      final meta = parseHtmlMetadata(html, 'https://example.com/');
      expect(meta.title, 'Twitter Title');
    });

    test('falls back to <title> when no og: or twitter: present', () {
      const html = '<html><head><title>Plain Title</title></head></html>';
      final meta = parseHtmlMetadata(html, 'https://example.com/');
      expect(meta.title, 'Plain Title');
    });

    test('returns null title when nothing is present', () {
      const html = '<html><head></head><body>no title at all</body></html>';
      final meta = parseHtmlMetadata(html, 'https://example.com/');
      expect(meta.title, isNull);
    });

    test('treats empty og:title content as missing and falls back', () {
      const html = '''
        <html><head>
          <title>Plain Title</title>
          <meta property="og:title" content="  " />
        </head></html>
      ''';
      final meta = parseHtmlMetadata(html, 'https://example.com/');
      expect(meta.title, 'Plain Title');
    });

    test('trims whitespace from title', () {
      const html =
          '<html><head><title>   Spaced Title   </title></head></html>';
      final meta = parseHtmlMetadata(html, 'https://example.com/');
      expect(meta.title, 'Spaced Title');
    });
  });

  group('parseHtmlMetadata: image precedence and URL resolution', () {
    test('prefers og:image over twitter:image', () {
      const html = '''
        <html><head>
          <meta property="og:image" content="https://cdn.example.com/og.png" />
          <meta name="twitter:image" content="https://cdn.example.com/tw.png" />
        </head></html>
      ''';
      final meta = parseHtmlMetadata(html, 'https://example.com/article');
      expect(meta.imageUrl, 'https://cdn.example.com/og.png');
    });

    test('accepts twitter:image:src as an alias when og:image missing', () {
      const html = '''
        <html><head>
          <meta name="twitter:image:src" content="https://cdn.example.com/src.png" />
        </head></html>
      ''';
      final meta = parseHtmlMetadata(html, 'https://example.com/article');
      expect(meta.imageUrl, 'https://cdn.example.com/src.png');
    });

    test('resolves a root-relative image against the base URL', () {
      const html =
          '<html><head><meta property="og:image" content="/img/cover.png" /></head></html>';
      final meta =
          parseHtmlMetadata(html, 'https://example.com/posts/article-1');
      expect(meta.imageUrl, 'https://example.com/img/cover.png');
    });

    test('resolves a path-relative image against the base URL', () {
      const html =
          '<html><head><meta property="og:image" content="cover.png" /></head></html>';
      final meta =
          parseHtmlMetadata(html, 'https://example.com/posts/article-1');
      expect(meta.imageUrl, 'https://example.com/posts/cover.png');
    });

    test('returns null image when no image meta tag is present', () {
      const html = '<html><head><title>x</title></head></html>';
      final meta = parseHtmlMetadata(html, 'https://example.com/');
      expect(meta.imageUrl, isNull);
    });
  });

  group('MetadataService.fetch: graceful failure', () {
    test('returns empty metadata on non-200 response', () async {
      final svc = MetadataService(
        http: mockHttp((_) async => http.Response('not found', 404)),
      );
      final meta = await svc.fetch('https://example.com/missing');
      expect(meta.isEmpty, isTrue);
      svc.dispose();
    });

    test('returns empty metadata on non-HTML content type', () async {
      final svc = MetadataService(
        http: mockHttp((_) async => http.Response(
              '{"title":"json"}',
              200,
              headers: {'content-type': 'application/json'},
            )),
      );
      final meta = await svc.fetch('https://api.example.com/x.json');
      expect(meta.isEmpty, isTrue);
      svc.dispose();
    });

    test('returns empty metadata on network error', () async {
      final svc = MetadataService(
        http: mockHttp((_) async => throw Exception('boom')),
      );
      final meta = await svc.fetch('https://example.com/');
      expect(meta.isEmpty, isTrue);
      svc.dispose();
    });

    test('parses metadata from a 200 HTML response', () async {
      const html = '''
        <html><head>
          <meta property="og:title" content="Real Title" />
          <meta property="og:image" content="https://cdn.example.com/cover.png" />
        </head></html>
      ''';
      final svc = MetadataService(
        http: mockHttp((_) async => http.Response(
              html,
              200,
              headers: {'content-type': 'text/html; charset=utf-8'},
            )),
      );
      final meta = await svc.fetch('https://example.com/post');
      expect(meta.title, 'Real Title');
      expect(meta.imageUrl, 'https://cdn.example.com/cover.png');
      svc.dispose();
    });
  });
}
