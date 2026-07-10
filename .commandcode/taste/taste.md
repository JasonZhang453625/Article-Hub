# Taste (Continuously Learned by [CommandCode][cmd])

[cmd]: https://commandcode.ai/

# planning

- When user shows uncertainty about the value/use of a feature, default to the simplest minimal version (e.g., just collect feedback data) rather than proposing a comprehensive multi-feature plan. Confidence: 0.70

# retrieval

- Use hybrid retrieval (parallel vector + keyword with fusion ranking like RRF) instead of sequential fallback from vector to keyword. Confidence: 0.65

# workflow
See [workflow/taste.md](workflow/taste.md)
# ui-style

- Use bold font for settings SwitchListTile titles (e.g., "检测剪贴板链接"). Confidence: 0.65
- Use color #00AEEF for settings section label text (e.g., "外观", "字体大小", "摘要样式", "行为"). Confidence: 0.70
- Use color #10273F as the app's primary theme color. Confidence: 0.80
- Use color #00AEEF as secondary brand color, named "seaFace" following the ocean-themed naming convention (companion to "deepSea"). Confidence: 0.85
- In dark mode, platform source icons should use white or seaFace (#00AEEF) instead of dark colors like black or deep blue. Confidence: 0.65

# code-style
- When multiple widgets need the same rendering logic (e.g., platform icon dark-mode coloring), centralize it in one place (e.g., a shared method or extension) instead of duplicating across files. Confidence: 0.60

# communication
- When reporting project status or what's next, only list remaining/unfinished tasks — do not summarize what's already completed or mention finished phases in passing. Confidence: 0.85

# architecture
- Externalize AI prompts into standalone text files under assets/prompts/ instead of hardcoding them in Dart source code, so each prompt can be individually edited without touching code. Confidence: 0.70

# prompt-design
- For article summary prompts, do not fix the number of key points (e.g., "5-8条") — let the count be driven by the article's actual information density, with wording like "原文有多少重要信息就列多少条". Confidence: 0.70
- For article summary prompts, express the word-count constraint as a percentage of source length (e.g., "原文60%以下") rather than a fixed character range (e.g., "200-300字"). Confidence: 0.70
- For article summary prompts, structure output as 总分总: a separate title generation step followed by three labeled sections — 摘要 (abstract), 要点 (key points), 总结 (conclusion). Confidence: 0.50
- When designing chunk/section-level prompts (e.g., chunk_instruction), derive them from the full-summary prompt — same atomic evidence extraction approach, same quality rules — rather than designing independently. Confidence: 0.65

# harmonyos
- Use "vp" (virtual pixels / 虚拟像素) for HarmonyOS logical pixel units, not "lpx" or plain "px". Confidence: 0.70
- Reference device dimensions for HarmonyOS tablet layout: MatePad Mini 8.8" = 1077×673 vp (landscape), generic MatePad reference = 1280×800 vp. Confidence: 0.65
- Use 600vp as the tablet breakpoint (for switching to rail navigation + grid layout) to accommodate MatePad Mini portrait mode (673vp wide), rather than the original 720px. Confidence: 0.70
- Tablet article list should use ListView, not GridView — cards are too wide for a grid to fit meaningfully on tablet screens (even in landscape). Confidence: 0.75

