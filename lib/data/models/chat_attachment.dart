enum ChatAttachmentKind {
  image('image'),
  file('file');

  final String storedValue;

  const ChatAttachmentKind(this.storedValue);

  static ChatAttachmentKind fromStoredValue(dynamic value) {
    return switch (value) {
      'image' => ChatAttachmentKind.image,
      _ => ChatAttachmentKind.file,
    };
  }
}

final RegExp _chatAttachmentIdPattern = RegExp(
  r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$',
);

bool isValidChatAttachmentId(String value) {
  return _chatAttachmentIdPattern.hasMatch(value);
}

/// Durable metadata for a file attached to a chat message.
///
/// The actual bytes stay under app-owned attachment storage. Keeping this as
/// JSON inside `ChatMessageRecord` avoids consuming another Hive type id.
class ChatAttachment {
  final int schemaVersion;
  final String id;
  final ChatAttachmentKind kind;
  final String localPath;
  final String mimeType;
  final String originalFileName;
  final int byteLength;
  final String sha256;

  const ChatAttachment({
    this.schemaVersion = 1,
    required this.id,
    required this.kind,
    required this.localPath,
    required this.mimeType,
    required this.originalFileName,
    required this.byteLength,
    required this.sha256,
  });

  bool get isImage => kind == ChatAttachmentKind.image;

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'id': id,
      'kind': kind.storedValue,
      'localPath': localPath,
      'mimeType': mimeType,
      'originalFileName': originalFileName,
      'byteLength': byteLength,
      'sha256': sha256,
    };
  }

  factory ChatAttachment.fromJson(Map<dynamic, dynamic> json) {
    final id = json['id'];
    final localPath = json['localPath'];
    final mimeType = json['mimeType'];
    final originalFileName = json['originalFileName'];
    final byteLength = json['byteLength'];
    final sha256 = json['sha256'];
    if (id is! String ||
        !isValidChatAttachmentId(id) ||
        localPath is! String ||
        localPath.trim().isEmpty ||
        mimeType is! String ||
        mimeType.trim().isEmpty ||
        originalFileName is! String ||
        originalFileName.trim().isEmpty ||
        byteLength is! int ||
        byteLength <= 0 ||
        sha256 is! String ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256)) {
      throw const FormatException('Invalid chat attachment metadata');
    }
    return ChatAttachment(
      schemaVersion: json['schemaVersion'] is int
          ? json['schemaVersion'] as int
          : 1,
      id: id,
      kind: ChatAttachmentKind.fromStoredValue(json['kind']),
      localPath: localPath,
      mimeType: mimeType.toLowerCase(),
      originalFileName: originalFileName,
      byteLength: byteLength,
      sha256: sha256.toLowerCase(),
    );
  }
}

List<ChatAttachment> chatAttachmentsFromStored(dynamic value) {
  if (value is! List) return const [];
  final attachments = <ChatAttachment>[];
  for (final item in value) {
    if (item is! Map) continue;
    try {
      attachments.add(ChatAttachment.fromJson(item));
    } on FormatException {
      // One corrupt attachment must not make the entire chat box unreadable.
    }
  }
  return List.unmodifiable(attachments);
}

/// Extracts only validated ownership ids from stored attachment metadata.
///
/// File cleanup must not depend on unrelated display metadata such as MIME,
/// original name, size, or digest remaining parseable.
List<String> chatAttachmentIdsFromStored(dynamic value) {
  if (value is! List) return const [];
  final ids = <String>{};
  for (final item in value) {
    final dynamic candidate = item is Map ? item['id'] : item;
    if (candidate is String && isValidChatAttachmentId(candidate)) {
      ids.add(candidate);
    }
  }
  final result = ids.toList()..sort();
  return List.unmodifiable(result);
}
