import 'package:flutter_test/flutter_test.dart';

import 'package:memora/features/reader/reader_screen.dart';

void main() {
  test('subresource failures do not replace a successfully loaded page', () {
    expect(shouldTreatWebResourceErrorAsPageFailure(false), isFalse);
  });

  test('main-frame failures still show the page error state', () {
    expect(shouldTreatWebResourceErrorAsPageFailure(true), isTrue);
  });
}
