import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

/// Calculates the decoded dimensions before allocating the image pixel buffer.
///
/// OCR detection already limits its input to [maxSide], so decoding any larger
/// only increases peak memory without preserving useful OCR detail.
({int width, int height}) calculateOcrDecodeTarget({
  required int width,
  required int height,
  required int maxSide,
}) {
  if (width <= 0 || height <= 0 || maxSide <= 0) {
    throw ArgumentError('Image dimensions and maxSide must be positive');
  }
  if (width <= maxSide && height <= maxSide) {
    return (width: width, height: height);
  }

  final scale = maxSide / math.max(width, height);
  return (
    width: math.max(1, (width * scale).round()),
    height: math.max(1, (height * scale).round()),
  );
}

/// Decodes encoded images through Flutter's engine at an OCR-sized resolution.
///
/// This avoids first allocating the full RGBA pixel buffer for high-resolution
/// camera images, which can otherwise cause Android to kill the process for OOM.
class OcrImageDecoder {
  final int maxSide;

  const OcrImageDecoder({required this.maxSide});

  Future<img.Image> decodeFile(String path) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    return _decodeBuffer(buffer);
  }

  Future<img.Image> decodeBytes(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return _decodeBuffer(buffer);
  }

  Future<img.Image> _decodeBuffer(ui.ImmutableBuffer buffer) async {
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? decoded;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final target = calculateOcrDecodeTarget(
        width: descriptor.width,
        height: descriptor.height,
        maxSide: maxSide,
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: target.width,
        targetHeight: target.height,
      );
      final frame = await codec.getNextFrame();
      decoded = frame.image;
      final pixels = await decoded.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (pixels == null) {
        throw StateError('Could not read decoded image pixels');
      }
      return img.Image.fromBytes(
        width: decoded.width,
        height: decoded.height,
        bytes: pixels.buffer,
        bytesOffset: pixels.offsetInBytes,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );
    } finally {
      decoded?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}
