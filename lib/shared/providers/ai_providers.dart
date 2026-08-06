import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/services/ai_service.dart';
import '../../data/services/embedding_service.dart';
import '../../data/services/index_service.dart';
import '../../data/services/prompt_service.dart';
import '../../data/services/rag_conversation_service.dart';
import '../../data/services/retrieval_service.dart';
import '../../data/services/retrieval_log_service.dart';
import '../../data/services/web_search_service.dart';
import 'article_providers.dart';
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

final webSearchServiceProvider = Provider<WebSearchService?>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  if (settings == null || settings.tavilyApiKey.trim().isEmpty) return null;
  return WebSearchService(apiKey: settings.tavilyApiKey);
});

final webSearchConfiguredProvider = Provider<bool>((ref) {
  return ref.watch(webSearchServiceProvider) != null;
});

final ragConversationServiceProvider = Provider<RagConversationService?>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  final retrieval = ref.watch(retrievalServiceProvider);
  if (settings == null ||
      settings.aiBaseUrl.trim().isEmpty ||
      settings.aiApiKey.trim().isEmpty ||
      retrieval == null) {
    return null;
  }

  final ai = AiService(
    baseUrl: settings.aiBaseUrl,
    apiKey: settings.aiApiKey,
    model: settings.aiModel,
  );
  ai.onTokensUsed = (tokens) {
    ref.read(settingsProvider.notifier).addTokenUsage(tokens);
  };
  final logService = ref.watch(retrievalLogServiceProvider);
  final webSearch = ref.watch(webSearchServiceProvider);

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
    saveLog: logService.save,
    promptService: PromptService(),
    webSearch: webSearch == null
        ? null
        : (query, {topK = 5}) => webSearch.search(query, topK: topK),
  );
});
