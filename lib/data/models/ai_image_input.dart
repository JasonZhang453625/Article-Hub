import 'dart:typed_data';

/// Ephemeral image input sent with one AI completion request.
///
/// Bytes are deliberately not persisted in Hive. Chat attachments keep only
/// app-owned file metadata and are resolved immediately before a request.
class AiImageInput {
  final String id;
  final String fileName;
  final String mimeType;
  final Uint8List bytes;

  const AiImageInput({
    required this.id,
    required this.fileName,
    required this.mimeType,
    required this.bytes,
  });
}
