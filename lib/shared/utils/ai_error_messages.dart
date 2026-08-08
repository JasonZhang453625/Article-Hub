import 'locale_strings.dart';

/// Converts provider and transport errors into messages that are useful to a
/// person using the chat. The original error remains available in developer
/// logs, but implementation details such as URLs and socket exceptions should
/// not be rendered in the conversation.
String localizedAiErrorMessage(LocaleStrings s, Object? error) {
  final message = error?.toString().trim() ?? '';
  final normalized = message.toLowerCase();

  if (normalized.isEmpty || normalized == 'unknown error') {
    return s.aiGenericError;
  }
  if (_containsAny(normalized, ['timed out', 'timeout', 'deadline exceeded'])) {
    return s.aiTimeoutError;
  }
  if (_containsAny(normalized, [
    '401',
    '403',
    'unauthorized',
    'forbidden',
    'invalid api key',
    'invalid token',
    'authentication',
  ])) {
    return s.aiAuthError;
  }
  if (_containsAny(normalized, [
    '429',
    'rate limit',
    'quota',
    'too many requests',
  ])) {
    return s.aiRateLimitError;
  }
  if (RegExp(r'\b5\d{2}\b').hasMatch(normalized) ||
      _containsAny(normalized, [
        'server error',
        'service unavailable',
        'bad gateway',
        'gateway timeout',
      ])) {
    return s.aiServerError;
  }
  if (_containsAny(normalized, ['empty response', 'content was empty'])) {
    return s.emptyAiResponse;
  }
  if (_containsAny(normalized, [
    '400',
    'bad request',
    'context length',
    'could not process',
    'invalid request',
  ])) {
    return s.aiRequestError;
  }
  if (_containsAny(normalized, [
    'clientexception',
    'socketexception',
    'software caused connection abort',
    'connection abort',
    'connection reset',
    'connection refused',
    'broken pipe',
    'failed host lookup',
    'network is unreachable',
    'no internet',
    'certificate',
    'tls',
  ])) {
    return s.aiNetworkError;
  }

  return s.aiGenericError;
}

bool _containsAny(String value, List<String> patterns) {
  return patterns.any(value.contains);
}
