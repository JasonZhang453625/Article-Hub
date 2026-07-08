String markdownToPlainText(String md) {
  var text = md;

  // Remove code blocks
  text = text.replaceAll(RegExp(r'```[\s\S]*?```'), '');
  // Remove inline code
  text = text.replaceAll(RegExp(r'`[^`]*`'), '');
  // Remove images
  text = text.replaceAll(RegExp(r'!\[.*?\]\(.*?\)'), '');
  // Remove links (keep text)
  text = text.replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1)!);
  // Remove bold/italic markers
  text = text.replaceAll(RegExp(r'\*{1,3}([^*]+)\*{1,3}'), r'$1');
  text = text.replaceAll(RegExp(r'_{1,3}([^_]+)_{1,3}'), r'$1');
  // Remove list markers
  text = text.replaceAll(RegExp(r'^[\s]*[-*+]\s+', multiLine: true), '');
  text = text.replaceAll(RegExp(r'^[\s]*\d+\.\s+', multiLine: true), '');
  // Remove heading markers
  text = text.replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '');
  // Remove blockquote markers
  text = text.replaceAll(RegExp(r'^>\s?', multiLine: true), '');
  // Remove horizontal rules
  text = text.replaceAll(RegExp(r'^[-*_]{3,}\s*$', multiLine: true), '');
  // Remove HTML tags
  text = text.replaceAll(RegExp(r'<[^>]+>'), '');
  // Collapse multiple blank lines
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');

  return text.trim();
}

String extractMarkdownTitle(String md) {
  final match = RegExp(r'^#\s+(.+)$', multiLine: true).firstMatch(md);
  if (match != null) {
    return match.group(1)!.trim();
  }
  return '';
}
