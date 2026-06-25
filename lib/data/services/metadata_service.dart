import 'dart:async';

import 'package:html/parser.dart' as html_parser;

import 'default_page_loader.dart';
import 'http_client.dart';
import 'page_loader.dart';

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
  var imageUrl = _resolveUrl(rawImage, baseUrl);

  // Fallback: extract the first meaningful image from the article body
  // when OG/Twitter meta tags don't provide one.
  imageUrl ??= _extractFirstContentImage(document, baseUrl);

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

/// Try to find the first meaningful image inside article content.
/// Targets common content containers, falls back to all images in body.
String? _extractFirstContentImage(dynamic document, String baseUrl) {
  // Try article-specific containers first, then broader fallbacks.
  final selectors = [
    '#js_content',
    '.main-content',
    '#body_wrapper',
    'article',
    '[role="main"]',
    'main',
    '.post-content',
    '.article-content',
    '.entry-content',
    '#content',
  ];

  for (final selector in selectors) {
    final el = document.querySelector(selector);
    if (el == null) continue;
    final img = _findValidImage(el, baseUrl);
    if (img != null) return img;
  }

  // Last resort: scan all images in the body.
  return _findValidImage(document.body ?? document, baseUrl);
}

/// Walk <img> elements under [root] and return the first one that looks
/// like a real content image (not an icon, avatar, or tracking pixel).
String? _findValidImage(dynamic root, String baseUrl) {
  final imgs = root.querySelectorAll('img');
  for (final img in imgs) {
    final src = img.attributes['src'] ??
        img.attributes['data-src'] ??
        img.attributes['data-original'];
    if (src == null || src.isEmpty) continue;

    // Skip data URIs, SVGs, and common non-content patterns.
    final lower = src.toLowerCase();
    if (lower.startsWith('data:')) continue;
    if (lower.endsWith('.svg')) continue;
    if (lower.contains('avatar') || lower.contains('icon')) continue;
    if (lower.contains('logo') || lower.contains('emoji')) continue;
    if (lower.contains('1x1') || lower.contains('spacer')) continue;
    if (lower.contains('pixel') || lower.contains('track')) continue;

    // Skip tiny images by explicit dimensions.
    final w = int.tryParse(img.attributes['width'] ?? '');
    final h = int.tryParse(img.attributes['height'] ?? '');
    if (w != null && w < 80) continue;
    if (h != null && h < 80) continue;

    final resolved = _resolveUrl(src, baseUrl);
    if (resolved != null) return resolved;
  }
  return null;
}

/// Fetches a URL and extracts page metadata. Never throws — returns an empty
/// [PageMetadata] on any network error, timeout, non-HTML response, or
/// non-200 status, so callers can fall back gracefully.
class MetadataService {
  final PageLoader _loader;
  final bool _ownsLoader;

  MetadataService({
    PageLoader? loader,
    AppHttpClient? http,
    bool ownsLoader = true,
  })  : assert(loader == null || http == null),
        _loader = loader ?? http ?? createDefaultPageLoader(),
        _ownsLoader = ownsLoader;

  Future<FetchedPage?> fetchPage(String url) async {
    try {
      return await _loader.fetch(url);
    } catch (_) {
      return null;
    }
  }

  Future<PageMetadata> fetch(String url) async {
    final page = await fetchPage(url);
    if (page == null ||
        !page.isHtml ||
        fetchedPageLooksBlocked(page)) {
      return const PageMetadata();
    }
    return parseHtmlMetadata(page.body, page.finalUrl);
  }

  /// Extract metadata from an already-fetched page (avoids a second HTTP call).
  PageMetadata fromFetchedPage(FetchedPage page, [String? baseUrl]) {
    if (!page.isHtml || fetchedPageLooksBlocked(page)) {
      return const PageMetadata();
    }
    return parseHtmlMetadata(page.body, page.finalUrl);
  }

  void dispose() {
    if (_ownsLoader) _loader.dispose();
  }
}
