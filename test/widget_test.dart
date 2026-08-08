import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:memora/app.dart';
import 'package:memora/shared/providers/filter_providers.dart';
import 'package:memora/shared/providers/home_navigation_provider.dart';
import 'package:memora/shared/providers/passage_providers.dart';
import 'package:memora/shared/providers/settings_providers.dart';

void main() {
  testWidgets('App renders shell with navigation', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [languageIndexProvider.overrideWith((ref) => 2)],
        child: const App(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    // The bottom navigation bar should have all 4 tabs.
    expect(find.text('Recall'), findsAtLeastNWidgets(1));
    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('Progress'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    // Recall appears in both AppBar title and NavigationBar label.
    expect(find.text('Recall'), findsAtLeastNWidgets(1));
  });

  testWidgets('double tapping Memory requests the knowledge list top', (
    WidgetTester tester,
  ) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [languageIndexProvider.overrideWith((ref) => 2)],
        child: const App(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(App)),
    );
    final navigationBarRect = tester.getRect(find.byType(NavigationBar));
    final memoryButtonCenter = Offset(
      navigationBarRect.left + navigationBarRect.width * 0.375,
      navigationBarRect.center.dy,
    );
    await tester.tapAt(memoryButtonCenter);
    await tester.pump();
    container.read(selectedSourceProvider.notifier).state = 'youtube';
    container.read(selectedFilterGroupProvider.notifier).state = 'custom';
    container.read(selectedFolderIdProvider.notifier).state = 'folder';
    await tester.pump();
    await tester.tapAt(memoryButtonCenter);
    await tester.pump();

    expect(container.read(homeScrollToTopRequestProvider), 1);
    expect(container.read(selectedSourceProvider), isEmpty);
    expect(container.read(selectedFilterGroupProvider), isEmpty);
    expect(container.read(selectedFolderIdProvider), isEmpty);
  });
}
