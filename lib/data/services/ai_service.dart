import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../models/memory_document.dart';
import 'prompt_service.dart';

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

class AiService {
  static const int _singlePassLimit = 15000;
  static const int _chunkSize = 12000;
  static const int _summaryMaxTokens = 4000;

  final String baseUrl;
  final String apiKey;
  final String model;
  final Duration timeout;
  final PromptService _prompts;
  String? lastError;

  /// Called after a successful API response with the total_tokens from usage.
  void Function(int totalTokens)? onTokensUsed;

  AiService({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.timeout = const Duration(seconds: 60),
    PromptService? promptService,
  }) : _prompts = promptService ?? PromptService();

  Uri _chatUri() {
    var base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (!base.endsWith('/v1') && !base.contains('/v1/')) {
      base = '$base/v1';
    }
    return Uri.parse('$base/chat/completions');
  }

  bool get isConfigured =>
      baseUrl.trim().isNotEmpty && apiKey.trim().isNotEmpty;

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

  /// Summarize content and also generate a proper article title.
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
      payload['max_completion_tokens'] = maxTokens;
      payload['thinking'] = {'type': 'disabled'};
    } else {
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
      developer.log('AI API timeout ($timeout), url: $uri', name: 'memora.ai');
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
