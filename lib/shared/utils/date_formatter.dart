import 'package:intl/intl.dart';

String formatDate(DateTime date) {
  return DateFormat('yyyy-MM-dd').format(date);
}

String formatDateTime(DateTime date) {
  return DateFormat('yyyy-MM-dd HH:mm').format(date);
}

String formatRelative(DateTime date) {
  final now = DateTime.now();
  final diff = now.difference(date);

  // Guard against future timestamps (clock skew / timezone issues): treat them
  // as "just now" rather than producing a negative relative time.
  if (diff.isNegative) return 'just now';

  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';

  return formatDate(date);
}
