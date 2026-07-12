import 'package:uuid/uuid.dart';

import '../models/passage.dart';
import '../models/source_platform.dart';
import 'attachment_store.dart';
import 'ocr_service.dart';
import 'pdf_content_extractor.dart';
import 'processing_pipeline.dart';

/// Result of preparing a local file import (image or PDF).
class LocalFileImportResult {
  final Article article;
  final String content;

  const LocalFileImportResult({
    required this.article,
    required this.content,
  });
}

/// Shared import path for manual pick + system share of local files.
class LocalFileImporter {
  final AttachmentStore _attachments;
  final OcrService _ocr;
  final PdfContentExtractor _pdf;

  factory LocalFileImporter({
    AttachmentStore? attachments,
    OcrService? ocr,
    PdfContentExtractor? pdf,
  }) {
    final ocrService = ocr ?? OcrService();
    return LocalFileImporter._(
      attachments: attachments ?? AttachmentStore(),
      ocr: ocrService,
      pdf: pdf ?? PdfContentExtractor(ocr: ocrService),
    );
  }

  LocalFileImporter._({
    required AttachmentStore attachments,
    required OcrService ocr,
    required PdfContentExtractor pdf,
  })  : _attachments = attachments,
        _ocr = ocr,
        _pdf = pdf;

  /// Copy file into app storage, extract text, return a pending [Article].
  Future<LocalFileImportResult> prepare({
    required String sourcePath,
    String? title,
    String notes = '',
    String? folderId,
    void Function(String stage, double? progress)? onProgress,
  }) async {
    final id = const Uuid().v4();
    onProgress?.call('save', 0);
    final relative = await _attachments.saveForArticle(
      articleId: id,
      sourcePath: sourcePath,
    );
    final abs = await _attachments.resolveAbsolutePath(relative);
    if (abs == null) {
      throw StateError('Failed to resolve saved attachment');
    }

    final mime = mimeFromPath(sourcePath) ?? mimeFromPath(relative);
    final content = await extractContent(
      abs,
      mime,
      onProgress: onProgress,
    );
    final baseTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : _titleFromPath(sourcePath);

    String? coverRelative;
    if (isPdfMime(mime) || isPdfPath(abs)) {
      try {
        onProgress?.call('cover', 0.95);
        final jpeg = await _pdf.renderCoverJpeg(abs);
        if (jpeg != null && jpeg.isNotEmpty) {
          coverRelative = await _attachments.saveBytesForArticle(
            articleId: id,
            fileName: 'cover.jpg',
            bytes: jpeg,
          );
        }
      } catch (_) {
        // Cover is best-effort.
      }
    }

    final article = Article(
      id: id,
      url: 'file://$abs',
      title: baseTitle,
      source: SourcePlatform.local,
      notes: notes,
      folderId: folderId,
      localFilePath: relative,
      localMimeType: mime,
      // Local relative path; UI resolves via AttachmentStore for both image/PDF.
      coverImageUrl: coverRelative,
      processingStatus: ProcessingStatus.pending,
    );

    onProgress?.call('ready', 1);
    return LocalFileImportResult(article: article, content: content);
  }

  /// Re-extract content for an already-saved local article.
  Future<String> reExtract(
    Article article, {
    void Function(String stage, double? progress)? onProgress,
  }) async {
    final abs = await _attachments.resolveAbsolutePath(article.localFilePath);
    if (abs == null) {
      throw StateError('Local file missing for article ${article.id}');
    }
    return extractContent(
      abs,
      article.localMimeType,
      onProgress: onProgress,
    );
  }

  Future<String> extractContent(
    String absPath,
    String? mime, {
    void Function(String stage, double? progress)? onProgress,
  }) async {
    if (isPdfMime(mime) || isPdfPath(absPath)) {
      return _pdf.extractText(absPath, onProgress: onProgress);
    }
    if (isImageMime(mime) || isImagePath(absPath)) {
      onProgress?.call('ocr', 0.2);
      final text = await _ocr.recognizeImagePath(absPath);
      onProgress?.call('ready', 1);
      return text;
    }
    throw StateError('Unsupported local file type: $mime / $absPath');
  }

  Future<Article?> process({
    required Article article,
    required String content,
    required ProcessingPipeline pipeline,
    bool fullText = false,
  }) {
    return pipeline.processFile(article, content, fullText: fullText);
  }

  void dispose() => _ocr.dispose();

  String _titleFromPath(String path) {
    final name = path.replaceAll('\\', '/').split('/').last;
    return name.replaceAll(RegExp(r'\.[^.]+$'), '');
  }
}

/// Backward-compatible alias used by older call sites.
@Deprecated('Use LocalFileImporter')
typedef LocalImageImporter = LocalFileImporter;

/// Backward-compatible alias for import result.
@Deprecated('Use LocalFileImportResult')
typedef LocalImageImportResult = LocalFileImportResult;
