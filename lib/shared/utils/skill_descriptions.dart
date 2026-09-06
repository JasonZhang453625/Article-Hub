import 'locale_strings.dart';

/// Returns a user-facing description for a server-owned Pi Skill.
///
/// The catalog remains authoritative for names and the original English
/// description. Chinese builds translate the small, controlled set of Skills
/// currently exposed by the Memora Agent. Unknown future Skills get a safe
/// Chinese explanation instead of leaking an untranslated backend string.
String localizedSkillDescription(
  LocaleStrings s, {
  required String name,
  required String description,
}) {
  final normalizedDescription = description.trim();
  if (!s.isChinese || _containsChinese(normalizedDescription)) {
    return normalizedDescription;
  }

  switch (name.trim().toLowerCase()) {
    case 'office':
      return '使用专用工具读取和搜索 PDF、Word 与 Excel 文件。先识别文档结构，再按需检索和读取；无需安装 LibreOffice、系统依赖或 OCR，适用于企业网络和离线环境。';
    case 'memora-assistant':
      return '结合可用的个人记忆上下文和工具回答记忆海问题，不虚构来源。';
    case 'web-research':
      return '仅在需要最新、易变化、较冷门，或用户明确要求联网的信息时使用网页搜索。';
    default:
      return '由当前记忆海智能体提供的“$name”技能，具体能力以服务端配置为准。';
  }
}

bool _containsChinese(String value) =>
    RegExp(r'[\u3400-\u9fff]').hasMatch(value);
