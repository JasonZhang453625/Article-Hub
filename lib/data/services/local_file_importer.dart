import 'package:uuid/uuid.dart';

import '../models/passage.dart';
import '../models/source_platform.dart';
import 'attachment_store.dart';
import 'pdf_content_extractor.dart';
import 'processing_pipeline.dart';

/// Result of preparing a local PDF import.
class LocalFileImportResult {
  final Article article;
  final String content;

  const LocalFileImportResult({required this.article, required this.content});
}

/// Shared import path for manual pick + system share of local files.
class LocalFileImporter {
  final AttachmentStore _attachments;
  final PdfContentExtractor _pdf;

  factory LocalFileImporter({
    AttachmentStore? attachments,
    PdfContentExtractor? pdf,
  }) {
    return LocalFileImporter._(
      attachments: attachments ?? AttachmentStore(),
      pdf: pdf ?? PdfContentExtractor(),
    );
  }

  LocalFileImporter._({
    required AttachmentStore attachments,
    required PdfContentExtractor pdf,
  }) : _attachments = attachments,
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
    final content = await extractContent(abs, mime, onProgress: onProgress);
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
      // Local relative path; UI resolves it via AttachmentStore.
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
    return extractContent(abs, article.localMimeType, onProgress: onProgress);
  }

  Future<String> extractContent(
    String absPath,
    String? mime, {
    void Function(String stage, double? progress)? onProgress,
  }) async {
    if (isPdfMime(mime) || isPdfPath(absPath)) {
      return _pdf.extractText(absPath, onProgress: onProgress);
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

  String _titleFromPath(String path) {
    final name = path.replaceAll('\\', '/').split('/').last;
    return name.replaceAll(RegExp(r'\.[^.]+$'), '');
  }
}
