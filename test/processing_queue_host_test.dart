import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/data/services/ai_service.dart';
import 'package:memora/data/services/processing_queue.dart';
import 'package:memora/shared/providers/ai_providers.dart';
import 'package:memora/shared/providers/pipeline_provider.dart';
import 'package:memora/shared/widgets/processing_queue_host.dart';

void main() {
  Article pendingArticle() => Article(
    id: 'pending',
    url: 'https://example.com/pending',
    title: 'Pending',
    source: SourcePlatform.web,
    processingStatus: ProcessingStatus.pending,
  );

  testWidgets('resumes pending work when the hosted gateway becomes ready', (
    tester,
  ) async {
    final gatewayState = StateProvider<AiGateway?>((ref) => null);
    final records = <String, Article>{'pending': pendingArticle()};
    var gatewayReady = false;
    var runs = 0;
    final queue = ProcessingQueue(
      getArticles: () => records.values.toList(),
      save: (article) async => records[article.id] = article,
      prepareRetry: (article) async => article,
      canProcess: (_) => gatewayReady,
      process: (article) async {
        runs++;
        final completed = article.copyWith(
          processingStatus: ProcessingStatus.completed,
        );
        records[article.id] = completed;
        return completed;
      },
    );
    final container = ProviderContainer(
      overrides: [
        processingQueueProvider.overrideWithValue(queue),
        summaryAiGatewayProvider.overrideWith((ref) => ref.watch(gatewayState)),
        imageUnderstandingServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ProcessingQueueHost(child: SizedBox()),
      ),
    );
    await tester.pump();
    await queue.whenIdle;
    expect(runs, 0);

    gatewayReady = true;
    container.read(gatewayState.notifier).state = AiService(
      baseUrl: 'https://example.com',
      apiKey: 'test-key',
      model: 'test-model',
    );
    await tester.pump();
    await queue.whenIdle;

    expect(runs, 1);
    expect(records['pending']!.processingStatus, ProcessingStatus.completed);
  });

  testWidgets('rescans pending work when the app returns to the foreground', (
    tester,
  ) async {
    final records = <String, Article>{'pending': pendingArticle()};
    var ready = false;
    var runs = 0;
    final queue = ProcessingQueue(
      getArticles: () => records.values.toList(),
      save: (article) async => records[article.id] = article,
      prepareRetry: (article) async => article,
      canProcess: (_) => ready,
      process: (article) async {
        runs++;
        final completed = article.copyWith(
          processingStatus: ProcessingStatus.completed,
        );
        records[article.id] = completed;
        return completed;
      },
    );
    final container = ProviderContainer(
      overrides: [
        processingQueueProvider.overrideWithValue(queue),
        summaryAiGatewayProvider.overrideWithValue(null),
        imageUnderstandingServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ProcessingQueueHost(child: SizedBox()),
      ),
    );
    await tester.pump();
    await queue.whenIdle;
    expect(runs, 0);

    ready = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await queue.whenIdle;

    expect(runs, 1);
    expect(records['pending']!.processingStatus, ProcessingStatus.completed);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await queue.whenIdle;
    expect(runs, 1);
  });
}
