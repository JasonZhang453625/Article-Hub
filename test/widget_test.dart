import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:article_hub/app.dart';

void main() {
  testWidgets('App renders shell with navigation', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: App()));
    await tester.pump(const Duration(milliseconds: 400));

    // The bottom navigation bar should have all 4 tabs.
    expect(find.text('Knowledge'), findsOneWidget);
    expect(find.text('Inbox'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    // "Chat" appears in both AppBar title and NavigationBar label.
    expect(find.text('Chat'), findsAtLeastNWidgets(1));
  });
}
