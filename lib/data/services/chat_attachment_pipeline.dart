import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../models/ai_image_input.dart';
import '../models/ai_text_attachment_input.dart';
import '../models/chat_attachment.dart';
import 'attachment_store.dart';
import 'chat_attachment_service.dart';
import 'pdf_content_extractor.dart';

const int maxChatAttachmentContextCharacters = 12000;

class PreparedChatAttachments {
  final String textContext;
  final List<AiTextAttachmentInput> textInputs;
  final List<AiImageInput> imageInputs;
  final bool includesImageUnderstanding;

  const PreparedChatAttachments({
    this.textContext = '',
    this.textInputs = const [],
    this.imageInputs = const [],
    this.includesImageUnderstanding = false,
  });
}

void validateNativeImageAttachmentEnvelope(
  Iterable<ChatAttachment> attachments, {
  required int maxImages,
  required int maxImageBytes,
  required int maxTotalImageBytes,
  Set<String>? allowedMimeTypes,
}) {
  final images = attachments.where((item) => item.isImage).toList();
  if (images.length > maxImages) {
    throw const ChatAttachmentException('too_many');
  }
  var imageBytes = 0;
  for (final image in images) {
    if (allowedMimeTypes != null &&
        !allowedMimeTypes.contains(image.mimeType.trim().toLowerCase())) {
      throw ChatAttachmentException(
        'unsupported_type',
        fileName: image.originalFileName,
      );
    }
    if (image.byteLength > maxImageBytes) {
      throw ChatAttachmentException(
        'too_large',
        fileName: image.originalFileName,
      );
    }
    imageBytes += image.byteLength;
  }
  if (imageBytes > maxTotalImageBytes) {
    throw const ChatAttachmentException('total_too_large');
  }
}

/// Converts durable chat attachments into one bounded prompt context and, when
/// supported by the selected chat model, native image message blocks.
class ChatAttachmentPipeline {
  final AttachmentStore _store;
  final PdfContentExtractor _pdf;

  ChatAttachmentPipeline({AttachmentStore? store, PdfContentExtractor? pdf})
    : _store = store ?? AttachmentStore(),
      _pdf = pdf ?? PdfContentExtractor();

  Future<PreparedChatAttachments> prepare({
    required List<ChatAttachment> attachments,
    required bool useNativeImageInput,
    int maxNativeImages = maxChatAttachments,
    int maxNativeImageBytes = maxChatAttachmentBytes,
    int maxNativeImageTotalBytes = maxChatAttachmentTotalBytes,
    Set<String>? allowedNativeImageMimeTypes,
    String? cachedTextContext,
    bool cachedIncludesImageUnderstanding = false,
  }) async {
    if (attachments.isEmpty) return const PreparedChatAttachments();

    final images = attachments.where((item) => item.isImage).toList();
    final files = attachments.where((item) => !item.isImage).toList();
    if (images.isNotEmpty && !useNativeImageInput) {
      throw const ChatAttachmentException('chat_model_no_image_input');
    }
    validateNativeImageAttachmentEnvelope(
      images,
      maxImages: maxNativeImages,
      maxImageBytes: maxNativeImageBytes,
      maxTotalImageBytes: maxNativeImageTotalBytes,
      allowedMimeTypes: allowedNativeImageMimeTypes,
    );

    // Older builds could cache a separate vision model's description here.
    // Do not replay that fallback into a direct-to-chat-model request; rebuild
    // the file context and send the original image bytes instead.
    final cached = cachedIncludesImageUnderstanding
        ? ''
        : cachedTextContext?.trim() ?? '';
    final sections = <String>[];
    if (cached.isNotEmpty) sections.add(cached);

    final textInputs = <AiTextAttachmentInput>[];
    if (cached.isEmpty) {
      var remainingText = maxChatAttachmentContextCharacters;
      for (var index = 0; index < files.length; index++) {
        final file = files[index];
        final rawText = await _extractFileText(file);
        final remainingFiles = files.length - index;
        final allowance = remainingText ~/ remainingFiles;
        final text = _boundedAttachmentText(rawText, allowance);
        remainingText -= text.length;
        textInputs.add(
          AiTextAttachmentInput(
            id: file.id,
            name: file.originalFileName,
            text: text,
          ),
        );
        sections.add('### File: ${file.originalFileName}\n$text');
      }
    } else if (files.isNotEmpty) {
      textInputs.add(
        AiTextAttachmentInput(
          id: 'cached-current-turn-text',
          name: files.length == 1
              ? files.single.originalFileName
              : 'Attached files',
          text: cached,
        ),
      );
    }

    final imageInputs = <AiImageInput>[];
    if (images.isNotEmpty) {
      for (final image in images) {
        final bytes = await _verifiedBytes(image);
        imageInputs.add(
          AiImageInput(
            id: image.id,
            fileName: image.originalFileName,
            mimeType: image.mimeType,
            bytes: bytes,
          ),
        );
      }
      if (cached.isEmpty) {
        sections.add(
          '### Images\n${images.map((item) => '- ${item.originalFileName}').join('\n')}',
        );
      }
    }

    return PreparedChatAttachments(
      textContext: _boundedContext(sections.join('\n\n')),
      textInputs: List.unmodifiable(textInputs),
      imageInputs: List.unmodifiable(imageInputs),
      includesImageUnderstanding: false,
    );
  }

  Future<String> _extractFileText(ChatAttachment attachment) async {
    final resolved = await _resolve(attachment);
    if (resolved == null) {
      throw ChatAttachmentException(
        'file_missing',
        fileName: attachment.originalFileName,
      );
    }

    String content;
    if (attachment.mimeType == 'application/pdf') {
      try {
        await _verifiedBytes(attachment, resolved: resolved);
        content = await _pdf.extractText(resolved.path);
      } catch (_) {
        throw ChatAttachmentException(
          'read_failed',
          fileName: attachment.originalFileName,
        );
      }
      if (!_pdf.isUsable(content)) {
        throw ChatAttachmentException(
          'pdf_no_text',
          fileName: attachment.originalFileName,
        );
      }
    } else {
      final bytes = await _verifiedBytes(attachment, resolved: resolved);
      content = utf8.decode(bytes, allowMalformed: true).trim();
      if (content.isEmpty) {
        throw ChatAttachmentException(
          'empty_file',
          fileName: attachment.originalFileName,
        );
      }
    }
    return content;
  }

  Future<Uint8List> _verifiedBytes(
    ChatAttachment attachment, {
    File? resolved,
  }) async {
    final file = resolved ?? await _resolve(attachment);
    if (file == null) {
      throw ChatAttachmentException(
        'file_missing',
        fileName: attachment.originalFileName,
      );
    }
    final bytes = await file.readAsBytes();
    if (bytes.length != attachment.byteLength) {
      throw ChatAttachmentException(
        'file_changed',
        fileName: attachment.originalFileName,
      );
    }
    final digest = await Sha256().hash(bytes);
    if (_hex(digest.bytes) != attachment.sha256) {
      throw ChatAttachmentException(
        'file_changed',
        fileName: attachment.originalFileName,
      );
    }
    return bytes;
  }

  Future<File?> _resolve(ChatAttachment attachment) {
    return _store.resolveChatAttachment(
      attachmentId: attachment.id,
      relativePath: attachment.localPath,
    );
  }
}

String _boundedContext(String value) {
  final text = value.trim();
  if (text.length <= maxChatAttachmentContextCharacters) return text;
  return '${text.substring(0, maxChatAttachmentContextCharacters)}\n\n[Attachment content truncated]';
}

String _boundedAttachmentText(String value, int maxCharacters) {
  final text = value.trim();
  if (text.length <= maxCharacters) return text;
  const marker = '\n\n[Attachment content truncated]';
  if (maxCharacters <= marker.length) {
    return text.substring(0, maxCharacters);
  }
  return '${text.substring(0, maxCharacters - marker.length)}$marker';
}

String _hex(List<int> bytes) {
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
