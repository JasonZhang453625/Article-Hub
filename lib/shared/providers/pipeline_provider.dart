import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../data/models/folder.dart';
import '../../data/services/backup_service.dart';
import '../../data/services/chat_attachment_pipeline.dart';
import '../../data/services/content_extractor.dart';
import '../../data/services/image_understanding_service.dart';
import '../../data/services/metadata_service.dart';
import '../../data/services/processing_queue.dart';
import '../../data/services/processing_pipeline.dart';
import 'article_providers.dart';
import 'attachment_providers.dart';
import 'filter_providers.dart';
import 'folder_providers.dart';
import 'ai_providers.dart';
import 'page_loader_provider.dart';
import 'settings_providers.dart';
import 'auth_provider.dart';

final imageUnderstandingServiceProvider = Provider<ImageUnderstandingGateway?>((
  ref,
) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  if (settings == null) return null;
  if (ref.watch(hostedAiEnabledProvider)) {
    final model = settings.hostedVisionModel.trim();
    if (model.isEmpty) return null;
    final service = ImageUnderstandingService(
      getSession: () => ref.read(currentSessionProvider),
      refreshSession: () => ref.read(authControllerProvider.notifier).refresh(),
      provider: imageProviderForModel(model),
      model: model,
    );
    ref.onDispose(service.dispose);
    return service;
  }
  if (settings.imageAiBaseUrl.trim().isEmpty ||
      settings.imageAiApiKey.trim().isEmpty ||
      settings.imageAiModel.trim().isEmpty) {
    return null;
  }
  final service = OpenAiImageUnderstandingService(
    baseUrl: settings.imageAiBaseUrl,
    apiKey: settings.imageAiApiKey,
    model: settings.imageAiModel,
  );
  ref.onDispose(service.dispose);
  return service;
});

final chatAttachmentPipelineProvider = Provider<ChatAttachmentPipeline>((ref) {
  return ChatAttachmentPipeline(store: ref.watch(attachmentStoreProvider));
});

final processingPipelineProvider = Provider<ProcessingPipeline>((ref) {
  final articles = ref.read(articlesProvider.notifier);
  final embedding = ref.watch(embeddingServiceProvider);
  final index = ref.watch(indexServiceProvider);
  final aiGateway = ref.watch(summaryAiGatewayProvider);
  final imageUnderstanding = ref.watch(imageUnderstandingServiceProvider);

  final pageLoader = ref.read(pageLoaderProvider);

  final pipeline = ProcessingPipeline(
    articles: articles,
    getSettings: () => ref.read(settingsProvider).valueOrNull,
    getFolders: () => ref.read(foldersProvider).valueOrNull ?? [],
    metadata: MetadataService(loader: pageLoader, ownsLoader: false),
    extractor: ContentExtractor(loader: pageLoader, ownsLoader: false),
    embedding: embedding,
    index: index,
    aiGateway: aiGateway,
    imageUnderstanding: imageUnderstanding,
    createFolder: (name) async {
      final folder = Folder(id: const Uuid().v4(), name: name);
      await ref.read(foldersProvider.notifier).add(folder);
      return folder;
    },
  );
  ref.onDispose(pipeline.dispose);
  return pipeline;
});

/// Application-scoped worker for durable article processing.
///
/// Pending and in-progress records are discovered whenever articles or AI
/// settings load. The queue serializes work and uses the persisted state to
/// resume automatically after an app restart.
final processingQueueProvider = Provider<ProcessingQueue>((ref) {
  final articles = ref.read(articlesProvider.notifier);
  final queue = ProcessingQueue(
    getArticles: () => ref.read(articlesProvider).valueOrNull ?? const [],
    save: articles.update,
    process: (article) => ref.read(processingPipelineProvider).resume(article),
    prepareRetry: (article) =>
        ref.read(processingPipelineProvider).prepareRetry(article),
    canProcess: (article) {
      if (article.isLocalImage) {
        if (ref.read(imageUnderstandingServiceProvider) == null &&
            article.imageUnderstanding == null) {
          return false;
        }
        if (article.isFullText) return true;
      } else if (article.isFullText) {
        return true;
      }
      return ref.read(summaryAiGatewayProvider) != null;
    },
  );

  ref.listen(articlesProvider, (_, next) {
    if (next.valueOrNull != null) queue.resume();
  }, fireImmediately: true);
  ref.listen(settingsProvider, (_, next) {
    if (next.valueOrNull != null) queue.resume();
  }, fireImmediately: true);
  ref.listen(authControllerProvider, (_, next) {
    if (next.valueOrNull != null) queue.resume();
  }, fireImmediately: true);
  return queue;
});

final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(
    getAllArticles: () {
      final repo = ref.read(articleRepositoryProvider).requireValue;
      return repo.getAll();
    },
    importArticles: (articles) async {
      return ref.read(articlesProvider.notifier).importAll(articles.cast());
    },
    getFilterGroups: () => ref.read(filterGroupsProvider).valueOrNull ?? [],
    importFilterGroups: (groups) async {
      return ref.read(filterGroupsProvider.notifier).importAll(groups.cast());
    },
    addFolder: (folder) async {
      await ref.read(foldersProvider.notifier).add(folder as dynamic);
    },
    replaceSettings: (settings) async {
      await ref
          .read(settingsProvider.notifier)
          .replaceWith(settings as dynamic);
    },
    getFolders: () => ref.read(foldersProvider).valueOrNull ?? [],
    getSettings: () => ref.read(settingsProvider).valueOrNull,
  );
});
