import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/models/ai_image_input.dart';
import '../../data/models/ai_text_attachment_input.dart';
import '../../data/models/settings.dart';
import '../../data/services/ai_service.dart';
import '../../data/services/agent_client_tool_store.dart';
import '../../data/services/chat_model_capabilities.dart';
import '../../data/services/conversation_feedback_service.dart';
import '../../data/services/embedding_service.dart';
import '../../data/services/hosted_ai_capabilities.dart';
import '../../data/services/hosted_agent_service.dart';
import '../../data/services/hosted_ai_service.dart';
import '../../data/services/hosted_task_run_service.dart';
import '../../data/services/hosted_task_run_store.dart';
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
  return ref.watch(embeddingServiceProvider)?.isConfigured == true;
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

final agentClientToolStoreProvider = Provider<AgentClientToolStore>((ref) {
  ref.watch(hiveInitProvider);
  return AgentClientToolStore();
});

final conversationFeedbackServiceProvider =
    Provider<ConversationFeedbackService>((ref) {
      final service = ConversationFeedbackService(
        getSession: () => ref.read(currentSessionProvider),
        refreshSession: () =>
            ref.read(authControllerProvider.notifier).refresh(),
      );
      ref.onDispose(service.dispose);
      return service;
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
  final scope = '${session.user.id}\u0000${session.device.id}';

  void scheduleRefresh(Duration delay) {
    final timer = Timer(
      delay <= Duration.zero ? const Duration(seconds: 1) : delay,
      ref.invalidateSelf,
    );
    ref.onDispose(timer.cancel);
  }

  if (cache.isFreshFor(scope)) {
    scheduleRefresh(cache.remainingTtl);
    return cache.value ?? _builtInCapabilities();
  }
  try {
    final capabilities = await HostedAiCapabilitiesService(
      getSession: () => ref.read(currentSessionProvider),
      refreshSession: () => ref.read(authControllerProvider.notifier).refresh(),
    ).fetchWithRetry();
    cache.store(capabilities, scope: scope);
    scheduleRefresh(cache.remainingTtl);
    return capabilities;
  } catch (_) {
    // Keep task negotiation fail-closed, but do not pin a transient outage for
    // the lifetime of this FutureProvider instance.
    scheduleRefresh(const Duration(seconds: 30));
    return _builtInCapabilities();
  }
});

/// Whether the currently selected chat model can receive native image blocks.
/// Hosted capability metadata is authoritative when available; BYOK falls
/// back to conservative model-family detection.
final hostedAgentImageInputCapabilitiesProvider =
    Provider<HostedAgentImageInputCapabilities?>((ref) {
      final settings = ref.watch(settingsProvider).valueOrNull;
      if (settings == null || !ref.watch(hostedAiEnabledProvider)) return null;
      final capabilities = ref.watch(hostedAiCapabilitiesProvider).valueOrNull;
      return hostedAgentImageInputForModel(
        capabilities,
        settings.hostedChatModel,
      );
    });

final hostedAgentClientToolsCapabilitiesProvider =
    Provider<HostedAgentClientToolsCapabilities?>((ref) {
      final settings = ref.watch(settingsProvider).valueOrNull;
      if (settings == null || !ref.watch(hostedAiEnabledProvider)) return null;
      return hostedAgentClientToolsForModel(
        ref.watch(hostedAiCapabilitiesProvider).valueOrNull,
        settings.hostedChatModel,
      );
    });

final chatModelSupportsImageInputProvider = Provider<bool>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  if (settings == null) return false;
  if (ref.watch(hostedAiEnabledProvider)) {
    return ref.watch(hostedAgentImageInputCapabilitiesProvider) != null;
  }
  return chatModelSupportsImageInput(settings.chatAiModel);
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
  final session = ref.watch(currentSessionProvider);
  if (ref.watch(hostedAiEnabledProvider)) {
    final service = HostedWebSearchService(
      getSession: () => ref.read(currentSessionProvider),
      refreshSession: () => ref.read(authControllerProvider.notifier).refresh(),
      cache: WebSearchCache(namespace: 'hosted:${session?.user.id ?? 'none'}'),
    );
    ref.onDispose(service.dispose);
    return service;
  }
  if (settings.tavilyApiKey.trim().isEmpty) return null;
  final service = WebSearchService(
    apiKey: settings.tavilyApiKey.trim(),
    cache: WebSearchCache(namespace: 'byok:${session?.user.id ?? 'local'}'),
  );
  ref.onDispose(service.dispose);
  return service;
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
  final capabilities = ref.watch(hostedAiCapabilitiesProvider).valueOrNull;
  final chatRuns = hostedChatRunsForModel(
    capabilities,
    settings.hostedChatModel,
  );
  if (chatRuns == null) return null;
  final imageCapabilities = ref.watch(
    hostedAgentImageInputCapabilitiesProvider,
  );
  return HostedAgentService(
    getSession: () => ref.read(currentSessionProvider),
    refreshSession: () => ref.read(authControllerProvider.notifier).refresh(),
    model: settings.hostedChatModel.trim(),
    maxImages: _lowerLimit(
      chatRuns.maxImages,
      imageCapabilities == null
          ? maxHostedAgentImages
          : _lowerLimit(imageCapabilities.maxImages, maxHostedAgentImages),
    ),
    maxImageBytes: _lowerLimit(
      chatRuns.maxImageBytes,
      imageCapabilities == null
          ? maxHostedAgentImageBytes
          : _lowerLimit(
              imageCapabilities.maxImageBytes,
              maxHostedAgentImageBytes,
            ),
    ),
    maxTotalImageBytes: _lowerLimit(
      chatRuns.maxTotalImageBytes,
      imageCapabilities == null
          ? maxHostedAgentImageTotalBytes
          : _lowerLimit(
              imageCapabilities.maxTotalImageBytes,
              maxHostedAgentImageTotalBytes,
            ),
    ),
    maxBodyBytes: _lowerLimit(
      chatRuns.maxBodyBytes,
      imageCapabilities == null
          ? maxHostedAgentBodyBytes
          : _lowerLimit(
              imageCapabilities.maxBodyBytes,
              maxHostedAgentBodyBytes,
            ),
    ),
    maxQuestionChars: _lowerLimit(
      chatRuns.maxQuestionChars,
      maxHostedChatQuestionCharacters,
    ),
    maxHistoryMessages: _lowerLimit(
      chatRuns.maxHistoryMessages,
      maxHostedChatHistoryMessages,
    ),
    maxHistoryMessageChars: _lowerLimit(
      chatRuns.maxHistoryMessageChars,
      maxHostedChatHistoryMessageCharacters,
    ),
    maxHistoryChars: _lowerLimit(
      chatRuns.maxHistoryChars,
      maxHostedChatHistoryCharacters,
    ),
    maxAttachments: _lowerLimit(
      chatRuns.maxAttachments,
      maxHostedChatAttachments,
    ),
    maxAttachmentIdChars: _lowerLimit(
      chatRuns.maxAttachmentIdChars,
      maxHostedChatAttachmentIdCharacters,
    ),
    maxAttachmentNameChars: _lowerLimit(
      chatRuns.maxAttachmentNameChars,
      maxHostedChatAttachmentNameCharacters,
    ),
    maxAttachmentTextChars: _lowerLimit(
      chatRuns.maxAttachmentTextChars,
      maxHostedChatAttachmentTextCharacters,
    ),
    maxTotalAttachmentTextChars: _lowerLimit(
      chatRuns.maxTotalAttachmentTextChars,
      maxHostedChatAttachmentTotalCharacters,
    ),
    allowedImageMimeTypes: imageCapabilities == null
        ? hostedAgentImageMimeTypes
        : imageCapabilities.mimeTypes.intersection(hostedAgentImageMimeTypes),
    imageInputEnabled: imageCapabilities != null,
    onClientToolWake: ref.read(hostedAgentClientToolWakeProvider).emit,
  );
});

/// App-global, payload-free wake channel for protocol-v3 client tools.
///
/// It is intentionally independent of ChatScreen. The app-global host
/// consumes only the run id and always reconciles through REST pending.
final hostedAgentClientToolWakeProvider = Provider<HostedAgentClientToolWakes>((
  ref,
) {
  final wakes = HostedAgentClientToolWakes();
  ref.onDispose(wakes.dispose);
  return wakes;
});

class HostedAgentClientToolWakes {
  final StreamController<HostedAgentClientToolWake> _controller =
      StreamController<HostedAgentClientToolWake>.broadcast(sync: true);

  Stream<HostedAgentClientToolWake> get stream => _controller.stream;

  void emit(HostedAgentClientToolWake wake) {
    if (!_controller.isClosed) _controller.add(wake);
  }

  void dispose() => _controller.close();
}

int _lowerLimit(int advertised, int localHardLimit) =>
    advertised < localHardLimit ? advertised : localHardLimit;

final hostedTaskRunStoreProvider = Provider<HostedTaskRunStore>((ref) {
  final initialization = ref.watch(hiveInitProvider.future);
  final store = HiveHostedTaskRunStore(initialization: initialization);
  ref.onDispose(() => unawaited(store.close()));
  return store;
});

final hostedSummaryTaskRunServiceProvider = Provider<HostedTaskRunService?>((
  ref,
) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  if (settings == null || !ref.watch(hostedAiEnabledProvider)) return null;
  final model = settings.hostedAiModel.trim();
  final capabilities = ref.watch(hostedAiCapabilitiesProvider).valueOrNull;
  final tasks = capabilities?.agentTasks;
  const requiredProfiles = {
    'summary.chunk',
    'summary.final',
    'memory.tags',
    'memory.folder',
  };
  if (model.isEmpty ||
      capabilities == null ||
      !capabilities.agentAvailable ||
      capabilities.agentProtocolVersion < hostedTaskProtocolVersion ||
      tasks == null ||
      requiredProfiles.any(
        (profile) => tasks.profileForModel(profile, model) == null,
      )) {
    return null;
  }
  return HostedTaskRunService(
    getSession: () => ref.read(currentSessionProvider),
    refreshSession: () => ref.read(authControllerProvider.notifier).refresh(),
    model: model,
    maxBodyBytes: tasks.maxBodyBytes,
    runStore: ref.watch(hostedTaskRunStoreProvider),
    onTokensUsed: (tokens) {
      ref.read(settingsProvider.notifier).addTokenUsage(tokens);
    },
  );
});

final hostedChatTaskRunServiceProvider = Provider<HostedTaskRunService?>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  if (settings == null || !ref.watch(hostedAiEnabledProvider)) return null;
  final model = settings.hostedChatModel.trim();
  final capabilities = ref.watch(hostedAiCapabilitiesProvider).valueOrNull;
  final tasks = capabilities?.agentTasks;
  if (model.isEmpty ||
      capabilities == null ||
      !capabilities.agentAvailable ||
      capabilities.agentProtocolVersion < hostedTaskProtocolVersion ||
      tasks?.profileForModel('retrieval.rewrite', model) == null) {
    return null;
  }
  return HostedTaskRunService(
    getSession: () => ref.read(currentSessionProvider),
    refreshSession: () => ref.read(authControllerProvider.notifier).refresh(),
    model: model,
    maxBodyBytes: tasks!.maxBodyBytes,
    runStore: ref.watch(hostedTaskRunStoreProvider),
    onTokensUsed: (tokens) {
      ref.read(settingsProvider.notifier).addTokenUsage(tokens);
    },
  );
});

final summaryAiGatewayProvider = Provider<AiGateway?>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  if (settings == null) return null;

  if (ref.watch(hostedAiEnabledProvider)) {
    if (settings.hostedAiModel.trim().isEmpty) return null;
    final taskRuns = ref.watch(hostedSummaryTaskRunServiceProvider);
    if (taskRuns == null) return null;
    final gateway = HostedAiService(
      getSession: () => ref.read(currentSessionProvider),
      refreshSession: () => ref.read(authControllerProvider.notifier).refresh(),
      model: settings.hostedAiModel.trim(),
      purpose: HostedAiPurpose.summary,
      taskGateway: taskRuns,
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
      taskGateway: ref.watch(hostedChatTaskRunServiceProvider),
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
  final clientToolsCapabilities = ref.watch(
    hostedAgentClientToolsCapabilitiesProvider,
  );
  final MultimodalAiGateway? multimodalAi = ai is MultimodalAiGateway
      ? ai as MultimodalAiGateway
      : null;

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
    multimodalCompleteStream: multimodalAi == null
        ? null
        : ({
            required String systemPrompt,
            required String userMessage,
            required List<AiImageInput> images,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
          }) {
            return multimodalAi.chatStreamWithImages(
              systemPrompt: systemPrompt,
              userMessage: userMessage,
              images: images,
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
            required String userQuestion,
            required List<AiImageInput> images,
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
              userQuestion: userQuestion,
              images: images,
              history: history,
              temperature: temperature,
              maxTokens: maxTokens,
              webSearch: webSearch,
              onEvent: onEvent,
              onRunCreated: onRunCreated,
              idempotencyKey: idempotencyKey ?? '',
            );
          },
    agentRunStreamV3: hostedAgent == null || clientToolsCapabilities == null
        ? null
        : ({
            required String systemPrompt,
            required String userMessage,
            required String userQuestion,
            required List<AiImageInput> images,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
            required bool webSearch,
            required bool localKnowledge,
            String? knowledgeMode,
            void Function(HostedAgentEvent event)? onEvent,
            FutureOr<void> Function(String runId)? onRunCreated,
            String? idempotencyKey,
          }) {
            return hostedAgent.chatStreamV3(
              systemPrompt: systemPrompt,
              userMessage: userMessage,
              userQuestion: userQuestion,
              images: images,
              history: history,
              temperature: temperature,
              maxTokens: maxTokens,
              webSearch: webSearch,
              localKnowledge: localKnowledge,
              knowledgeMode: knowledgeMode,
              onEvent: onEvent,
              onRunCreated: onRunCreated,
              idempotencyKey: idempotencyKey ?? '',
            );
          },
    hostedChatRunStream: hostedAgent == null
        ? null
        : ({
            required String question,
            required List<Map<String, dynamic>> history,
            required HostedChatKnowledgeMode knowledgeMode,
            required HostedChatLength length,
            required HostedChatLanguage language,
            required bool webSearch,
            required bool localKnowledge,
            required List<AiTextAttachmentInput> attachments,
            required List<AiImageInput> images,
            void Function(HostedAgentEvent event)? onEvent,
            FutureOr<void> Function(String runId)? onRunCreated,
            required String idempotencyKey,
          }) {
            return hostedAgent.chatStreamV4(
              question: question,
              history: history,
              knowledgeMode: knowledgeMode,
              length: length,
              language: language,
              webSearch: webSearch,
              localKnowledge: localKnowledge,
              attachments: attachments,
              images: images,
              onEvent: onEvent,
              onRunCreated: onRunCreated,
              idempotencyKey: idempotencyKey,
            );
          },
    completionError: () => ai.lastError,
    taskQueryRewrite: ai is HostedAiService
        ? ({
            required String question,
            required List<Map<String, String>> conversation,
            required HostedTaskRewriteLanguage language,
          }) {
            return ai.rewriteQueryTask(
              question: question,
              conversation: conversation,
              language: language,
            );
          }
        : null,
    agentCompletionError: hostedAgent == null
        ? null
        : () => hostedAgent.lastError,
    configureThinking: (level) {
      ai.thinkingLevel = level;
      if (hostedAgent != null) hostedAgent.thinkingLevel = level;
    },
    agentWebUrls: hostedAgent == null ? null : () => hostedAgent.lastWebUrls,
    agentRunId: hostedAgent == null ? null : () => hostedAgent.lastRunId,
    agentLocalSources: hostedAgent == null
        ? null
        : () => hostedAgent.lastLocalSources,
    agentPrivateEvidenceUsed: hostedAgent == null
        ? null
        : () => hostedAgent.lastPrivateEvidenceUsed,
    agentClientToolsEnabled: clientToolsCapabilities != null,
    resolveAgentLocalCitations: hostedAgent == null
        ? null
        : ({
            required String runId,
            required String answer,
            required List<HostedAgentLocalSource> sources,
          }) async {
            final session = ref.read(currentSessionProvider);
            if (session == null ||
                session.user.id != hostedAgent.currentUserId ||
                session.device.id != hostedAgent.currentDeviceId) {
              return const <String>[];
            }
            final repository = await ref.read(articleRepositoryProvider.future);
            return ref
                .read(agentClientToolStoreProvider)
                .resolveCitedArticleIds(
                  binding: AgentToolRunBinding(
                    ownerUserId: session.user.id,
                    ownerDeviceId: session.device.id,
                    runId: runId,
                  ),
                  answer: answer,
                  localSources: sources
                      .map(
                        (source) =>
                            (id: source.id, articleRef: source.articleRef),
                      )
                      .toList(growable: false),
                  existingArticleIds: repository
                      .getAll()
                      .map((article) => article.id)
                      .toSet(),
                );
          },
    saveLog: logService.save,
    promptService: PromptService(),
    webSearch: webSearch == null
        ? null
        : (query, {topK = 5}) => webSearch.search(query, topK: topK),
  );
});
