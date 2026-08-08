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

/// Client for a durable server-side Agent run.
///
/// A run is created with a short JSON request and then observed through a
/// separate SSE endpoint. The SSE connection is only a view of the run: if
/// the app process dies, the server keeps working and a later call to
/// [resumeStream] reads the persisted run events/result.
class HostedAgentService {
  final AuthSession? Function() _getSession;
  final Future<AuthSession?> Function() _refreshSession;
  final String model;
  final Duration timeout;

  String? lastError;
  int? lastStatusCode;
  String? lastRunId;
  int lastEventSeq = 0;
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

  /// Creates a durable hosted run and yields its answer events.
  Stream<String> chatStream({
    required String systemPrompt,
    required String userMessage,
    List<Map<String, String>> history = const [],
    double temperature = 0.3,
    int maxTokens = 800,
    bool webSearch = false,
    void Function(HostedAgentEvent event)? onEvent,
    FutureOr<void> Function(String runId)? onRunCreated,
    String? idempotencyKey,
  }) async* {
    _resetRunState();
    if (!isConfigured) {
      lastError = 'Hosted Agent is not configured';
      return;
    }

    var session = await _freshSession();
    if (session == null) return;

    final requestBody = <String, dynamic>{
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
    };

    Map<String, dynamic>? created;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        created = await _createRun(session!, requestBody, idempotencyKey);
        break;
      } on _RunHttpException catch (error) {
        lastStatusCode = error.statusCode;
        lastError = 'HTTP ${error.statusCode}: ${_responseError(error.body)}';
        if (error.statusCode == 401 && attempt == 0) {
          final refreshed = await _refreshSession();
          if (refreshed != null) {
            session = refreshed;
            lastError = null;
            continue;
          }
        }
        return;
      } on TimeoutException {
        lastError = 'Hosted Agent timed out after ${timeout.inSeconds} seconds';
        return;
      } catch (error) {
        lastError = 'Hosted Agent request failed: $error';
        return;
      }
    }

    final runId = (created?['id'] ?? created?['runId'] ?? '').toString();
    if (runId.isEmpty) {
      lastError = 'Hosted Agent returned no run id.';
      return;
    }
    lastRunId = runId;
    await onRunCreated?.call(runId);

    try {
      await for (final delta in _watchRun(
        runId,
        session: session!,
        afterEventSeq: lastEventSeq,
        onEvent: onEvent,
      )) {
        if (delta.isNotEmpty) yield delta;
      }
    } on TimeoutException {
      lastError = 'Hosted Agent timed out after ${timeout.inSeconds} seconds';
    } on _RunHttpException catch (error) {
      lastStatusCode = error.statusCode;
      lastError = 'HTTP ${error.statusCode}: ${_responseError(error.body)}';
    } catch (error) {
      lastError = 'Hosted Agent request failed: $error';
    }
  }

  /// Reconnects to an existing durable run after the app has restarted.
  ///
  /// The snapshot is checked first so a completed answer is restored without
  /// waiting for the event stream. Running jobs then resume from the latest
  /// persisted event sequence.
  Stream<String> resumeStream(
    String runId, {
    void Function(HostedAgentEvent event)? onEvent,
  }) async* {
    _resetRunState();
    lastRunId = runId;
    if (!isConfigured) {
      lastError = 'Hosted Agent is not configured';
      return;
    }

    var session = await _freshSession();
    if (session == null) return;

    Map<String, dynamic> snapshot;
    try {
      snapshot = await _fetchRun(session, runId);
    } on _RunHttpException catch (error) {
      lastStatusCode = error.statusCode;
      if (error.statusCode == 401) {
        final refreshed = await _refreshSession();
        if (refreshed == null) {
          lastError = 'Your session has expired. Sign in again.';
          return;
        }
        session = refreshed;
        try {
          snapshot = await _fetchRun(session, runId);
        } on _RunHttpException catch (retryError) {
          lastStatusCode = retryError.statusCode;
          lastError =
              'HTTP ${retryError.statusCode}: ${_responseError(retryError.body)}';
          return;
        }
      } else {
        lastError = 'HTTP ${error.statusCode}: ${_responseError(error.body)}';
        return;
      }
    } on TimeoutException {
      lastError = 'Hosted Agent timed out after ${timeout.inSeconds} seconds';
      return;
    } catch (error) {
      lastError = 'Hosted Agent request failed: $error';
      return;
    }

    final snapshotSeq = (snapshot['lastEventSeq'] as num?)?.toInt() ?? 0;
    if (snapshotSeq > lastEventSeq) lastEventSeq = snapshotSeq;
    _captureRunSnapshot(snapshot, onEvent: onEvent);

    final status = (snapshot['status'] ?? '').toString();
    final answer = (snapshot['answer'] ?? '').toString();
    if (status == 'completed') {
      if (answer.trim().isNotEmpty) yield answer;
      return;
    }
    if (status == 'failed' || status == 'cancelled') return;

    try {
      await for (final delta in _watchRun(
        runId,
        session: session,
        afterEventSeq: lastEventSeq,
        onEvent: onEvent,
      )) {
        if (delta.isNotEmpty) yield delta;
      }
    } on TimeoutException {
      lastError = 'Hosted Agent timed out after ${timeout.inSeconds} seconds';
    } on _RunHttpException catch (error) {
      lastStatusCode = error.statusCode;
      lastError = 'HTTP ${error.statusCode}: ${_responseError(error.body)}';
    } catch (error) {
      lastError = 'Hosted Agent request failed: $error';
    }
  }

  Future<Map<String, dynamic>> _createRun(
    AuthSession session,
    Map<String, dynamic> body,
    String? idempotencyKey,
  ) async {
    final client = http.Client();
    try {
      final request = http.Request('POST', BackendConfig.uri('/ai/runs'))
        ..headers.addAll({
          'Authorization': 'Bearer ${session.accessToken}',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          if (idempotencyKey != null && idempotencyKey.trim().isNotEmpty)
            'Idempotency-Key': idempotencyKey.trim(),
        })
        ..body = jsonEncode(body);
      final response = await client.send(request).timeout(timeout);
      lastStatusCode = response.statusCode;
      final text = await response.stream.bytesToString().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _RunHttpException(response.statusCode, text);
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Hosted Agent returned invalid run JSON.');
      }
      return decoded;
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _fetchRun(
    AuthSession session,
    String runId,
  ) async {
    final client = http.Client();
    try {
      final request = http.Request(
        'GET',
        BackendConfig.uri('/ai/runs/$runId'),
      )
        ..headers.addAll({
          'Authorization': 'Bearer ${session.accessToken}',
          'Accept': 'application/json',
        });
      final response = await client.send(request).timeout(timeout);
      final text = await response.stream.bytesToString().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _RunHttpException(response.statusCode, text);
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Hosted Agent returned invalid run JSON.');
      }
      return decoded;
    } finally {
      client.close();
    }
  }

  Stream<String> _watchRun(
    String runId, {
    required AuthSession session,
    required int afterEventSeq,
    void Function(HostedAgentEvent event)? onEvent,
  }) async* {
    final client = http.Client();
    try {
      final uri = BackendConfig.uri('/ai/runs/$runId/events').replace(
        queryParameters: {'after': '$afterEventSeq'},
      );
      final request = http.Request('GET', uri)
        ..headers.addAll({
          'Authorization': 'Bearer ${session.accessToken}',
          'Accept': 'text/event-stream',
          'Last-Event-ID': '$afterEventSeq',
        });
      final response = await client.send(request).timeout(timeout);
      lastStatusCode = response.statusCode;
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString().timeout(timeout);
        throw _RunHttpException(response.statusCode, body);
      }
      yield* _decodeRunEvents(response, onEvent: onEvent);
    } finally {
      client.close();
    }
  }

  Stream<String> _decodeRunEvents(
    http.StreamedResponse response, {
    void Function(HostedAgentEvent event)? onEvent,
  }) async* {
    var eventName = 'message';
    var eventId = 0;
    final eventData = StringBuffer();
    var terminal = false;

    Future<List<String>> flush() async {
      if (eventData.isEmpty) return const [];
      final data = eventData.toString().trim();
      eventData.clear();
      final currentEvent = eventName;
      final currentId = eventId;
      eventName = 'message';
      eventId = 0;
      if (currentId > lastEventSeq) lastEventSeq = currentId;
      if (data == '[DONE]') {
        terminal = true;
        return const [];
      }
      try {
        final decoded = jsonDecode(data);
        if (decoded is! Map<String, dynamic>) return const [];
        final event = _captureRunEvent(
          decoded,
          eventName: currentEvent,
          onEvent: onEvent,
        );
        if (event != null && event.isNotEmpty) return [event];
        return const [];
      } catch (_) {
        return const [];
      }
    }

    await for (final line in response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(timeout)) {
      if (line.startsWith(':')) continue;
      if (line.startsWith('id:')) {
        eventId = int.tryParse(line.substring(3).trim()) ?? 0;
        continue;
      }
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
        if (terminal) break;
      }
    }
    if (eventData.isNotEmpty) {
      for (final text in await flush()) {
        yield text;
      }
    }
    if (!terminal && !_runIsTerminal) {
      throw StateError('Hosted Agent event stream ended before completion.');
    }
  }

  bool _runIsTerminal = false;

  String? _captureRunEvent(
    Map<String, dynamic> decoded, {
    required String eventName,
    void Function(HostedAgentEvent event)? onEvent,
  }) {
    if (decoded.containsKey('choices')) {
      return _completionText(decoded);
    }

    final event = HostedAgentEvent(
      type: (decoded['type'] ?? eventName).toString(),
      data: decoded,
    );
    lastEvents = List.unmodifiable([...lastEvents, event]);
    _captureSources(decoded['sources']);
    if (event.type == 'run.result') {
      _captureSources(decoded['sources']);
      _runIsTerminal = true;
      return (decoded['answer'] ?? '').toString();
    }
    if (event.type == 'run.failed') {
      lastError = (decoded['error'] ?? 'Hosted Agent failed.').toString();
      _runIsTerminal = true;
    } else if (event.type == 'run.completed') {
      // The durable service emits run.result immediately after this event.
    }
    onEvent?.call(event);
    return null;
  }

  void _captureRunSnapshot(
    Map<String, dynamic> decoded, {
    void Function(HostedAgentEvent event)? onEvent,
  }) {
    _captureSources(decoded['sources']);
    final status = (decoded['status'] ?? '').toString();
    if (status == 'failed' || status == 'cancelled') {
      lastError = (decoded['errorMessage'] ?? 'Hosted Agent failed.').toString();
      _runIsTerminal = true;
    } else if (status == 'completed') {
      _runIsTerminal = true;
    }
    final rawError = decoded['error'];
    if (rawError is Map) {
      lastError = (rawError['message'] ?? 'Hosted Agent failed.').toString();
    }
    final event = HostedAgentEvent(
      type: 'run.snapshot',
      data: decoded,
    );
    onEvent?.call(event);
  }

  void _captureSources(dynamic rawSources) {
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

  void _resetRunState() {
    lastError = null;
    lastStatusCode = null;
    lastRunId = null;
    lastEventSeq = 0;
    lastSources = const [];
    lastEvents = const [];
    _runIsTerminal = false;
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

class _RunHttpException implements Exception {
  final int statusCode;
  final String body;

  const _RunHttpException(this.statusCode, this.body);
}
