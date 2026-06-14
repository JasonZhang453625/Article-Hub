import 'dart:developer' as developer;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

class ContentExtractor {
  final http.Client _client;
  final Duration timeout;

  ContentExtractor({http.Client? client, this.timeout = const Duration(seconds: 10)})
      : _client = client ?? http.Client();

  Future<String?> extract(String url) async {
    try {
      final response = await _client
          .get(
            Uri.parse(url),
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (compatible; Article-Hub/1.0; +https://github.com)',
              'Accept': 'text/html,application/xhtml+xml',
            },
          )
          .timeout(timeout);

      developer.log(
        'status: ${response.statusCode}, url: $url',
        name: 'article_hub.extractor',
      );
      if (response.statusCode != 200) return null;

      final contentType = response.headers['content-type'] ?? '';
      developer.log('content-type: $contentType', name: 'article_hub.extractor');
      if (!contentType.contains('html') && contentType.isNotEmpty) return null;

      final text = _extractText(response.body);
      developer.log(
        'extracted text length: ${text?.length ?? 0}',
        name: 'article_hub.extractor',
      );
      return text;
    } catch (e, st) {
      developer.log(
        'extract error',
        name: 'article_hub.extractor',
        error: e,
        stackTrace: st,
      );
      return null;
    }
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

  void dispose() => _client.close();
}
