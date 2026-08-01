import 'package:hive/hive.dart';

class ChatThread {
  static const int typeId = 7;

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String lastMessagePreview;

  const ChatThread({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.lastMessagePreview = '',
  });

  ChatThread copyWith({
    String? title,
    DateTime? updatedAt,
    String? lastMessagePreview,
  }) {
    return ChatThread(
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
    );
  }
}

class ChatThreadAdapter extends TypeAdapter<ChatThread> {
  @override
  final int typeId = ChatThread.typeId;

  @override
  ChatThread read(BinaryReader reader) {
    final fieldCount = reader.readByte();
    final fields = <int, dynamic>{
      for (var i = 0; i < fieldCount; i++) reader.readByte(): reader.read(),
    };
    final createdAt = fields[2] as DateTime? ?? DateTime.now().toUtc();
    return ChatThread(
      id: fields[0] as String? ?? '',
      title: fields[1] as String? ?? '',
      createdAt: createdAt,
      updatedAt: fields[3] as DateTime? ?? createdAt,
      lastMessagePreview: fields[4] as String? ?? '',
    );
  }

  @override
  void write(BinaryWriter writer, ChatThread obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.createdAt)
      ..writeByte(3)
      ..write(obj.updatedAt)
      ..writeByte(4)
      ..write(obj.lastMessagePreview);
  }
}

String chatTitleFromMessage(String message, {int maxRunes = 32}) {
  return _boundedChatText(message, maxRunes: maxRunes);
}

String chatPreviewFromMessage(String message, {int maxRunes = 64}) {
  return _boundedChatText(message, maxRunes: maxRunes);
}

String _boundedChatText(String text, {required int maxRunes}) {
  final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isEmpty) return '';
  final runes = normalized.runes.toList(growable: false);
  if (runes.length <= maxRunes) return normalized;
  return '${String.fromCharCodes(runes.take(maxRunes))}…';
}
