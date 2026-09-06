import 'package:flutter_test/flutter_test.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/shared/utils/locale_strings.dart';
import 'package:memora/shared/utils/processing_error_messages.dart';

void main() {
  final zh = LocaleStrings.of(1);

  test('localizes every pipeline stage', () {
    const expected = {
      'metadata': '获取网页信息失败',
      'content': '提取正文失败',
      'summary': '生成摘要失败',
      'tags': '生成标签失败',
      'folder': '推荐文件夹失败',
      'image_understanding': '识别图片失败',
      'queue': '处理队列失败',
    };
    for (final entry in expected.entries) {
      expect(
        localizedProcessingError(zh, '${entry.key}: unknown error'),
        startsWith('${entry.value}：'),
      );
    }
  });

  test('localizes the main actionable error categories', () {
    const cases = {
      'summary: task_invalid_output: The hosted model did not submit a result':
          '生成摘要失败：模型未返回有效结果，请重试。',
      'summary: provider_invalid_output': '生成摘要失败：模型未返回有效结果，请重试。',
      'summary: hosted_task_auth_expired': '生成摘要失败：登录或认证已失效，请重新登录后重试。',
      'summary: AI not configured': '生成摘要失败：相关服务尚未配置，请先检查 AI 设置。',
      'summary: provider_auth_failed': '生成摘要失败：AI 服务配置异常，请稍后重试或联系管理员。',
      'summary: hosted_task_request_too_large': '生成摘要失败：内容过长，已超出服务限制。',
      'summary: task_observation_timeout': '生成摘要失败：服务响应超时，请稍后重试。',
      'summary: 429 rate limit': '生成摘要失败：请求过于频繁或额度已用尽，请稍后重试。',
      'summary: daily_quota_exceeded': '生成摘要失败：请求过于频繁或额度已用尽，请稍后重试。',
      'summary: task_cancelled': '生成摘要失败：任务已取消，可点击重试。',
      'summary: task_profile_mismatch': '生成摘要失败：任务版本不匹配，请重试。',
      'metadata: Could not load original page': '获取网页信息失败：无法加载原始页面，请检查链接后重试。',
      'content: No extractable text in PDF (may be a scanned document)':
          '提取正文失败：PDF 中没有可提取文字；扫描版文件需要 OCR。',
      'image_understanding: legacy image has no upload fingerprint':
          '识别图片失败：旧版图片缺少必要信息，请重新添加图片。',
      'image_understanding: attachment_changed': '识别图片失败：图片内容已发生变化，请重新添加后重试。',
      'queue: SocketException: connection reset': '处理队列失败：网络连接失败，请检查网络后重试。',
      'summary: unexpected provider detail':
          '生成摘要失败：任务未完成，请重试；若反复失败，请检查网络和 AI 设置。',
    };
    for (final entry in cases.entries) {
      expect(localizedProcessingError(zh, entry.key), entry.value);
    }
  });

  test('uses fallback stage and keeps English diagnostics unchanged', () {
    expect(
      localizedProcessingError(zh, null, fallbackStage: ProcessingStage.tags),
      '生成标签失败：原因未知，请重试。',
    );
    expect(
      localizedProcessingError(LocaleStrings.of(2), 'summary: provider detail'),
      'summary: provider detail',
    );
  });
}
