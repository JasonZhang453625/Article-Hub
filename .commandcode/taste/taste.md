# Taste (Continuously Learned by [CommandCode][cmd])

[cmd]: https://commandcode.ai/

# planning

- When user shows uncertainty about the value/use of a feature, default to the simplest minimal version (e.g., just collect feedback data) rather than proposing a comprehensive multi-feature plan. Confidence: 0.70

# retrieval

- Use hybrid retrieval (parallel vector + keyword with fusion ranking like RRF) instead of sequential fallback from vector to keyword. Confidence: 0.65

# workflow

- Before release builds, run `dart run tools/bump_version.dart` to auto-increment the patch version in pubspec.yaml. Confidence: 0.70

# ui-style

- Use bold font for settings SwitchListTile titles (e.g., "检测剪贴板链接"). Confidence: 0.65
- Use color #00AEEF for settings section label text (e.g., "外观", "字体大小", "摘要样式", "行为"). Confidence: 0.70

