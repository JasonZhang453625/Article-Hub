import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:memora/data/models/folder.dart';
import 'package:memora/data/models/article_attachment.dart';
import 'package:memora/data/models/image_understanding_document.dart';
import 'package:memora/data/models/memory_document.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/settings.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/data/repositories/article_repository.dart';
import 'package:memora/data/services/ai_service.dart';
import 'package:memora/data/services/auth_service.dart';
import 'package:memora/data/services/content_extractor.dart';
import 'package:memora/data/services/attachment_store.dart';
import 'package:memora/data/services/image_understanding_service.dart';
import 'package:memora/data/services/hosted_ai_service.dart';
import 'package:memora/data/services/hosted_task_run_service.dart';
import 'package:memora/data/services/hosted_task_run_store.dart';
import 'package:memora/data/services/http_client.dart';
import 'package:memora/data/services/metadata_service.dart';
import 'package:memora/data/services/processing_pipeline.dart';
import 'package:memora/shared/providers/passage_providers.dart';

/// Helper to create an [AppHttpClient] backed by a [MockClient].
AppHttpClient mockHttp(Future<http.Response> Function(http.Request) handler) {
  return AppHttpClient(client: MockClient(handler));
}

/// Phase 1.4 service tests for [ProcessingPipeline].
///
/// Covers per-stage success/failure outcomes without hitting the network or
/// real Hive. Writes go through [ArticlesNotifier] backed by an in-memory
/// repository wired in via [ProviderContainer] overrides.
///
/// The AI summary success path requires HTTP-level stubbing of chat
/// completions and is intentionally out of scope here. The failure branch
/// ("AI not configured") is the deterministic, user-visible one and is
/// what these tests lock down.
void main() {
  late _InMemoryArticleRepository repo;
  late ProviderContainer container;

  setUp(() {
    repo = _InMemoryArticleRepository();
    container = ProviderContainer(
      overrides: [
        hiveInitProvider.overrideWith((ref) async {}),
        articleRepositoryProvider.overrideWith((ref) async => repo),
      ],
    );
  });

  tearDown(() => container.dispose());

  Article seedArticle({String id = 'p1'}) => Article(
    id: id,
    url: 'https://example.com/post',
    title: 'placeholder',
    source: SourcePlatform.web,
    processingStatus: ProcessingStatus.pending,
  );

  Future<ArticlesNotifier> seedAndGetNotifier(Article seed) async {
    await repo.add(seed);
    final notifier = container.read(articlesProvider.notifier);
    await container.read(articleRepositoryProvider.future);
    return notifier;
  }

  http.Response htmlResponse(String body) =>
      http.Response(body, 200, headers: {'content-type': 'text/html'});

  group('Stage 1: metadata', () {
    test('success applies og:title and og:image to the article', () async {
      const html =
          '<html><head>'
          '<meta property="og:title" content="Real Title" />'
          '<meta property="og:image" content="https://cdn.example.com/c.png" />'
          '</head></html>';
      final notifier = await seedAndGetNotifier(seedArticle());
      final pipeline = ProcessingPipeline(
        articles: notifier,
        getSettings: () => null,
        getFolders: () => const <Folder>[],
        metadata: MetadataService(
          http: mockHttp((_) async => htmlResponse(html)),
        ),
        extractor: ContentExtractor(
          http: mockHttp(
            (_) async => htmlResponse('<html><body><p>body</p></body></html>'),
          ),
        ),
      );

      final result = await pipeline.process(seedArticle());
      expect(result, isNotNull);
      expect(result!.title, 'Real Title');
      expect(result.coverImageUrl, 'https://cdn.example.com/c.png');
    });

    test('network failure is reported at the metadata stage', () async {
      final notifier = await seedAndGetNotifier(seedArticle());
      final pipeline = ProcessingPipeline(
        articles: notifier,
        getSettings: () => null,
        getFolders: () => const <Folder>[],
        metadata: MetadataService(
          http: mockHttp((_) async => throw Exception('dns failure')),
        ),
        extractor: ContentExtractor(
          http: mockHttp((_) async => http.Response('boom', 500)),
        ),
      );

      final result = await pipeline.process(seedArticle());
      expect(result, isNotNull);
      expect(result!.title, 'placeholder');
      expect(result.processingStatus, ProcessingStatus.failed);
      expect(result.processingError, startsWith('metadata:'));
    });
  });

  group('Stage 2: content extraction', () {
    test('HTTP non-200 marks the article failed at content stage', () async {
      final notifier = await seedAndGetNotifier(seedArticle());
      final pipeline = ProcessingPipeline(
        articles: notifier,
        getSettings: () => null,
        getFolders: () => const <Folder>[],
        metadata: MetadataService(
          http: mockHttp(
            (_) async =>
                htmlResponse('<html><head><title>X</title></head></html>'),
          ),
        ),
        extractor: ContentExtractor(
          http: mockHttp((_) async => http.Response('nope', 500)),
        ),
      );

      final result = await pipeline.process(seedArticle());
      expect(result, isNotNull);
      expect(result!.processingStatus, ProcessingStatus.failed);
      expect(result.processingError, startsWith('content:'));
      expect(result.lastProcessedAt, isNotNull);
    });

    test('empty body marks the article failed at content stage', () async {
      final notifier = await seedAndGetNotifier(seedArticle());
      final pipeline = ProcessingPipeline(
        articles: notifier,
        getSettings: () => null,
        getFolders: () => const <Folder>[],
        metadata: MetadataService(
          http: mockHttp(
            (_) async =>
                htmlResponse('<html><head><title>X</title></head></html>'),
          ),
        ),
        extractor: ContentExtractor(
          http: mockHttp(
            (_) async => htmlResponse('<html><body></body></html>'),
          ),
        ),
      );

      final result = await pipeline.process(seedArticle());
      expect(result, isNotNull);
      expect(result!.processingStatus, ProcessingStatus.failed);
      expect(result.processingError, contains('content:'));
    });
  });

  group('Stage 3: AI summary', () {
    test('failure when AI is not configured (empty base URL / key)', () async {
      final notifier = await seedAndGetNotifier(seedArticle());
      final pipeline = ProcessingPipeline(
        articles: notifier,
        getSettings: () => AppSettings(aiBaseUrl: '', aiApiKey: ''),
        getFolders: () => const <Folder>[],
        metadata: MetadataService(
          http: mockHttp(
            (_) async => htmlResponse(
              '<html><head><title>X</title></head>'
              '<body><article>$_longArticleText</article></body></html>',
            ),
          ),
        ),
        extractor: ContentExtractor(
          http: mockHttp((_) async => htmlResponse(_longArticleHtml)),
        ),
      );

      final result = await pipeline.process(seedArticle());
      expect(result, isNotNull);
      expect(result!.processingStatus, ProcessingStatus.failed);
      expect(result.processingError, startsWith('summary:'));
      expect(result.processingError, contains('not configured'));
    });

    test(
      'one AI request stores structured memory and generated tags',
      () async {
        final seed = seedArticle().copyWith(tags: ['stale-ai-tag']);
        final notifier = await seedAndGetNotifier(seed);
        final settings = AppSettings(
          aiBaseUrl: 'https://example.com/v1',
          aiApiKey: 'test-key',
          aiModel: 'test-model',
        );
        final pipeline = ProcessingPipeline(
          articles: notifier,
          getSettings: () => settings,
          aiGateway: AiService(
            baseUrl: settings.aiBaseUrl,
            apiKey: settings.aiApiKey,
            model: settings.aiModel,
          ),
          getFolders: () => const <Folder>[],
          metadata: MetadataService(
            http: mockHttp((_) async => htmlResponse(_longArticleHtml)),
          ),
          extractor: ContentExtractor(
            http: mockHttp((_) async => htmlResponse(_longArticleHtml)),
          ),
        );
        var aiRequests = 0;
        final aiClient = MockClient((_) async {
          aiRequests++;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': jsonEncode({
                      'schemaVersion': 1,
                      'title': 'Generated title',
                      'tags': ['AI tag', 'Agent SDK'],
                      'overview': 'Generated overview.',
                      'keyPoints': [
                        {
                          'topic': 'Handoff',
                          'content': 'Agents can delegate work.',
                        },
                      ],
                      'conclusion': 'Generated conclusion.',
                    }),
                  },
                },
              ],
            }),
            200,
          );
        });

        final result = await http.runWithClient(
          () => pipeline.process(seed),
          () => aiClient,
        );

        expect(
          aiRequests,
          1,
          reason: 'tags are returned by the summary request',
        );
        expect(result?.memory?.overview, 'Generated overview.');
        expect(result?.memory?.generation?.model, 'test-model');
        expect(result?.summary, isNull);
        expect(result?.tags, ['AI tag', 'Agent SDK']);
        expect(result?.processingStatus, ProcessingStatus.completed);
      },
    );

    test('hosted summary persists every structured v4 final field', () async {
      final seed = seedArticle(
        id: 'hosted-summary',
      ).copyWith(tags: ['Keep me'], suggestedFolderId: 'stale-folder');
      final notifier = await seedAndGetNotifier(seed);
      final tasks = _PipelineTaskGateway();
      final hosted = HostedAiService(
        getSession: () => null,
        refreshSession: () async => null,
        model: 'mimo-v2.5-pro',
        purpose: HostedAiPurpose.summary,
        taskGateway: tasks,
      );
      final pipeline = ProcessingPipeline(
        articles: notifier,
        getSettings: () => AppSettings(languageIndex: 2),
        getFolders: () => const <Folder>[],
        aiGateway: hosted,
      );

      final first = await pipeline.processFile(seed, 'Stable article body.');

      expect(first?.title, 'Generated title');
      expect(first?.memory?.overview, 'Structured overview');
      expect(first?.memory?.keyPoints, hasLength(1));
      expect(first?.memory?.keyPoints.single.topic, 'Runtime');
      expect(first?.memory?.keyPoints.single.content, 'Pi runs the task.');
      expect(first?.memory?.conclusion, 'Structured conclusion');
      expect(first?.tags, ['Keep me', 'Pi']);
      expect(first?.suggestedFolderId, isNull);
      expect(first?.hostedTaskGeneration, isNull);
      expect(first?.memory?.generation?.promptVersion, 'pi-summary-v1');
      expect(tasks.calls.map((call) => call.profile), [
        HostedTaskProfile.summaryChunk,
        HostedTaskProfile.summaryFinal,
        HostedTaskProfile.memoryTags,
        HostedTaskProfile.memoryFolder,
      ]);
      expect(
        tasks.calls.where(
          (call) => call.profile == HostedTaskProfile.memoryTags,
        ),
        hasLength(1),
      );
      expect(
        tasks.calls.take(4).map((call) => call.operation?.generation).toSet(),
        hasLength(1),
      );
      expect(tasks.calls.take(4).map((call) => call.operation?.stage), [
        'summary.chunk.0',
        'summary.final',
        'memory.tags',
        'memory.folder',
      ]);

      final replay = await pipeline.processFile(seed, 'Stable article body.');

      expect(replay?.memory?.keyPoints, hasLength(1));
      expect(tasks.calls.map((call) => call.profile), [
        HostedTaskProfile.summaryChunk,
        HostedTaskProfile.summaryFinal,
        HostedTaskProfile.memoryTags,
        HostedTaskProfile.memoryFolder,
        HostedTaskProfile.summaryChunk,
        HostedTaskProfile.summaryFinal,
        HostedTaskProfile.memoryTags,
        HostedTaskProfile.memoryFolder,
      ]);
      expect(
        tasks.calls.where(
          (call) => call.profile == HostedTaskProfile.memoryTags,
        ),
        hasLength(2),
      );
      for (var index = 0; index < 4; index++) {
        expect(
          tasks.calls[index].idempotencyKey,
          isNot(tasks.calls[index + 4].idempotencyKey),
        );
      }
      expect(
        tasks.calls.first.operation?.generation,
        isNot(tasks.calls[4].operation?.generation),
      );
    });
  });

  group('Retry semantics', () {
    test('retry bumps retryCount and re-runs from scratch', () async {
      final notifier = await seedAndGetNotifier(seedArticle());
      final pipeline = ProcessingPipeline(
        articles: notifier,
        getSettings: () => null,
        getFolders: () => const <Folder>[],
        metadata: MetadataService(
          http: mockHttp(
            (_) async =>
                htmlResponse('<html><head><title>X</title></head></html>'),
          ),
        ),
        extractor: ContentExtractor(
          http: mockHttp((_) async => http.Response('nope', 500)),
        ),
      );

      final failed = await pipeline.process(seedArticle());
      expect(failed!.processingStatus, ProcessingStatus.failed);
      expect(failed.retryCount, 0);

      final retried = await pipeline.retry(failed);
      expect(retried, isNotNull);
      expect(retried!.retryCount, 1);
      expect(retried.processingStatus, ProcessingStatus.failed);
      expect(retried.processingError, startsWith('content:'));
    });

    test(
      'rotating a dead hosted generation deletes its old side metadata',
      () async {
        final failed = seedArticle().copyWith(
          processingStatus: ProcessingStatus.failed,
          processingError: 'summary: invalid task result',
          hostedTaskGeneration: 'dead-generation',
        );
        final notifier = await seedAndGetNotifier(failed);
        final store = _RotationTrackingTaskRunStore();
        final tasks = HostedTaskRunService(
          getSession: _pipelineAuthSession,
          refreshSession: () async => null,
          model: 'mimo-v2.5-pro',
          maxBodyBytes: 1024 * 1024,
          runStore: store,
        );
        final hosted = HostedAiService(
          getSession: _pipelineAuthSession,
          refreshSession: () async => null,
          model: 'mimo-v2.5-pro',
          purpose: HostedAiPurpose.summary,
          taskGateway: tasks,
        );
        final pipeline = ProcessingPipeline(
          articles: notifier,
          getSettings: () => AppSettings(languageIndex: 2),
          getFolders: () => const <Folder>[],
          aiGateway: hosted,
          metadata: MetadataService(
            http: mockHttp(
              (_) async => htmlResponse('<html><title>X</title></html>'),
            ),
          ),
          extractor: ContentExtractor(
            http: mockHttp((_) async => http.Response('unavailable', 500)),
          ),
        );

        final result = await pipeline.retry(failed);

        expect(store.finalized, ['p1::dead-generation']);
        expect(result?.hostedTaskGeneration, isNot('dead-generation'));
      },
    );
  });

  group('Durable resume semantics', () {
    test(
      'resume preserves a queued full-text job instead of converting it to an AI memory',
      () async {
        final queued = seedArticle().copyWith(
          isFullText: true,
          processingStatus: ProcessingStatus.processing,
          processingStage: ProcessingStage.content,
        );
        final notifier = await seedAndGetNotifier(queued);
        final pipeline = ProcessingPipeline(
          articles: notifier,
          getSettings: () => AppSettings(),
          getFolders: () => const <Folder>[],
          metadata: MetadataService(
            http: mockHttp((_) async => htmlResponse(_longArticleHtml)),
          ),
          extractor: ContentExtractor(
            http: mockHttp((_) async => htmlResponse(_longArticleHtml)),
          ),
        );

        final result = await pipeline.resume(queued);

        expect(result?.processingStatus, ProcessingStatus.completed);
        expect(result?.isFullText, isTrue);
        expect(
          result?.memory?.body,
          contains('sufficiently long article body'),
        );
      },
    );

    test('late stage writes cannot overwrite the completed state', () async {
      final delayedRepo = _InMemoryArticleRepository(
        delayedStage: ProcessingStage.content,
        updateDelay: const Duration(milliseconds: 50),
      );
      final delayedContainer = ProviderContainer(
        overrides: [
          hiveInitProvider.overrideWith((ref) async {}),
          articleRepositoryProvider.overrideWith((ref) async => delayedRepo),
        ],
      );
      addTearDown(delayedContainer.dispose);

      final seed = seedArticle();
      await delayedRepo.add(seed);
      final notifier = delayedContainer.read(articlesProvider.notifier);
      await delayedContainer.read(articleRepositoryProvider.future);
      final pipeline = ProcessingPipeline(
        articles: notifier,
        getSettings: () => AppSettings(),
        getFolders: () => const <Folder>[],
        metadata: MetadataService(
          http: mockHttp((_) async => htmlResponse(_longArticleHtml)),
        ),
        extractor: ContentExtractor(
          http: mockHttp((_) async => htmlResponse(_longArticleHtml)),
        ),
      );

      final result = await pipeline.processFullText(seed);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final persisted = delayedRepo.getById(seed.id);

      expect(result?.processingStatus, ProcessingStatus.completed);
      expect(persisted?.processingStatus, ProcessingStatus.completed);
      expect(persisted?.processingStage, isNull);
    });
  });

  group('Stage 4 & 5: tags and folder suggestion recovery', () {
    test(
      'failed summary short-circuits the pipeline — no tags or folder suggestion',
      () async {
        // When the summary stage fails the pipeline returns immediately;
        // tags and folder suggestion never run, so neither field is written.
        final notifier = await seedAndGetNotifier(seedArticle());
        final pipeline = ProcessingPipeline(
          articles: notifier,
          getSettings: () => AppSettings(aiBaseUrl: '', aiApiKey: ''),
          getFolders: () => const <Folder>[],
          metadata: MetadataService(
            http: mockHttp(
              (_) async => htmlResponse(
                '<html><head><title>X</title></head>'
                '<body><article>$_longArticleText</article></body></html>',
              ),
            ),
          ),
          extractor: ContentExtractor(
            http: mockHttp((_) async => htmlResponse(_longArticleHtml)),
          ),
        );

        final result = await pipeline.process(seedArticle());
        expect(result!.processingStatus, ProcessingStatus.failed);
        expect(result.tags, isEmpty);
        expect(result.suggestedFolderId, isNull);
      },
    );

    test('hosted folder task writes only a confirmable suggestion', () async {
      final seed = seedArticle(id: 'hosted-folder');
      final notifier = await seedAndGetNotifier(seed);
      final tasks = _PipelineTaskGateway();
      final hosted = HostedAiService(
        getSession: () => null,
        refreshSession: () async => null,
        model: 'mimo-v2.5-pro',
        purpose: HostedAiPurpose.summary,
        taskGateway: tasks,
      );
      final pipeline = ProcessingPipeline(
        articles: notifier,
        getSettings: () => AppSettings(languageIndex: 2),
        getFolders: () => [Folder(id: 'folder-ai', name: 'AI')],
        aiGateway: hosted,
      );

      final first = await pipeline.processFile(
        seed,
        'Stable full text for hosted task classification.',
        fullText: true,
      );
      final replay = await pipeline.processFile(
        seed,
        'Stable full text for hosted task classification.',
        fullText: true,
      );

      expect(first?.folderId, isNull);
      expect(first?.suggestedFolderId, 'folder-ai');
      expect(replay?.folderId, isNull);
      expect(replay?.suggestedFolderId, 'folder-ai');
      expect(tasks.calls.map((call) => call.profile), [
        HostedTaskProfile.memoryTags,
        HostedTaskProfile.memoryFolder,
        HostedTaskProfile.memoryTags,
        HostedTaskProfile.memoryFolder,
      ]);
      expect(
        tasks.calls[0].idempotencyKey,
        isNot(tasks.calls[2].idempotencyKey),
      );
      expect(
        tasks.calls[1].idempotencyKey,
        isNot(tasks.calls[3].idempotencyKey),
      );
      expect(
        tasks.calls.every(
          (call) => !call.idempotencyKey.contains('Stable full text'),
        ),
        isTrue,
      );
    });

    test(
      'hosted task failures retain the generation for durable retry',
      () async {
        final seed = seedArticle(id: 'hosted-tags-failure');
        final notifier = await seedAndGetNotifier(seed);
        final tasks = _PipelineTaskGateway(
          failureProfile: HostedTaskProfile.memoryTags,
        );
        final hosted = HostedAiService(
          getSession: () => null,
          refreshSession: () async => null,
          model: 'mimo-v2.5-pro',
          purpose: HostedAiPurpose.summary,
          taskGateway: tasks,
        );
        final pipeline = ProcessingPipeline(
          articles: notifier,
          getSettings: () => AppSettings(languageIndex: 2),
          getFolders: () => [Folder(id: 'folder-ai', name: 'AI')],
          aiGateway: hosted,
        );

        final result = await pipeline.processFile(
          seed,
          'Stable full text for hosted task classification.',
          fullText: true,
        );

        expect(result?.processingStatus, ProcessingStatus.failed);
        expect(result?.processingError, startsWith('tags:'));
        expect(result?.processingError, contains('task_observation_timeout'));
        expect(result?.hostedTaskGeneration, isNotNull);
        expect(tasks.calls.map((call) => call.profile), [
          HostedTaskProfile.memoryTags,
        ]);
      },
    );

    test(
      'retryable hosted folder observation retains the generation',
      () async {
        final seed = seedArticle(id: 'hosted-folder-retryable');
        final notifier = await seedAndGetNotifier(seed);
        final tasks = _PipelineTaskGateway(
          failureProfile: HostedTaskProfile.memoryFolder,
        );
        final hosted = HostedAiService(
          getSession: () => null,
          refreshSession: () async => null,
          model: 'mimo-v2.5-pro',
          purpose: HostedAiPurpose.summary,
          taskGateway: tasks,
        );
        final pipeline = ProcessingPipeline(
          articles: notifier,
          getSettings: () => AppSettings(languageIndex: 2),
          getFolders: () => [Folder(id: 'folder-ai', name: 'AI')],
          aiGateway: hosted,
        );

        final result = await pipeline.processFile(
          seed,
          'Stable full text for hosted task classification.',
          fullText: true,
        );

        expect(result?.processingStatus, ProcessingStatus.failed);
        expect(result?.processingError, startsWith('folder:'));
        expect(result?.hostedTaskGeneration, isNotNull);
        expect(tasks.calls.map((call) => call.profile), [
          HostedTaskProfile.memoryTags,
          HostedTaskProfile.memoryFolder,
        ]);
      },
    );

    test('terminal hosted folder failure stays optional', () async {
      final seed = seedArticle(id: 'hosted-folder-terminal');
      final notifier = await seedAndGetNotifier(seed);
      final tasks = _PipelineTaskGateway(
        failureProfile: HostedTaskProfile.memoryFolder,
        failureRetryable: false,
      );
      final hosted = HostedAiService(
        getSession: () => null,
        refreshSession: () async => null,
        model: 'mimo-v2.5-pro',
        purpose: HostedAiPurpose.summary,
        taskGateway: tasks,
      );
      final pipeline = ProcessingPipeline(
        articles: notifier,
        getSettings: () => AppSettings(languageIndex: 2),
        getFolders: () => [Folder(id: 'folder-ai', name: 'AI')],
        aiGateway: hosted,
      );

      final result = await pipeline.processFile(
        seed,
        'Stable full text for hosted task classification.',
        fullText: true,
      );

      expect(result?.processingStatus, ProcessingStatus.completed);
      expect(result?.processingError, isNull);
      expect(result?.hostedTaskGeneration, isNull);
      expect(result?.suggestedFolderId, isNull);
    });
  });

  group('Shared resilient page load', () {
    test('metadata and content stages reuse one fetched page', () async {
      final notifier = await seedAndGetNotifier(seedArticle());
      final loader = _CountingPageLoader(
        FetchedPage(
          statusCode: 200,
          contentType: 'text/html',
          body:
              '<html><head><title>One Fetch</title></head>'
              '<body><article>$_longArticleText</article></body></html>',
          finalUrl: 'https://example.com/final',
          source: PageLoadSource.webView,
        ),
      );
      final pipeline = ProcessingPipeline(
        articles: notifier,
        getSettings: () => AppSettings(aiBaseUrl: '', aiApiKey: ''),
        getFolders: () => const <Folder>[],
        metadata: MetadataService(loader: loader, ownsLoader: false),
        extractor: ContentExtractor(loader: loader, ownsLoader: false),
      );

      final result = await pipeline.process(seedArticle());

      expect(loader.fetchCount, 1);
      expect(result!.title, 'One Fetch');
      expect(result.processingError, startsWith('summary:'));
      pipeline.dispose();
      loader.dispose();
    });

    test('verification page fails before the MiMo stage', () async {
      final notifier = await seedAndGetNotifier(seedArticle());
      final loader = _CountingPageLoader(
        const FetchedPage(
          statusCode: 200,
          contentType: 'text/html',
          body:
              '<html><head><title>安全验证</title></head>'
              '<body>请输入验证码后继续访问</body></html>',
          finalUrl: 'https://example.com/verify',
          source: PageLoadSource.webView,
        ),
      );
      final pipeline = ProcessingPipeline(
        articles: notifier,
        getSettings: () => AppSettings(
          aiBaseUrl: 'https://should-not-be-called.example/v1',
          aiApiKey: 'unused',
        ),
        getFolders: () => const <Folder>[],
        metadata: MetadataService(loader: loader, ownsLoader: false),
        extractor: ContentExtractor(loader: loader, ownsLoader: false),
      );

      final result = await pipeline.process(seedArticle());

      expect(loader.fetchCount, 1);
      expect(result!.processingError, startsWith('content:'));
      pipeline.dispose();
      loader.dispose();
    });
  });

  group('Image understanding stage', () {
    test(
      'full-text image memory persists result and reuses it on retry',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'memora-pipeline-image-',
        );
        final image = File('${temp.path}/image.jpg');
        await image.writeAsBytes([1, 2, 3, 4]);
        final attachment = _imageAttachment(image.path);
        final article = Article(
          id: 'image-full-text',
          url: 'local-images://image-full-text',
          title: 'Image',
          source: SourcePlatform.local,
          attachments: [attachment],
          isFullText: true,
          processingStatus: ProcessingStatus.pending,
        );
        final notifier = await seedAndGetNotifier(article);
        final gateway = _FakeImageUnderstandingGateway();
        final pipeline = ProcessingPipeline(
          articles: notifier,
          getSettings: () => null,
          getFolders: () => const <Folder>[],
          imageUnderstanding: gateway,
          attachmentStore: _FakeAttachmentStore(image),
        );

        try {
          final first = await pipeline.processImages(article);
          expect(first, isNotNull);
          expect(first!.processingStatus, ProcessingStatus.completed);
          expect(first.memory?.kind, MemoryKind.fullText);
          expect(first.memory?.body, contains('完整图片内容'));
          expect(first.memory?.generation?.method, 'image_understanding');
          expect(first.imageUnderstanding?.requestId, 'request-1');
          expect(gateway.calls, 1);

          final second = await pipeline.processImages(first);
          expect(second?.processingStatus, ProcessingStatus.completed);
          expect(gateway.calls, 1);
        } finally {
          pipeline.dispose();
          await temp.delete(recursive: true);
        }
      },
    );

    test(
      'AI-memory failure keeps understanding result for later retry',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'memora-pipeline-image-',
        );
        final image = File('${temp.path}/image.jpg');
        await image.writeAsBytes([1, 2, 3, 4]);
        final attachment = _imageAttachment(image.path);
        final article = Article(
          id: 'image-ai-memory',
          url: 'local-images://image-ai-memory',
          title: 'Image',
          source: SourcePlatform.local,
          attachments: [attachment],
          processingStatus: ProcessingStatus.pending,
        );
        final notifier = await seedAndGetNotifier(article);
        final gateway = _FakeImageUnderstandingGateway();
        final pipeline = ProcessingPipeline(
          articles: notifier,
          getSettings: () => null,
          getFolders: () => const <Folder>[],
          imageUnderstanding: gateway,
          attachmentStore: _FakeAttachmentStore(image),
        );

        try {
          final first = await pipeline.processImages(article);
          expect(first?.processingStatus, ProcessingStatus.failed);
          expect(first?.processingError, startsWith('summary:'));
          expect(first?.imageUnderstanding?.requestId, 'request-1');
          expect(gateway.calls, 1);

          final retried = await pipeline.retry(first!);
          expect(retried?.processingStatus, ProcessingStatus.failed);
          expect(retried?.imageUnderstanding?.requestId, 'request-1');
          expect(gateway.calls, 1);
        } finally {
          pipeline.dispose();
          await temp.delete(recursive: true);
        }
      },
    );
  });
}

/// Tiny in-memory [ArticleRepository] for service-level tests — no Hive.
class _InMemoryArticleRepository implements ArticleRepository {
  final List<Article> _articles = [];
  final ProcessingStage? delayedStage;
  final Duration updateDelay;

  _InMemoryArticleRepository({
    this.delayedStage,
    this.updateDelay = Duration.zero,
  });

  @override
  Future<void> init() async {}

  @override
  List<Article> getAll() =>
      List<Article>.of(_articles)
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  Article? getById(String id) {
    for (final a in _articles) {
      if (a.id == id) return a;
    }
    return null;
  }

  @override
  Future<void> add(Article article) async => _articles.add(article);

  @override
  Future<int> importAll(Iterable<Article> articles) async {
    _articles.addAll(articles);
    return articles.length;
  }

  @override
  Future<void> update(Article article) async {
    if (article.processingStage == delayedStage &&
        updateDelay > Duration.zero) {
      await Future<void>.delayed(updateDelay);
    }
    final i = _articles.indexWhere((a) => a.id == article.id);
    if (i >= 0) {
      _articles[i] = article;
    } else {
      _articles.add(article);
    }
  }

  @override
  Future<void> delete(String id) async =>
      _articles.removeWhere((a) => a.id == id);

  @override
  List<Article> search(String query) => getAll();

  @override
  List<Article> filterBySource(String sourceName) => getAll();

  @override
  Future<void> unsetFolder(String folderId) async {}

  @override
  Future<void> unsetFolderBatch(String folderId) async {}
}

/// HTML body whose <article> text exceeds 200 chars so [ContentExtractor]
/// returns a real (non-null) string and the pipeline advances to the summary
/// stage. The repetition is intentional — it's the deterministic way to clear
/// the extractor's length threshold without writing fake prose.
const String _longArticleText =
    'This is a sufficiently long article body for the content extractor to '
    'consider it real prose. It needs to exceed two hundred characters so '
    'the extractor returns a non-null string and the pipeline proceeds past '
    'the content stage into the summary stage, where we assert the AI-not-'
    'configured failure. Padding padding padding padding padding padding.';

const String _longArticleHtml =
    '<html><body><article>$_longArticleText</article></body></html>';

class _CountingPageLoader implements PageLoader {
  final FetchedPage? page;
  int fetchCount = 0;
  bool disposed = false;

  _CountingPageLoader(this.page);

  @override
  Future<FetchedPage?> fetch(
    String url, {
    PageLoadRequirement requirement = PageLoadRequirement.usableContent,
  }) async {
    fetchCount++;
    return page;
  }

  @override
  void dispose() {
    disposed = true;
  }
}

ArticleAttachment _imageAttachment(String path) {
  return ArticleAttachment(
    id: 'attachment-1',
    order: 0,
    localPath: path,
    mimeType: 'image/jpeg',
    originalFileName: 'image.jpg',
    byteLength: 4,
    sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  );
}

class _FakeAttachmentStore extends AttachmentStore {
  final File file;

  _FakeAttachmentStore(this.file);

  @override
  Future<File?> resolve(String? relativePath) async => file;
}

class _FakeImageUnderstandingGateway implements ImageUnderstandingGateway {
  int calls = 0;

  @override
  Future<ImageUnderstandingDocument> understand({
    required String articleId,
    required List<ImageUnderstandingUpload> images,
    required String locale,
  }) async {
    calls++;
    final attachment = images.single.attachment;
    return ImageUnderstandingDocument(
      requestId: 'request-1',
      provider: 'sensenova',
      model: 'sensenova-6.7-flash-lite',
      promptVersion: imageUnderstandingPromptVersion,
      generatedAt: DateTime.utc(2026, 8, 1),
      sourceImages: [
        ImageUnderstandingSourceImage(
          attachmentId: attachment.id,
          order: attachment.order,
          sha256: attachment.sha256,
        ),
      ],
      suggestedTitle: '',
      documentType: 'screenshot',
      pages: [
        ImageUnderstandingPage(
          attachmentId: attachment.id,
          order: attachment.order,
          transcriptionMarkdown: '完整图片内容',
          visualDescription: 'Screenshot',
        ),
      ],
      combinedMarkdown: '# 图片转写\n\n完整图片内容',
    );
  }
}

class _RotationTrackingTaskRunStore implements HostedTaskRunStore {
  final List<String> finalized = [];

  @override
  Future<HostedTaskRunBinding?> readBinding(
    String scopeHash,
    String idempotencyKey,
  ) async => null;

  @override
  Future<HostedTaskRunBinding?> readBindingForOperation({
    required String scopeHash,
    required String articleId,
    required String generation,
    required String stage,
  }) async => null;

  @override
  Future<void> writeBinding(
    String scopeHash,
    HostedTaskRunBinding binding,
  ) async {}

  @override
  Future<bool> recordTokenUsage(
    String scopeHash,
    String runId,
    int totalTokens,
  ) async => true;

  @override
  Future<bool> hasReplayableBindings({
    required String scopeHash,
    required String articleId,
    required String generation,
  }) async => false;

  @override
  Future<void> finalizeGeneration({
    required String scopeHash,
    required String articleId,
    required String generation,
  }) async {
    finalized.add('$articleId::$generation');
  }

  @override
  Future<void> close() async {}
}

AuthSession _pipelineAuthSession() {
  final payload = base64Url.encode(
    utf8.encode(
      jsonEncode({
        'sessionId': '11111111-1111-4111-8111-111111111111',
        'deviceId': '22222222-2222-4222-8222-222222222222',
      }),
    ),
  );
  return AuthSession(
    accessToken: 'header.${payload.replaceAll('=', '')}.signature',
    refreshToken: 'refresh',
    refreshTokenExpiresAt: null,
    user: const AuthUser(
      id: 'user-1',
      email: 'user@example.com',
      displayName: null,
      status: 'active',
      plan: 'free',
      storageUsedBytes: '0',
    ),
    device: const AuthDevice(
      id: 'device-1',
      userId: 'user-1',
      deviceName: 'test',
      platform: 'test',
      appVersion: '1.0.0',
    ),
  );
}

class _PipelineTaskCall {
  final HostedTaskProfile profile;
  final Map<String, dynamic> input;
  final String idempotencyKey;
  final HostedTaskOperationContext? operation;

  const _PipelineTaskCall(
    this.profile,
    this.input,
    this.idempotencyKey,
    this.operation,
  );
}

class _PipelineTaskGateway implements HostedTaskGateway {
  final List<_PipelineTaskCall> calls = [];
  final HostedTaskProfile? failureProfile;
  final bool failureRetryable;

  _PipelineTaskGateway({this.failureProfile, this.failureRetryable = true});

  @override
  Future<HostedTaskRunResult> run({
    required HostedTaskProfile profile,
    required Map<String, dynamic> input,
    required String idempotencyKey,
    HostedTaskOperationContext? operation,
  }) async {
    calls.add(_PipelineTaskCall(profile, input, idempotencyKey, operation));
    if (profile == failureProfile) {
      throw HostedTaskRunException(
        code: 'task_observation_timeout',
        message: 'Resume this hosted task later.',
        retryable: failureRetryable,
      );
    }
    final Map<String, dynamic> result = switch (profile) {
      HostedTaskProfile.summaryChunk => {
        'schemaVersion': 1,
        'summaryMarkdown': 'Chunk summary',
      },
      HostedTaskProfile.summaryFinal => {
        'schemaVersion': 1,
        'title': 'Generated title',
        'overview': 'Structured overview',
        'keyPoints': [
          {'topic': 'Runtime', 'content': 'Pi runs the task.'},
        ],
        'conclusion': 'Structured conclusion',
      },
      HostedTaskProfile.memoryTags => {
        'schemaVersion': 1,
        'tags': ['Pi'],
      },
      HostedTaskProfile.memoryFolder => {
        'schemaVersion': 1,
        'folderId': (input['folders'] as List).isEmpty ? null : 'folder-ai',
        'reason': 'Best match',
      },
      _ => throw StateError('Unexpected task profile: $profile'),
    };
    return HostedTaskRunResult(
      runId: 'run-${calls.length}',
      profile: profile,
      profileVersion: 1,
      resultSchemaVersion: 1,
      result: result,
    );
  }
}
