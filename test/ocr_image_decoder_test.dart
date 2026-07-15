import 'package:flutter_test/flutter_test.dart';
import 'package:memora/data/services/ocr/ocr_image_decoder.dart';

void main() {
  group('calculateOcrDecodeTarget', () {
    test('keeps images that already fit inside the limit unchanged', () {
      expect(calculateOcrDecodeTarget(width: 800, height: 600, maxSide: 960), (
        width: 800,
        height: 600,
      ));
    });

    test('bounds a high-resolution landscape image before decoding', () {
      expect(
        calculateOcrDecodeTarget(width: 12000, height: 9000, maxSide: 960),
        (width: 960, height: 720),
      );
    });

    test('bounds a high-resolution portrait image before decoding', () {
      expect(
        calculateOcrDecodeTarget(width: 9000, height: 12000, maxSide: 960),
        (width: 720, height: 960),
      );
    });
  });
}
