import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:memora/app.dart';

void main() {
  testWidgets('App renders shell with navigation', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: App()));
    await tester.pump(const Duration(milliseconds: 400));

    // The bottom navigation bar should have all 4 tabs.
    expect(find.text('Memora'), findsAtLeastNWidgets(1));
    expect(find.text('Progress'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    // "Chat" appears in both AppBar title and NavigationBar label.
    expect(find.text('Chat'), findsAtLeastNWidgets(1));
  });
}
