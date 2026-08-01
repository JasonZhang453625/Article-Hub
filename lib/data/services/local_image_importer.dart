import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

import '../models/article_attachment.dart';
import '../models/passage.dart';
import '../models/source_platform.dart';
import 'attachment_store.dart';

const int maxImagesPerMemory = 9;

const Set<String> supportedImageUnderstandingMimeTypes = {
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
};

class LocalImageCandidate {
  final String path;
  final String fileName;
  final String mimeType;

  const LocalImageCandidate({
    required this.path,
    required this.fileName,
    required this.mimeType,
  });
}

/// Copies an ordered image selection into app-owned storage and creates a
/// durable pending Article. It does not perform OCR or any network request.
class LocalImageImporter {
  final AttachmentStore _attachments;

  LocalImageImporter({AttachmentStore? attachments})
    : _attachments = attachments ?? AttachmentStore();

  Future<Article> prepare({
    required List<LocalImageCandidate> images,
    String? title,
    String notes = '',
    List<String> tags = const [],
    String? folderId,
    bool fullText = false,
    bool processImages = true,
  }) async {
    if (images.isEmpty || images.length > maxImagesPerMemory) {
      throw ArgumentError.value(
        images.length,
        'images',
        'Select between 1 and $maxImagesPerMemory images',
      );
    }

    final id = const Uuid().v4();
    final stored = <ArticleAttachment>[];
    try {
      for (var order = 0; order < images.length; order++) {
        final candidate = images[order];
        final mimeType = candidate.mimeType.toLowerCase();
        if (!supportedImageUnderstandingMimeTypes.contains(mimeType)) {
          throw ArgumentError.value(
            candidate.mimeType,
            'mimeType',
            'Unsupported image type',
          );
        }
        final source = File(candidate.path);
        if (!await source.exists()) {
          throw StateError('Image file not found: ${candidate.path}');
        }
        final bytes = await source.readAsBytes();
        if (bytes.isEmpty) {
          throw StateError('Image file is empty: ${candidate.path}');
        }
        final digest = await Sha256().hash(bytes);
        final relativePath = await _attachments.saveForArticle(
          articleId: id,
          sourcePath: candidate.path,
          preferredName:
              '${order.toString().padLeft(2, '0')}_${candidate.fileName}',
        );
        stored.add(
          ArticleAttachment(
            id: const Uuid().v4(),
            order: order,
            localPath: relativePath,
            mimeType: mimeType,
            originalFileName: candidate.fileName,
            byteLength: bytes.length,
            sha256: _hex(digest.bytes),
          ),
        );
      }

      final requestedTitle = title?.trim() ?? '';
      final fallbackTitle = _withoutExtension(images.first.fileName);
      return Article(
        id: id,
        url: 'local-images://$id',
        title: requestedTitle.isNotEmpty
            ? requestedTitle
            : (fallbackTitle.isNotEmpty ? fallbackTitle : 'Image memory'),
        source: SourcePlatform.local,
        tags: tags,
        notes: notes,
        folderId: folderId,
        isFullText: fullText,
        attachments: stored,
        processingStatus: processImages
            ? ProcessingStatus.pending
            : ProcessingStatus.completed,
        lastProcessedAt: processImages ? null : DateTime.now().toUtc(),
      );
    } catch (_) {
      await _attachments.deleteForArticle(id);
      rethrow;
    }
  }
}

String _hex(List<int> bytes) {
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

String _withoutExtension(String name) {
  return name.replaceFirst(RegExp(r'\.[^.]+$'), '').trim();
}
