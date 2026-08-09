import '../../data/models/chat_message_record.dart';
import '../../data/models/chat_attachment.dart';

enum MessageRole { user, assistant }

class ChatMessage {
  final String id;
  final MessageRole role;
  final String text;
  final List<String> articleIds;
  final List<String> weakArticleIds;
  final String? method;
  final String? logId;
  final bool isNoResult;
  final String? query;
  final ChatMessageStatus status;
  final List<String> webUrls;
  final List<ChatAttachment> attachments;
  int? feedback;

  ChatMessage({
    this.id = '',
    required this.role,
    required this.text,
    this.articleIds = const [],
    this.weakArticleIds = const [],
    this.method,
    this.logId,
    this.isNoResult = false,
    this.query,
    this.status = ChatMessageStatus.completed,
    this.webUrls = const [],
    this.attachments = const [],
  });

  bool get isPending => status == ChatMessageStatus.sending;

  bool get isInterrupted => status == ChatMessageStatus.interrupted;

  factory ChatMessage.fromRecord(ChatMessageRecord record) {
    return ChatMessage(
      id: record.id,
      role: record.role == ChatMessageRole.user
          ? MessageRole.user
          : MessageRole.assistant,
      text: record.content,
      articleIds: record.articleIds,
      weakArticleIds: record.weakArticleIds,
      method: record.method,
      logId: record.logId,
      isNoResult: record.isNoResult,
      query: record.query,
      status: record.status,
      webUrls: record.webUrls,
      attachments: record.attachments,
    )..feedback = record.feedback;
  }
}
