import 'package:hive/hive.dart';

import 'chat_attachment.dart';

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

  /// Durable server-side generation id for hosted AI answers. This is kept
  /// separately from the local widget run token so a process restart can
  /// reconnect to the same server task instead of starting a duplicate run.
  final String? aiRunId;

  /// Last server event sequence observed by the client. It makes an SSE
  /// reconnect idempotent when the app is backgrounded or briefly loses
  /// connectivity.
  final int? aiRunEventSeq;

  /// Idempotency key for one concrete server generation attempt.
  ///
  /// It is deliberately distinct from [id]: a transport replay of the same
  /// attempt reuses this value, while an explicit user retry creates a new one.
  final String? aiRunRequestKey;

  /// Account that authorized the concrete hosted Agent create attempt.
  ///
  /// This is written before `POST /ai/runs`. Together with
  /// [aiRunRequestKey], it lets a later process safely reconcile a create
  /// whose 202 response may have been lost. A different signed-in account
  /// must never use this key for lookup.
  final String? aiRunOwnerUserId;

  /// Device that authorized the durable Agent attempt. Device-local tools
  /// must never be claimed by another installation, even for the same user.
  final String? aiRunOwnerDeviceId;

  /// Immutable protocol metadata negotiated before `POST /ai/runs`.
  final int? aiRunProtocolVersion;
  final int? aiRunClientToolsVersion;

  /// Local-knowledge policy frozen for this concrete run (`only`/`hybrid`).
  final String? aiRunKnowledgeMode;

  /// Files owned by this message. User messages may have attachments;
  /// assistant messages normally keep this empty.
  final List<ChatAttachment> attachments;

  /// Validated storage ownership ids retained even when the rest of an old
  /// attachment record is corrupt. This exists solely for idempotent cleanup.
  final List<String> attachmentIdsForCleanup;

  /// Bounded text extracted from files and, when required, the vision-model
  /// interpretation. It is cached for retry and bounded follow-up context,
  /// but is not rendered in the bubble.
  final String? attachmentContext;

  final bool attachmentContextIncludesImages;

  /// Whether this completed turn used private evidence.
  ///
  /// Hosted `memora.chat@2` reports the authoritative value after a durable
  /// run completes. The flag is copied to both messages in the completed
  /// user/assistant pair so later turns can propagate the DLP boundary without
  /// replaying attachment text into ordinary history.
  final bool privateEvidenceUsed;

  /// Accumulated reasoning text streamed from the Hosted Agent as
  /// `thinking.delta` events. Rendered in a collapsed "thinking" view, not
  /// into the main answer body.
  final String thinking;

  /// Tool-call progress events streamed from the Hosted Agent, each stored as
  /// a JSON object string. They stay visible alongside the final answer.
  final List<String> toolEvents;

  bool get hasUnresolvedAiRunCreate =>
      aiRunId == null &&
      aiRunOwnerUserId?.trim().isNotEmpty == true &&
      aiRunRequestKey?.trim().isNotEmpty == true &&
      (status == ChatMessageStatus.sending ||
          errorCode == 'hosted_cancel_requested');

  bool get usesDeviceClientTools =>
      aiRunProtocolVersion != null &&
      aiRunProtocolVersion! >= 3 &&
      aiRunClientToolsVersion == 1 &&
      (aiRunKnowledgeMode == 'only' || aiRunKnowledgeMode == 'hybrid');

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
    this.aiRunId,
    this.aiRunEventSeq,
    this.aiRunRequestKey,
    this.aiRunOwnerUserId,
    this.aiRunOwnerDeviceId,
    this.aiRunProtocolVersion,
    this.aiRunClientToolsVersion,
    this.aiRunKnowledgeMode,
    this.attachments = const [],
    this.attachmentIdsForCleanup = const [],
    this.attachmentContext,
    this.attachmentContextIncludesImages = false,
    this.privateEvidenceUsed = false,
    this.thinking = '',
    this.toolEvents = const [],
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
    String? aiRunId,
    int? aiRunEventSeq,
    String? aiRunRequestKey,
    String? aiRunOwnerUserId,
    String? aiRunOwnerDeviceId,
    int? aiRunProtocolVersion,
    int? aiRunClientToolsVersion,
    String? aiRunKnowledgeMode,
    List<ChatAttachment>? attachments,
    List<String>? attachmentIdsForCleanup,
    String? attachmentContext,
    bool? attachmentContextIncludesImages,
    bool? privateEvidenceUsed,
    String? thinking,
    List<String>? toolEvents,
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
      aiRunId: aiRunId ?? this.aiRunId,
      aiRunEventSeq: aiRunEventSeq ?? this.aiRunEventSeq,
      aiRunRequestKey: aiRunRequestKey ?? this.aiRunRequestKey,
      aiRunOwnerUserId: aiRunOwnerUserId ?? this.aiRunOwnerUserId,
      aiRunOwnerDeviceId: aiRunOwnerDeviceId ?? this.aiRunOwnerDeviceId,
      aiRunProtocolVersion: aiRunProtocolVersion ?? this.aiRunProtocolVersion,
      aiRunClientToolsVersion:
          aiRunClientToolsVersion ?? this.aiRunClientToolsVersion,
      aiRunKnowledgeMode: aiRunKnowledgeMode ?? this.aiRunKnowledgeMode,
      attachments: attachments ?? this.attachments,
      attachmentIdsForCleanup:
          attachmentIdsForCleanup ?? this.attachmentIdsForCleanup,
      attachmentContext: attachmentContext ?? this.attachmentContext,
      attachmentContextIncludesImages:
          attachmentContextIncludesImages ??
          this.attachmentContextIncludesImages,
      privateEvidenceUsed: privateEvidenceUsed ?? this.privateEvidenceUsed,
      thinking: thinking ?? this.thinking,
      toolEvents: toolEvents ?? this.toolEvents,
    );
  }

  /// Resets only the generated answer while keeping the original message id
  /// and question. Retrying in place avoids duplicating the user's question
  /// and prevents stale citations, feedback, or provider metadata from being
  /// shown while the new answer is being generated.
  ChatMessageRecord retrying({required String aiRunRequestKey}) {
    if (hasUnresolvedAiRunCreate) {
      throw StateError(
        'Cannot retry while a hosted Agent create is unresolved.',
      );
    }
    return ChatMessageRecord(
      id: id,
      threadId: threadId,
      role: role,
      content: '',
      createdAt: createdAt,
      query: query,
      status: ChatMessageStatus.sending,
      aiRunId: null,
      aiRunEventSeq: null,
      aiRunRequestKey: aiRunRequestKey,
      aiRunOwnerUserId: null,
      aiRunOwnerDeviceId: null,
      aiRunProtocolVersion: null,
      aiRunClientToolsVersion: null,
      aiRunKnowledgeMode: null,
      attachmentIdsForCleanup: attachmentIdsForCleanup,
      privateEvidenceUsed: false,
      thinking: '',
      toolEvents: const [],
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
      aiRunId: fields[15] as String?,
      aiRunEventSeq: (fields[16] as num?)?.toInt(),
      attachments: chatAttachmentsFromStored(fields[17]),
      attachmentIdsForCleanup: _cleanupAttachmentIds(fields[17], fields[21]),
      attachmentContext: fields[18] as String?,
      attachmentContextIncludesImages: fields[19] as bool? ?? false,
      aiRunRequestKey: fields[20] as String?,
      aiRunOwnerUserId: fields[22] as String?,
      aiRunOwnerDeviceId: fields[23] as String?,
      aiRunProtocolVersion: (fields[24] as num?)?.toInt(),
      aiRunClientToolsVersion: (fields[25] as num?)?.toInt(),
      aiRunKnowledgeMode: fields[26] as String?,
      privateEvidenceUsed: _privateEvidenceFromStoredFields(fields),
      thinking: fields[28] as String? ?? '',
      toolEvents: _stringList(fields[29]),
    );
  }

  @override
  void write(BinaryWriter writer, ChatMessageRecord obj) {
    writer
      ..writeByte(30)
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
      ..write(obj.webUrls)
      ..writeByte(15)
      ..write(obj.aiRunId)
      ..writeByte(16)
      ..write(obj.aiRunEventSeq)
      ..writeByte(17)
      ..write(obj.attachments.map((item) => item.toJson()).toList())
      ..writeByte(18)
      ..write(obj.attachmentContext)
      ..writeByte(19)
      ..write(obj.attachmentContextIncludesImages)
      ..writeByte(20)
      ..write(obj.aiRunRequestKey)
      ..writeByte(21)
      ..write(
        _cleanupAttachmentIds(
          obj.attachments.map((attachment) => attachment.toJson()).toList(),
          obj.attachmentIdsForCleanup,
        ),
      )
      ..writeByte(22)
      ..write(obj.aiRunOwnerUserId)
      ..writeByte(23)
      ..write(obj.aiRunOwnerDeviceId)
      ..writeByte(24)
      ..write(obj.aiRunProtocolVersion)
      ..writeByte(25)
      ..write(obj.aiRunClientToolsVersion)
      ..writeByte(26)
      ..write(obj.aiRunKnowledgeMode)
      ..writeByte(27)
      ..write(obj.privateEvidenceUsed)
      ..writeByte(28)
      ..write(obj.thinking)
      ..writeByte(29)
      ..write(obj.toolEvents);
  }
}

bool _privateEvidenceFromStoredFields(Map<int, dynamic> fields) {
  if (fields.containsKey(27)) {
    return fields[27] as bool? ?? false;
  }

  // Builds that supported protocol-v3 device tools predate field 27. Their
  // terminal record cannot prove whether local_search/read_article actually
  // returned private evidence (a valid local citation was not guaranteed), so
  // migrate that unknown state fail-closed. Current records always write field
  // 27, allowing an authoritative false from the server to remain public.
  final protocolVersion = (fields[24] as num?)?.toInt();
  final clientToolsVersion = (fields[25] as num?)?.toInt();
  final knowledgeMode = fields[26] as String?;
  return protocolVersion != null &&
      protocolVersion >= 3 &&
      clientToolsVersion == 1 &&
      (knowledgeMode == 'only' || knowledgeMode == 'hybrid');
}

List<String> _stringList(dynamic value) {
  if (value is! List) return const [];
  return value.whereType<String>().toList(growable: false);
}

List<String> _cleanupAttachmentIds(
  dynamic storedAttachments,
  dynamic storedIds,
) {
  final ids = <String>{
    ...chatAttachmentIdsFromStored(storedAttachments),
    ..._stringList(storedIds).where(isValidChatAttachmentId),
  };
  final result = ids.toList()..sort();
  return List.unmodifiable(result);
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
