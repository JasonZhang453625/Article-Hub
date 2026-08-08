import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../models/ai_thinking_level.dart';
import '../models/memory_document.dart';
import 'prompt_service.dart';

bool supportsDeepSeekThinking({required String model, String baseUrl = ''}) {
  final normalizedModel = model.trim().toLowerCase().split('/').last;
  return normalizedModel.contains('deepseek') ||
      baseUrl.trim().toLowerCase().contains('deepseek');
}

Map<String, dynamic> deepSeekThinkingOptions(AiThinkingLevel level) {
  final effort = level.deepSeekReasoningEffort;
  if (effort == null) {
    return {
      'thinking': {'type': 'disabled'},
    };
  }
  return {
    'thinking': {'type': 'enabled'},
    'reasoning_effort': effort,
  };
}

class AiSummaryResult {
  final String? title;
  final List<String> tags;
  final MemoryDocument? memory;

  const AiSummaryResult({this.title, this.tags = const [], this.memory});

  String? get summary {
    final rendered = memory?.toMarkdown().trim();
    return rendered == null || rendered.isEmpty ? null : rendered;
  }
}

/// Common interface for LLM completion providers.
///
/// [AiService] implements the BYOK path (client talks directly to the user's
/// configured OpenAI-compatible provider). [HostedAiService] implements the
/// hosted path (client talks to the Memora backend, which proxies to its own
/// model credentials). Pipeline stages and RAG only depend on this interface.
abstract interface class AiGateway {
  bool get isConfigured;

  String? get lastError;

  void Function(int totalTokens)? onTokensUsed;

  AiThinkingLevel get thinkingLevel;

  set thinkingLevel(AiThinkingLevel value);

  Future<AiSummaryResult> summarizeWithTitle(
    String title,
    String content, {
    String languageHint = '',
  });

  Future<String?> chat({
    required String systemPrompt,
    required String userMessage,
    List<Map<String, String>> history = const [],
    double temperature = 0.3,
    int maxTokens = 800,
  });

  /// Streams assistant text as soon as the provider sends each SSE delta.
  ///
  /// Implementations should keep [lastError] and [lastStatusCode] updated when
  /// the stream cannot be completed. A caller may still receive a few chunks
  /// before a transport error, so partial text must be treated as usable UI
  /// state rather than discarded automatically.
  Stream<String> chatStream({
    required String systemPrompt,
    required String userMessage,
    List<Map<String, String>> history = const [],
    double temperature = 0.3,
    int maxTokens = 800,
  });
}

class AiService implements AiGateway {
  static const int _singlePassLimit = 15000;
  static const int _chunkSize = 12000;
  static const int _summaryMaxTokens = 4000;
  static const int _maxTransientRetries = 1;
  static const Duration defaultTimeout = Duration(seconds: 90);
  static const Duration defaultRetryDelay = Duration(milliseconds: 800);

  final String baseUrl;
  final String apiKey;
  final String model;
  final Duration timeout;
  final Duration retryDelay;
  final PromptService _prompts;

  @override
  AiThinkingLevel thinkingLevel;

  @override
  String? lastError;

  int? lastStatusCode;

  /// Called after a successful API response with the total_tokens from usage.
  @override
  void Function(int totalTokens)? onTokensUsed;

  AiService({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.timeout = defaultTimeout,
    this.retryDelay = defaultRetryDelay,
    this.thinkingLevel = AiThinkingLevel.none,
    PromptService? promptService,
  }) : _prompts = promptService ?? PromptService();

  Uri _chatUri() {
    var base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (!base.endsWith('/v1') && !base.contains('/v1/')) {
      base = '$base/v1';
    }
    return Uri.parse('$base/chat/completions');
  }

  @override
  bool get isConfigured =>
      baseUrl.trim().isNotEmpty && apiKey.trim().isNotEmpty;

  bool get _isMiMo {
    final b = baseUrl.toLowerCase();
    final m = model.toLowerCase();
    return b.contains('mimo') || m.contains('mimo');
  }

  bool get _isDeepSeek =>
      supportsDeepSeekThinking(model: model, baseUrl: baseUrl);

  bool get _usesMaxCompletionTokens {
    if (_isMiMo) return true;
    final normalizedModel = model.trim().toLowerCase().split('/').last;
    return normalizedModel.startsWith('gpt-5') ||
        RegExp(r'^(?:o1|o3|o4)(?:[-.]|$)').hasMatch(normalizedModel);
  }

  Map<String, dynamic> _outputTokenOptions(
    int maxTokens, {
    AiThinkingLevel? chatThinkingLevel,
  }) {
    final options = <String, dynamic>{};
    if (_isMiMo) {
      options.addAll({
        'max_completion_tokens': maxTokens,
        'thinking': {'type': 'disabled'},
      });
    } else if (_usesMaxCompletionTokens) {
      options['max_completion_tokens'] = maxTokens;
    } else {
      options['max_tokens'] = maxTokens;
    }

    if (_isDeepSeek && chatThinkingLevel != null) {
      options.addAll(deepSeekThinkingOptions(chatThinkingLevel));
    }
    return options;
  }

  /// Summarize content and also generate a proper article title.
  @override
  Future<AiSummaryResult> summarizeWithTitle(
    String title,
    String content, {
    String languageHint = '',
  }) async {
    if (!isConfigured) return const AiSummaryResult();

    if (content.length > _singlePassLimit) {
      final chunkSummaries = await _summarizeChunks(
        content,
        languageHint: languageHint,
      );
      if (chunkSummaries.isEmpty) return const AiSummaryResult();
      return _summarizeWithTitleSingle(
        title,
        chunkSummaries.join('\n\n---\n\n'),
        languageHint: languageHint,
      );
    }

    return _summarizeWithTitleSingle(
      title,
      content,
      languageHint: languageHint,
    );
  }

  Future<AiSummaryResult> _summarizeWithTitleSingle(
    String title,
    String content, {
    required String languageHint,
  }) async {
    final isChinese =
        languageHint.contains('Chinese') || languageHint.contains('中文');
    final lang = isChinese ? 'zh' : 'en';

    final systemPrompt = await _prompts.load('summary/full_summary_$lang.txt');

    final body = jsonEncode({
      'model': model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': 'Title: $title\n\n$content'},
      ],
      'temperature': 0.3,
      ..._outputTokenOptions(_summaryMaxTokens),
    });

    return _postChatWithTitle(_chatUri(), body);
  }

  Future<List<String>> _summarizeChunks(
    String content, {
    required String languageHint,
  }) async {
    final isChinese =
        languageHint.contains('Chinese') || languageHint.contains('中文');
    final lang = isChinese ? 'zh' : 'en';

    final instruction = await _prompts.load(
      'summary/chunk_instruction_$lang.txt',
    );

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
        ..._outputTokenOptions(_summaryMaxTokens),
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

  Future<AiSummaryResult> _postChatWithTitle(Uri uri, String body) async {
    final text = await _postChat(uri, body);
    if (text == null || text.isEmpty) return const AiSummaryResult();

    return _parseStructuredSummary(text);
  }

  /// Parses the current JSON contract and keeps legacy tagged-text/JSON
  /// compatibility for providers that cached an older prompt.
  AiSummaryResult _parseStructuredSummary(String text) {
    final jsonResult = _tryParseJsonMemory(text);
    if (jsonResult != null) return jsonResult;

    final titleMatch = RegExp(
      r'【(?:标题|Title)】\s*\n?(.+?)(?=\n【(?:摘要|Summary)】)',
      dotAll: true,
    ).firstMatch(text);
    final summaryMatch = RegExp(
      r'【(?:摘要|Summary)】\s*\n?(.+?)(?=\n【(?:要点|Key\s+Points)】)',
      dotAll: true,
    ).firstMatch(text);
    final pointsMatch = RegExp(
      r'【(?:要点|Key\s+Points)】\s*\n?(.+?)(?=\n【(?:总结|Conclusion)】)',
      dotAll: true,
    ).firstMatch(text);
    final conclusionMatch = RegExp(
      r'【(?:总结|Conclusion)】\s*\n?(.+?)(?:\n✓\s*)?$',
      dotAll: true,
    ).firstMatch(text);

    if (titleMatch != null || summaryMatch != null || pointsMatch != null) {
      return AiSummaryResult(
        title: _nonEmptyString(titleMatch?.group(1)),
        memory: MemoryDocument.ai(
          overview: summaryMatch?.group(1)?.trim() ?? '',
          keyPoints: _keyPointsFromLegacyText(
            pointsMatch?.group(1)?.trim() ?? '',
          ),
          conclusion: conclusionMatch?.group(1)?.trim() ?? '',
        ),
      );
    }

    final oldConclusion = RegExp(
      r'【(?:一句话结论|Key\s+Conclusion)】\s*\n?(.+?)(?=\n【(?:核心摘要|Core\s+Summary)】)',
      dotAll: true,
    ).firstMatch(text);
    final oldSummary = RegExp(
      r'【(?:核心摘要|Core\s+Summary)】\s*\n?(.+?)(?=\n【(?:全篇要点|Key\s+Points)】)',
      dotAll: true,
    ).firstMatch(text);
    final oldPoints = RegExp(
      r'【(?:全篇要点|Key\s+Points)】\s*\n?(.+?)(?:\n✓\s*)?$',
      dotAll: true,
    ).firstMatch(text);

    if (oldConclusion != null || oldSummary != null || oldPoints != null) {
      return AiSummaryResult(
        title: _nonEmptyString(oldConclusion?.group(1)),
        memory: MemoryDocument.ai(
          overview: oldSummary?.group(1)?.trim() ?? '',
          keyPoints: _keyPointsFromLegacyText(
            oldPoints?.group(1)?.trim() ?? '',
          ),
          conclusion: '',
        ),
      );
    }

    lastError = 'AI returned invalid structured memory JSON';
    return const AiSummaryResult();
  }

  AiSummaryResult? _tryParseJsonMemory(String text) {
    try {
      var jsonText = text.trim();
      final fence = RegExp(
        r'^```(?:json)?\s*\n?(.*?)\n?```$',
        dotAll: true,
      ).firstMatch(jsonText);
      if (fence != null) jsonText = fence.group(1)!.trim();

      final decoded = jsonDecode(jsonText);
      if (decoded is! Map<String, dynamic>) return null;

      final title = _nonEmptyString(decoded['title']);
      final legacySummary = _nonEmptyString(decoded['summary']);
      if (legacySummary != null) {
        return AiSummaryResult(
          title: title,
          memory: MemoryDocument.legacyMarkdown(body: legacySummary),
        );
      }

      final overview = _nonEmptyString(decoded['overview']);
      final conclusion = decoded['conclusion'] is String
          ? (decoded['conclusion'] as String).trim()
          : null;
      final rawTags = decoded['tags'];
      final rawPoints = decoded['keyPoints'];
      if (title == null ||
          overview == null ||
          conclusion == null ||
          rawTags is! List ||
          rawPoints is! List) {
        lastError = 'AI returned incomplete structured memory JSON';
        return const AiSummaryResult();
      }

      final tags = rawTags
          .whereType<String>()
          .map((tag) => tag.trim())
          .where((tag) => tag.isNotEmpty)
          .toSet()
          .take(5)
          .toList();
      if (tags.length < 2) {
        lastError = 'AI returned fewer than 2 structured memory tags';
        return const AiSummaryResult();
      }

      final keyPoints = <MemoryKeyPoint>[];
      for (final rawPoint in rawPoints) {
        if (rawPoint is! Map) continue;
        final topic = _nonEmptyString(rawPoint['topic']);
        final content = _nonEmptyString(rawPoint['content']);
        if (topic == null || content == null) continue;
        keyPoints.add(
          MemoryKeyPoint(
            id: 'kp_${const Uuid().v4()}',
            order: keyPoints.length + 1,
            topic: topic,
            content: content,
            sourceRefs:
                (rawPoint['sourceRefs'] as List?)
                    ?.whereType<String>()
                    .toList() ??
                const [],
          ),
        );
      }
      if (keyPoints.isEmpty) {
        lastError = 'AI returned no valid structured memory key points';
        return const AiSummaryResult();
      }

      return AiSummaryResult(
        title: title,
        tags: tags,
        memory: MemoryDocument.ai(
          overview: overview,
          keyPoints: keyPoints,
          conclusion: conclusion,
        ),
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  List<MemoryKeyPoint> _keyPointsFromLegacyText(String text) {
    final points = <MemoryKeyPoint>[];
    for (final rawLine in text.split('\n')) {
      final content = rawLine
          .replaceFirst(RegExp(r'^\s*(?:\d+[.)]|[-*])\s*'), '')
          .trim();
      if (content.isEmpty) continue;
      points.add(
        MemoryKeyPoint(
          id: 'kp_${const Uuid().v4()}',
          order: points.length + 1,
          topic: '',
          content: content,
        ),
      );
    }
    return points;
  }

  String? _nonEmptyString(dynamic value) {
    if (value is! String || value.trim().isEmpty) return null;
    return value.trim();
  }

  @override
  Future<String?> chat({
    required String systemPrompt,
    required String userMessage,
    List<Map<String, String>> history = const [],
    double temperature = 0.3,
    int maxTokens = 800,
  }) async {
    if (!isConfigured) {
      lastError = 'AI service is not configured';
      return null;
    }
    final buffer = StringBuffer();
    await for (final chunk in chatStream(
      systemPrompt: systemPrompt,
      userMessage: userMessage,
      history: history,
      temperature: temperature,
      maxTokens: maxTokens,
    )) {
      buffer.write(chunk);
    }
    final text = buffer.toString().trim();
    if (text.isEmpty) {
      lastError ??= 'AI response content was empty';
      return null;
    }
    return text;
  }

  @override
  Stream<String> chatStream({
    required String systemPrompt,
    required String userMessage,
    List<Map<String, String>> history = const [],
    double temperature = 0.3,
    int maxTokens = 800,
  }) async* {
    if (!isConfigured) {
      lastError = 'AI service is not configured';
      return;
    }

    final uri = _chatUri();
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': systemPrompt},
      ...history,
      {'role': 'user', 'content': userMessage},
    ];
    final payload = <String, dynamic>{
      'model': model,
      'messages': messages,
      'stream': true,
    };
    if (!_isDeepSeek || thinkingLevel == AiThinkingLevel.none) {
      payload['temperature'] = temperature;
    }
    payload.addAll(
      _outputTokenOptions(maxTokens, chatThinkingLevel: thinkingLevel),
    );

    developer.log(
      'chatStream() usesMaxCompletionTokens=$_usesMaxCompletionTokens '
      'model="$model" baseUrl="$baseUrl"',
      name: 'memora.ai',
    );

    lastError = null;
    lastStatusCode = null;
    final body = jsonEncode(payload);

    for (var attempt = 0; attempt <= _maxTransientRetries; attempt++) {
      var emitted = false;
      final client = http.Client();
      try {
        final request = http.Request('POST', uri)
          ..headers.addAll({
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream',
            'Authorization': 'Bearer $apiKey',
          })
          ..body = body;
        final response = await client.send(request).timeout(timeout);
        lastStatusCode = response.statusCode;
        developer.log(
          'Streaming API response status: ${response.statusCode}, url: $uri',
          name: 'memora.ai',
        );

        if (response.statusCode != 200) {
          final responseBody = await response.stream.bytesToString().timeout(
            timeout,
          );
          final error =
              'HTTP ${response.statusCode}: ${_responseError(responseBody)}';
          developer.log(
            'Streaming AI request failed with HTTP ${response.statusCode}',
            name: 'memora.ai',
          );
          if (_isTransientStatus(response.statusCode, responseBody) &&
              attempt < _maxTransientRetries) {
            await _waitBeforeRetry(attempt, error);
            continue;
          }
          lastError = error;
          return;
        }

        await for (final chunk in _decodeChatStream(response)) {
          if (chunk.isEmpty) continue;
          emitted = true;
          yield chunk;
        }
        if (!emitted) {
          lastError = 'AI response content was empty';
        }
        return;
      } on TimeoutException {
        final error = 'AI request timed out after ${timeout.inSeconds} seconds';
        if (!emitted && attempt < _maxTransientRetries) {
          await _waitBeforeRetry(attempt, error);
          continue;
        }
        lastError = error;
        developer.log(
          'Streaming AI API timeout ($timeout), url: $uri',
          name: 'memora.ai',
        );
        return;
      } catch (e, st) {
        final error = 'AI request failed: $e';
        if (!emitted &&
            _isTransientException(e) &&
            attempt < _maxTransientRetries) {
          await _waitBeforeRetry(attempt, error);
          continue;
        }
        lastError = error;
        developer.log(
          'Streaming API call error',
          name: 'memora.ai',
          error: e,
          stackTrace: st,
        );
        return;
      } finally {
        client.close();
      }
    }
  }

  /// Decodes both the normal OpenAI-compatible SSE response and a JSON
  /// response from older providers that ignore `stream: true`. The latter is
  /// a compatibility fallback; normal chat requests always ask for SSE.
  Stream<String> _decodeChatStream(http.StreamedResponse response) async* {
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    if (!contentType.contains('text/event-stream')) {
      final body = await response.stream.bytesToString().timeout(timeout);
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return;
      _recordUsage(decoded);
      final text = _chatTextFromJson(decoded);
      if (text != null && text.isNotEmpty) yield text;
      return;
    }

    final eventData = StringBuffer();
    var done = false;
    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .timeout(timeout)) {
      if (line.startsWith(':')) continue;
      if (line.startsWith('data:')) {
        eventData.write(line.substring(5).trimLeft());
        eventData.write('\n');
        continue;
      }
      if (line.trim().isEmpty && eventData.length > 0) {
        final data = eventData.toString().trim();
        eventData.clear();
        if (data == '[DONE]') {
          done = true;
          break;
        }
        final text = _chatTextFromSseData(data);
        if (text != null && text.isNotEmpty) yield text;
      }
    }

    if (!done && eventData.length > 0) {
      final data = eventData.toString().trim();
      if (data != '[DONE]') {
        final text = _chatTextFromSseData(data);
        if (text != null && text.isNotEmpty) yield text;
      }
    }
    if (!done) {
      throw http.ClientException(
        'AI stream ended before [DONE]',
        response.request?.url,
      );
    }
  }

  String? _chatTextFromSseData(String data) {
    try {
      final decoded = jsonDecode(data);
      if (decoded is! Map<String, dynamic>) return null;
      _recordUsage(decoded);
      return _chatTextFromJson(decoded);
    } catch (_) {
      // A malformed SSE event is ignored so one provider-side keepalive or
      // extension event cannot destroy the rest of an otherwise valid stream.
      return null;
    }
  }

  String? _chatTextFromJson(Map<String, dynamic> json) {
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      return null;
    }
    final choice = choices.first as Map;
    final delta = choice['delta'];
    final message = choice['message'];
    final content = delta is Map
        ? delta['content']
        : message is Map
        ? message['content']
        : choice['text'];
    if (content is String) return content;
    if (content is List) {
      final parts = content
          .whereType<Map>()
          .map((part) => part['text'])
          .whereType<String>()
          .join();
      return parts.isEmpty ? null : parts;
    }
    return null;
  }

  void _recordUsage(Map<String, dynamic> json) {
    if (onTokensUsed == null) return;
    final usage = json['usage'];
    if (usage is! Map) return;
    final totalTokens = (usage['total_tokens'] as num?)?.toInt();
    if (totalTokens != null && totalTokens > 0) {
      onTokensUsed!(totalTokens);
    }
  }

  Future<String?> _postChat(Uri uri, String body) async {
    lastError = null;
    lastStatusCode = null;
    for (var attempt = 0; attempt <= _maxTransientRetries; attempt++) {
      lastStatusCode = null;
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

        lastStatusCode = response.statusCode;
        developer.log(
          'API response status: ${response.statusCode}, url: $uri',
          name: 'memora.ai',
        );
        if (response.statusCode != 200) {
          final error =
              'HTTP ${response.statusCode}: ${_responseError(response.body)}';
          developer.log(
            'AI request failed with HTTP ${response.statusCode}',
            name: 'memora.ai',
          );
          if (_isTransientStatus(response.statusCode, response.body) &&
              attempt < _maxTransientRetries) {
            await _waitBeforeRetry(attempt, error);
            continue;
          }
          lastError = error;
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
        final error = 'AI request timed out after ${timeout.inSeconds} seconds';
        if (attempt < _maxTransientRetries) {
          await _waitBeforeRetry(attempt, error);
          continue;
        }
        lastError = error;
        developer.log(
          'AI API timeout ($timeout), url: $uri',
          name: 'memora.ai',
        );
        return null;
      } catch (e, st) {
        final error = 'AI request failed: $e';
        if (_isTransientException(e) && attempt < _maxTransientRetries) {
          await _waitBeforeRetry(attempt, error);
          continue;
        }
        lastError = error;
        developer.log(
          'API call error',
          name: 'memora.ai',
          error: e,
          stackTrace: st,
        );
        return null;
      }
    }
    return null;
  }

  bool _isTransientStatus(int statusCode, String body) =>
      (statusCode == 429 &&
          _responseErrorCode(body) != 'daily_quota_exceeded') ||
      statusCode >= 500 && statusCode <= 599;

  String? _responseErrorCode(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is Map<String, dynamic> && error['code'] is String) {
          return error['code'] as String;
        }
      }
    } catch (_) {}
    return null;
  }

  bool _isTransientException(Object error) {
    final message = error.toString().toLowerCase();
    return error is http.ClientException ||
        message.contains('connection abort') ||
        message.contains('connection reset') ||
        message.contains('connection refused') ||
        message.contains('broken pipe') ||
        message.contains('failed host lookup') ||
        message.contains('network is unreachable');
  }

  Future<void> _waitBeforeRetry(int attempt, String reason) async {
    developer.log(
      '$reason; retrying AI request (${attempt + 1}/$_maxTransientRetries)',
      name: 'memora.ai',
    );
    if (retryDelay <= Duration.zero) return;
    await Future<void>.delayed(
      Duration(milliseconds: retryDelay.inMilliseconds * (attempt + 1)),
    );
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
