import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

import 'ocr_model_store.dart';
import 'ppocr_postprocess.dart';

class OcrLine {
  final String text;
  final OcrBox box;
  final double score;

  const OcrLine({
    required this.text,
    required this.box,
    required this.score,
  });
}

class OcrResult {
  final String text;
  final List<OcrLine> lines;

  const OcrResult({required this.text, required this.lines});
}

/// Local PP-OCRv6_small engine (det + rec) via ONNX Runtime.
///
/// Models are downloaded on first use and cached under app support storage.
class PpOcrV6Engine {
  static const dictAsset = 'assets/ocr/ppocrv6_dict.txt';
  static const detLimitSideLen = 960;
  static const recImageHeight = 48;
  static const recMaxWidth = 320;
  static const minTextLength = 1;

  final OcrModelStore _store;
  OrtSession? _detSession;
  OrtSession? _recSession;
  List<String>? _characters;
  bool _envReady = false;
  Future<void>? _initFuture;

  PpOcrV6Engine({OcrModelStore? store}) : _store = store ?? OcrModelStore();

  Future<void> ensureReady({
    void Function(String stage, double? progress)? onProgress,
  }) {
    return _initFuture ??= _doInit(onProgress: onProgress);
  }

  Future<void> _doInit({
    void Function(String stage, double? progress)? onProgress,
  }) async {
    if (!_envReady) {
      OrtEnv.instance.init();
      _envReady = true;
    }

    onProgress?.call('models', null);
    await _store.ensureModels(onProgress: onProgress);

    final sessionOptions = OrtSessionOptions();
    try {
      if (_detSession == null) {
        final detBytes = await _store.readDetBytes();
        _detSession = OrtSession.fromBuffer(detBytes, sessionOptions);
      }
      if (_recSession == null) {
        final recBytes = await _store.readRecBytes();
        _recSession = OrtSession.fromBuffer(recBytes, sessionOptions);
      }
    } finally {
      sessionOptions.release();
    }

    if (_characters == null) {
      final dictText = await rootBundle.loadString(dictAsset);
      final dict = dictText
          .split('\n')
          .map((e) => e.trimRight())
          .where((e) => e.isNotEmpty)
          .toList();
      // rec output classes observed as 18710 = blank + 18708 dict + space
      _characters = buildCtcCharacters(dict, 18710);
    }
    onProgress?.call('ready', 1);
  }

  Future<OcrResult> recognizeFile(String path) async {
    final bytes = await img.decodeImageFile(path).then((value) {
      if (value == null) {
        throw StateError('Could not decode image: $path');
      }
      return value;
    });
    return recognizeImage(bytes);
  }

  Future<OcrResult> recognizeBytes(Uint8List bytes) async {
    final image = img.decodeImage(bytes);
    if (image == null) {
      throw StateError('Could not decode image bytes');
    }
    return recognizeImage(image);
  }

  Future<OcrResult> recognizeImage(img.Image image) async {
    await ensureReady();
    final det = _detSession;
    final rec = _recSession;
    final characters = _characters;
    if (det == null || rec == null || characters == null) {
      throw StateError('OCR engine not initialized');
    }

    final rgb =
        image.numChannels == 3 ? image : image.convert(numChannels: 3);

    final boxes = await _detect(det, rgb);
    if (boxes.isEmpty) {
      return const OcrResult(text: '', lines: []);
    }

    final lines = <OcrLine>[];
    for (final box in boxes) {
      final crop = _cropBox(rgb, box);
      if (crop == null) continue;
      final text = await _recognize(rec, crop, characters);
      if (text.trim().length < minTextLength) continue;
      lines.add(OcrLine(text: text.trim(), box: box, score: box.score));
    }

    final text = lines.map((e) => e.text).join('\n');
    return OcrResult(text: text, lines: lines);
  }

  Future<List<OcrBox>> _detect(OrtSession session, img.Image image) async {
    final prepared = _prepareDetInput(image);
    final inputOrt = OrtValueTensor.createTensorWithDataList(
      [prepared.nchw],
      [1, 3, prepared.resizedHeight, prepared.resizedWidth],
    );
    final runOptions = OrtRunOptions();
    try {
      final outputs = await session.runAsync(runOptions, {'x': inputOrt});
      final out = outputs?.first;
      if (out == null) return const [];
      final value = out.value;
      out.release();
      outputs?.forEach((e) => e?.release());

      final map = _asFloat32List(value);
      // Output shape is typically [1, 1, H, W]
      final mapH = prepared.resizedHeight;
      final mapW = prepared.resizedWidth;
      if (map.length < mapH * mapW) {
        // Some exports keep full resolution; fall back to sqrt estimate.
        final side = math.sqrt(map.length).round();
        return dbPostProcess(
          map,
          mapHeight: side,
          mapWidth: side,
          scaleX: prepared.scaleX,
          scaleY: prepared.scaleY,
          originWidth: image.width,
          originHeight: image.height,
        );
      }
      return dbPostProcess(
        map.sublist(0, mapH * mapW),
        mapHeight: mapH,
        mapWidth: mapW,
        scaleX: prepared.scaleX,
        scaleY: prepared.scaleY,
        originWidth: image.width,
        originHeight: image.height,
      );
    } finally {
      inputOrt.release();
      runOptions.release();
    }
  }

  Future<String> _recognize(
    OrtSession session,
    img.Image crop,
    List<String> characters,
  ) async {
    final prepared = _prepareRecInput(crop);
    final inputOrt = OrtValueTensor.createTensorWithDataList(
      [prepared.nchw],
      [1, 3, recImageHeight, prepared.width],
    );
    final runOptions = OrtRunOptions();
    try {
      final outputs = await session.runAsync(runOptions, {'x': inputOrt});
      final out = outputs?.first;
      if (out == null) return '';
      final value = out.value;
      out.release();
      outputs?.forEach((e) => e?.release());

      final logits = _asFloat32List(value);
      // Expected shape [1, seq, classes] or [seq, classes]
      final numClasses = characters.length;
      if (numClasses == 0 || logits.isEmpty) return '';
      final seqLen = logits.length ~/ numClasses;
      if (seqLen <= 0) return '';
      return ctcGreedyDecode(
        logits,
        seqLen: seqLen,
        numClasses: numClasses,
        characters: characters,
      );
    } finally {
      inputOrt.release();
      runOptions.release();
    }
  }

  _DetPrepared _prepareDetInput(img.Image src) {
    final maxSide = math.max(src.width, src.height);
    var ratio = 1.0;
    if (maxSide > detLimitSideLen) {
      ratio = detLimitSideLen / maxSide;
    }
    var resizeW = (src.width * ratio).round();
    var resizeH = (src.height * ratio).round();
    resizeW = math.max(32, ((resizeW / 32).ceil() * 32));
    resizeH = math.max(32, ((resizeH / 32).ceil() * 32));

    final resized = img.copyResize(
      src,
      width: resizeW,
      height: resizeH,
      interpolation: img.Interpolation.linear,
    );

    final nchw = Float32List(3 * resizeH * resizeW);
    const mean = [0.485, 0.456, 0.406];
    const std = [0.229, 0.224, 0.225];
    var i = 0;
    for (var y = 0; y < resizeH; y++) {
      for (var x = 0; x < resizeW; x++) {
        final p = resized.getPixel(x, y);
        // Normalize using RGB channels (Image package is RGB).
        final r = p.r / 255.0;
        final g = p.g / 255.0;
        final b = p.b / 255.0;
        nchw[0 * resizeH * resizeW + i] = (r - mean[0]) / std[0];
        nchw[1 * resizeH * resizeW + i] = (g - mean[1]) / std[1];
        nchw[2 * resizeH * resizeW + i] = (b - mean[2]) / std[2];
        i++;
      }
    }

    return _DetPrepared(
      nchw: nchw,
      resizedWidth: resizeW,
      resizedHeight: resizeH,
      scaleX: src.width / resizeW,
      scaleY: src.height / resizeH,
    );
  }

  _RecPrepared _prepareRecInput(img.Image src) {
    final ratio = src.width / math.max(1, src.height);
    var resizeW = (recImageHeight * ratio).round();
    if (resizeW > recMaxWidth) resizeW = recMaxWidth;
    if (resizeW < 8) resizeW = 8;
    // Keep width multiple of 8 for stability.
    resizeW = math.max(8, ((resizeW / 8).ceil() * 8));
    if (resizeW > recMaxWidth) resizeW = recMaxWidth;

    final resized = img.copyResize(
      src,
      width: resizeW,
      height: recImageHeight,
      interpolation: img.Interpolation.linear,
    );

    // Pad to recMaxWidth on the right with zeros (after normalize => -1 roughly,
    // but Paddle uses zero-padded normalized canvas).
    final width = recMaxWidth;
    final nchw = Float32List(3 * recImageHeight * width);
    // default zeros
    var i = 0;
    for (var y = 0; y < recImageHeight; y++) {
      for (var x = 0; x < resizeW; x++) {
        final p = resized.getPixel(x, y);
        final r = (p.r / 255.0 - 0.5) / 0.5;
        final g = (p.g / 255.0 - 0.5) / 0.5;
        final b = (p.b / 255.0 - 0.5) / 0.5;
        final plane = y * width + x;
        nchw[0 * recImageHeight * width + plane] = r;
        nchw[1 * recImageHeight * width + plane] = g;
        nchw[2 * recImageHeight * width + plane] = b;
        i++;
      }
    }
    // silence unused
    assert(i >= 0);

    return _RecPrepared(nchw: nchw, width: width);
  }

  img.Image? _cropBox(img.Image src, OcrBox box) {
    final left = box.left.floor().clamp(0, src.width - 1);
    final top = box.top.floor().clamp(0, src.height - 1);
    final right = box.right.ceil().clamp(left + 1, src.width);
    final bottom = box.bottom.ceil().clamp(top + 1, src.height);
    final w = right - left;
    final h = bottom - top;
    if (w < 2 || h < 2) return null;
    return img.copyCrop(src, x: left, y: top, width: w, height: h);
  }

  Float32List _asFloat32List(Object? value) {
    if (value is Float32List) return value;
    if (value is List) {
      final flat = <double>[];
      void walk(Object? node) {
        if (node is List) {
          for (final e in node) {
            walk(e);
          }
        } else if (node is num) {
          flat.add(node.toDouble());
        }
      }

      walk(value);
      return Float32List.fromList(flat);
    }
    throw StateError('Unexpected ONNX output type: ${value.runtimeType}');
  }

  void dispose() {
    _detSession?.release();
    _recSession?.release();
    _detSession = null;
    _recSession = null;
    if (_envReady) {
      OrtEnv.instance.release();
      _envReady = false;
    }
    _initFuture = null;
  }
}

class _DetPrepared {
  final Float32List nchw;
  final int resizedWidth;
  final int resizedHeight;
  final double scaleX;
  final double scaleY;

  const _DetPrepared({
    required this.nchw,
    required this.resizedWidth,
    required this.resizedHeight,
    required this.scaleX,
    required this.scaleY,
  });
}

class _RecPrepared {
  final Float32List nchw;
  final int width;

  const _RecPrepared({required this.nchw, required this.width});
}
