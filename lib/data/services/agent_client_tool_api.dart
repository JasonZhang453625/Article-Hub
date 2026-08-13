import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../config/backend_config.dart';
import 'agent_client_tool_store.dart';
import 'auth_service.dart';
import 'hosted_agent_service.dart';

class AgentClientToolCall {
  static const Set<String> supportedTools = {'local_search', 'read_article'};
  static const Set<String> supportedStatuses = {'pending', 'claimed'};

  final String callId;
  final String tool;
  final Map<String, dynamic> arguments;
  final String status;
  final String leaseEpoch;
  final int remainingResultBytes;
  final DateTime? leaseExpiresAt;
  final DateTime createdAt;

  const AgentClientToolCall({
    required this.callId,
    required this.tool,
    required this.arguments,
    required this.status,
    required this.leaseEpoch,
    required this.remainingResultBytes,
    required this.leaseExpiresAt,
    required this.createdAt,
  });

  factory AgentClientToolCall.fromJson(Map<String, dynamic> json) {
    _requireExactKeys(json, const {
      'callId',
      'tool',
      'arguments',
      'status',
      'leaseEpoch',
      'remainingResultBytes',
      'leaseExpiresAt',
      'createdAt',
    });
    final callId = _strictId(json['callId']);
    final tool = json['tool'];
    final status = json['status'];
    final leaseEpoch = _strictLeaseEpoch(json['leaseEpoch']);
    final remainingResultBytes = json['remainingResultBytes'];
    final arguments = json['arguments'];
    final createdAt = _strictServerDate(json['createdAt']);
    final rawLeaseExpiry = json['leaseExpiresAt'];
    final leaseExpiresAt = _strictServerDate(rawLeaseExpiry);
    if (callId == null ||
        tool is! String ||
        !supportedTools.contains(tool) ||
        status is! String ||
        !supportedStatuses.contains(status) ||
        leaseEpoch == null ||
        remainingResultBytes is! int ||
        remainingResultBytes < 0 ||
        remainingResultBytes > 65536 ||
        arguments is! Map ||
        createdAt == null ||
        (rawLeaseExpiry != null && leaseExpiresAt == null) ||
        (status == 'claimed' &&
            (leaseEpoch == '0' || leaseExpiresAt == null)) ||
        (status == 'pending' && leaseExpiresAt != null)) {
      throw const FormatException('Invalid client-tool call response.');
    }
    final strictArguments = Map<String, dynamic>.from(arguments);
    _validateArguments(tool, strictArguments);
    return AgentClientToolCall(
      callId: callId,
      tool: tool,
      arguments: Map.unmodifiable(strictArguments),
      status: status,
      leaseEpoch: leaseEpoch,
      remainingResultBytes: remainingResultBytes,
      leaseExpiresAt: leaseExpiresAt,
      createdAt: createdAt,
    );
  }

  static void _validateArguments(String tool, Map<String, dynamic> arguments) {
    if (tool == 'local_search') {
      final query = arguments['query'];
      if (arguments.length != 1 ||
          query is! String ||
          query.trim().isEmpty ||
          query.runes.length > 500) {
        throw const FormatException('Invalid local-search arguments.');
      }
      return;
    }
    final articleRef = arguments['article_ref'];
    if (arguments.length != 1 ||
        articleRef is! String ||
        !AgentClientToolStore.articleRefPattern.hasMatch(articleRef)) {
      throw const FormatException('Invalid read-article arguments.');
    }
  }
}

class AgentClientToolPendingResponse {
  final String runId;
  final String status;
  final List<AgentClientToolCall> calls;

  const AgentClientToolPendingResponse({
    required this.runId,
    required this.status,
    required this.calls,
  });

  factory AgentClientToolPendingResponse.fromJson(Map<String, dynamic> json) {
    _requireExactKeys(json, const {'runId', 'status', 'calls'});
    final runId = _strictId(json['runId']);
    final status = json['status'];
    final rawCalls = json['calls'];
    if (runId == null ||
        status is! String ||
        !HostedAgentRunLookup.supportedStatuses.contains(status) ||
        rawCalls is! List) {
      throw const FormatException('Invalid client-tool pending response.');
    }
    final calls = rawCalls
        .map(
          (item) => AgentClientToolCall.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList(growable: false);
    if (calls.map((item) => item.callId).toSet().length != calls.length) {
      throw const FormatException('Duplicate client-tool calls.');
    }
    if (calls.isNotEmpty && status != 'waiting_client') {
      throw const FormatException('Client-tool call is not waiting.');
    }
    return AgentClientToolPendingResponse(
      runId: runId,
      status: status,
      calls: List.unmodifiable(calls),
    );
  }
}

class AgentClientToolClaim {
  final AgentClientToolCall call;
  final String claimToken;

  const AgentClientToolClaim({required this.call, required this.claimToken});

  factory AgentClientToolClaim.fromJson(Map<String, dynamic> json) {
    _requireExactKeys(json, const {
      'callId',
      'tool',
      'arguments',
      'status',
      'claimToken',
      'leaseEpoch',
      'remainingResultBytes',
      'leaseExpiresAt',
      'createdAt',
    });
    final claimToken = _strictUuid(json['claimToken']);
    if (claimToken == null) {
      throw const FormatException('Invalid client-tool claim response.');
    }
    final rawCall = Map<String, dynamic>.from(json)..remove('claimToken');
    final call = AgentClientToolCall.fromJson(rawCall);
    if (call.status != 'claimed') {
      throw const FormatException('Client-tool claim was not acquired.');
    }
    return AgentClientToolClaim(call: call, claimToken: claimToken);
  }
}

class AgentClientToolCallStatus {
  static const Set<String> supportedStatuses = {
    'pending',
    'claimed',
    'completed',
    'cancelled',
    'expired',
  };

  final String callId;
  final String tool;
  final String status;
  final String leaseEpoch;
  final DateTime? leaseExpiresAt;
  final DateTime? completedAt;
  final int remainingResultBytes;
  final DateTime createdAt;

  const AgentClientToolCallStatus({
    required this.callId,
    required this.tool,
    required this.status,
    required this.leaseEpoch,
    required this.leaseExpiresAt,
    required this.completedAt,
    required this.remainingResultBytes,
    required this.createdAt,
  });

  factory AgentClientToolCallStatus.fromJson(Map<String, dynamic> json) {
    _requireExactKeys(json, const {
      'callId',
      'tool',
      'status',
      'leaseEpoch',
      'leaseExpiresAt',
      'completedAt',
      'remainingResultBytes',
      'createdAt',
    });
    final callId = _strictId(json['callId']);
    final tool = json['tool'];
    final status = json['status'];
    final leaseEpoch = _strictLeaseEpoch(json['leaseEpoch']);
    final rawLeaseExpiresAt = json['leaseExpiresAt'];
    final leaseExpiresAt = _strictServerDate(rawLeaseExpiresAt);
    final rawCompletedAt = json['completedAt'];
    final completedAt = _strictServerDate(rawCompletedAt);
    final remainingResultBytes = json['remainingResultBytes'];
    final createdAt = _strictServerDate(json['createdAt']);
    if (callId == null ||
        tool is! String ||
        !AgentClientToolCall.supportedTools.contains(tool) ||
        status is! String ||
        !supportedStatuses.contains(status) ||
        leaseEpoch == null ||
        remainingResultBytes is! int ||
        remainingResultBytes < 0 ||
        remainingResultBytes > 65536 ||
        createdAt == null ||
        (rawLeaseExpiresAt != null && leaseExpiresAt == null) ||
        (rawCompletedAt != null && completedAt == null) ||
        (status == 'claimed' &&
            (leaseEpoch == '0' || leaseExpiresAt == null)) ||
        (status != 'claimed' && leaseExpiresAt != null) ||
        (status == 'completed' && completedAt == null)) {
      throw const FormatException('Invalid client-tool status response.');
    }
    return AgentClientToolCallStatus(
      callId: callId,
      tool: tool,
      status: status,
      leaseEpoch: leaseEpoch,
      leaseExpiresAt: leaseExpiresAt,
      completedAt: completedAt,
      remainingResultBytes: remainingResultBytes,
      createdAt: createdAt,
    );
  }
}

class AgentClientToolApiException implements Exception {
  final String message;
  final int? statusCode;
  final bool retryable;
  final bool conflict;
  final bool notFound;
  final String? code;

  const AgentClientToolApiException({
    required this.message,
    this.statusCode,
    required this.retryable,
    this.conflict = false,
    this.notFound = false,
    this.code,
  });

  @override
  String toString() => message;
}

typedef AgentToolGenerationGuard = void Function();

/// Authenticated REST source-of-truth for durable device-tool calls.
class AgentClientToolApi {
  final AuthSession? Function() _getSession;
  final Future<AuthSession?> Function() _refreshSession;
  final Duration timeout;
  final Set<http.Client> _activeClients = {};
  Future<AuthSession?>? _refreshInFlight;
  bool _closed = false;

  AgentClientToolApi({
    required AuthSession? Function() getSession,
    required Future<AuthSession?> Function() refreshSession,
    this.timeout = const Duration(seconds: 15),
  }) : _getSession = getSession,
       _refreshSession = refreshSession;

  Future<AgentClientToolPendingResponse> pending({
    required AgentToolRunBinding binding,
    AgentToolGenerationGuard? guard,
  }) async {
    final decoded = await _requestJson(
      method: 'GET',
      path:
          '/ai/runs/${Uri.encodeComponent(binding.runId)}/client-tools/pending',
      binding: binding,
      guard: guard,
    );
    final response = AgentClientToolPendingResponse.fromJson(decoded);
    if (response.runId != binding.runId) {
      throw const FormatException('Client-tool run identity changed.');
    }
    return response;
  }

  Future<AgentClientToolCallStatus> callStatus({
    required AgentToolRunBinding binding,
    required AgentClientToolReceipt receipt,
    AgentToolGenerationGuard? guard,
  }) async {
    final decoded = await _requestJson(
      method: 'GET',
      path:
          '/ai/runs/${Uri.encodeComponent(binding.runId)}/client-tools/${Uri.encodeComponent(receipt.callId)}',
      binding: binding,
      guard: guard,
    );
    final response = AgentClientToolCallStatus.fromJson(decoded);
    if (response.callId != receipt.callId || response.tool != receipt.tool) {
      throw const FormatException('Client-tool status identity changed.');
    }
    return response;
  }

  Future<AgentClientToolClaim> claim({
    required AgentToolRunBinding binding,
    required AgentClientToolCall call,
    required String idempotencyKey,
    AgentToolGenerationGuard? guard,
  }) async {
    final decoded = await _requestJson(
      method: 'POST',
      path:
          '/ai/runs/${Uri.encodeComponent(binding.runId)}/client-tools/${Uri.encodeComponent(call.callId)}/claim',
      binding: binding,
      idempotencyKey: idempotencyKey,
      guard: guard,
    );
    final claim = AgentClientToolClaim.fromJson(decoded);
    if (claim.call.callId != call.callId ||
        claim.call.tool != call.tool ||
        stablePayloadHash(canonicalJsonEncode(claim.call.arguments)) !=
            stablePayloadHash(canonicalJsonEncode(call.arguments))) {
      throw const FormatException('Client-tool claim identity changed.');
    }
    return claim;
  }

  Future<bool> submitResult({
    required AgentToolRunBinding binding,
    required AgentClientToolReceipt receipt,
    AgentToolGenerationGuard? guard,
  }) async {
    final claimToken = receipt.claimToken;
    final leaseEpoch = receipt.leaseEpoch;
    final result = receipt.result;
    if (claimToken == null ||
        _strictUuid(claimToken) == null ||
        leaseEpoch == null ||
        leaseEpoch == '0' ||
        _strictLeaseEpoch(leaseEpoch) == null ||
        result == null) {
      throw const FormatException('Client-tool receipt is incomplete.');
    }
    validateAgentClientToolResult(
      tool: receipt.tool,
      argumentsJson: receipt.argumentsJson,
      result: result,
    );
    final decoded = await _requestJson(
      method: 'PUT',
      path:
          '/ai/runs/${Uri.encodeComponent(binding.runId)}/client-tools/${Uri.encodeComponent(receipt.callId)}/result',
      binding: binding,
      idempotencyKey: receipt.resultReceiptKey,
      guard: guard,
      body: {
        'claim_token': claimToken,
        'lease_epoch': leaseEpoch,
        'result': result,
      },
    );
    _requireExactKeys(decoded, const {'accepted', 'idempotent', 'run'});
    final run = decoded['run'];
    if (decoded['accepted'] != true ||
        decoded['idempotent'] is! bool ||
        run is! Map ||
        run['id'] != binding.runId) {
      throw const FormatException('Invalid client-tool result response.');
    }
    return decoded['idempotent'] as bool;
  }

  void close() {
    _closed = true;
    for (final client in _activeClients.toList(growable: false)) {
      client.close();
    }
    _activeClients.clear();
  }

  Future<Map<String, dynamic>> _requestJson({
    required String method,
    required String path,
    required AgentToolRunBinding binding,
    required AgentToolGenerationGuard? guard,
    String? idempotencyKey,
    Map<String, dynamic>? body,
  }) async {
    guard?.call();
    if (idempotencyKey != null &&
        (idempotencyKey.trim().isEmpty || idempotencyKey.length > 128)) {
      throw const FormatException('Invalid client-tool idempotency key.');
    }
    if (_closed) {
      throw const AgentClientToolApiException(
        message: 'Client-tool transport is closed.',
        retryable: true,
      );
    }
    var session = _getSession();
    if (session == null || !session.hasValidAccessToken) {
      session = await _refreshOnce();
      guard?.call();
    }
    if (session == null ||
        session.user.id != binding.ownerUserId ||
        session.device.id != binding.ownerDeviceId) {
      throw const AgentClientToolApiException(
        message: 'Client-tool owner changed.',
        statusCode: 401,
        retryable: false,
      );
    }
    var activeSession = session;
    var refreshedAfterUnauthorized = false;
    while (true) {
      guard?.call();
      if (activeSession.user.id != binding.ownerUserId ||
          activeSession.device.id != binding.ownerDeviceId) {
        throw const AgentClientToolApiException(
          message: 'Client-tool owner changed.',
          statusCode: 401,
          retryable: false,
        );
      }
      final client = http.Client();
      _activeClients.add(client);
      try {
        final headers = <String, String>{
          'Authorization': 'Bearer ${activeSession.accessToken}',
          'Accept': 'application/json',
          if (body != null) 'Content-Type': 'application/json',
        };
        if (idempotencyKey case final key?) {
          headers['Idempotency-Key'] = key;
        }
        final request = http.Request(method, BackendConfig.uri(path))
          ..headers.addAll(headers);
        if (body != null) request.body = jsonEncode(body);
        guard?.call();
        final response = await client.send(request).timeout(timeout);
        guard?.call();
        final responseBody = await response.stream.bytesToString().timeout(
          timeout,
        );
        guard?.call();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          if (response.statusCode == 401 && !refreshedAfterUnauthorized) {
            refreshedAfterUnauthorized = true;
            final refreshed = await _refreshOnce();
            guard?.call();
            if (refreshed != null &&
                refreshed.user.id == binding.ownerUserId &&
                refreshed.device.id == binding.ownerDeviceId) {
              activeSession = refreshed;
              continue;
            }
            throw const AgentClientToolApiException(
              message: 'Client-tool owner changed during refresh.',
              statusCode: 401,
              retryable: false,
            );
          }
          String? code;
          bool? serverRetryable;
          try {
            final errorJson = jsonDecode(responseBody);
            if (errorJson is Map) {
              final nested = errorJson['error'];
              if (nested is Map) {
                if (nested['code'] is String) {
                  code = nested['code'] as String;
                }
                if (nested['retryable'] is bool) {
                  serverRetryable = nested['retryable'] as bool;
                }
              } else if (errorJson['code'] is String) {
                // Keep the protocol-v3 parser compatible with the brief
                // top-level error envelope used by pre-release servers.
                code = errorJson['code'] as String;
                if (errorJson['retryable'] is bool) {
                  serverRetryable = errorJson['retryable'] as bool;
                }
              }
            }
          } catch (_) {
            // HTTP classification remains authoritative when the error body is
            // not JSON; never expose or log the raw response.
          }
          throw AgentClientToolApiException(
            message: 'Client-tool request failed.',
            statusCode: response.statusCode,
            retryable:
                serverRetryable ??
                (response.statusCode == 408 ||
                    response.statusCode == 425 ||
                    response.statusCode == 429 ||
                    response.statusCode >= 500 ||
                    code == 'client_tool_lease_expired' ||
                    code == 'client_tool_already_claimed'),
            conflict: response.statusCode == 409,
            notFound: response.statusCode == 404,
            code: code,
          );
        }
        final value = jsonDecode(responseBody);
        if (value is! Map<String, dynamic>) {
          throw const FormatException('Invalid client-tool JSON response.');
        }
        return value;
      } on TimeoutException {
        throw const AgentClientToolApiException(
          message: 'Client-tool request timed out.',
          retryable: true,
        );
      } on http.ClientException {
        throw const AgentClientToolApiException(
          message: 'Client-tool transport failed.',
          retryable: true,
        );
      } finally {
        _activeClients.remove(client);
        client.close();
      }
    }
  }

  Future<AuthSession?> _refreshOnce() {
    final current = _refreshInFlight;
    if (current != null) return current;
    late final Future<AuthSession?> refresh;
    refresh = Future<AuthSession?>.sync(_refreshSession).whenComplete(() {
      if (identical(_refreshInFlight, refresh)) _refreshInFlight = null;
    });
    _refreshInFlight = refresh;
    return refresh;
  }
}

String? _strictId(dynamic value) {
  if (value is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$').hasMatch(value)) {
    return null;
  }
  return value;
}

String? _strictLeaseEpoch(dynamic value) {
  if (value is! String || !RegExp(r'^(?:0|[1-9]\d{0,18})$').hasMatch(value)) {
    return null;
  }
  return value;
}

String? _strictUuid(dynamic value) {
  if (value is! String ||
      !RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        caseSensitive: false,
      ).hasMatch(value)) {
    return null;
  }
  return value;
}

DateTime? _strictServerDate(dynamic value) {
  if (value is! String || value.isEmpty) return null;
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !parsed.isUtc) return null;
  return parsed.toUtc();
}

void _requireExactKeys(Map<String, dynamic> value, Set<String> keys) {
  if (value.length != keys.length || !value.keys.toSet().containsAll(keys)) {
    throw const FormatException('Client-tool response contains extra fields.');
  }
}

void validateAgentClientToolResult({
  required String tool,
  required String argumentsJson,
  required Map<String, dynamic> result,
}) {
  final kindPattern = RegExp(r'^[A-Za-z0-9_-]{1,32}$');
  bool boundedString(dynamic value, int min, int max) =>
      value is String && value.runes.length >= min && value.runes.length <= max;

  if (tool == 'local_search') {
    _requireExactKeys(result, const {
      'schemaVersion',
      'status',
      'results',
      'truncated',
    });
    final status = result['status'];
    final results = result['results'];
    if (result['schemaVersion'] != 1 ||
        result['truncated'] is! bool ||
        results is! List ||
        results.length > 5 ||
        (results.isEmpty ? status != 'empty' : status != 'ok')) {
      throw const FormatException('Invalid local-search result.');
    }
    for (final rawItem in results) {
      if (rawItem is! Map) {
        throw const FormatException('Invalid local-search result.');
      }
      final item = Map<String, dynamic>.from(rawItem);
      _requireExactKeys(item, const {'article_ref', 'title', 'snippets'});
      final snippets = item['snippets'];
      if (item['article_ref'] is! String ||
          !AgentClientToolStore.articleRefPattern.hasMatch(
            item['article_ref'] as String,
          ) ||
          !boundedString(item['title'], 1, 500) ||
          snippets is! List ||
          snippets.isEmpty ||
          snippets.length > 2) {
        throw const FormatException('Invalid local-search result.');
      }
      for (final rawSnippet in snippets) {
        if (rawSnippet is! Map) {
          throw const FormatException('Invalid local-search result.');
        }
        final snippet = Map<String, dynamic>.from(rawSnippet);
        _requireExactKeys(snippet, const {'kind', 'text'});
        if (snippet['kind'] is! String ||
            !kindPattern.hasMatch(snippet['kind'] as String) ||
            !boundedString(snippet['text'], 1, 4000)) {
          throw const FormatException('Invalid local-search result.');
        }
      }
    }
    if (utf8.encode(canonicalJsonEncode(result)).length > 16384) {
      throw const FormatException('Local-search result exceeds hard limit.');
    }
    return;
  }

  if (tool != 'read_article') {
    throw const FormatException('Unsupported client-tool result.');
  }
  _requireExactKeys(result, const {
    'schemaVersion',
    'status',
    'article_ref',
    'title',
    'sections',
    'truncated',
  });
  final arguments = jsonDecode(argumentsJson);
  final expectedRef = arguments is Map ? arguments['article_ref'] : null;
  final status = result['status'];
  final sections = result['sections'];
  final title = result['title'];
  if (result['schemaVersion'] != 1 ||
      result['truncated'] is! bool ||
      expectedRef is! String ||
      result['article_ref'] != expectedRef ||
      !AgentClientToolStore.articleRefPattern.hasMatch(expectedRef) ||
      sections is! List ||
      sections.length > 12 ||
      title is! String ||
      title.runes.length > 500 ||
      (sections.isEmpty ? status != 'not_found' : status != 'ok') ||
      (status == 'ok' && title.isEmpty)) {
    throw const FormatException('Invalid read-article result.');
  }
  for (final rawSection in sections) {
    if (rawSection is! Map) {
      throw const FormatException('Invalid read-article result.');
    }
    final section = Map<String, dynamic>.from(rawSection);
    final allowedKeys = section.containsKey('topic')
        ? const {'kind', 'topic', 'text'}
        : const {'kind', 'text'};
    _requireExactKeys(section, allowedKeys);
    if (section['kind'] is! String ||
        !kindPattern.hasMatch(section['kind'] as String) ||
        !boundedString(section['text'], 1, 8000) ||
        section.containsKey('topic') &&
            !boundedString(section['topic'], 1, 500)) {
      throw const FormatException('Invalid read-article result.');
    }
  }
  if (utf8.encode(canonicalJsonEncode(result)).length > 24576) {
    throw const FormatException('Read-article result exceeds hard limit.');
  }
}
