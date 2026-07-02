import 'dart:developer' as developer;
import 'package:html/parser.dart' as html_parser;

import 'default_page_loader.dart';
import 'http_client.dart';
import 'page_loader.dart';

class ContentExtractor {
  final PageLoader _loader;
  final bool _ownsLoader;

  ContentExtractor({
    PageLoader? loader,
    AppHttpClient? http,
    bool ownsLoader = true,
  })  : assert(loader == null || http == null),
        _loader = loader ?? http ?? createDefaultPageLoader(),
        _ownsLoader = ownsLoader;

  Future<String?> extract(String url) async {
    final page = await _loader.fetch(url);
    developer.log(
      'status: ${page?.statusCode}, source: ${page?.source.name}, '
      'finalUrl: ${page?.finalUrl ?? url}',
      name: 'memora.extractor',
    );
    if (page == null ||
        !page.isHtml ||
        fetchedPageLooksBlocked(page)) {
      return null;
    }

    final text = _extractText(page.body);
    developer.log(
      'extracted text length: ${text?.length ?? 0}',
      name: 'memora.extractor',
    );
    return text;
  }

  /// Extract content from an already-fetched page (avoids a second HTTP call).
  String? fromFetchedPage(FetchedPage page) {
    if (!page.isHtml || fetchedPageLooksBlocked(page)) return null;
    return _extractText(page.body);
  }

  String? _extractText(String htmlBody) {
    final document = html_parser.parse(htmlBody);

    // Remove non-content elements
    for (final tag in ['script', 'style', 'nav', 'header', 'footer', 'aside', 'noscript']) {
      for (final el in document.querySelectorAll(tag)) {
        el.remove();
      }
    }

    // Try common article containers first
    for (final selector in [
      '.J-lemma-content', // Baidu Baike
      'article',
      '[role="main"]',
      'main',
      '.post-content',
      '.article-content',
      '.entry-content',
      '#content',
    ]) {
      final el = document.querySelector(selector);
      if (el != null) {
        final text = _cleanText(el.text);
        if (text.length > 200) return text;
      }
    }

    // Fallback: extract all paragraph text
    final paragraphs = document.querySelectorAll('p');
    if (paragraphs.isNotEmpty) {
      final text = paragraphs.map((p) => p.text.trim()).where((t) => t.isNotEmpty).join('\n\n');
      if (text.length > 100) return _cleanText(text);
    }

    // Last resort: body text
    final body = document.body?.text ?? '';
    final text = _cleanText(body);
    return text.length > 100 ? text : null;
  }

  String _cleanText(String text) {
    // Collapse multiple whitespace/newlines into single ones
    return text
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  void dispose() {
    if (_ownsLoader) _loader.dispose();
  }
}
