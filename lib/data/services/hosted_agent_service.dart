import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../config/backend_config.dart';
import '../models/ai_thinking_level.dart';
import 'ai_service.dart';
import 'auth_service.dart';

class HostedAgentSource {
  final String id;
  final String title;
  final String url;
  final String content;
  final double score;

  const HostedAgentSource({
    required this.id,
    required this.title,
    required this.url,
    required this.content,
    required this.score,
  });

  factory HostedAgentSource.fromJson(Map<String, dynamic> json) {
    return HostedAgentSource(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      content: (json['content'] ?? '').toString(),
      score: (json['score'] as num?)?.toDouble() ?? 0,
    );
  }
}

class HostedAgentEvent {
  final String type;
  final Map<String, dynamic> data;

  const HostedAgentEvent({required this.type, required this.data});
}

/// Streaming client for the server-side Memora Agent Runtime.
///
/// Unlike [HostedAiService], this endpoint may run several model/tool steps
/// before it emits the final answer. `webSearch` is a per-run permission: the
/// model decides whether and how often the registered `web_search` tool is
/// actually useful.
class HostedAgentService {
  final AuthSession? Function() _getSession;
  final Future<AuthSession?> Function() _refreshSession;
  final String model;
  final Duration timeout;

  String? lastError;
  int? lastStatusCode;
  List<HostedAgentSource> lastSources = const [];
  List<HostedAgentEvent> lastEvents = const [];
  AiThinkingLevel thinkingLevel;

  HostedAgentService({
    required AuthSession? Function() getSession,
    required Future<AuthSession?> Function() refreshSession,
    required this.model,
    this.timeout = AiService.defaultTimeout,
    this.thinkingLevel = AiThinkingLevel.none,
  }) : _getSession = getSession,
       _refreshSession = refreshSession;

  bool get isConfigured =>
      BackendConfig.isConfigured && model.trim().isNotEmpty;

  List<String> get lastWebUrls => lastSources
      .map((source) => source.url.trim())
      .where((url) => url.isNotEmpty)
      .toList(growable: false);

  Future<AuthSession?> _freshSession() async {
    var session = _getSession();
    if (session == null) {
      lastError = 'Sign in to use hosted AI.';
      lastStatusCode = 401;
      return null;
    }
    if (!session.hasValidAccessToken) {
      session = await _refreshSession();
      if (session == null) {
        lastError = 'Your session has expired. Sign in again.';
        lastStatusCode = 401;
        return null;
      }
    }
    return session;
  }

  Stream<String> chatStream({
    required String systemPrompt,
    required String userMessage,
    List<Map<String, String>> history = const [],
    double temperature = 0.3,
    int maxTokens = 800,
    bool webSearch = false,
    void Function(HostedAgentEvent event)? onEvent,
  }) async* {
    lastError = null;
    lastStatusCode = null;
    lastSources = const [];
    lastEvents = const [];
    if (!isConfigured) {
      lastError = 'Hosted Agent is not configured';
      return;
    }

    var session = await _freshSession();
    if (session == null) return;
    var emitted = false;

    for (var attempt = 0; attempt < 2; attempt++) {
      final client = http.Client();
      try {
        final request =
            http.Request(
                'POST',
                BackendConfig.uri('/ai/agent/v1/chat/completions'),
              )
              ..headers.addAll({
                'Authorization': 'Bearer ${session!.accessToken}',
                'Content-Type': 'application/json',
                'Accept': 'text/event-stream',
              })
              ..body = jsonEncode({
                'model': model,
                'messages': [
                  {'role': 'system', 'content': systemPrompt},
                  ...history,
                  {'role': 'user', 'content': userMessage},
                ],
                'temperature': temperature,
                'max_completion_tokens': maxTokens,
                'stream': true,
                'memora_tools': {'web_search': webSearch},
                if (supportsDeepSeekThinking(model: model))
                  ...deepSeekThinkingOptions(thinkingLevel),
              });
        final response = await client.send(request).timeout(timeout);
        lastStatusCode = response.statusCode;
        if (response.statusCode != 200) {
          final body = await response.stream.bytesToString().timeout(timeout);
          lastError = 'HTTP ${response.statusCode}: ${_responseError(body)}';
          if (response.statusCode == 401 && !emitted && attempt == 0) {
            final refreshed = await _refreshSession();
            if (refreshed != null) {
              session = refreshed;
              lastError = null;
              continue;
            }
          }
          return;
        }

        await for (final delta in _decodeStream(response, onEvent: onEvent)) {
          if (delta.isEmpty) continue;
          emitted = true;
          yield delta;
        }
        if (!emitted && (lastError == null || lastError!.trim().isEmpty)) {
          lastError = 'AI response content was empty';
        }
        return;
      } on TimeoutException {
        lastError = 'Hosted Agent timed out after ${timeout.inSeconds} seconds';
        return;
      } catch (error) {
        lastError = 'Hosted Agent request failed: $error';
        return;
      } finally {
        client.close();
      }
    }
  }

  Stream<String> _decodeStream(
    http.StreamedResponse response, {
    void Function(HostedAgentEvent event)? onEvent,
  }) async* {
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    if (!contentType.contains('text/event-stream')) {
      final body = await response.stream.bytesToString().timeout(timeout);
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return;
      _captureResponseMetadata(decoded);
      final text = _completionText(decoded);
      if (text != null && text.isNotEmpty) yield text;
      return;
    }

    var eventName = 'message';
    final eventData = StringBuffer();
    var done = false;

    Future<List<String>> flush() async {
      if (eventData.isEmpty) return const [];
      final data = eventData.toString().trim();
      eventData.clear();
      final currentEvent = eventName;
      eventName = 'message';
      if (data == '[DONE]') {
        done = true;
        return const [];
      }
      if (currentEvent == 'agent') {
        _captureAgentEvent(data, onEvent: onEvent);
        return const [];
      }
      try {
        final decoded = jsonDecode(data);
        if (decoded is! Map<String, dynamic>) return const [];
        final text = _completionText(decoded);
        return text == null || text.isEmpty ? const [] : [text];
      } catch (_) {
        return const [];
      }
    }

    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .timeout(timeout)) {
      if (line.startsWith(':')) continue;
      if (line.startsWith('event:')) {
        eventName = line.substring(6).trim();
        continue;
      }
      if (line.startsWith('data:')) {
        eventData.write(line.substring(5).trimLeft());
        eventData.write('\n');
        continue;
      }
      if (line.trim().isEmpty) {
        for (final text in await flush()) {
          yield text;
        }
        if (done) break;
      }
    }
    if (!done && eventData.isNotEmpty) {
      for (final text in await flush()) {
        yield text;
      }
    }
    if (!done && lastError == null) {
      lastError = 'Hosted Agent stream ended before [DONE]';
    }
  }

  void _captureAgentEvent(
    String data, {
    void Function(HostedAgentEvent event)? onEvent,
  }) {
    try {
      final decoded = jsonDecode(data);
      if (decoded is! Map<String, dynamic>) return;
      final event = HostedAgentEvent(
        type: (decoded['type'] ?? '').toString(),
        data: decoded,
      );
      lastEvents = List.unmodifiable([...lastEvents, event]);
      if (event.type == 'sources') {
        final rawSources = decoded['sources'];
        if (rawSources is List) {
          lastSources = List.unmodifiable(
            rawSources
                .whereType<Map>()
                .map(
                  (source) => HostedAgentSource.fromJson(
                    Map<String, dynamic>.from(source),
                  ),
                )
                .where((source) => source.url.trim().isNotEmpty),
          );
        }
      } else if (event.type == 'run.failed') {
        lastError = (decoded['error'] ?? 'Hosted Agent failed.').toString();
      }
      onEvent?.call(event);
    } catch (_) {
      // Ignore malformed advisory events; the normal completion stream can
      // still produce a valid answer.
    }
  }

  void _captureResponseMetadata(Map<String, dynamic> decoded) {
    final metadata = decoded['memora_agent'];
    if (metadata is! Map) return;
    final rawSources = metadata['sources'];
    if (rawSources is! List) return;
    lastSources = List.unmodifiable(
      rawSources
          .whereType<Map>()
          .map(
            (source) =>
                HostedAgentSource.fromJson(Map<String, dynamic>.from(source)),
          )
          .where((source) => source.url.trim().isNotEmpty),
    );
  }

  static String? _completionText(Map<String, dynamic> decoded) {
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      return null;
    }
    final choice = Map<String, dynamic>.from(choices.first as Map);
    final delta = choice['delta'];
    if (delta is Map && delta['content'] is String) {
      return delta['content'] as String;
    }
    final message = choice['message'];
    if (message is Map && message['content'] is String) {
      return message['content'] as String;
    }
    return null;
  }

  static String _responseError(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map) {
          return (error['message'] ?? error['code'] ?? error).toString();
        }
        return (decoded['message'] ?? error ?? body).toString();
      }
    } catch (_) {
      // Use the response body below.
    }
    final trimmed = body.trim();
    return trimmed.isEmpty ? 'Request failed.' : trimmed;
  }
}
