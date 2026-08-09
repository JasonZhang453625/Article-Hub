import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/chat_attachment.dart';

/// App-owned storage for imported local files (images, etc.).
class AttachmentStore {
  static const rootFolderName = 'attachments';
  static const chatFolderName = 'chat';

  Future<Directory> _root() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, rootFolderName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Copy [sourcePath] into `attachments/{articleId}/...`.
  ///
  /// Returns a relative path (from app support) suitable for Hive storage.
  Future<String> saveForArticle({
    required String articleId,
    required String sourcePath,
    String? preferredName,
  }) async {
    final root = await _root();
    final articleDir = Directory(p.join(root.path, articleId));
    if (!await articleDir.exists()) {
      await articleDir.create(recursive: true);
    }

    final source = File(sourcePath);
    if (!await source.exists()) {
      throw StateError('Source file not found: $sourcePath');
    }

    final baseName = preferredName ?? p.basename(sourcePath);
    final safeName = baseName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final dest = File(p.join(articleDir.path, safeName));
    await source.copy(dest.path);
    return p.join(rootFolderName, articleId, safeName);
  }

  Future<File?> resolve(String? relativePath) async {
    if (relativePath == null || relativePath.trim().isEmpty) return null;
    final support = await getApplicationSupportDirectory();
    final file = File(p.join(support.path, relativePath));
    if (await file.exists()) return file;
    // Also accept absolute paths written by older builds.
    final abs = File(relativePath);
    if (await abs.exists()) return abs;
    return null;
  }

  Future<String?> resolveAbsolutePath(String? relativePath) async {
    final file = await resolve(relativePath);
    return file?.path;
  }

  Future<void> deleteForArticle(String articleId) async {
    final root = await _root();
    final dir = Directory(p.join(root.path, articleId));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// Store one chat attachment in its own folder.
  ///
  /// A per-attachment folder makes draft removal and thread deletion precise:
  /// no sibling message or article files can be removed accidentally.
  Future<String> saveBytesForChatAttachment({
    required String attachmentId,
    required String fileName,
    required List<int> bytes,
  }) async {
    if (!isValidChatAttachmentId(attachmentId)) {
      throw ArgumentError.value(
        attachmentId,
        'attachmentId',
        'Invalid chat attachment id',
      );
    }
    final root = await _root();
    final dir = Directory(p.join(root.path, chatFolderName, attachmentId));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final safeName = _safeFileName(fileName);
    final dest = File(p.join(dir.path, safeName));
    await dest.writeAsBytes(bytes, flush: true);
    return p.join(rootFolderName, chatFolderName, attachmentId, safeName);
  }

  /// Resolve a chat attachment only inside its app-owned UUID directory.
  ///
  /// Chat metadata can be restored from Hive/backup data, so it must not be
  /// allowed to turn a relative path into an arbitrary local file read.
  Future<File?> resolveChatAttachment({
    required String attachmentId,
    required String relativePath,
  }) async {
    if (!isValidChatAttachmentId(attachmentId) || relativePath.trim().isEmpty) {
      return null;
    }
    final support = await getApplicationSupportDirectory();
    final attachmentDir = p.normalize(
      p.join(support.path, rootFolderName, chatFolderName, attachmentId),
    );
    final candidate = p.normalize(
      p.isAbsolute(relativePath)
          ? relativePath
          : p.join(support.path, relativePath),
    );
    if (!p.isWithin(attachmentDir, candidate)) return null;
    final file = File(candidate);
    return await file.exists() ? file : null;
  }

  Future<void> deleteChatAttachment(String attachmentId) async {
    if (!isValidChatAttachmentId(attachmentId)) return;
    final root = await _root();
    final dir = Directory(p.join(root.path, chatFolderName, attachmentId));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// Write raw [bytes] as a file under `attachments/{articleId}/`.
  ///
  /// Returns a relative path suitable for Hive storage.
  Future<String> saveBytesForArticle({
    required String articleId,
    required String fileName,
    required List<int> bytes,
  }) async {
    final root = await _root();
    final articleDir = Directory(p.join(root.path, articleId));
    if (!await articleDir.exists()) {
      await articleDir.create(recursive: true);
    }
    final safeName = _safeFileName(fileName);
    final dest = File(p.join(articleDir.path, safeName));
    await dest.writeAsBytes(bytes, flush: true);
    return p.join(rootFolderName, articleId, safeName);
  }
}

String _safeFileName(String value) {
  final sanitized = value
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .trim();
  if (sanitized.isEmpty || sanitized == '.' || sanitized == '..') {
    return 'attachment';
  }
  return sanitized;
}

/// Guess a MIME type from a file path extension.
String? mimeFromPath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.bmp')) return 'image/bmp';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.pdf')) return 'application/pdf';
  if (lower.endsWith('.md')) return 'text/markdown';
  if (lower.endsWith('.txt')) return 'text/plain';
  return null;
}

bool isImageMime(String? mime) =>
    mime != null && mime.toLowerCase().startsWith('image/');

bool isPdfMime(String? mime) =>
    mime != null && mime.toLowerCase() == 'application/pdf';

bool isImagePath(String path) {
  final mime = mimeFromPath(path);
  return isImageMime(mime);
}

bool isPdfPath(String path) {
  final mime = mimeFromPath(path);
  return isPdfMime(mime);
}
