import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_attachment.dart';
import 'attachment_store.dart';

const int maxChatAttachments = 9;
const int maxChatAttachmentBytes = 10 * 1024 * 1024;
const int maxChatAttachmentTotalBytes = 24 * 1024 * 1024;

const Set<String> chatImageExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp'};

const Set<String> chatFileExtensions = {
  'pdf',
  'txt',
  'md',
  'markdown',
  'csv',
  'json',
  'yaml',
  'yml',
  'xml',
  'html',
  'htm',
  'log',
  'ini',
  'toml',
  'sql',
  'dart',
  'js',
  'ts',
  'py',
  'java',
  'kt',
  'swift',
  'c',
  'h',
  'cpp',
  'hpp',
  'rs',
  'go',
};

class ChatAttachmentDraft {
  final ChatAttachment attachment;
  final Uint8List previewBytes;

  const ChatAttachmentDraft({
    required this.attachment,
    required this.previewBytes,
  });
}

class ChatAttachmentException implements Exception {
  final String code;
  final String? fileName;

  const ChatAttachmentException(this.code, {this.fileName});

  @override
  String toString() => fileName == null ? code : '$code: $fileName';
}

/// Picks, validates, fingerprints, and stores chat attachment drafts.
class ChatAttachmentService {
  final AttachmentStore _store;

  ChatAttachmentService({AttachmentStore? store})
    : _store = store ?? AttachmentStore();

  Future<List<ChatAttachmentDraft>> pickImages({
    int remainingSlots = maxChatAttachments,
    int remainingBytes = maxChatAttachmentTotalBytes,
  }) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: chatImageExtensions.toList(growable: false),
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return const [];
    return importPickedFiles(
      result.files,
      kind: ChatAttachmentKind.image,
      remainingSlots: remainingSlots,
      remainingBytes: remainingBytes,
    );
  }

  Future<List<ChatAttachmentDraft>> pickFiles({
    int remainingSlots = maxChatAttachments,
    int remainingBytes = maxChatAttachmentTotalBytes,
  }) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: chatFileExtensions.toList(growable: false),
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return const [];
    return importPickedFiles(
      result.files,
      kind: ChatAttachmentKind.file,
      remainingSlots: remainingSlots,
      remainingBytes: remainingBytes,
    );
  }

  Future<List<ChatAttachmentDraft>> importPickedFiles(
    List<PlatformFile> files, {
    required ChatAttachmentKind kind,
    int remainingSlots = maxChatAttachments,
    int remainingBytes = maxChatAttachmentTotalBytes,
  }) async {
    if (files.length > remainingSlots) {
      throw const ChatAttachmentException('too_many');
    }

    final drafts = <ChatAttachmentDraft>[];
    var selectedBytes = 0;
    try {
      for (final file in files) {
        final extension = _extension(file.name);
        final allowed = kind == ChatAttachmentKind.image
            ? chatImageExtensions
            : chatFileExtensions;
        if (!allowed.contains(extension)) {
          throw ChatAttachmentException(
            'unsupported_type',
            fileName: file.name,
          );
        }

        final bytes = await _readBytes(file);
        if (bytes.isEmpty) {
          throw ChatAttachmentException('empty_file', fileName: file.name);
        }
        if (bytes.length > maxChatAttachmentBytes) {
          throw ChatAttachmentException('too_large', fileName: file.name);
        }
        selectedBytes += bytes.length;
        if (selectedBytes > remainingBytes) {
          throw const ChatAttachmentException('total_too_large');
        }

        final id = const Uuid().v4();
        final digest = await Sha256().hash(bytes);
        final relativePath = await _store.saveBytesForChatAttachment(
          attachmentId: id,
          fileName: file.name,
          bytes: bytes,
        );
        drafts.add(
          ChatAttachmentDraft(
            attachment: ChatAttachment(
              id: id,
              kind: kind,
              localPath: relativePath,
              mimeType: _mimeType(file.name, kind),
              originalFileName: file.name,
              byteLength: bytes.length,
              sha256: _hex(digest.bytes),
            ),
            previewBytes: bytes,
          ),
        );
      }
      return List.unmodifiable(drafts);
    } catch (_) {
      await discardDrafts(drafts);
      rethrow;
    }
  }

  Future<void> discardDraft(ChatAttachmentDraft draft) {
    return _store.deleteChatAttachment(draft.attachment.id);
  }

  Future<void> discardDrafts(Iterable<ChatAttachmentDraft> drafts) async {
    for (final draft in drafts) {
      await _store.deleteChatAttachment(draft.attachment.id);
    }
  }

  Future<void> deletePersisted(Iterable<ChatAttachment> attachments) async {
    for (final attachment in attachments) {
      await _store.deleteChatAttachment(attachment.id);
    }
  }

  Future<Uint8List> _readBytes(PlatformFile file) async {
    final included = file.bytes;
    if (included != null) return included;
    final path = file.path;
    if (path == null || path.trim().isEmpty) {
      throw ChatAttachmentException('read_failed', fileName: file.name);
    }
    try {
      return File(path).readAsBytes();
    } catch (_) {
      throw ChatAttachmentException('read_failed', fileName: file.name);
    }
  }
}

String _extension(String fileName) {
  final match = RegExp(r'\.([^.]+)$').firstMatch(fileName.trim());
  return match?.group(1)?.toLowerCase() ?? '';
}

String _mimeType(String fileName, ChatAttachmentKind kind) {
  final extension = _extension(fileName);
  if (kind == ChatAttachmentKind.image) {
    return switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      _ => 'image/png',
    };
  }
  return switch (extension) {
    'pdf' => 'application/pdf',
    'md' || 'markdown' => 'text/markdown',
    'csv' => 'text/csv',
    'json' => 'application/json',
    'yaml' || 'yml' => 'application/yaml',
    'xml' => 'application/xml',
    'html' || 'htm' => 'text/html',
    _ => 'text/plain',
  };
}

String _hex(List<int> bytes) {
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
