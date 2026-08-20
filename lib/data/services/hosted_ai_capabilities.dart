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
  final bool agentAvailable;
  final int agentProtocolVersion;
  final HostedAgentImageInputCapabilities? agentImageInput;
  final HostedAgentClientToolsCapabilities? agentClientTools;
  final HostedTaskCapabilities? agentTasks;

  const HostedAiCapabilities({
    required this.chatModels,
    required this.summaryModels,
    required this.visionModels,
    this.agentAvailable = false,
    this.agentProtocolVersion = 1,
    this.agentImageInput,
    this.agentClientTools,
    this.agentTasks,
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
      agentAvailable: _agentAvailable(json['agent']),
      agentProtocolVersion: _agentProtocolVersion(json['agent']),
      agentImageInput: HostedAgentImageInputCapabilities.fromAgentSection(
        json['agent'],
      ),
      agentClientTools: HostedAgentClientToolsCapabilities.fromAgentSection(
        json['agent'],
      ),
      agentTasks: HostedTaskCapabilities.fromAgentSection(json['agent']),
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

  static int _agentProtocolVersion(dynamic agentSection) {
    if (agentSection is! Map) return 1;
    final value = agentSection['protocolVersion'];
    return value is int && value > 0 ? value : 1;
  }

  static bool _agentAvailable(dynamic agentSection) =>
      agentSection is Map && agentSection['available'] == true;

  /// Falls back to the built-in list when the server response is empty or
  /// malformed, so the settings screen never shows an empty dropdown.
  bool get hasServerChatModels => chatModels.isNotEmpty;

  bool get hasServerSummaryModels => summaryModels.isNotEmpty;

  bool get hasServerVisionModels => visionModels.isNotEmpty;
}

/// Fail-closed protocol-v4 contract for server-owned durable Pi task profiles.
class HostedTaskCapabilities {
  static const int supportedVersion = 1;
  static const String supportedCreateEndpoint = '/ai/tasks/runs';

  final int version;
  final String createEndpoint;
  final int maxBodyBytes;
  final List<HostedTaskProfileCapabilities> profiles;

  const HostedTaskCapabilities({
    required this.version,
    required this.createEndpoint,
    required this.maxBodyBytes,
    required this.profiles,
  });

  factory HostedTaskCapabilities.fromJson(Map<dynamic, dynamic> json) {
    final rawProfiles = json['profiles'];
    return HostedTaskCapabilities(
      version: json['version'] is int ? json['version'] as int : 0,
      createEndpoint: json['createEndpoint'] is String
          ? (json['createEndpoint'] as String).trim()
          : '',
      maxBodyBytes: json['maxBodyBytes'] is int
          ? json['maxBodyBytes'] as int
          : 0,
      profiles: rawProfiles is List
          ? rawProfiles
                .whereType<Map>()
                .map(HostedTaskProfileCapabilities.fromJson)
                .where((profile) => profile.isValid)
                .toList(growable: false)
          : const [],
    );
  }

  static HostedTaskCapabilities? fromAgentSection(dynamic agentSection) {
    if (agentSection is! Map || agentSection['protocolVersion'] is! int) {
      return null;
    }
    if ((agentSection['protocolVersion'] as int) < 4) return null;
    final raw = agentSection['tasks'];
    if (raw is! Map) return null;
    final parsed = HostedTaskCapabilities.fromJson(raw);
    if (parsed.version != supportedVersion ||
        parsed.createEndpoint != supportedCreateEndpoint ||
        parsed.maxBodyBytes <= 0 ||
        parsed.profiles.isEmpty) {
      return null;
    }
    return parsed;
  }

  HostedTaskProfileCapabilities? profileForModel(
    String profileId,
    String model,
  ) {
    final normalizedModel = model.trim().toLowerCase();
    if (normalizedModel.isEmpty) return null;
    for (final profile in profiles) {
      if (profile.id == profileId &&
          profile.version == 1 &&
          profile.resultSchemaVersion == 1 &&
          profile.durable &&
          !profile.requiresImages &&
          profile.available &&
          profile.models.any(
            (candidate) => candidate.trim().toLowerCase() == normalizedModel,
          )) {
        return profile;
      }
    }
    return null;
  }
}

class HostedTaskProfileCapabilities {
  final String id;
  final int version;
  final int resultSchemaVersion;
  final bool durable;
  final bool requiresImages;
  final List<String> models;
  final bool available;

  const HostedTaskProfileCapabilities({
    required this.id,
    required this.version,
    required this.resultSchemaVersion,
    required this.durable,
    required this.requiresImages,
    required this.models,
    required this.available,
  });

  factory HostedTaskProfileCapabilities.fromJson(Map<dynamic, dynamic> json) {
    final rawModels = json['models'];
    return HostedTaskProfileCapabilities(
      id: json['id'] is String ? (json['id'] as String).trim() : '',
      version: json['version'] is int ? json['version'] as int : 0,
      resultSchemaVersion: json['resultSchemaVersion'] is int
          ? json['resultSchemaVersion'] as int
          : 0,
      durable: json['durable'] == true,
      requiresImages: json['requiresImages'] == true,
      models: rawModels is List
          ? rawModels
                .whereType<String>()
                .map((model) => model.trim())
                .where((model) => model.isNotEmpty)
                .toList(growable: false)
          : const [],
      available: json['available'] == true,
    );
  }

  bool get isValid =>
      id.isNotEmpty &&
      version > 0 &&
      resultSchemaVersion > 0 &&
      models.isNotEmpty;
}

class HostedAgentClientToolResultLimits {
  final int maxResultBytes;
  final int maxResultTokens;

  const HostedAgentClientToolResultLimits({
    required this.maxResultBytes,
    required this.maxResultTokens,
  });
}

class HostedAgentLocalSearchLimits extends HostedAgentClientToolResultLimits {
  final int maxResults;
  final int maxSnippetsPerResult;

  const HostedAgentLocalSearchLimits({
    required this.maxResults,
    required this.maxSnippetsPerResult,
    required super.maxResultBytes,
    required super.maxResultTokens,
  });
}

/// Fail-closed device-tool contract advertised by Agent protocol v3.
class HostedAgentClientToolsCapabilities {
  static const int supportedVersion = 1;
  static const Set<String> requiredTools = {'local_search', 'read_article'};

  final int version;
  final List<String> models;
  final Set<String> tools;
  final int maxTotalCalls;
  final int maxLocalSearchCalls;
  final int maxReadArticleCalls;
  final int maxResultBytes;
  final int leaseSeconds;
  final int waitSeconds;
  final int wallSeconds;
  final HostedAgentLocalSearchLimits localSearch;
  final HostedAgentClientToolResultLimits readArticle;

  const HostedAgentClientToolsCapabilities({
    required this.version,
    required this.models,
    required this.tools,
    required this.maxTotalCalls,
    required this.maxLocalSearchCalls,
    required this.maxReadArticleCalls,
    required this.maxResultBytes,
    required this.leaseSeconds,
    required this.waitSeconds,
    required this.wallSeconds,
    required this.localSearch,
    required this.readArticle,
  });

  static HostedAgentClientToolsCapabilities? fromAgentSection(
    dynamic agentSection,
  ) {
    if (agentSection is! Map || agentSection['protocolVersion'] is! int) {
      return null;
    }
    if ((agentSection['protocolVersion'] as int) < 3) return null;
    final raw = agentSection['clientTools'];
    if (raw is! Map || raw['available'] != true) return null;
    if (!_hasExactKeys(raw, const {
      'available',
      'version',
      'models',
      'tools',
      'limits',
    })) {
      return null;
    }
    final version = raw['version'];
    final models = _strictStringList(raw['models']);
    final parsedTools = _strictStringList(raw['tools']);
    final limits = raw['limits'];
    if (version != supportedVersion ||
        models == null ||
        models.isEmpty ||
        parsedTools == null ||
        parsedTools.isEmpty ||
        limits is! Map) {
      return null;
    }
    final tools = parsedTools.toSet();
    if (tools.length != requiredTools.length ||
        !tools.containsAll(requiredTools)) {
      return null;
    }

    final local = limits['localSearch'];
    final read = limits['readArticle'];
    if (!_hasExactKeys(limits, const {
          'maxTotalCalls',
          'maxLocalSearchCalls',
          'maxReadArticleCalls',
          'maxResultBytes',
          'leaseSeconds',
          'waitSeconds',
          'wallSeconds',
          'localSearch',
          'readArticle',
        }) ||
        local is! Map ||
        read is! Map ||
        !_hasExactKeys(local, const {
          'maxResults',
          'maxSnippetsPerResult',
          'maxResultBytes',
          'maxResultTokens',
        }) ||
        !_hasExactKeys(read, const {'maxResultBytes', 'maxResultTokens'})) {
      return null;
    }
    final maxTotalCalls = _strictPositiveInt(limits['maxTotalCalls']);
    final maxLocalSearchCalls = _strictPositiveInt(
      limits['maxLocalSearchCalls'],
    );
    final maxReadArticleCalls = _strictPositiveInt(
      limits['maxReadArticleCalls'],
    );
    final maxResultBytes = _strictPositiveInt(limits['maxResultBytes']);
    final leaseSeconds = _strictPositiveInt(limits['leaseSeconds']);
    final waitSeconds = _strictPositiveInt(limits['waitSeconds']);
    final wallSeconds = _strictPositiveInt(limits['wallSeconds']);
    final localMaxResults = _strictPositiveInt(local['maxResults']);
    final localMaxSnippets = _strictPositiveInt(local['maxSnippetsPerResult']);
    final localMaxBytes = _strictPositiveInt(local['maxResultBytes']);
    final localMaxTokens = _strictPositiveInt(local['maxResultTokens']);
    final readMaxBytes = _strictPositiveInt(read['maxResultBytes']);
    final readMaxTokens = _strictPositiveInt(read['maxResultTokens']);
    if (maxTotalCalls == null ||
        maxLocalSearchCalls == null ||
        maxReadArticleCalls == null ||
        maxResultBytes == null ||
        leaseSeconds == null ||
        waitSeconds == null ||
        wallSeconds == null ||
        localMaxResults == null ||
        localMaxSnippets == null ||
        localMaxBytes == null ||
        localMaxTokens == null ||
        readMaxBytes == null ||
        readMaxTokens == null) {
      return null;
    }
    if (maxLocalSearchCalls > maxTotalCalls ||
        maxReadArticleCalls > maxTotalCalls ||
        localMaxBytes > maxResultBytes ||
        readMaxBytes > maxResultBytes ||
        leaseSeconds > waitSeconds ||
        waitSeconds > wallSeconds ||
        maxResultBytes < 256 ||
        localMaxBytes < 256 ||
        readMaxBytes < 256 ||
        localMaxTokens < 32 ||
        readMaxTokens < 32) {
      return null;
    }

    return HostedAgentClientToolsCapabilities(
      version: version as int,
      models: List.unmodifiable(models),
      tools: Set.unmodifiable(tools),
      maxTotalCalls: maxTotalCalls,
      maxLocalSearchCalls: maxLocalSearchCalls,
      maxReadArticleCalls: maxReadArticleCalls,
      maxResultBytes: maxResultBytes,
      leaseSeconds: leaseSeconds,
      waitSeconds: waitSeconds,
      wallSeconds: wallSeconds,
      localSearch: HostedAgentLocalSearchLimits(
        maxResults: localMaxResults,
        maxSnippetsPerResult: localMaxSnippets,
        maxResultBytes: localMaxBytes,
        maxResultTokens: localMaxTokens,
      ),
      readArticle: HostedAgentClientToolResultLimits(
        maxResultBytes: readMaxBytes,
        maxResultTokens: readMaxTokens,
      ),
    );
  }

  bool supportsModel(String model) {
    final candidate = model.trim();
    return candidate.isNotEmpty && models.contains(candidate);
  }

  static List<String>? _strictStringList(dynamic value) {
    if (value is! List ||
        value.isEmpty ||
        value.any((item) => item is! String)) {
      return null;
    }
    final normalized = value
        .cast<String>()
        .map((item) => item.trim())
        .toList(growable: false);
    if (normalized.any((item) => item.isEmpty) ||
        normalized.toSet().length != normalized.length) {
      return null;
    }
    return normalized;
  }

  static int? _strictPositiveInt(dynamic value) =>
      value is int && value > 0 ? value : null;

  static bool _hasExactKeys(Map value, Set<String> keys) =>
      value.length == keys.length && value.keys.toSet().containsAll(keys);
}

HostedAgentClientToolsCapabilities? hostedAgentClientToolsForModel(
  HostedAiCapabilities? capabilities,
  String model,
) {
  final tools = capabilities?.agentClientTools;
  if (capabilities == null ||
      !capabilities.agentAvailable ||
      capabilities.agentProtocolVersion < 3 ||
      tools == null ||
      !tools.supportsModel(model)) {
    return null;
  }
  return tools;
}

class HostedAgentImageInputCapabilities {
  final List<String> models;
  final Set<String> mimeTypes;
  final int maxImages;
  final int maxImageBytes;
  final int maxTotalImageBytes;
  final int maxBodyBytes;

  const HostedAgentImageInputCapabilities({
    required this.models,
    required this.mimeTypes,
    required this.maxImages,
    required this.maxImageBytes,
    required this.maxTotalImageBytes,
    required this.maxBodyBytes,
  });

  factory HostedAgentImageInputCapabilities.fromJson(
    Map<dynamic, dynamic> json,
  ) {
    final models = _stringList(json['models']);
    final mimeTypes = _stringList(json['mimeTypes'])
        .map((value) => value.trim().toLowerCase())
        .where((value) => value.isNotEmpty)
        .toSet();
    return HostedAgentImageInputCapabilities(
      models: models,
      mimeTypes: Set.unmodifiable(mimeTypes),
      maxImages: _positiveInt(json['maxImages']),
      maxImageBytes: _positiveInt(json['maxImageBytes']),
      maxTotalImageBytes: _positiveInt(json['maxTotalImageBytes']),
      maxBodyBytes: _positiveInt(json['maxBodyBytes']),
    );
  }

  static HostedAgentImageInputCapabilities? fromAgentSection(
    dynamic agentSection,
  ) {
    if (agentSection is! Map) return null;
    final imageInput = agentSection['imageInput'];
    if (imageInput is! Map) return null;
    final parsed = HostedAgentImageInputCapabilities.fromJson(imageInput);
    if (parsed.models.isEmpty ||
        parsed.mimeTypes.isEmpty ||
        parsed.maxImages == 0 ||
        parsed.maxImageBytes == 0 ||
        parsed.maxTotalImageBytes == 0 ||
        parsed.maxBodyBytes == 0) {
      return null;
    }
    return parsed;
  }

  static List<String> _stringList(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<String>()
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  static int _positiveInt(dynamic value) =>
      value is int && value > 0 ? value : 0;
}

HostedAgentImageInputCapabilities? hostedAgentImageInputForModel(
  HostedAiCapabilities? capabilities,
  String model,
) {
  final normalizedModel = model.trim().toLowerCase();
  final imageInput = capabilities?.agentImageInput;
  if (capabilities == null ||
      !capabilities.agentAvailable ||
      capabilities.agentProtocolVersion < 2 ||
      imageInput == null ||
      normalizedModel.isEmpty ||
      !imageInput.models.any(
        (candidate) => candidate.trim().toLowerCase() == normalizedModel,
      )) {
    return null;
  }
  return imageInput;
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
  static final HostedAiCapabilitiesCache instance = HostedAiCapabilitiesCache();

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
