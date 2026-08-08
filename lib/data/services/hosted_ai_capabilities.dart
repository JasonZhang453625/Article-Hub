import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../config/backend_config.dart';
import 'auth_service.dart';

/// Model list served by the Memora backend for hosted AI.
///
/// The server owns the canonical set of supported hosted models (see
/// `/ai/capabilities` on the backend). The client caches the response in
/// memory for a short window so the settings screen can populate its model
/// dropdowns without a network round trip on every rebuild.
class HostedAiCapabilities {
  final List<String> chatModels;
  final List<String> summaryModels;
  final List<String> visionModels;

  const HostedAiCapabilities({
    required this.chatModels,
    required this.summaryModels,
    required this.visionModels,
  });

  factory HostedAiCapabilities.fromJson(Map<String, dynamic> json) {
    List<String> models(dynamic section) {
      if (section is! Map) return const [];
      final raw = section['models'];
      if (raw is! List) return const [];
      return raw.whereType<String>().toList(growable: false);
    }

    return HostedAiCapabilities(
      chatModels: models(json['chat']),
      summaryModels: models(json['summary']),
      visionModels: _visionModels(json['image']),
    );
  }

  static List<String> _visionModels(dynamic imageSection) {
    if (imageSection is! Map) return const [];
    final providers = imageSection['providers'];
    if (providers is! List) return const [];
    final models = <String>[];
    for (final provider in providers) {
      if (provider is! Map) continue;
      if (provider['available'] != true) continue;
      final raw = provider['models'];
      if (raw is! List) continue;
      for (final model in raw.whereType<String>()) {
        if (!models.contains(model)) models.add(model);
      }
    }
    return models;
  }

  /// Falls back to the built-in list when the server response is empty or
  /// malformed, so the settings screen never shows an empty dropdown.
  bool get hasServerChatModels => chatModels.isNotEmpty;

  bool get hasServerSummaryModels => summaryModels.isNotEmpty;

  bool get hasServerVisionModels => visionModels.isNotEmpty;
}

/// Fetches hosted-AI capabilities from the backend.
class HostedAiCapabilitiesService {
  final AuthSession? Function() _getSession;
  final http.Client _client;
  final Duration timeout;

  HostedAiCapabilitiesService({
    required AuthSession? Function() getSession,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _getSession = getSession,
       _client = client ?? http.Client();

  Future<HostedAiCapabilities> fetch() async {
    final session = _getSession();
    if (session == null || !BackendConfig.isConfigured) {
      return const HostedAiCapabilities(
        chatModels: [],
        summaryModels: [],
        visionModels: [],
      );
    }
    final response = await _client
        .get(
          BackendConfig.uri('/ai/capabilities'),
          headers: {'Authorization': 'Bearer ${session.accessToken}'},
        )
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw HostedAiCapabilitiesException(
        'Request failed with status ${response.statusCode}.',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const HostedAiCapabilitiesException('Invalid server response.');
    }
    return HostedAiCapabilities.fromJson(decoded);
  }
}

/// Effective hosted text-model list for a purpose: server-driven when the
/// backend advertised models, built-in defaults otherwise.
List<String> hostedTextModelOptions({
  required List<String> serverModels,
  required List<String> builtInModels,
}) {
  return serverModels.isNotEmpty ? serverModels : builtInModels;
}

class HostedAiCapabilitiesException implements Exception {
  final String message;
  final int? statusCode;

  const HostedAiCapabilitiesException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

/// Keeps the last fetched capabilities in memory so repeated reads within a
/// short window (e.g. rebuilding the settings screen) do not hit the network
/// again. The list is deliberately not persisted: it is advisory UI data and
/// the backend is the source of truth.
class HostedAiCapabilitiesCache {
  static final HostedAiCapabilitiesCache instance =
      HostedAiCapabilitiesCache();

  HostedAiCapabilities? _value;
  DateTime? _fetchedAt;
  static const Duration _ttl = Duration(minutes: 5);

  HostedAiCapabilities? get value => _value;

  bool get isFresh {
    final fetchedAt = _fetchedAt;
    if (fetchedAt == null) return false;
    return DateTime.now().difference(fetchedAt) < _ttl;
  }

  void store(HostedAiCapabilities capabilities) {
    _value = capabilities;
    _fetchedAt = DateTime.now();
  }

  void clear() {
    _value = null;
    _fetchedAt = null;
  }
}
