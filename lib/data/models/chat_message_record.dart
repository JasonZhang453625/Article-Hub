import 'package:hive/hive.dart';

enum ChatMessageRole { system, user, assistant }

enum ChatMessageStatus { sending, completed, failed, interrupted }

class ChatMessageRecord {
  static const int typeId = 8;

  final String id;
  final String threadId;
  final ChatMessageRole role;
  final String content;
  final DateTime createdAt;
  final List<String> articleIds;
  final List<String> weakArticleIds;
  final String? method;
  final String? logId;
  final bool isNoResult;
  final String? query;
  final int? feedback;
  final ChatMessageStatus status;
  final String? errorCode;

  /// Web URLs the model cited (via `[wN]`) in a web-fallback answer.
  final List<String> webUrls;

  const ChatMessageRecord({
    required this.id,
    required this.threadId,
    required this.role,
    required this.content,
    required this.createdAt,
    this.articleIds = const [],
    this.weakArticleIds = const [],
    this.method,
    this.logId,
    this.isNoResult = false,
    this.query,
    this.feedback,
    this.status = ChatMessageStatus.completed,
    this.errorCode,
    this.webUrls = const [],
  });

  ChatMessageRecord copyWith({
    String? content,
    List<String>? articleIds,
    List<String>? weakArticleIds,
    String? method,
    String? logId,
    bool? isNoResult,
    String? query,
    int? feedback,
    ChatMessageStatus? status,
    String? errorCode,
    List<String>? webUrls,
  }) {
    return ChatMessageRecord(
      id: id,
      threadId: threadId,
      role: role,
      content: content ?? this.content,
      createdAt: createdAt,
      articleIds: articleIds ?? this.articleIds,
      weakArticleIds: weakArticleIds ?? this.weakArticleIds,
      method: method ?? this.method,
      logId: logId ?? this.logId,
      isNoResult: isNoResult ?? this.isNoResult,
      query: query ?? this.query,
      feedback: feedback ?? this.feedback,
      status: status ?? this.status,
      errorCode: errorCode ?? this.errorCode,
      webUrls: webUrls ?? this.webUrls,
    );
  }

  /// Resets only the generated answer while keeping the original message id
  /// and question. Retrying in place avoids duplicating the user's question
  /// and prevents stale citations, feedback, or provider metadata from being
  /// shown while the new answer is being generated.
  ChatMessageRecord retrying() {
    return ChatMessageRecord(
      id: id,
      threadId: threadId,
      role: role,
      content: '',
      createdAt: createdAt,
      query: query,
      status: ChatMessageStatus.sending,
    );
  }
}

class ChatMessageRecordAdapter extends TypeAdapter<ChatMessageRecord> {
  @override
  final int typeId = ChatMessageRecord.typeId;

  @override
  ChatMessageRecord read(BinaryReader reader) {
    final fieldCount = reader.readByte();
    final fields = <int, dynamic>{
      for (var i = 0; i < fieldCount; i++) reader.readByte(): reader.read(),
    };
    return ChatMessageRecord(
      id: fields[0] as String? ?? '',
      threadId: fields[1] as String? ?? '',
      role: _roleFromStoredValue((fields[2] as num?)?.toInt()),
      content: fields[3] as String? ?? '',
      createdAt: fields[4] as DateTime? ?? DateTime.now().toUtc(),
      articleIds: _stringList(fields[5]),
      weakArticleIds: _stringList(fields[6]),
      method: fields[7] as String?,
      logId: fields[8] as String?,
      isNoResult: fields[9] as bool? ?? false,
      query: fields[10] as String?,
      feedback: (fields[11] as num?)?.toInt(),
      status: _statusFromStoredValue((fields[12] as num?)?.toInt()),
      errorCode: fields[13] as String?,
      webUrls: _stringList(fields[14]),
    );
  }

  @override
  void write(BinaryWriter writer, ChatMessageRecord obj) {
    writer
      ..writeByte(15)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.threadId)
      ..writeByte(2)
      ..write(_roleToStoredValue(obj.role))
      ..writeByte(3)
      ..write(obj.content)
      ..writeByte(4)
      ..write(obj.createdAt)
      ..writeByte(5)
      ..write(obj.articleIds)
      ..writeByte(6)
      ..write(obj.weakArticleIds)
      ..writeByte(7)
      ..write(obj.method)
      ..writeByte(8)
      ..write(obj.logId)
      ..writeByte(9)
      ..write(obj.isNoResult)
      ..writeByte(10)
      ..write(obj.query)
      ..writeByte(11)
      ..write(obj.feedback)
      ..writeByte(12)
      ..write(_statusToStoredValue(obj.status))
      ..writeByte(13)
      ..write(obj.errorCode)
      ..writeByte(14)
      ..write(obj.webUrls);
  }
}

List<String> _stringList(dynamic value) {
  if (value is! List) return const [];
  return value.whereType<String>().toList(growable: false);
}

int _roleToStoredValue(ChatMessageRole role) {
  return switch (role) {
    ChatMessageRole.system => 0,
    ChatMessageRole.user => 1,
    ChatMessageRole.assistant => 2,
  };
}

ChatMessageRole _roleFromStoredValue(int? value) {
  return switch (value) {
    0 => ChatMessageRole.system,
    1 => ChatMessageRole.user,
    _ => ChatMessageRole.assistant,
  };
}

int _statusToStoredValue(ChatMessageStatus status) {
  return switch (status) {
    ChatMessageStatus.sending => 0,
    ChatMessageStatus.completed => 1,
    ChatMessageStatus.failed => 2,
    ChatMessageStatus.interrupted => 3,
  };
}

ChatMessageStatus _statusFromStoredValue(int? value) {
  return switch (value) {
    0 => ChatMessageStatus.sending,
    2 => ChatMessageStatus.failed,
    3 => ChatMessageStatus.interrupted,
    _ => ChatMessageStatus.completed,
  };
}
