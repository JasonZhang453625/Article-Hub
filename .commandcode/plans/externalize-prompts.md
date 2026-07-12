# 将 AI Prompts 外部化到 assets/prompts/

## 目标

把 `ai_service.dart` 和 `processing_pipeline.dart` 中的所有硬编码 prompt 抽到独立 .txt 文件，按功能分包，方便单独编辑。

## 文件结构

```
assets/prompts/
├── summary/
│   ├── quality_rules_zh.txt          ✅ 已创建
│   ├── quality_rules_en.txt          ✅ 已创建
│   ├── instruction_zh_concise.txt    ✅ 已创建
│   ├── instruction_zh_detailed_short.txt  ✅ 已创建
│   ├── instruction_zh_detailed_medium.txt ✅ 已创建
│   ├── instruction_zh_detailed_long.txt   ✅ 已创建
│   ├── instruction_en_concise.txt    ✅ 已创建
│   ├── instruction_en_detailed_short.txt  ✅ 已创建
│   ├── instruction_en_detailed_medium.txt ✅ 已创建
│   ├── instruction_en_detailed_long.txt   ✅ 已创建
│   ├── system_zh.txt                 待创建
│   ├── system_en.txt                 待创建
│   ├── system_with_title_zh.txt      待创建
│   ├── system_with_title_en.txt      待创建
│   ├── chunk_instruction_zh.txt      待创建
│   └── chunk_instruction_en.txt      待创建
├── tags/
│   ├── system.txt                    待创建
│   └── user_prompt.txt               待创建
└── folder/
    ├── system_with_folders.txt       待创建
    └── system_no_folders.txt         待创建
```

## Prompt 映射关系

### Summary
- `quality_rules_zh/en` → `AiService._summaryInstructionChinese/English` 中的 qualityRules
- `instruction_zh/en_*` → 按 verbosity + contentLength 选择的指令
- `system_zh/en` → `_summarizeSingle` 的 systemPrompt
- `system_with_title_zh/en` → `_summarizeWithTitleSingle` 的 systemPrompt
- `chunk_instruction_zh/en` → `_summarizeChunks` 的 instruction

### Tags (processing_pipeline.dart ~L287)
- `tags/system.txt`: `'You are a precise content classifier.'`
- `tags/user_prompt.txt`: 完整 user prompt（含 rules + 格式要求）

### Folder (processing_pipeline.dart ~L373-394)
- `folder/system_no_folders.txt`: 无文件夹时的 system prompt
- `folder/system_with_folders.txt`: 有文件夹时的 system prompt（`[namesList]` 为模板变量）

## 代码改动

### 1. 新建 `lib/data/services/prompt_service.dart`

```dart
import 'package:flutter/services.dart' show rootBundle;

class PromptService {
  final Map<String, String> _cache = {};

  Future<String> load(String path) async {
    return _cache.putIfAbsent(path, () async {
      return rootBundle.loadString('lib/assets/prompts/$path');
    });
  }

  // 便捷方法，按需扩展
}
```

### 2. 修改 `AiService`

- `summaryInstruction()` 改为读取 `quality_rules_*.txt` + `instruction_*.txt` 并拼接
- `_summarizeSingle()` 改为用 `PromptService` 读取 `system_*.txt` 模板 + `instruction`
- `_summarizeWithTitleSingle()` 同上，用 `system_with_title_*.txt`
- `_summarizeChunks()` 用 `chunk_instruction_*.txt`
- `AiService` 构造函数新增 `PromptService? promptService` 参数

### 3. 修改 `ProcessingPipeline`

- `_generateTags()` 用 `tags/system.txt` + `tags/user_prompt.txt`
- `_suggestFolder()` 用 `folder/system_no_folders.txt` 或 `folder/system_with_folders.txt`

### 4. `pubspec.yaml` 新增

```yaml
flutter:
  assets:
    - assets/prompts/
```

## 下一步

退出 plan mode 后按以上顺序实现。
