import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/chat_attachment.dart';
import 'package:memora/data/models/image_understanding_document.dart';
import 'package:memora/data/services/attachment_store.dart';
import 'package:memora/data/services/chat_attachment_pipeline.dart';
import 'package:memora/data/services/image_understanding_service.dart';

void main() {
  late Directory tempDir;
  late _MappedAttachmentStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('chat-attachments-');
    store = _MappedAttachmentStore();
  });

  tearDown(() => tempDir.delete(recursive: true));

  Future<ChatAttachment> attachment({
    required String id,
    required String name,
    required String mimeType,
    required ChatAttachmentKind kind,
    required List<int> bytes,
  }) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsBytes(bytes);
    store.files[id] = file;
    final digest = await Sha256().hash(bytes);
    return ChatAttachment(
      id: id,
      kind: kind,
      localPath: id,
      mimeType: mimeType,
      originalFileName: name,
      byteLength: bytes.length,
      sha256: _hex(digest.bytes),
    );
  }

  test(
    'extracts text files and sends images natively when supported',
    () async {
      final vision = _FakeVision();
      final pipeline = ChatAttachmentPipeline(store: store, vision: vision);
      final note = await attachment(
        id: 'note',
        name: 'note.md',
        mimeType: 'text/markdown',
        kind: ChatAttachmentKind.file,
        bytes: utf8.encode('Important local details.'),
      );
      final image = await attachment(
        id: 'image',
        name: 'chart.png',
        mimeType: 'image/png',
        kind: ChatAttachmentKind.image,
        bytes: [1, 2, 3, 4],
      );

      final prepared = await pipeline.prepare(
        requestId: 'request-1',
        attachments: [note, image],
        useNativeImageInput: true,
        locale: 'zh-CN',
      );

      expect(prepared.textContext, contains('Important local details.'));
      expect(prepared.textContext, contains('chart.png'));
      expect(prepared.imageInputs.single.bytes, [1, 2, 3, 4]);
      expect(prepared.includesImageUnderstanding, isFalse);
      expect(vision.calls, 0);
    },
  );

  test('uses the vision gateway before a text-only chat model', () async {
    final vision = _FakeVision();
    final pipeline = ChatAttachmentPipeline(store: store, vision: vision);
    final image = await attachment(
      id: 'image',
      name: 'receipt.webp',
      mimeType: 'image/webp',
      kind: ChatAttachmentKind.image,
      bytes: [7, 8, 9],
    );

    final prepared = await pipeline.prepare(
      requestId: 'request-2',
      attachments: [image],
      useNativeImageInput: false,
      locale: 'zh-CN',
    );

    expect(vision.calls, 1);
    expect(prepared.imageInputs, isEmpty);
    expect(prepared.textContext, contains('识别出的收据内容'));
    expect(prepared.includesImageUnderstanding, isTrue);
  });
}

class _MappedAttachmentStore extends AttachmentStore {
  final Map<String, File> files = {};

  @override
  Future<File?> resolveChatAttachment({
    required String attachmentId,
    required String relativePath,
  }) async => files[relativePath];
}

class _FakeVision implements ImageUnderstandingGateway {
  int calls = 0;

  @override
  Future<ImageUnderstandingDocument> understand({
    required String articleId,
    required List<ImageUnderstandingUpload> images,
    required String locale,
  }) async {
    calls++;
    return ImageUnderstandingDocument(
      requestId: articleId,
      provider: 'fake-vision',
      model: 'vision-model',
      promptVersion: imageUnderstandingPromptVersion,
      generatedAt: DateTime.utc(2026, 8, 9),
      sourceImages: [
        for (final image in images)
          ImageUnderstandingSourceImage(
            attachmentId: image.attachment.id,
            order: image.attachment.order,
            sha256: image.attachment.sha256,
          ),
      ],
      suggestedTitle: '',
      documentType: 'receipt',
      pages: [
        for (final image in images)
          ImageUnderstandingPage(
            attachmentId: image.attachment.id,
            order: image.attachment.order,
            transcriptionMarkdown: '识别出的收据内容',
            visualDescription: '',
          ),
      ],
      combinedMarkdown: '识别出的收据内容',
    );
  }
}

String _hex(List<int> bytes) {
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
