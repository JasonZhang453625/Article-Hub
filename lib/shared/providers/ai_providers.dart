import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/services/embedding_service.dart';
import '../../data/services/index_service.dart';
import '../../data/services/retrieval_service.dart';
import '../../data/services/retrieval_log_service.dart';
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
  return RetrievalService(embedding: embedding, index: index);
});

final retrievalLogServiceProvider = Provider<RetrievalLogService>((ref) {
  return RetrievalLogService();
});
