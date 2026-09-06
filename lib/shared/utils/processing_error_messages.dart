import '../../data/models/passage.dart';
import 'locale_strings.dart';

/// Converts a persisted pipeline diagnostic into a concise user-facing error.
///
/// [Article.processingError] intentionally keeps the original stage and error
/// details for recovery and developer logs. Chinese UI must not expose raw
/// provider messages, exception class names, URLs, or transport internals.
String localizedProcessingError(
  LocaleStrings s,
  String? raw, {
  ProcessingStage? fallbackStage,
}) {
  final diagnostic = raw?.trim() ?? '';
  if (!s.isChinese) return diagnostic.isEmpty ? 'Unknown error' : diagnostic;

  final parsed = _parseDiagnostic(diagnostic);
  final stage = parsed.stage ?? _stageKey(fallbackStage);
  final normalized = parsed.detail.toLowerCase();
  final prefix = _stageLabel(stage);
  final reason = _localizedReason(normalized);
  return '$prefix：$reason';
}

({String? stage, String detail}) _parseDiagnostic(String raw) {
  final separator = raw.indexOf(':');
  if (separator <= 0) return (stage: null, detail: raw);
  final candidate = raw.substring(0, separator).trim().toLowerCase();
  if (!_knownStages.contains(candidate)) return (stage: null, detail: raw);
  return (stage: candidate, detail: raw.substring(separator + 1).trim());
}

const _knownStages = {
  'metadata',
  'content',
  'summary',
  'tags',
  'folder',
  'image_understanding',
  'queue',
};

String? _stageKey(ProcessingStage? stage) => switch (stage) {
  ProcessingStage.metadata => 'metadata',
  ProcessingStage.content => 'content',
  ProcessingStage.summary => 'summary',
  ProcessingStage.tags => 'tags',
  ProcessingStage.folderSuggestion => 'folder',
  ProcessingStage.imageUnderstanding => 'image_understanding',
  ProcessingStage.indexing => 'indexing',
  null => null,
};

String _stageLabel(String? stage) => switch (stage) {
  'metadata' => '获取网页信息失败',
  'content' => '提取正文失败',
  'summary' => '生成摘要失败',
  'tags' => '生成标签失败',
  'folder' => '推荐文件夹失败',
  'image_understanding' => '识别图片失败',
  'indexing' => '建立索引失败',
  'queue' => '处理队列失败',
  _ => '处理失败',
};

String _localizedReason(String error) {
  if (error.trim().isEmpty || error == 'unknown error') {
    return '原因未知，请重试。';
  }
  if (_containsAny(error, [
    'task_invalid_output',
    'invalid_task_result',
    'provider_invalid_output',
    'invalid_response',
    'invalid typed result',
    'did not submit',
    'empty summary',
    'empty response',
    'returned no content',
    'content was empty',
  ])) {
    return '模型未返回有效结果，请重试。';
  }
  if (_containsAny(error, [
        'hosted_task_auth_required',
        'hosted_task_auth_expired',
        'hosted_task_account_changed',
        'hosted_task_identity_invalid',
        'login_required',
        'user_not_found',
        'unauthorized',
        'forbidden',
        'authentication',
        'invalid api key',
        'invalid token',
      ]) ||
      RegExp(r'(^|\D)(401|403)(\D|$)').hasMatch(error)) {
    return '登录或认证已失效，请重新登录后重试。';
  }
  if (_containsAny(error, ['provider_auth_failed'])) {
    return 'AI 服务配置异常，请稍后重试或联系管理员。';
  }
  if (_containsAny(error, [
    'hosted_tasks_not_configured',
    'hosted_task_limit_invalid',
    'backend_not_configured',
    'image_ai_not_configured',
    'agent_disabled',
    'ai not configured',
    'service is not configured',
    'service not configured',
  ])) {
    return '相关服务尚未配置，请先检查 AI 设置。';
  }
  if (_containsAny(error, ['provider_response_too_large'])) {
    return '服务返回的内容超出限制，请稍后重试。';
  }
  if (_containsAny(error, [
        'hosted_task_request_too_large',
        'request_too_large',
        'context length',
        'payload too large',
        'content too long',
      ]) ||
      RegExp(r'(^|\D)413(\D|$)').hasMatch(error)) {
    return '内容过长，已超出服务限制。';
  }
  if (_containsAny(error, [
        'task_observation_timeout',
        'task_reconciliation_timeout',
        'provider_timeout',
        'agent_timeout',
        'timed out',
        'timeout',
        'deadline exceeded',
      ]) ||
      RegExp(r'(^|\D)(408|504)(\D|$)').hasMatch(error)) {
    return '服务响应超时，请稍后重试。';
  }
  if (_containsAny(error, [
        'rate limit',
        'rate_limited',
        'quota',
        'daily_quota_exceeded',
        'too many requests',
      ]) ||
      RegExp(r'(^|\D)429(\D|$)').hasMatch(error)) {
    return '请求过于频繁或额度已用尽，请稍后重试。';
  }
  if (_containsAny(error, [
    'task_cancelled',
    'agent_cancelled',
    'was cancelled',
    'request was cancelled',
    'canceled',
  ])) {
    return '任务已取消，可点击重试。';
  }
  if (_containsAny(error, [
    'task_input_changed_during_recovery',
    'article changed',
    'input changed',
  ])) {
    return '内容已发生变化，请重试以重新处理。';
  }
  if (_containsAny(error, [
    'task_profile_mismatch',
    'hosted_task_summary_plan_mismatch',
    'hosted_task_binding_mismatch',
    'profile mismatch',
    'binding mismatch',
    'plan mismatch',
  ])) {
    return '任务版本不匹配，请重试。';
  }
  if (_containsAny(error, [
    'task_create_ambiguous',
    'task_observation_failed',
    'task_reconciliation_failed',
    'hosted_task_http_error',
    'provider_request_failed',
    'clientexception',
    'socketexception',
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
    return '网络连接失败，请检查网络后重试。';
  }
  if (RegExp(r'(^|\D)5\d\d(\D|$)').hasMatch(error) ||
      _containsAny(error, [
        'server error',
        'provider_unavailable',
        'service unavailable',
        'bad gateway',
        'temporarily unavailable',
      ])) {
    return '服务暂时不可用，请稍后重试。';
  }
  if (_containsAny(error, [
    'could not load original page',
    'failed to load page',
    'page not found',
  ])) {
    return '无法加载原始页面，请检查链接后重试。';
  }
  if (_containsAny(error, ['no extractable text in pdf', 'scanned document'])) {
    return 'PDF 中没有可提取文字；扫描版文件需要 OCR。';
  }
  if (_containsAny(error, [
    'could not extract page content',
    'could not extract page content for summarization',
    'extraction failed',
  ])) {
    return '未提取到可处理的正文，请检查原文后重试。';
  }
  if (_containsAny(error, [
    'legacy image has no upload fingerprint',
    'add it again to process it',
  ])) {
    return '旧版图片缺少必要信息，请重新添加图片。';
  }
  if (_containsAny(error, ['attachment_changed', 'image changed'])) {
    return '图片内容已发生变化，请重新添加后重试。';
  }
  if (_containsAny(error, [
    'image understanding service is not configured',
    'local image recognition is not configured',
  ])) {
    return '图片识别服务尚未配置。';
  }
  if (_containsAny(error, [
    'file not found',
    'no such file',
    'pathnotfoundexception',
  ])) {
    return '找不到原文件，请重新添加后再试。';
  }
  if (_containsAny(error, ['permission denied', 'filesystemexception'])) {
    return '无法读取文件，请检查文件权限后重试。';
  }
  if (_containsAny(error, [
        'bad request',
        'invalid request',
        'invalid_input',
        'invalid_idempotency_key',
      ]) ||
      RegExp(r'(^|\D)400(\D|$)').hasMatch(error)) {
    return '请求内容无效，请检查内容后重试。';
  }
  return '任务未完成，请重试；若反复失败，请检查网络和 AI 设置。';
}

bool _containsAny(String value, List<String> patterns) =>
    patterns.any(value.contains);
