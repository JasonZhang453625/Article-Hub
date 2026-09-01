import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'package:memora/data/models/passage.dart';
import 'package:memora/data/repositories/article_repository.dart';
import 'package:memora/features/shell/share_handler.dart';
import 'package:memora/features/shell/share_save_sheet.dart';
import 'package:memora/shared/providers/article_providers.dart';
import 'package:memora/shared/providers/settings_providers.dart';

void main() {
  testWidgets('initial and warm links are reset and presented in order', (
    tester,
  ) async {
    final mediaStream = StreamController<List<SharedMediaFile>>.broadcast(
      sync: true,
    );
    addTearDown(mediaStream.close);
    ReceiveSharingIntent.setMockValues(
      initialMedia: [
        SharedMediaFile(
          path: 'https://example.com/initial',
          type: SharedMediaType.text,
          mimeType: 'text/plain',
        ),
      ],
      mediaStream: mediaStream.stream,
    );
    final repositoryGate = Completer<ArticleRepository>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          languageIndexProvider.overrideWithValue(1),
          articleRepositoryProvider.overrideWith(
            (ref) => repositoryGate.future,
          ),
          articlesProvider.overrideWith((ref) => _TestArticlesNotifier(ref)),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: ShareHandler(receiveIntents: true, child: SizedBox.expand()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<ShareSaveSheet>(find.byType(ShareSaveSheet)).url,
      'https://example.com/initial',
    );
    expect(
      await ReceiveSharingIntent.instance.getInitialMedia(),
      isEmpty,
      reason: 'consumed cold-start intents must be reset',
    );

    mediaStream.add([
      SharedMediaFile(
        path: 'https://example.com/warm',
        type: SharedMediaType.text,
        mimeType: 'text/plain',
      ),
    ]);
    await tester.pump();

    // The warm share waits instead of being discarded while the first sheet
    // is still open.
    expect(
      tester.widget<ShareSaveSheet>(find.byType(ShareSaveSheet)).url,
      'https://example.com/initial',
    );

    Navigator.of(tester.element(find.byType(ShareSaveSheet))).pop();
    await tester.pumpAndSettle();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      tester.widget<ShareSaveSheet>(find.byType(ShareSaveSheet)).url,
      'https://example.com/warm',
    );
  });

  testWidgets('a link received in the background waits until resume', (
    tester,
  ) async {
    final mediaStream = StreamController<List<SharedMediaFile>>.broadcast(
      sync: true,
    );
    addTearDown(mediaStream.close);
    ReceiveSharingIntent.setMockValues(
      initialMedia: const [],
      mediaStream: mediaStream.stream,
    );
    final repositoryGate = Completer<ArticleRepository>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          languageIndexProvider.overrideWithValue(1),
          articleRepositoryProvider.overrideWith(
            (ref) => repositoryGate.future,
          ),
          articlesProvider.overrideWith((ref) => _TestArticlesNotifier(ref)),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: ShareHandler(receiveIntents: true, child: SizedBox.expand()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    mediaStream.add([
      SharedMediaFile(
        path: 'https://example.com/resumed',
        type: SharedMediaType.text,
        mimeType: 'text/plain',
      ),
    ]);
    await tester.pump();
    expect(find.byType(ShareSaveSheet), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(
      tester.widget<ShareSaveSheet>(find.byType(ShareSaveSheet)).url,
      'https://example.com/resumed',
    );
  });
}

class _TestArticlesNotifier extends ArticlesNotifier {
  _TestArticlesNotifier(super.ref) {
    state = const AsyncValue<List<Article>>.data([]);
  }
}
