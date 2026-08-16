import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/chat_attachment.dart';
import 'package:memora/data/services/attachment_store.dart';
import 'package:memora/data/services/chat_attachment_service.dart';

void main() {
  test('imports a picked file with durable metadata and fingerprint', () async {
    final store = _FakeAttachmentStore();
    final service = ChatAttachmentService(store: store);
    final bytes = utf8.encode('# Notes\nUseful text.');

    final drafts = await service.importPickedFiles([
      PlatformFile(
        name: 'notes.md',
        size: bytes.length,
        bytes: Uint8List.fromList(bytes),
      ),
    ], kind: ChatAttachmentKind.file);

    final attachment = drafts.single.attachment;
    expect(attachment.mimeType, 'text/markdown');
    expect(attachment.byteLength, bytes.length);
    expect(attachment.sha256, hasLength(64));
    expect(store.saved[attachment.id], bytes);

    await service.discardDraft(drafts.single);
    expect(store.deleted, [attachment.id]);
  });

  test(
    'rejects a selection that exceeds the remaining attachment slots',
    () async {
      final service = ChatAttachmentService(store: _FakeAttachmentStore());
      final files = [
        PlatformFile(name: 'a.txt', size: 1, bytes: Uint8List.fromList([1])),
        PlatformFile(name: 'b.txt', size: 1, bytes: Uint8List.fromList([2])),
      ];

      await expectLater(
        service.importPickedFiles(
          files,
          kind: ChatAttachmentKind.file,
          remainingSlots: 1,
        ),
        throwsA(
          isA<ChatAttachmentException>().having(
            (error) => error.code,
            'code',
            'too_many',
          ),
        ),
      );
    },
  );

  test('applies the caller-provided per-file byte limit', () async {
    final service = ChatAttachmentService(store: _FakeAttachmentStore());

    await expectLater(
      service.importPickedFiles(
        [
          PlatformFile(
            name: 'large.png',
            size: 3,
            bytes: Uint8List.fromList([1, 2, 3]),
          ),
        ],
        kind: ChatAttachmentKind.image,
        maxFileBytes: 2,
      ),
      throwsA(
        isA<ChatAttachmentException>().having(
          (error) => error.code,
          'code',
          'too_large',
        ),
      ),
    );
  });

  test('ignores restored attachment metadata with an unsafe id', () {
    final restored = chatAttachmentsFromStored([
      {
        'id': '../../outside',
        'kind': 'file',
        'localPath': '../../outside/secret.txt',
        'mimeType': 'text/plain',
        'originalFileName': 'secret.txt',
        'byteLength': 5,
        'sha256': List.filled(64, '0').join(),
      },
    ]);

    expect(restored, isEmpty);
  });
}

class _FakeAttachmentStore extends AttachmentStore {
  final Map<String, List<int>> saved = {};
  final List<String> deleted = [];

  @override
  Future<String> saveBytesForChatAttachment({
    required String attachmentId,
    required String fileName,
    required List<int> bytes,
  }) async {
    saved[attachmentId] = List.of(bytes);
    return 'attachments/chat/$attachmentId/$fileName';
  }

  @override
  Future<void> deleteChatAttachment(String attachmentId) async {
    deleted.add(attachmentId);
    saved.remove(attachmentId);
  }
}
