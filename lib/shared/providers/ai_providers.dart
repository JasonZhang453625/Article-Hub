import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/models/settings.dart';
import '../../data/services/ai_service.dart';
import '../../data/services/embedding_service.dart';
import '../../data/services/hosted_ai_capabilities.dart';
import '../../data/services/hosted_agent_service.dart';
import '../../data/services/hosted_ai_service.dart';
import '../../data/services/index_service.dart';
import '../../data/services/prompt_service.dart';
import '../../data/services/rag_conversation_service.dart';
import '../../data/services/retrieval_service.dart';
import '../../data/services/retrieval_log_service.dart';
import '../../data/services/web_search_service.dart';
import 'article_providers.dart';
import 'auth_provider.dart';
import 'settings_providers.dart';

final embeddingServiceProvider = Provider<EmbeddingService?>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  if (settings == null) return null;
  return EmbeddingService(
    baseUrl: settings.effectiveEmbeddingBaseUrl,
    apiKey: settings.effectiveEmbeddingApiKey,
    model: settings.effectiveEmbeddingModel,
  );
});

final embeddingConfiguredProvider = Provider<bool>((ref) {
  return ref.watch(embeddingServiceProvider) != null;
});

final indexServiceProvider = Provider<IndexService>((ref) {
  ref.watch(hiveInitProvider);
  return IndexService();
});

final indexCountProvider = StreamProvider<int>((ref) async* {
  final index = ref.watch(indexServiceProvider);
  final box = await index.openBox();
  yield box.length;
  await for (final _ in box.watch()) {
    yield box.length;
  }
});

final retrievalServiceProvider = Provider<RetrievalService?>((ref) {
  final embedding = ref.watch(embeddingServiceProvider);
  final index = ref.watch(indexServiceProvider);
  if (embedding == null) return null;
  return RetrievalService(embedding: embedding, index: index, topK: 10);
});

final retrievalLogServiceProvider = Provider<RetrievalLogService>((ref) {
  return RetrievalLogService();
});

/// Effective hosted mode is account-bound. A persisted hosted preference is
/// deliberately ignored while signed out, so every capability falls back to
/// its BYOK configuration.
final hostedAiEnabledProvider = Provider<bool>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  final session = ref.watch(currentSessionProvider);
  return settings?.aiProviderMode == 1 && session != null;
});

/// Hosted-AI capabilities fetched from the backend (`/ai/capabilities`).
///
/// The result is cached in memory (see [HostedAiCapabilitiesCache]) so the
/// settings screen does not hit the network on every rebuild. On failure the
/// value falls back to the built-in model list so the UI stays usable.
final hostedAiCapabilitiesProvider = FutureProvider<HostedAiCapabilities?>((
  ref,
) async {
  final session = ref.watch(currentSessionProvider);
  if (session == null) return null;
  final cache = HostedAiCapabilitiesCache.instance;
  if (cache.isFresh) return cache.value ?? _builtInCapabilities();
  try {
    final capabilities = await HostedAiCapabilitiesService(
      getSession: () => ref.read(currentSessionProvider),
    ).fetch();
    cache.store(capabilities);
    return capabilities;
  } catch (_) {
    return _builtInCapabilities();
  }
});

HostedAiCapabilities _builtInCapabilities() {
  return HostedAiCapabilities(
    chatModels: AppSettings.hostedTextModels,
    summaryModels: AppSettings.hostedTextModels,
    visionModels: AppSettings.hostedVisionModels,
  );
}

final webSearchServiceProvider = Provider<WebSearchGateway?>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  if (settings == null) return null;
  if (ref.watch(hostedAiEnabledProvider)) {
    final service = HostedWebSearchService(
      getSession: () => ref.read(currentSessionProvider),
      refreshSession: () => ref.read(authControllerProvider.notifier).refresh(),
    );
    ref.onDispose(service.dispose);
    return service;
  }
  if (settings.tavilyApiKey.trim().isEmpty) return null;
  return WebSearchService(apiKey: settings.tavilyApiKey.trim());
});

final webSearchConfiguredProvider = Provider<bool>((ref) {
  if (ref.watch(hostedAiEnabledProvider)) {
    return ref.watch(hostedAgentServiceProvider) != null;
  }
  return ref.watch(webSearchServiceProvider) != null;
});

/// Whether the hosted (backend-proxied) AI path is available: the user must
/// be signed in and have chosen a hosted model.
final hostedAiConfiguredProvider = Provider<bool>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  if (settings == null || !ref.watch(hostedAiEnabledProvider)) return false;
  return settings.hostedAiModel.trim().isNotEmpty &&
      settings.hostedChatModel.trim().isNotEmpty;
});

final hostedAgentServiceProvider = Provider<HostedAgentService?>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  if (settings == null || !ref.watch(hostedAiEnabledProvider)) return null;
  if (settings.hostedChatModel.trim().isEmpty) return null;
  return HostedAgentService(
    getSession: () => ref.read(currentSessionProvider),
    refreshSession: () => ref.read(authControllerProvider.notifier).refresh(),
    model: settings.hostedChatModel.trim(),
  );
});

final summaryAiGatewayProvider = Provider<AiGateway?>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  if (settings == null) return null;

  if (ref.watch(hostedAiEnabledProvider)) {
    if (settings.hostedAiModel.trim().isEmpty) return null;
    final gateway = HostedAiService(
      getSession: () => ref.read(currentSessionProvider),
      refreshSession: () => ref.read(authControllerProvider.notifier).refresh(),
      model: settings.hostedAiModel.trim(),
      purpose: HostedAiPurpose.summary,
    );
    gateway.onTokensUsed = (tokens) {
      ref.read(settingsProvider.notifier).addTokenUsage(tokens);
    };
    return gateway;
  }

  if (settings.aiBaseUrl.trim().isEmpty || settings.aiApiKey.trim().isEmpty) {
    return null;
  }
  final gateway = AiService(
    baseUrl: settings.aiBaseUrl,
    apiKey: settings.aiApiKey,
    model: settings.aiModel,
  );
  gateway.onTokensUsed = (tokens) {
    ref.read(settingsProvider.notifier).addTokenUsage(tokens);
  };
  return gateway;
});

final chatAiGatewayProvider = Provider<AiGateway?>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  if (settings == null) return null;

  if (ref.watch(hostedAiEnabledProvider)) {
    if (settings.hostedChatModel.trim().isEmpty) return null;
    final gateway = HostedAiService(
      getSession: () => ref.read(currentSessionProvider),
      refreshSession: () => ref.read(authControllerProvider.notifier).refresh(),
      model: settings.hostedChatModel.trim(),
      purpose: HostedAiPurpose.chat,
    );
    gateway.onTokensUsed = (tokens) {
      ref.read(settingsProvider.notifier).addTokenUsage(tokens);
    };
    return gateway;
  }

  if (settings.chatAiBaseUrl.trim().isEmpty ||
      settings.chatAiApiKey.trim().isEmpty ||
      settings.chatAiModel.trim().isEmpty) {
    return null;
  }
  final gateway = AiService(
    baseUrl: settings.chatAiBaseUrl,
    apiKey: settings.chatAiApiKey,
    model: settings.chatAiModel,
  );
  gateway.onTokensUsed = (tokens) {
    ref.read(settingsProvider.notifier).addTokenUsage(tokens);
  };
  return gateway;
});

/// Backward-compatible name for summary-generation call sites not yet split.
final aiGatewayProvider = Provider<AiGateway?>((ref) {
  return ref.watch(summaryAiGatewayProvider);
});

final ragConversationServiceProvider = Provider<RagConversationService?>((ref) {
  final retrieval = ref.watch(retrievalServiceProvider);
  final ai = ref.watch(chatAiGatewayProvider);
  if (ai == null || retrieval == null) return null;

  final logService = ref.watch(retrievalLogServiceProvider);
  final webSearch = ref.watch(webSearchServiceProvider);
  final hostedAgent = ref.watch(hostedAgentServiceProvider);

  return RagConversationService(
    retrieve: retrieval.retrieve,
    complete:
        ({
          required String systemPrompt,
          required String userMessage,
          List<Map<String, String>> history = const [],
          double temperature = 0.3,
          int maxTokens = 800,
        }) {
          return ai.chat(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            history: history,
            temperature: temperature,
            maxTokens: maxTokens,
          );
        },
    completeStream:
        ({
          required String systemPrompt,
          required String userMessage,
          List<Map<String, String>> history = const [],
          double temperature = 0.3,
          int maxTokens = 800,
        }) {
          return ai.chatStream(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            history: history,
            temperature: temperature,
            maxTokens: maxTokens,
          );
        },
    agentRunStream: hostedAgent == null
        ? null
        : ({
            required String systemPrompt,
            required String userMessage,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
            required bool webSearch,
            void Function(HostedAgentEvent event)? onEvent,
            FutureOr<void> Function(String runId)? onRunCreated,
            String? idempotencyKey,
          }) {
            return hostedAgent.chatStream(
              systemPrompt: systemPrompt,
              userMessage: userMessage,
              history: history,
              temperature: temperature,
              maxTokens: maxTokens,
              webSearch: webSearch,
              onEvent: onEvent,
              onRunCreated: onRunCreated,
              idempotencyKey: idempotencyKey,
            );
          },
    completionError: () => hostedAgent?.lastError ?? ai.lastError,
    configureThinking: (level) {
      ai.thinkingLevel = level;
      if (hostedAgent != null) hostedAgent.thinkingLevel = level;
    },
    agentWebUrls: hostedAgent == null ? null : () => hostedAgent.lastWebUrls,
    saveLog: logService.save,
    promptService: PromptService(),
    webSearch: webSearch == null
        ? null
        : (query, {topK = 5}) => webSearch.search(query, topK: topK),
  );
});
