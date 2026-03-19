import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:article_hub/app.dart';

void main() {
  testWidgets('App renders home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: App()));
    // Don't use pumpAndSettle as async providers can take time
    await tester.pump();

    expect(find.text('Article-Hub'), findsOneWidget);
  });
}
