import 'dart:math' as math;
import 'dart:typed_data';

/// Axis-aligned text box in original image coordinates.
class OcrBox {
  final double left;
  final double top;
  final double right;
  final double bottom;
  final double score;

  const OcrBox({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.score,
  });

  double get width => math.max(0, right - left);
  double get height => math.max(0, bottom - top);
  double get centerY => (top + bottom) / 2;
  double get centerX => (left + right) / 2;
}

/// DBNet-style post-process for PP-OCR detection maps.
///
/// Uses connected components on the binary map (axis-aligned boxes). This is
/// slightly less precise than OpenCV minAreaRect + unclip polygons, but is
/// pure Dart and good enough for document / screenshot OCR.
List<OcrBox> dbPostProcess(
  Float32List map, {
  required int mapHeight,
  required int mapWidth,
  required double scaleX,
  required double scaleY,
  required int originWidth,
  required int originHeight,
  double thresh = 0.2,
  double boxThresh = 0.45,
  double unclipRatio = 1.4,
  int minSize = 3,
  int maxCandidates = 3000,
}) {
  final binary = Uint8List(mapHeight * mapWidth);
  for (var i = 0; i < binary.length; i++) {
    binary[i] = map[i] > thresh ? 1 : 0;
  }

  final labels = Int32List(mapHeight * mapWidth);
  var nextLabel = 1;
  final boxes = <OcrBox>[];

  for (var y = 0; y < mapHeight; y++) {
    for (var x = 0; x < mapWidth; x++) {
      final idx = y * mapWidth + x;
      if (binary[idx] == 0 || labels[idx] != 0) continue;

      // Flood-fill connected component.
      var minX = x;
      var maxX = x;
      var minY = y;
      var maxY = y;
      var sumScore = 0.0;
      var count = 0;
      final stackX = <int>[x];
      final stackY = <int>[y];
      labels[idx] = nextLabel;

      while (stackX.isNotEmpty) {
        final cx = stackX.removeLast();
        final cy = stackY.removeLast();
        final cidx = cy * mapWidth + cx;
        sumScore += map[cidx];
        count++;
        if (cx < minX) minX = cx;
        if (cx > maxX) maxX = cx;
        if (cy < minY) minY = cy;
        if (cy > maxY) maxY = cy;

        for (final dy in const [-1, 0, 1]) {
          for (final dx in const [-1, 0, 1]) {
            if (dx == 0 && dy == 0) continue;
            final nx = cx + dx;
            final ny = cy + dy;
            if (nx < 0 || ny < 0 || nx >= mapWidth || ny >= mapHeight) {
              continue;
            }
            final nidx = ny * mapWidth + nx;
            if (binary[nidx] == 0 || labels[nidx] != 0) continue;
            labels[nidx] = nextLabel;
            stackX.add(nx);
            stackY.add(ny);
          }
        }
      }

      nextLabel++;
      if (count < 4) continue;

      final meanScore = sumScore / count;
      if (meanScore < boxThresh) continue;

      final bw = maxX - minX + 1;
      final bh = maxY - minY + 1;
      if (bw < minSize || bh < minSize) continue;

      // Expand box by unclip ratio around center.
      final cx = (minX + maxX + 1) / 2.0;
      final cy = (minY + maxY + 1) / 2.0;
      final halfW = bw * unclipRatio / 2.0;
      final halfH = bh * unclipRatio / 2.0;

      var left = (cx - halfW) * scaleX;
      var top = (cy - halfH) * scaleY;
      var right = (cx + halfW) * scaleX;
      var bottom = (cy + halfH) * scaleY;

      left = left.clamp(0, originWidth - 1).toDouble();
      top = top.clamp(0, originHeight - 1).toDouble();
      right = right.clamp(0, originWidth.toDouble()).toDouble();
      bottom = bottom.clamp(0, originHeight.toDouble()).toDouble();

      if (right - left < 2 || bottom - top < 2) continue;
      boxes.add(OcrBox(
        left: left,
        top: top,
        right: right,
        bottom: bottom,
        score: meanScore,
      ));

      if (boxes.length >= maxCandidates) {
        return _sortReadingOrder(boxes);
      }
    }
  }

  return _sortReadingOrder(boxes);
}

List<OcrBox> _sortReadingOrder(List<OcrBox> boxes) {
  final sorted = [...boxes];
  sorted.sort((a, b) {
    final rowDiff = a.centerY - b.centerY;
    if (rowDiff.abs() > math.max(a.height, b.height) * 0.5) {
      return rowDiff.compareTo(0);
    }
    return a.left.compareTo(b.left);
  });
  return sorted;
}

/// CTC greedy decode for PP-OCR recognition output.
///
/// [logits] shape: [seqLen, numClasses] (single batch item, row-major).
String ctcGreedyDecode(
  Float32List logits, {
  required int seqLen,
  required int numClasses,
  required List<String> characters,
}) {
  // characters[0] is blank; remaining map to class ids 1..n
  final sb = StringBuffer();
  var prev = -1;
  for (var t = 0; t < seqLen; t++) {
    var maxIdx = 0;
    var maxVal = logits[t * numClasses];
    for (var c = 1; c < numClasses; c++) {
      final v = logits[t * numClasses + c];
      if (v > maxVal) {
        maxVal = v;
        maxIdx = c;
      }
    }
    if (maxIdx != 0 && maxIdx != prev) {
      if (maxIdx < characters.length) {
        sb.write(characters[maxIdx]);
      }
    }
    prev = maxIdx;
  }
  return sb.toString();
}

/// Build CTC character table matching PaddleOCR CTCLabelDecode.
///
/// Output classes are typically: blank + dict (+ optional space).
List<String> buildCtcCharacters(List<String> dict, int numClasses) {
  final chars = <String>['']; // blank at index 0
  chars.addAll(dict);
  if (chars.length < numClasses) {
    // PP-OCR often appends a space token after the dict.
    chars.add(' ');
  }
  while (chars.length < numClasses) {
    chars.add('');
  }
  return chars;
}
