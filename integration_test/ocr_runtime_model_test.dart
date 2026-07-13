import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:memora/data/services/ocr_service.dart';

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
}
