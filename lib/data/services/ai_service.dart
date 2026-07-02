import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;

class AiService {
  static const int _singlePassLimit = 15000;
  static const int _chunkSize = 12000;
  static const int _summaryMaxTokens = 4000;

  final String baseUrl;
  final String apiKey;
  final String model;
  final Duration timeout;
  String? lastError;

  /// Called after a successful API response with the total_tokens from usage.
  void Function(int totalTokens)? onTokensUsed;

  AiService({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.timeout = const Duration(seconds: 60),
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

  /// True when the configured endpoint or model looks like MiMo.
  /// MiMo uses `max_completion_tokens` instead of `max_tokens` and has a
  /// "thinking" mode that consumes tokens before generating the answer.
  bool get _isMiMo {
    final b = baseUrl.toLowerCase();
    final m = model.toLowerCase();
    return b.contains('mimo') || m.contains('mimo');
  }

  Map<String, dynamic> get _summaryOutputOptions {
    if (_isMiMo) {
      return {
        'max_completion_tokens': _summaryMaxTokens,
        'thinking': {'type': 'disabled'},
      };
    }
    return {'max_tokens': _summaryMaxTokens};
  }

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
        '每条要点必须可以独立阅读——不要出现"同上""如前所述"等回指。'
        '每条要点应当尽量包含文章中的具体事实、产品名、时间点、数字或专有名词。'
        '禁止使用"文章介绍了..."、"本文讨论了..."等空泛开头，直接陈述事实。'
        '仅使用文章中的信息，不要添加外部知识或推测。';

    if (verbosity == 0) {
      return '用80-120个中文字概括这篇文章的立场、结论或主要发现；然后列出3~5条全篇的要点。$qualityRules';
    }

    if (contentLength < 2000) {
      return '用100-150个中文字概括这篇文章的立场、结论或主要发现；然后列出3~5条全篇的要点。$qualityRules';
    } else if (contentLength < 8000) {
      return '用200-300个中文字概括这篇文章的立场、结论或主要发现；然后列出5~8条全篇的要点。$qualityRules';
    } else {
      return '用300-500个中文字概括这篇文章的立场、结论或主要发现；然后列出5~7条全篇的要点。$qualityRules';
    }
  }

  static String _summaryInstructionEnglish(int contentLength, int verbosity) {
    const qualityRules =
        'Each bullet point MUST be self-contained — avoid back-references like '
        '"same as above" or "as mentioned earlier". '
        'Each bullet should include specific facts, product names, dates, '
        'numbers, or named entities from the article. '
        'Do NOT start bullets with "The article discusses...", "This piece covers..." '
        '— go straight to the fact. '
        'Use ONLY information from the article; do not add external knowledge or assumptions.';

    if (verbosity == 0) {
      return 'Summarize the position, conclusion, or key finding in 60-100 words, '
          'then list 3-5 key takeaways as bullet points. $qualityRules';
    }

    if (contentLength < 1500) {
      return 'Summarize the position, conclusion, or key finding in 80-120 words, '
          'then list 3-5 key takeaways as bullet points. $qualityRules';
    } else if (contentLength < 6000) {
      return 'Summarize the position, conclusion, or key finding in 150-250 words, '
          'then list 5-8 key takeaways as bullet points. $qualityRules';
    } else {
      return 'Summarize the position, conclusion, or key finding in 250-400 words, '
          'then list 5-7 key takeaways as bullet points. $qualityRules';
    }
  }

  Future<String?> summarize(String title, String content,
      {String languageHint = '', int verbosity = 0}) async {
    if (!isConfigured) return null;

    if (content.length > _singlePassLimit) {
      final chunkSummaries = await _summarizeChunks(
        content,
        languageHint: languageHint,
      );
      if (chunkSummaries.isEmpty) return null;
      return _summarizeSingle(
        title,
        chunkSummaries.join('\n\n---\n\n'),
        languageHint: languageHint,
        verbosity: verbosity,
        sourceLength: content.length,
      );
    }

    return _summarizeSingle(
      title,
      content,
      languageHint: languageHint,
      verbosity: verbosity,
      sourceLength: content.length,
    );
  }

  Future<String?> _summarizeSingle(
    String title,
    String content, {
    required String languageHint,
    required int verbosity,
    required int sourceLength,
  }) async {
    final isChinese =
        languageHint.contains('Chinese') || languageHint.contains('中文');

    final instruction = summaryInstruction(
      sourceLength,
      languageHint,
      verbosity,
    );

    final systemPrompt = isChinese
        ? '你是一个简洁的阅读助手。请用与原文相同的语言总结文章。$instruction'
        : 'You are a concise reading assistant. Summarize the article in the same language as the source. $instruction';

    final body = jsonEncode({
      'model': model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': 'Title: $title\n\n$content'},
      ],
      'temperature': 0.3,
      ..._summaryOutputOptions,
    });

    return _postChat(_chatUri(), body);
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

    if (content.length > _singlePassLimit) {
      final chunkSummaries = await _summarizeChunks(
        content,
        languageHint: languageHint,
      );
      if (chunkSummaries.isEmpty) return (title: null, summary: null);
      return _summarizeWithTitleSingle(
        title,
        chunkSummaries.join('\n\n---\n\n'),
        languageHint: languageHint,
        verbosity: verbosity,
        sourceLength: content.length,
      );
    }

    return _summarizeWithTitleSingle(
      title,
      content,
      languageHint: languageHint,
      verbosity: verbosity,
      sourceLength: content.length,
    );
  }

  Future<({String? title, String? summary})> _summarizeWithTitleSingle(
    String title,
    String content, {
    required String languageHint,
    required int verbosity,
    required int sourceLength,
  }) async {
    final isChinese =
        languageHint.contains('Chinese') || languageHint.contains('中文');

    final instruction = summaryInstruction(
      sourceLength,
      languageHint,
      verbosity,
    );

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
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': 'Title: $title\n\n$content'},
      ],
      'temperature': 0.3,
      ..._summaryOutputOptions,
    });

    return _postChatWithTitle(_chatUri(), body);
  }

  Future<List<String>> _summarizeChunks(
    String content, {
    required String languageHint,
  }) async {
    final isChinese =
        languageHint.contains('Chinese') || languageHint.contains('中文');
    final instruction = isChinese
        ? '请从这个文章片段中提取以下信息：\n'
            '1. 这段讲了什么事件/观点？（2-3句）\n'
            '2. 列出3-5个关键要点\n'
            '3. 这段与全文的关系：它是介绍背景 / 展开论证 / 给出结论？\n'
            '要求：只提取片段中的信息，不要猜测上下文，保留重要数字和专有名词。'
        : 'Extract the following from this article section:\n'
            '1. What event or viewpoint does this section describe? (2-3 sentences)\n'
            '2. List 3-5 key takeaways\n'
            '3. Role in the full article: background / argument / conclusion?\n'
            'Rules: Only extract information from this section. Do not guess context beyond the section. '
            'Preserve important numbers and named entities.';

    final summaries = <String>[];
    final chunkCount = (content.length / _chunkSize).ceil();

    for (
      var start = 0, index = 0;
      start < content.length;
      start += _chunkSize, index++
    ) {
      final end = (start + _chunkSize).clamp(0, content.length);
      final chunk = content.substring(start, end);
      final body = jsonEncode({
        'model': model,
        'messages': [
          {'role': 'system', 'content': instruction},
          {
            'role': 'user',
            'content': 'Section ${index + 1} of $chunkCount:\n\n$chunk',
          },
        ],
        'temperature': 0.2,
        ..._summaryOutputOptions,
      });

      final summary = await _postChat(_chatUri(), body);
      if (summary == null || summary.isEmpty) {
        developer.log(
          'long-article chunk ${index + 1}/$chunkCount failed',
          name: 'memora.ai',
        );
        return const [];
      }
      summaries.add(summary);
    }

    return summaries;
  }

  Future<({String? title, String? summary})> _postChatWithTitle(
    Uri uri,
    String body,
  ) async {
    final text = await _postChat(uri, body);
    if (text == null || text.isEmpty) return (title: null, summary: null);

    try {
      // Strip markdown code block wrappers if present (many LLMs wrap JSON in ```json ... ```)
      var jsonStr = text.trim();
      final codeBlockPattern =
          RegExp(r'^```(?:json)?\s*\n?(.*?)\n?```$', dotAll: true);
      final match = codeBlockPattern.firstMatch(jsonStr);
      if (match != null) {
        jsonStr = match.group(1)!.trim();
      }

      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
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

    final isMiMo = _isMiMo;
    developer.log(
      'chat() isMiMo=$isMiMo model="$model" baseUrl="$baseUrl"',
      name: 'memora.ai',
    );
    final payload = <String, dynamic>{
      'model': model,
      'messages': messages,
      'temperature': temperature,
    };
    if (isMiMo) {
      // MiMo: explicit thinking-disable + MiMo-specific token field.
      payload['max_completion_tokens'] = maxTokens;
      payload['thinking'] = {'type': 'disabled'};
    } else {
      // Other providers: send BOTH token fields so thinking models
      // (DeepSeek-R1, o1/o3, etc.) and classic models both work without
      // per-provider detection. Servers ignore the field they don't use.
      payload['max_tokens'] = maxTokens;
      payload['max_completion_tokens'] = maxTokens;
    }

    return _postChat(uri, jsonEncode(payload));
  }

  Future<String?> _postChat(Uri uri, String body) async {
    lastError = null;
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
        'API response status: ${response.statusCode}, url: $uri',
        name: 'memora.ai',
      );
      if (response.statusCode != 200) {
        lastError =
            'HTTP ${response.statusCode}: ${_responseError(response.body)}';
        developer.log(
          'response body: ${response.body.substring(0, response.body.length.clamp(0, 500))}',
          name: 'memora.ai',
        );
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final choices = json['choices'] as List?;
      if (choices == null || choices.isEmpty) {
        lastError = 'AI response did not contain any choices';
        return null;
      }

      final message = choices[0]['message'] as Map<String, dynamic>?;
      final text = message?['content'] as String?;

      // Track token usage if the API returns it.
      if (onTokensUsed != null) {
        final usage = json['usage'] as Map<String, dynamic>?;
        final totalTokens = usage?['total_tokens'] as int?;
        if (totalTokens != null && totalTokens > 0) {
          onTokensUsed!(totalTokens);
        }
      }

      final finishReason = choices[0]['finish_reason'] as String?;
      if (finishReason != null && finishReason != 'stop') {
        developer.log(
          'AI response finish_reason: $finishReason',
          name: 'memora.ai',
        );
      }

      if (text != null && text.trim().isNotEmpty) return text.trim();
      lastError = 'AI response content was empty';
      return null;
    } on TimeoutException {
      lastError = 'AI request timed out after ${timeout.inSeconds} seconds';
      developer.log(
        'AI API timeout ($timeout), url: $uri',
        name: 'memora.ai',
      );
      return null;
    } catch (e, st) {
      lastError = 'AI request failed: $e';
      developer.log(
        'API call error',
        name: 'memora.ai',
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

  String _responseError(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is Map<String, dynamic>) {
          final message = error['message'];
          if (message is String && message.trim().isNotEmpty) {
            return message.trim();
          }
        }
        final message = decoded['message'];
        if (message is String && message.trim().isNotEmpty) {
          return message.trim();
        }
      }
    } catch (_) {}

    final compact = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.isEmpty) return 'empty error response';
    return compact.substring(0, compact.length.clamp(0, 200));
  }
}
