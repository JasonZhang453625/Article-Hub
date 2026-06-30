enum MessageRole { user, assistant }

class ChatMessage {
  final MessageRole role;
  final String text;
  final List<String> articleIds;
  final List<String> weakArticleIds;
  final String? method;
  final String? logId;
  final bool isNoResult;
  final String? query;
  int? feedback;

  ChatMessage({
    required this.role,
    required this.text,
    this.articleIds = const [],
    this.weakArticleIds = const [],
    this.method,
    this.logId,
    this.isNoResult = false,
    this.query,
  });
}
