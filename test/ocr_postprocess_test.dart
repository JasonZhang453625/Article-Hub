import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:memora/data/services/ocr/ppocr_postprocess.dart';

void main() {
  group('ctcGreedyDecode', () {
    test('decodes simple non-blank sequence with blanks and repeats', () {
      const numClasses = 3;
      final logits = Float32List.fromList([
        0.1, 0.9, 0.0, // a
        0.1, 0.8, 0.0, // a (repeat)
        0.9, 0.05, 0.05, // blank
        0.1, 0.0, 0.9, // b
      ]);
      final text = ctcGreedyDecode(
        logits,
        seqLen: 4,
        numClasses: numClasses,
        characters: ['', 'a', 'b'],
      );
      expect(text, 'ab');
    });
  });

  group('buildCtcCharacters', () {
    test('prefixes blank and pads to class count', () {
      final chars = buildCtcCharacters(['a', 'b'], 5);
      expect(chars.first, '');
      expect(chars[1], 'a');
      expect(chars[2], 'b');
      expect(chars.length, 5);
    });
  });

  group('dbPostProcess', () {
    test('returns box for a high-score blob', () {
      const h = 8;
      const w = 8;
      final map = Float32List(h * w);
      for (var y = 2; y <= 4; y++) {
        for (var x = 2; x <= 5; x++) {
          map[y * w + x] = 0.95;
        }
      }
      final boxes = dbPostProcess(
        map,
        mapHeight: h,
        mapWidth: w,
        scaleX: 2,
        scaleY: 2,
        originWidth: 16,
        originHeight: 16,
        thresh: 0.2,
        boxThresh: 0.45,
      );
      expect(boxes, isNotEmpty);
      expect(boxes.first.score, greaterThan(0.5));
    });
  });
}
