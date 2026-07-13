import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'ocr/ocr_model_store.dart';
import 'ocr/ppocr_v6_engine.dart';

/// App-facing OCR service. Uses PP-OCRv6_small (Mobile) locally.
class OcrService {
  final PpOcrV6Engine _engine;

  OcrService({PpOcrV6Engine? engine})
      : _engine = engine ?? PpOcrV6Engine(store: OcrModelStore());

  Future<void> ensureReady({
    void Function(String stage, double? progress)? onProgress,
  }) {
    return _engine.ensureReady(onProgress: onProgress);
  }

  Future<String> recognizeImagePath(String path) async {
    final result = await _engine.recognizeFile(path);
    return result.text.trim();
  }

  Future<String> recognizeBytes(Uint8List bytes) async {
    final result = await _engine.recognizeBytes(bytes);
    return result.text.trim();
  }

  Future<String> recognizeImage(img.Image image) async {
    final result = await _engine.recognizeImage(image);
    return result.text.trim();
  }

  Future<void> dispose() => _engine.dispose();
}
