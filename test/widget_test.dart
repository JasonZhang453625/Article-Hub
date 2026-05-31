import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:article_hub/app.dart';

void main() {
  testWidgets('App renders home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: App()));
    await tester.pump(const Duration(milliseconds: 400));

    // The "Add" FAB and the search field are stable elements of the home screen.
    expect(find.text('Add'), findsOneWidget);
    expect(find.text('Search articles, tags or notes...'), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
  });
}
