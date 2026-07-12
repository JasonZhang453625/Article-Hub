import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

import 'ocr_service.dart';

/// Extract plain text from a PDF via PDFium (pdfrx).
///
/// Strategy:
/// 1. Prefer digital text layer
/// 2. If too short, render pages and OCR with [OcrService] (scan PDFs)
class PdfContentExtractor {
  static const minUsableChars = 100;
  static const maxOcrPages = 30;
  static const ocrMaxSide = 1280;
  static const thumbMaxSide = 256;

  final OcrService? _ocr;

  PdfContentExtractor({OcrService? ocr}) : _ocr = ocr;

  /// Open [path] and extract text (text layer first, OCR fallback).
  Future<String> extractText(
    String path, {
    void Function(String stage, double? progress)? onProgress,
  }) async {
    await pdfrxFlutterInitialize();
    onProgress?.call('open', 0);
    final doc = await PdfDocument.openFile(path);
    try {
      onProgress?.call('text_layer', 0.1);
      final layered = await _extractTextLayer(doc);
      if (isUsable(layered)) {
        onProgress?.call('ready', 1);
        return layered;
      }

      final ocr = _ocr;
      if (ocr == null) {
        onProgress?.call('ready', 1);
        return layered;
      }

      onProgress?.call('ocr', 0.15);
      final scanned = await _extractViaOcr(
        doc,
        ocr,
        onProgress: onProgress,
      );
      onProgress?.call('ready', 1);
      return isUsable(scanned) ? scanned : layered;
    } finally {
      await doc.dispose();
    }
  }

  /// Render page 1 to a JPEG thumbnail (max side [thumbMaxSide]).
  Future<Uint8List?> renderCoverJpeg(String path) async {
    await pdfrxFlutterInitialize();
    final doc = await PdfDocument.openFile(path);
    try {
      if (doc.pages.isEmpty) return null;
      final page = doc.pages.first;
      final image = await _renderPage(page, maxSide: thumbMaxSide);
      if (image == null) return null;
      try {
        final decoded = _bgraToImage(image);
        return Uint8List.fromList(img.encodeJpg(decoded, quality: 85));
      } finally {
        image.dispose();
      }
    } finally {
      await doc.dispose();
    }
  }

  Future<String> _extractTextLayer(PdfDocument doc) async {
    final buffer = StringBuffer();
    for (final page in doc.pages) {
      final raw = await page.loadText();
      final text = raw?.fullText.trim() ?? '';
      if (text.isEmpty) continue;
      if (buffer.isNotEmpty) buffer.writeln();
      buffer.writeln(text);
    }
    return _clean(buffer.toString());
  }

  Future<String> _extractViaOcr(
    PdfDocument doc,
    OcrService ocr, {
    void Function(String stage, double? progress)? onProgress,
  }) async {
    final pageCount = doc.pages.length;
    final limit = pageCount > maxOcrPages ? maxOcrPages : pageCount;
    final buffer = StringBuffer();

    for (var i = 0; i < limit; i++) {
      final page = doc.pages[i];
      onProgress?.call(
        'ocr',
        0.15 + 0.8 * ((i + 1) / limit),
      );
      final rendered = await _renderPage(page, maxSide: ocrMaxSide);
      if (rendered == null) continue;
      try {
        final image = _bgraToImage(rendered);
        final text = await ocr.recognizeImage(image);
        if (text.trim().isEmpty) continue;
        if (buffer.isNotEmpty) buffer.writeln();
        buffer.writeln(text.trim());
      } finally {
        rendered.dispose();
      }
    }
    return _clean(buffer.toString());
  }

  Future<PdfImage?> _renderPage(PdfPage page, {required int maxSide}) async {
    final w = page.width;
    final h = page.height;
    if (w <= 0 || h <= 0) return null;
    final scale = maxSide / (w > h ? w : h);
    final fullWidth = (w * scale).clamp(32.0, 4096.0);
    final fullHeight = (h * scale).clamp(32.0, 4096.0);
    return page.render(
      fullWidth: fullWidth,
      fullHeight: fullHeight,
    );
  }

  img.Image _bgraToImage(PdfImage pdfImage) {
    return img.Image.fromBytes(
      width: pdfImage.width,
      height: pdfImage.height,
      bytes: pdfImage.pixels.buffer,
      order: img.ChannelOrder.bgra,
      numChannels: 4,
    );
  }

  String _clean(String text) {
    return text
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  bool isUsable(String text) => text.trim().length >= minUsableChars;
}
