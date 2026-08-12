import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/chat_attachment.dart';
import 'package:memora/data/services/attachment_store.dart';
import 'package:memora/data/services/chat_attachment_pipeline.dart';
import 'package:memora/data/services/chat_attachment_service.dart';

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
      final pipeline = ChatAttachmentPipeline(store: store);
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
        attachments: [note, image],
        useNativeImageInput: true,
      );

      expect(prepared.textContext, contains('Important local details.'));
      expect(prepared.textContext, contains('chart.png'));
      expect(prepared.imageInputs.single.bytes, [1, 2, 3, 4]);
      expect(prepared.includesImageUnderstanding, isFalse);
    },
  );

  test('rejects images when the selected chat model has no vision', () async {
    final pipeline = ChatAttachmentPipeline(store: store);
    final image = await attachment(
      id: 'image',
      name: 'receipt.webp',
      mimeType: 'image/webp',
      kind: ChatAttachmentKind.image,
      bytes: [7, 8, 9],
    );

    await expectLater(
      pipeline.prepare(attachments: [image], useNativeImageInput: false),
      throwsA(
        isA<ChatAttachmentException>().having(
          (error) => error.code,
          'code',
          'chat_model_no_image_input',
        ),
      ),
    );
  });

  test('does not replay cached fallback vision text', () async {
    final pipeline = ChatAttachmentPipeline(store: store);
    final image = await attachment(
      id: 'image',
      name: 'photo.png',
      mimeType: 'image/png',
      kind: ChatAttachmentKind.image,
      bytes: [4, 3, 2, 1],
    );

    final prepared = await pipeline.prepare(
      attachments: [image],
      useNativeImageInput: true,
      cachedTextContext: 'stale separate-model description',
      cachedIncludesImageUnderstanding: true,
    );

    expect(prepared.textContext, contains('photo.png'));
    expect(prepared.textContext, isNot(contains('stale separate-model')));
    expect(prepared.imageInputs.single.bytes, [4, 3, 2, 1]);
    expect(prepared.includesImageUnderstanding, isFalse);
  });

  test(
    'enforces the hosted Agent image envelope before reading bytes',
    () async {
      final pipeline = ChatAttachmentPipeline(store: store);
      final first = await attachment(
        id: 'first',
        name: 'first.png',
        mimeType: 'image/png',
        kind: ChatAttachmentKind.image,
        bytes: [1, 2],
      );
      final second = await attachment(
        id: 'second',
        name: 'second.webp',
        mimeType: 'image/webp',
        kind: ChatAttachmentKind.image,
        bytes: [3, 4],
      );

      await expectLater(
        pipeline.prepare(
          attachments: [first, second],
          useNativeImageInput: true,
          maxNativeImages: 1,
        ),
        throwsA(
          isA<ChatAttachmentException>().having(
            (error) => error.code,
            'code',
            'too_many',
          ),
        ),
      );
      await expectLater(
        pipeline.prepare(
          attachments: [first, second],
          useNativeImageInput: true,
          maxNativeImageTotalBytes: 3,
        ),
        throwsA(
          isA<ChatAttachmentException>().having(
            (error) => error.code,
            'code',
            'total_too_large',
          ),
        ),
      );
    },
  );
}

class _MappedAttachmentStore extends AttachmentStore {
  final Map<String, File> files = {};

  @override
  Future<File?> resolveChatAttachment({
    required String attachmentId,
    required String relativePath,
  }) async => files[relativePath];
}

String _hex(List<int> bytes) {
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
