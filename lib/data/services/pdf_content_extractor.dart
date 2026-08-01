import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

/// Extract plain text from a PDF via PDFium (pdfrx).
///
/// Only the embedded digital text layer is read. Scanned PDFs intentionally
/// return no usable text until remote image recognition is configured.
class PdfContentExtractor {
  static const minUsableChars = 100;
  static const thumbMaxSide = 256;

  /// Open [path] and extract its embedded text layer.
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
      onProgress?.call('ready', 1);
      return layered;
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

  Future<PdfImage?> _renderPage(PdfPage page, {required int maxSide}) async {
    final w = page.width;
    final h = page.height;
    if (w <= 0 || h <= 0) return null;
    final scale = maxSide / (w > h ? w : h);
    final fullWidth = (w * scale).clamp(32.0, 4096.0);
    final fullHeight = (h * scale).clamp(32.0, 4096.0);
    return page.render(fullWidth: fullWidth, fullHeight: fullHeight);
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
