/// Ephemeral text attachment sent only with the current chat turn.
///
/// Extracted text is deliberately not part of conversation history. Durable
/// chat messages keep their attachment metadata and bounded retry cache, while
/// the hosted request receives this typed current-turn value.
class AiTextAttachmentInput {
  final String id;
  final String? name;
  final String text;

  const AiTextAttachmentInput({
    required this.id,
    this.name,
    required this.text,
  });
}
