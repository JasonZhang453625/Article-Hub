import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:memora/app.dart';
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
}
