import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;

class AiService {
  final String baseUrl;
  final String apiKey;
  final String model;
  final Duration timeout;

  AiService({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.timeout = const Duration(seconds: 30),
  });

  Uri _chatUri() {
    var base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    // Auto-append /v1 if the user entered a bare provider domain
    // (e.g. https://api.deepseek.com → https://api.deepseek.com/v1).
    if (!base.endsWith('/v1') && !base.contains('/v1/')) {
      base = '$base/v1';
    }
    return Uri.parse('$base/chat/completions');
  }

  bool get isConfigured =>
      baseUrl.trim().isNotEmpty && apiKey.trim().isNotEmpty;

  Future<String?> summarize(String title, String content, {String languageHint = ''}) async {
    if (!isConfigured) return null;

    final uri = _chatUri();

    final truncatedContent = content.length > 8000
        ? '${content.substring(0, 8000)}...'
        : content;

    final langInstruction = languageHint.isNotEmpty
        ? '\n$languageHint'
        : '';

    final body = jsonEncode({
      'model': model,
      'messages': [
        {
          'role': 'system',
          'content':
              'You are a concise reading assistant. Summarize the article in the same language as the source. '
              'Format: a one-sentence overview followed by 3-5 bullet points of key takeaways. '
              'Keep the total under 200 words. Be factual; do not add opinions.'
              '$langInstruction',
        },
        {
          'role': 'user',
          'content': 'Title: $title\n\n$truncatedContent',
        },
      ],
      'temperature': 0.3,
      'max_tokens': 500,
    });

    return _postChat(uri, body);
  }

  Future<String?> summarizeFromUrl(String title, String url, {String languageHint = ''}) async {
    if (!isConfigured) return null;

    final uri = _chatUri();

    final langInstruction = languageHint.isNotEmpty
        ? '\n$languageHint'
        : '';

    final body = jsonEncode({
      'model': model,
      'messages': [
        {
          'role': 'system',
          'content':
              'You are a concise reading assistant. The user will give you a URL and title. '
              'If you can access the URL, read the content and summarize it. '
              'If you cannot access it, summarize based on the title alone — give a brief '
              'one-sentence description of what this article is likely about. '
              'Format: a one-sentence overview followed by 3-5 bullet points. '
              'Keep the total under 200 words. Be factual; do not add opinions.'
              '$langInstruction',
        },
        {
          'role': 'user',
          'content': 'Title: $title\nURL: $url',
        },
      ],
      'temperature': 0.3,
      'max_tokens': 500,
    });

    return _postChat(uri, body);
  }

  Future<String?> _postChat(Uri uri, String body) async {
    try {
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: body,
          )
          .timeout(timeout);

      developer.log(
        'API response status: ${response.statusCode}',
        name: 'article_hub.ai',
      );
      if (response.statusCode != 200) {
        developer.log(
          'response body: ${response.body.substring(0, response.body.length.clamp(0, 500))}',
          name: 'article_hub.ai',
        );
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final choices = json['choices'] as List?;
      if (choices == null || choices.isEmpty) return null;

      final message = choices[0]['message'] as Map<String, dynamic>?;
      final text = message?['content'] as String?;
      if (text != null && text.trim().isNotEmpty) return text.trim();
      return null;
    } catch (e, st) {
      developer.log(
        'API call error',
        name: 'article_hub.ai',
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }
}
