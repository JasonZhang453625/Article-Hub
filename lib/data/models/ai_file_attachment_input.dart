import 'dart:typed_data';

/// Original office attachment bytes sent only to a durable Hosted Agent run.
class AiFileAttachmentInput {
  final String id;
  final String name;
  final String mimeType;
  final Uint8List bytes;
  final String sha256;

  const AiFileAttachmentInput({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.bytes,
    required this.sha256,
  });
}
