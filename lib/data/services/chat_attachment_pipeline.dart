import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../models/ai_image_input.dart';
import '../models/article_attachment.dart';
import '../models/chat_attachment.dart';
import 'attachment_store.dart';
import 'chat_attachment_service.dart';
import 'image_understanding_service.dart';
import 'pdf_content_extractor.dart';

const int maxChatAttachmentContextCharacters = 12000;

class PreparedChatAttachments {
  final String textContext;
  final List<AiImageInput> imageInputs;
  final bool includesImageUnderstanding;

  const PreparedChatAttachments({
    this.textContext = '',
    this.imageInputs = const [],
    this.includesImageUnderstanding = false,
  });
}

/// Converts durable chat attachments into one bounded prompt context and, when
/// supported by the selected chat model, native image message blocks.
class ChatAttachmentPipeline {
  final AttachmentStore _store;
  final PdfContentExtractor _pdf;
  final ImageUnderstandingGateway? _vision;

  ChatAttachmentPipeline({
    AttachmentStore? store,
    PdfContentExtractor? pdf,
    ImageUnderstandingGateway? vision,
  }) : _store = store ?? AttachmentStore(),
       _pdf = pdf ?? PdfContentExtractor(),
       _vision = vision;

  Future<PreparedChatAttachments> prepare({
    required String requestId,
    required List<ChatAttachment> attachments,
    required bool useNativeImageInput,
    required String locale,
    String? cachedTextContext,
    bool cachedIncludesImageUnderstanding = false,
  }) async {
    if (attachments.isEmpty) return const PreparedChatAttachments();

    final images = attachments.where((item) => item.isImage).toList();
    final files = attachments.where((item) => !item.isImage).toList();
    final cached = cachedTextContext?.trim() ?? '';
    final sections = <String>[];
    if (cached.isNotEmpty) sections.add(cached);

    if (cached.isEmpty) {
      for (final file in files) {
        sections.add(await _extractFileSection(file));
      }
    }

    final imageInputs = <AiImageInput>[];
    var includesImageUnderstanding = cachedIncludesImageUnderstanding;
    if (images.isNotEmpty && useNativeImageInput) {
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
    } else if (images.isNotEmpty && !cachedIncludesImageUnderstanding) {
      final vision = _vision;
      if (vision == null) {
        throw const ChatAttachmentException('vision_not_configured');
      }
      final uploads = <ImageUnderstandingUpload>[];
      for (var index = 0; index < images.length; index++) {
        final image = images[index];
        uploads.add(
          ImageUnderstandingUpload(
            attachment: ArticleAttachment(
              id: image.id,
              order: index,
              localPath: image.localPath,
              mimeType: image.mimeType,
              originalFileName: image.originalFileName,
              byteLength: image.byteLength,
              sha256: image.sha256,
            ),
            bytes: await _verifiedBytes(image),
          ),
        );
      }
      final document = await vision.understand(
        articleId: 'chat-$requestId',
        images: uploads,
        locale: locale,
      );
      sections.add(
        '### Image understanding\n${document.combinedMarkdown.trim()}',
      );
      includesImageUnderstanding = true;
    }

    return PreparedChatAttachments(
      textContext: _boundedContext(sections.join('\n\n')),
      imageInputs: List.unmodifiable(imageInputs),
      includesImageUnderstanding: includesImageUnderstanding,
    );
  }

  Future<String> _extractFileSection(ChatAttachment attachment) async {
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
    return '### File: ${attachment.originalFileName}\n$content';
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

String _hex(List<int> bytes) {
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
