import 'dart:developer' as developer;
import 'package:html/parser.dart' as html_parser;

import 'http_client.dart';

class ContentExtractor {
  final AppHttpClient _http;

  ContentExtractor({AppHttpClient? http}) : _http = http ?? AppHttpClient();

  Future<String?> extract(String url) async {
    final page = await _http.fetch(url);
    developer.log(
      'status: ${page?.statusCode}, url: $url',
      name: 'article_hub.extractor',
    );
    if (page == null || !page.isHtml) return null;

    final text = _extractText(page.body);
    developer.log(
      'extracted text length: ${text?.length ?? 0}',
      name: 'article_hub.extractor',
    );
    return text;
  }

  /// Extract content from an already-fetched page (avoids a second HTTP call).
  String? fromFetchedPage(FetchedPage page) {
    if (!page.isHtml) return null;
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

  void dispose() => _http.dispose();
}
