enum ArticleAttachmentKind {
  image('image');

  final String storedValue;
  const ArticleAttachmentKind(this.storedValue);

  static ArticleAttachmentKind fromStoredValue(dynamic value) {
    for (final kind in ArticleAttachmentKind.values) {
      if (kind.storedValue == value) return kind;
    }
    throw FormatException('Unsupported attachment kind: $value');
  }
}

/// App-owned metadata for a local article attachment.
///
/// Attachment bytes remain in [localPath]. Only this JSON-compatible metadata
/// is persisted in Hive, backup, and sync payloads.
class ArticleAttachment {
  final int schemaVersion;
  final String id;
  final ArticleAttachmentKind kind;
  final int order;
  final String localPath;
  final String mimeType;
  final String originalFileName;
  final int byteLength;
  final String sha256;
  final int? width;
  final int? height;

  const ArticleAttachment({
    this.schemaVersion = 1,
    required this.id,
    this.kind = ArticleAttachmentKind.image,
    required this.order,
    required this.localPath,
    required this.mimeType,
    required this.originalFileName,
    required this.byteLength,
    required this.sha256,
    this.width,
    this.height,
  });

  bool get isImage => kind == ArticleAttachmentKind.image;

  /// Legacy single-image records have no byte length or hash. They are useful
  /// for display compatibility but must be re-fingerprinted before upload.
  bool get hasUploadFingerprint =>
      byteLength > 0 && RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256);

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'id': id,
      'kind': kind.storedValue,
      'order': order,
      'localPath': localPath,
      'mimeType': mimeType,
      'originalFileName': originalFileName,
      'byteLength': byteLength,
      'sha256': sha256,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
    };
  }

  factory ArticleAttachment.fromJson(Map<dynamic, dynamic> json) {
    final id = json['id'];
    final order = json['order'];
    final localPath = json['localPath'];
    final mimeType = json['mimeType'];
    if (id is! String ||
        id.trim().isEmpty ||
        order is! int ||
        order < 0 ||
        localPath is! String ||
        localPath.trim().isEmpty ||
        mimeType is! String ||
        mimeType.trim().isEmpty) {
      throw const FormatException('Attachment is missing required fields');
    }

    final originalFileName = json['originalFileName'];
    final byteLength = json['byteLength'];
    final sha256 = json['sha256'];
    return ArticleAttachment(
      schemaVersion: json['schemaVersion'] is int
          ? json['schemaVersion'] as int
          : 1,
      id: id,
      kind: ArticleAttachmentKind.fromStoredValue(json['kind'] ?? 'image'),
      order: order,
      localPath: localPath,
      mimeType: mimeType,
      originalFileName:
          originalFileName is String && originalFileName.trim().isNotEmpty
          ? originalFileName
          : _fileNameFromPath(localPath),
      byteLength: byteLength is int && byteLength >= 0 ? byteLength : 0,
      sha256: sha256 is String ? sha256.toLowerCase() : '',
      width: json['width'] is int ? json['width'] as int : null,
      height: json['height'] is int ? json['height'] as int : null,
    );
  }

  factory ArticleAttachment.legacyImage({
    required String articleId,
    required String localPath,
    required String mimeType,
  }) {
    return ArticleAttachment(
      id: 'legacy-$articleId',
      order: 0,
      localPath: localPath,
      mimeType: mimeType,
      originalFileName: _fileNameFromPath(localPath),
      byteLength: 0,
      sha256: '',
    );
  }
}

String _fileNameFromPath(String path) {
  final parts = path.split(RegExp(r'[/\\]'));
  return parts.isEmpty || parts.last.isEmpty ? 'image' : parts.last;
}
