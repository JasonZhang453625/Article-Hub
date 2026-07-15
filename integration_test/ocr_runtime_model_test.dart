import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:memora/data/services/ocr_service.dart';
import 'package:memora/data/services/ocr/ocr_image_decoder.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('bundled OCR models are loadable by the app runtime', (
    tester,
  ) async {
    final runtime = OnnxRuntime();

    for (final asset in const [
      'assets/ocr/models/ppocrv6_small_det.onnx',
      'assets/ocr/models/ppocrv6_small_rec.onnx',
    ]) {
      OrtSession? session;
      try {
        session = await runtime.createSessionFromAsset(asset);
        expect(session.inputNames, contains('x'));
        expect(session.outputNames, isNotEmpty);
      } finally {
        await session?.close();
      }
    }
  });

  testWidgets('OCR engine can run inference with the bundled models', (
    tester,
  ) async {
    final ocr = OcrService();
    try {
      final text = await ocr.recognizeImage(
        img.Image(width: 64, height: 64, numChannels: 3),
      );
      expect(text, isEmpty);
    } finally {
      await ocr.dispose();
    }
  });

  testWidgets('encoded images are decoded at the bounded OCR resolution', (
    tester,
  ) async {
    final source = img.Image(width: 1600, height: 1200, numChannels: 3);
    final encoded = img.encodeJpg(source);
    final decoded = await const OcrImageDecoder(
      maxSide: 960,
    ).decodeBytes(encoded);

    expect(decoded.width, 960);
    expect(decoded.height, 720);
  });

  testWidgets('OCR engine recognizes a camera-sized image containing text', (
    tester,
  ) async {
    final image = img.Image(width: 3024, height: 4032, numChannels: 3);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    for (var row = 0; row < 12; row++) {
      img.drawString(
        image,
        'MEMORA OCR TEST ${row + 1}',
        font: img.arial48,
        x: 160,
        y: 240 + row * 260,
        color: img.ColorRgb8(0, 0, 0),
      );
    }

    final ocr = OcrService();
    try {
      final text = await ocr.recognizeImage(image);
      expect(text, isNotEmpty);
    } finally {
      await ocr.dispose();
    }
  });
}
