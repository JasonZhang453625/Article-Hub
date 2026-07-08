import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;

import 'prompt_service.dart';

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

  Future<String> _buildSummaryInstruction(
      int contentLength, String languageHint, int verbosity) async {
    final isChinese =
        languageHint.contains('Chinese') || languageHint.contains('中文');
    final lang = isChinese ? 'zh' : 'en';

    final qualityRules = await _prompts.load('summary/quality_rules_$lang.txt');

    String instructionFile;
    if (verbosity == 0) {
      instructionFile = 'summary/instruction_${lang}_concise.txt';
    } else {
      final thresholds = isChinese
          ? [2000, 8000]
          : [1500, 6000];
      final sizes = ['short', 'medium', 'long'];
      final idx = contentLength < thresholds[0]
          ? 0
          : contentLength < thresholds[1]
              ? 1
              : 2;
      instructionFile = 'summary/instruction_${lang}_detailed_${sizes[idx]}.txt';
    }

    final instruction = await _prompts.load(instructionFile);
    return '$instruction $qualityRules';
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
    final lang = isChinese ? 'zh' : 'en';

    final instruction = await _buildSummaryInstruction(
      sourceLength,
      languageHint,
      verbosity,
    );
    final systemPrompt = await _prompts.load('summary/system_$lang.txt',
        {'instruction': instruction});

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
    final lang = isChinese ? 'zh' : 'en';

    final instruction = await _buildSummaryInstruction(
      sourceLength,
      languageHint,
      verbosity,
    );
    final systemPrompt = await _prompts.load('summary/system_with_title_$lang.txt',
        {'instruction': instruction});

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

    final instruction = await _prompts.load('summary/chunk_instruction_$lang.txt');

    final summaries = <String>[];
    final chunkCount = (content.length / _chunkSize).ceil();

    for (
        var start = 0, index = 0;
        start < content.length;
        start += _chunkSize, index++) {
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
        title: (aiTitle != null && aiTitle.trim().isNotEmpty)
            ? aiTitle.trim()
            : null,
        summary: (aiSummary != null && aiSummary.trim().isNotEmpty)
            ? aiSummary.trim()
            : null,
      );
    } catch (_) {
      return (title: null, summary: text);
    }
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
