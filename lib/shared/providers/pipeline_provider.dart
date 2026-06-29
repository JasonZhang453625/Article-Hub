import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../data/models/folder.dart';
import '../../data/services/content_extractor.dart';
import '../../data/services/metadata_service.dart';
import '../../data/services/processing_pipeline.dart';
import 'article_providers.dart';
import 'folder_providers.dart';
import 'ai_providers.dart';
import 'page_loader_provider.dart';
import 'settings_providers.dart';

final processingPipelineProvider = Provider<ProcessingPipeline>((ref) {
  final articles = ref.read(articlesProvider.notifier);
  final embedding = ref.read(embeddingServiceProvider);
  final index = ref.read(indexServiceProvider);

  final pageLoader = ref.read(pageLoaderProvider);

  final pipeline = ProcessingPipeline(
    articles: articles,
    getSettings: () => ref.read(settingsProvider).valueOrNull,
    getFolders: () => ref.read(foldersProvider).valueOrNull ?? [],
    metadata: MetadataService(loader: pageLoader, ownsLoader: false),
    extractor: ContentExtractor(loader: pageLoader, ownsLoader: false),
    embedding: embedding,
    index: index,
    createFolder: (name) async {
      final folder = Folder(
        id: const Uuid().v4(),
        name: name,
      );
      await ref.read(foldersProvider.notifier).add(folder);
      return folder;
    },
  );
  ref.onDispose(pipeline.dispose);
  return pipeline;
});
