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
