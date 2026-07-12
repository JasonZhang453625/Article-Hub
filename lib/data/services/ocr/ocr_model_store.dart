import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:typed_data';

/// Loads bundled PP-OCRv6_small ONNX models from app assets into local cache.
///
/// Models ship with the app under `assets/ocr/models/` so OCR works offline
/// without a first-run download.
class OcrModelStore {
  static const detFileName = 'ppocrv6_small_det.onnx';
  static const recFileName = 'ppocrv6_small_rec.onnx';

  static const detAsset = 'assets/ocr/models/$detFileName';
  static const recAsset = 'assets/ocr/models/$recFileName';

  static const minDetBytes = 5 * 1024 * 1024;
  static const minRecBytes = 10 * 1024 * 1024;

  Future<Directory> modelDir() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory(p.join(root.path, 'ocr', 'pp-ocrv6-small'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> detModelFile() async {
    final dir = await modelDir();
    return File(p.join(dir.path, detFileName));
  }

  Future<File> recModelFile() async {
    final dir = await modelDir();
    return File(p.join(dir.path, recFileName));
  }

  Future<bool> isReady() async {
    final det = await detModelFile();
    final rec = await recModelFile();
    if (!await det.exists() || !await rec.exists()) return false;
    return await det.length() >= minDetBytes &&
        await rec.length() >= minRecBytes;
  }

  /// Ensure both models are present locally by extracting bundled assets.
  Future<void> ensureModels({
    void Function(String stage, double? progress)? onProgress,
  }) async {
    final det = await detModelFile();
    final rec = await recModelFile();

    if (!await _isValid(det, minDetBytes)) {
      onProgress?.call('extract_det', 0);
      await _extractAsset(detAsset, det);
      onProgress?.call('extract_det', 1);
    }
    if (!await _isValid(rec, minRecBytes)) {
      onProgress?.call('extract_rec', 0);
      await _extractAsset(recAsset, rec);
      onProgress?.call('extract_rec', 1);
    }
    onProgress?.call('ready', 1);
  }

  Future<bool> _isValid(File file, int minBytes) async {
    if (!await file.exists()) return false;
    return await file.length() >= minBytes;
  }

  Future<void> _extractAsset(String assetPath, File dest) async {
    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List();
    final tmp = File('${dest.path}.part');
    if (await tmp.exists()) {
      await tmp.delete();
    }
    await tmp.writeAsBytes(bytes, flush: true);
    if (await dest.exists()) {
      await dest.delete();
    }
    await tmp.rename(dest.path);
  }

  Future<Uint8List> readDetBytes() async {
    final file = await detModelFile();
    return file.readAsBytes();
  }

  Future<Uint8List> readRecBytes() async {
    final file = await recModelFile();
    return file.readAsBytes();
  }
}
