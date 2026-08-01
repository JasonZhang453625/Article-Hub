import 'package:flutter_test/flutter_test.dart';
import 'package:memora/data/services/attachment_store.dart';
import 'package:memora/data/services/local_file_importer.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/source_platform.dart';

void main() {
  group('mime helpers', () {
    test('detects pdf and image paths', () {
      expect(isPdfPath('a/b/c.pdf'), isTrue);
      expect(isPdfMime('application/pdf'), isTrue);
      expect(isImagePath('x.PNG'), isTrue);
      expect(isImageMime('image/jpeg'), isTrue);
      expect(isPdfPath('x.jpg'), isFalse);
    });

    test('local importer does not run image recognition locally', () async {
      final importer = LocalFileImporter();
      await expectLater(
        importer.extractContent('x.png', 'image/png'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('Article local flags', () {
    test('isLocalPdf / isLocalImage', () {
      final pdf = Article(
        id: '1',
        url: 'file://x',
        title: 't',
        source: SourcePlatform.local,
        localFilePath: 'attachments/1/a.pdf',
        localMimeType: 'application/pdf',
      );
      expect(pdf.isLocalPdf, isTrue);
      expect(pdf.isLocalImage, isFalse);
      expect(pdf.isLocalAttachment, isTrue);

      final img = Article(
        id: '2',
        url: 'file://y',
        title: 't',
        source: SourcePlatform.local,
        localFilePath: 'attachments/2/a.png',
        localMimeType: 'image/png',
      );
      expect(img.isLocalImage, isTrue);
      expect(img.isLocalPdf, isFalse);
    });
  });
}
