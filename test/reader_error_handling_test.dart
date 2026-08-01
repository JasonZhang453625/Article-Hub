import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memora/features/reader/reader_screen.dart';

void main() {
  test('subresource failures do not replace a successfully loaded page', () {
    expect(shouldTreatWebResourceErrorAsPageFailure(false), isFalse);
  });

  test('main-frame failures still show the page error state', () {
    expect(shouldTreatWebResourceErrorAsPageFailure(true), isTrue);
  });

  test('reader enables its navigation interception callback', () {
    final settings = createReaderWebViewSettings(100);

    expect(settings.useShouldOverrideUrlLoading, isTrue);
  });

  testWidgets('error overlay keeps the WebView mounted for retry', (
    tester,
  ) async {
    const webViewKey = Key('reader-web-view');
    const errorKey = Key('reader-error');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ReaderWebViewSurface(
            webView: SizedBox(key: webViewKey),
            errorOverlay: ColoredBox(key: errorKey, color: Colors.white),
          ),
        ),
      ),
    );

    expect(find.byKey(webViewKey), findsOneWidget);
    expect(find.byKey(errorKey), findsOneWidget);
  });
}
