import 'dart:async';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

/// Lightweight page metadata extracted from a URL's HTML.
class PageMetadata {
  final String? title;
  final String? imageUrl;

  const PageMetadata({this.title, this.imageUrl});

  bool get isEmpty => title == null && imageUrl == null;
}

/// Parses page metadata from an HTML document string. Prefers Open Graph
/// (`og:title` / `og:image`), falling back to Twitter cards and the `<title>`
/// tag. Relative image URLs are resolved against [baseUrl].
///
/// Pure and synchronous so it can be unit-tested without network access.
PageMetadata parseHtmlMetadata(String htmlBody, String baseUrl) {
  final document = html_parser.parse(htmlBody);

  String? metaContent(List<String> propertyValues) {
    for (final value in propertyValues) {
      // Match both <meta property="..."> and <meta name="...">.
      final el = document.querySelector('meta[property="$value"]') ??
          document.querySelector('meta[name="$value"]');
      final content = el?.attributes['content']?.trim();
      if (content != null && content.isNotEmpty) return content;
    }
    return null;
  }

  var title = metaContent(['og:title', 'twitter:title']);
  if (title == null || title.isEmpty) {
    final titleText = document.querySelector('title')?.text.trim();
    if (titleText != null && titleText.isNotEmpty) {
      title = titleText;
    }
  }

  final rawImage = metaContent(['og:image', 'twitter:image', 'twitter:image:src']);
  final imageUrl = _resolveUrl(rawImage, baseUrl);

  return PageMetadata(
    title: (title != null && title.isNotEmpty) ? title : null,
    imageUrl: imageUrl,
  );
}

String? _resolveUrl(String? raw, String baseUrl) {
  if (raw == null || raw.isEmpty) return null;
  final base = Uri.tryParse(baseUrl);
  final resolved = Uri.tryParse(raw);
  if (resolved == null) return null;
  if (resolved.hasScheme) return resolved.toString();
  if (base == null) return null;
  return base.resolveUri(resolved).toString();
}

/// Fetches a URL and extracts page metadata. Never throws — returns an empty
/// [PageMetadata] on any network error, timeout, non-HTML response, or
/// non-200 status, so callers can fall back gracefully.
class MetadataService {
  final http.Client _client;
  final Duration timeout;

  MetadataService({http.Client? client, this.timeout = const Duration(seconds: 8)})
      : _client = client ?? http.Client();

  Future<PageMetadata> fetch(String url) async {
    try {
      final response = await _client.get(
        Uri.parse(url),
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (compatible; Article-Hub/1.0; +https://github.com)',
          'Accept': 'text/html,application/xhtml+xml',
        },
      ).timeout(timeout);

      if (response.statusCode != 200) return const PageMetadata();

      final contentType = response.headers['content-type'] ?? '';
      if (!contentType.contains('html') && contentType.isNotEmpty) {
        return const PageMetadata();
      }

      return parseHtmlMetadata(response.body, url);
    } catch (_) {
      return const PageMetadata();
    }
  }

  void dispose() => _client.close();
}
