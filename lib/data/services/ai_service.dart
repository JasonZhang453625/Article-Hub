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

  /// Build a language- and length-aware summary instruction.
  ///
  /// [contentLength] is the character count of the extracted article body.
  /// [languageHint] is the user's language preference string.
  /// [verbosity] controls detail level: 0 = concise (3 bullets),
  ///   1 = detailed (adaptive by article length, 3-7 bullets).
  static String summaryInstruction(
      int contentLength, String languageHint, int verbosity) {
    final isChinese = languageHint.contains('Chinese') ||
        languageHint.contains('中文');

    // Content-quality constraints — applied to all modes.
    final qualityRules = isChinese
        ? 'Each bullet point MUST mention a specific fact, number, or entity from the article. '
            'Do NOT use vague phrases like "文章介绍了..." or "本文讨论了..." — go straight to the fact. '
            'Use ONLY information from the article; do not add external knowledge.'
        : 'Each bullet point MUST mention a specific fact, number, or entity from the article. '
            'Do NOT start bullets with "The article discusses...", "This piece covers..." — go straight to the fact. '
            'Use ONLY information from the article; do not add external knowledge or assumptions.';

    if (verbosity == 0) {
      if (isChinese) {
        return 'Write a brief 80-120 character overview followed by 3 key takeaways as bullet points. $qualityRules';
      } else {
        return 'Write a brief 60-100 word overview followed by 3 key takeaways as bullet points. $qualityRules';
      }
    }

    // Detailed mode — adaptive by article length.
    if (isChinese) {
      if (contentLength < 2000) {
        return 'Write a 100-150 character overview followed by 3 key takeaways as bullet points. $qualityRules';
      } else if (contentLength < 8000) {
        return 'Write a 200-300 character overview followed by 5 key takeaways as bullet points. $qualityRules';
      } else {
        return 'Write a 300-500 character overview followed by 5-7 key takeaways as bullet points. $qualityRules';
      }
    } else {
      if (contentLength < 1500) {
        return 'Write a 80-120 word overview followed by 3 key takeaways as bullet points. $qualityRules';
      } else if (contentLength < 6000) {
        return 'Write a 150-250 word overview followed by 5 key takeaways as bullet points. $qualityRules';
      } else {
        return 'Write a 250-400 word overview followed by 5-7 key takeaways as bullet points. $qualityRules';
      }
    }
  }

  Future<String?> summarize(String title, String content, {String languageHint = '', int verbosity = 0}) async {
    if (!isConfigured) return null;

    final uri = _chatUri();

    final truncatedContent = content.length > 15000
        ? '${content.substring(0, 15000)}...'
        : content;

    final langInstruction = languageHint.isNotEmpty
        ? '\n$languageHint'
        : '';

    final instruction = summaryInstruction(truncatedContent.length, languageHint, verbosity);

    final body = jsonEncode({
      'model': model,
      'messages': [
        {
          'role': 'system',
          'content':
              'You are a concise reading assistant. Summarize the article in the same language as the source. '
              '$instruction '
              '$langInstruction',
        },
        {
          'role': 'user',
          'content': 'Title: $title\n\n$truncatedContent',
        },
      ],
      'temperature': 0.3,
      'max_tokens': 1500,
    });

    return _postChat(uri, body);
  }

  Future<String?> summarizeFromUrl(String title, String url, {String languageHint = '', int verbosity = 0}) async {
    if (!isConfigured) return null;

    final uri = _chatUri();

    final langInstruction = languageHint.isNotEmpty
        ? '\n$languageHint'
        : '';

    final instruction = summaryInstruction(4000, languageHint, verbosity);

    final body = jsonEncode({
      'model': model,
      'messages': [
        {
          'role': 'system',
          'content':
              'You are a concise reading assistant. The user will give you a URL and title. '
              'If you can access the URL, read the content and summarize it. '
              'If you cannot access it, summarize based on the title alone — give a brief '
              'description of what this article is likely about. '
              '$instruction '
              '$langInstruction',
        },
        {
          'role': 'user',
          'content': 'Title: $title\nURL: $url',
        },
      ],
      'temperature': 0.3,
      'max_tokens': 1500,
    });

    return _postChat(uri, body);
  }

  /// General-purpose chat completion with explicit system + user messages.
  /// Used by the RAG conversation flow where the caller controls both prompts.
  Future<String?> chat({
    required String systemPrompt,
    required String userMessage,
    double temperature = 0.3,
    int maxTokens = 800,
  }) async {
    if (!isConfigured) return null;
    final uri = _chatUri();
    final body = jsonEncode({
      'model': model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userMessage},
      ],
      'temperature': temperature,
      'max_tokens': maxTokens,
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

      final finishReason = choices[0]['finish_reason'] as String?;
      if (finishReason != null && finishReason != 'stop') {
        developer.log(
          'AI response finish_reason: $finishReason',
          name: 'article_hub.ai',
        );
      }

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
