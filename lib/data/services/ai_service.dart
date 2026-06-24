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

    if (isChinese) {
      return _summaryInstructionChinese(contentLength, verbosity);
    } else {
      return _summaryInstructionEnglish(contentLength, verbosity);
    }
  }

  static String _summaryInstructionChinese(int contentLength, int verbosity) {
    const qualityRules =
        '每条要点必须包含文章中的具体事实、数字或专有名词。'
        '禁止使用"文章介绍了..."、"本文讨论了..."等空泛开头，直接陈述事实。'
        '仅使用文章中的信息，不要添加外部知识或推测。';

    if (verbosity == 0) {
      return '用80-120个中文字写一段概述，然后列出3条要点。$qualityRules';
    }

    if (contentLength < 2000) {
      return '用100-150个中文字写一段概述，然后列出3条要点。$qualityRules';
    } else if (contentLength < 8000) {
      return '用200-300个中文字写一段概述，然后列出5条要点。$qualityRules';
    } else {
      return '用300-500个中文字写一段概述，然后列出5-7条要点。$qualityRules';
    }
  }

  static String _summaryInstructionEnglish(int contentLength, int verbosity) {
    const qualityRules =
        'Each bullet point MUST mention a specific fact, number, or entity from the article. '
        'Do NOT start bullets with "The article discusses...", "This piece covers..." — go straight to the fact. '
        'Use ONLY information from the article; do not add external knowledge or assumptions.';

    if (verbosity == 0) {
      return 'Write a brief 60-100 word overview followed by 3 key takeaways as bullet points. $qualityRules';
    }

    if (contentLength < 1500) {
      return 'Write a 80-120 word overview followed by 3 key takeaways as bullet points. $qualityRules';
    } else if (contentLength < 6000) {
      return 'Write a 150-250 word overview followed by 5 key takeaways as bullet points. $qualityRules';
    } else {
      return 'Write a 250-400 word overview followed by 5-7 key takeaways as bullet points. $qualityRules';
    }
  }

  Future<String?> summarize(String title, String content, {String languageHint = '', int verbosity = 0}) async {
    if (!isConfigured) return null;

    final uri = _chatUri();

    final truncatedContent = content.length > 15000
        ? '${content.substring(0, 15000)}...'
        : content;

    final isChinese = languageHint.contains('Chinese') ||
        languageHint.contains('中文');

    final instruction = summaryInstruction(truncatedContent.length, languageHint, verbosity);

    final systemPrompt = isChinese
        ? '你是一个简洁的阅读助手。请用与原文相同的语言总结文章。$instruction'
        : 'You are a concise reading assistant. Summarize the article in the same language as the source. $instruction';

    final body = jsonEncode({
      'model': model,
      'messages': [
        {
          'role': 'system',
          'content': systemPrompt,
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

    final isChinese = languageHint.contains('Chinese') ||
        languageHint.contains('中文');

    final instruction = summaryInstruction(4000, languageHint, verbosity);

    final systemPrompt = isChinese
        ? '你是一个简洁的阅读助手。用户会给你一个URL和标题。'
            '如果你能访问该URL，请阅读全文并进行总结。'
            '如果无法访问，请仅根据标题推测文章内容并简要描述。'
            '$instruction'
        : 'You are a concise reading assistant. The user will give you a URL and title. '
            'If you can access the URL, read the content and summarize it. '
            'If you cannot access it, summarize based on the title alone — give a brief '
            'description of what this article is likely about. '
            '$instruction';

    final body = jsonEncode({
      'model': model,
      'messages': [
        {
          'role': 'system',
          'content': systemPrompt,
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

  /// Summarize content and also generate a proper article title.
  /// Returns a record of (title, summary). Either may be null on failure.
  Future<({String? title, String? summary})> summarizeWithTitle(
    String title,
    String content, {
    String languageHint = '',
    int verbosity = 0,
  }) async {
    if (!isConfigured) return (title: null, summary: null);

    final uri = _chatUri();

    final truncatedContent = content.length > 15000
        ? '${content.substring(0, 15000)}...'
        : content;

    final isChinese = languageHint.contains('Chinese') ||
        languageHint.contains('中文');

    final instruction = summaryInstruction(truncatedContent.length, languageHint, verbosity);

    final systemPrompt = isChinese
        ? '你是一个简洁的阅读助手。请用与原文相同的语言阅读文章，然后返回一个JSON对象，包含两个字段：\n'
            '1. "title"：一个简洁准确的中文文章标题（不是URL或域名，而是能概括文章内容的标题）\n'
            '2. "summary"：文章摘要。$instruction\n'
            '请只返回JSON，不要添加其他文字。格式：{"title":"...","summary":"..."}'
        : 'You are a concise reading assistant. Read the article and return a JSON object with two fields:\n'
            '1. "title": a concise, descriptive article title (not a URL or domain name)\n'
            '2. "summary": the article summary. $instruction\n'
            'Return ONLY the JSON, nothing else. Format: {"title":"...","summary":"..."}';

    final body = jsonEncode({
      'model': model,
      'messages': [
        {
          'role': 'system',
          'content': systemPrompt,
        },
        {
          'role': 'user',
          'content': 'Title: $title\n\n$truncatedContent',
        },
      ],
      'temperature': 0.3,
      'max_tokens': 1500,
    });

    return _postChatWithTitle(uri, body);
  }

  /// Summarize from URL and also generate a proper article title.
  Future<({String? title, String? summary})> summarizeFromUrlWithTitle(
    String title,
    String url, {
    String languageHint = '',
    int verbosity = 0,
  }) async {
    if (!isConfigured) return (title: null, summary: null);

    final uri = _chatUri();

    final isChinese = languageHint.contains('Chinese') ||
        languageHint.contains('中文');

    final instruction = summaryInstruction(4000, languageHint, verbosity);

    final systemPrompt = isChinese
        ? '你是一个简洁的阅读助手。用户会给你一个URL和标题。\n'
            '如果你能访问该URL，请阅读全文。如果无法访问，请仅根据标题推测。\n'
            '然后返回一个JSON对象，包含两个字段：\n'
            '1. "title"：一个简洁准确的文章标题（不是URL或域名）\n'
            '2. "summary"：文章摘要。$instruction\n'
            '请只返回JSON，不要添加其他文字。格式：{"title":"...","summary":"..."}'
        : 'You are a concise reading assistant. The user will give you a URL and title.\n'
            'If you can access the URL, read the content. If not, infer from the title.\n'
            'Then return a JSON object with two fields:\n'
            '1. "title": a concise, descriptive article title (not a URL or domain name)\n'
            '2. "summary": the article summary. $instruction\n'
            'Return ONLY the JSON, nothing else. Format: {"title":"...","summary":"..."}';

    final body = jsonEncode({
      'model': model,
      'messages': [
        {
          'role': 'system',
          'content': systemPrompt,
        },
        {
          'role': 'user',
          'content': 'Title: $title\nURL: $url',
        },
      ],
      'temperature': 0.3,
      'max_tokens': 1500,
    });

    return _postChatWithTitle(uri, body);
  }

  Future<({String? title, String? summary})> _postChatWithTitle(Uri uri, String body) async {
    final text = await _postChat(uri, body);
    if (text == null || text.isEmpty) return (title: null, summary: null);

    try {
      // Try to parse as JSON
      final json = jsonDecode(text) as Map<String, dynamic>;
      final aiTitle = json['title'] as String?;
      final aiSummary = json['summary'] as String?;
      return (
        title: (aiTitle != null && aiTitle.trim().isNotEmpty) ? aiTitle.trim() : null,
        summary: (aiSummary != null && aiSummary.trim().isNotEmpty) ? aiSummary.trim() : null,
      );
    } catch (_) {
      // JSON parsing failed — treat entire response as summary only
      return (title: null, summary: text);
    }
  }

  /// General-purpose chat completion with explicit system + user messages.
  /// Used by the RAG conversation flow where the caller controls both prompts.
  Future<String?> chat({
    required String systemPrompt,
    required String userMessage,
    List<Map<String, String>> history = const [],
    double temperature = 0.3,
    int maxTokens = 800,
  }) async {
    if (!isConfigured) return null;
    final uri = _chatUri();
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': systemPrompt},
      ...history,
      {'role': 'user', 'content': userMessage},
    ];
    final body = jsonEncode({
      'model': model,
      'messages': messages,
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
