# Article-Hub

**本地优先的 AI 个人知识收件箱 / A local-first AI personal knowledge inbox**

> 分享即知识化，对话即检索，原文始终可追溯。<br>
> Share into knowledge. Ask to retrieve. Trace every answer back to its source.

[中文](#中文) · [English](#english) · [产品文档 / Product docs](docs/OVERVIEW.md)

---

# 中文

## 产品介绍

Article-Hub 用来收集散落在微信、知乎、Bilibili、小红书、X、YouTube、Reddit 和普通网页中的文章、视频与帖子链接，并将它们转换为统一、可搜索、可提问的个人知识卡片。

它不只是保存 URL，而是围绕下面的闭环工作：

```text
收集链接
  → 可靠保存
  → 提取元数据与正文
  → 生成 AI 摘要、标签和文件夹建议
  → 建立本地索引
  → 向整个知识库提问
  → 查看引用卡片并返回原文
```

Article-Hub 不提供账号体系、云内容后端或 AI 代理后端。文章、摘要、标签、文件夹、处理状态和向量索引保存在本机；摘要和对话请求直接发送到用户配置的兼容服务，embedding 使用内置默认服务或用户自定义服务。

## 核心特点

### 跨来源收集

- 识别 WeChat、Zhihu、Web、X、Bilibili、Rednote、ChatGPT、YouTube 和 Reddit。
- 支持单个 URL、批量 URL、剪贴板链接检测和 Android 系统分享。
- 来源筛选项可以排序、隐藏和拖拽调整。

### 可靠的知识化流水线

- 链接先写入本地存储，再执行网络请求和 AI 处理。
- 处理过程分为元数据、正文、摘要、标签和文件夹建议五个阶段。
- 每个阶段都记录状态、错误、重试次数和最后处理时间。
- 失败条目进入待处理箱，可以查看原因并重新执行，不会直接丢失。

### 抗 403 的正文提取

- 默认先使用快速 HTTP 请求抓取页面。
- 遇到 HTTP 403、超时、网络失败或无效页面时，自动启动无界面 WebView。
- WebView 等待动态 DOM 稳定后读取最终 HTML，再复用正文清洗逻辑。
- 验证码、安全验证、登录拦截和过短错误页不会进入 AI 摘要。
- 后台 WebView 全局串行执行，并在每次使用后释放。

### AI 摘要与后台生成

- 支持用户配置的 OpenAI-compatible Chat Completions 接口。
- 长文章通过分块摘要再合成，避免一次请求超过上下文限制。
- 可选择精简或详细摘要，以及跟随系统、中文或英文输出。
- 点击“重新生成”后可以离开摘要页面，任务仍会继续并自动保存结果。
- 页面退出不会取消任务；应用进程被系统终止时，当前内存任务仍会停止。

### 自动整理，但保留用户控制

- AI 标签可以自动写入，用户仍可编辑。
- AI 直接把新文章自动分类到合适的文件夹，匹配不到现有文件夹时自动创建新文件夹。
- 进程页可以看到正在处理与失败的条目，从知识库切换文件夹查看时支持当前过滤可视化。
- 支持标签、备注、收藏、文件夹、嵌套文件夹、自定义筛选和全文字段搜索。

### 思考模型兼容

- 支持 MiMo（关闭思考模式 + `max_completion_tokens`）。
- 同时发送 `max_tokens` 与 `max_completion_tokens`，自动覆盖 DeepSeek、o1/o3 等其他 OpenAI-compatible 思考模型。
- 文件夹分类等短回答类调用为思考过程预留 token，并自动剥离 `<think>...</think>` 标签。

### 本地检索与 RAG 对话

- 标题、摘要和标签组成 embedding 输入。
- 每篇完成知识化的文章对应一个本地索引记录。
- 优先使用向量相似度召回；embedding 不可用时降级为关键词检索。
- 对话模型只接收召回到的知识卡片摘要。
- 模型引用会经过候选文章白名单校验，未知或已删除的引用会被过滤。
- 知识库不足以回答时，界面明确提示信息不足，而不是伪造来源。

### 本地优先与可迁移数据

- 核心数据使用 Hive 保存在设备本地。
- JSON 备份支持文章、标签、文件夹、筛选和设置的导出与恢复。
- AI API Key 和 embedding API Key 不写入导出的备份文件。
- 向量索引属于可重建数据，不作为核心备份内容。

## 机制设计

### 1. 先保存，再处理

收集入口首先创建本地 `Article` 记录，然后异步启动处理流水线。网络、正文提取或 AI 失败只会改变处理状态，不会撤销已经保存的链接。

### 2. 一次加载，多阶段复用

元数据服务和正文提取器共享同一次弹性页面加载结果。对于返回 403 的页面，不会分别为标题、正文和摘要重复请求同一个站点。

```text
URL
 ├─ HTTP 成功且页面有效 ───────────┐
 └─ HTTP 失败 → Headless WebView ─┤
                                  ↓
                         最终 URL + HTML
                          ├─ 元数据解析
                          └─ 正文清洗
```

### 3. 可恢复的五阶段状态机

```text
metadata → content → summary → tags → folder suggestion
```

每个阶段都会更新 Hive 中的处理状态。致命错误会停止后续阶段并进入失败状态；标签和文件夹建议属于非关键阶段，其失败不会销毁已经生成的摘要。

### 4. 摘要作为首版知识单元

当前设计采用“一篇文章、一张摘要卡片、一个检索 chunk”。这样可以控制存储和 API 成本，并保持引用粒度清晰。它适合主题召回和观点归纳，但不等同于基于全文多 chunk 的精细事实问答。

### 5. 可追溯回答

RAG 流程先在本地召回，再把候选摘要交给聊天模型。回答中的引用编号会映射回真实 `articleId`，用户可以继续打开摘要卡片和原页面。

## 当前功能

| 模块 | 已实现能力 |
|---|---|
| 收集 | 单 URL、批量 URL、剪贴板检测、Android 分享 |
| 知识化 | 元数据（含封面回退）、正文、AI 摘要、自动标签、自动文件夹分类（必要时新建文件夹） |
| 可靠性 | 进程页、阶段状态、错误展示、重试、HTTP → WebView 兜底 |
| 知识库 | 搜索、来源筛选、标签、备注、收藏、文件夹、嵌套文件夹、当前文件夹过滤 chip |
| 检索 | 本地向量索引、余弦相似度、关键词降级 |
| 对话 | 全库 RAG、引用卡片、信息不足提示、回答反馈 |
| 阅读 | 摘要优先页面、应用内 WebView、外部浏览器入口 |
| AI 兼容 | OpenAI-compatible、MiMo 思考模型、DeepSeek/o1/o3 等思考模型自动兼容 |
| 设置 | 中英文界面、主题、字体、WebView 缩放、来源排序与隐藏 |
| 数据 | JSON 备份恢复、API Key 排除、索引可重建 |

## 平台状态

| 平台 | 状态 |
|---|---|
| Android | 主要开发与实机验证平台，支持系统分享 |
| iOS | 工程保留；系统分享入口尚未完成 |
| Web | 工程保留，可用于基础运行与界面调试 |
| Windows | 工程保留 |
| macOS | 工程保留 |
| Linux | 当前不维护，平台工程已移除 |

不同平台的插件能力并不完全一致。Android 是目前经过完整内容抓取、WebView 兜底和后台摘要流程验证的平台。

## 技术架构

| 层面 | 选型 |
|---|---|
| 客户端 | Flutter / Dart |
| 状态管理 | Riverpod |
| 本地存储 | Hive，手写 `TypeAdapter` |
| 路由 | `go_router` |
| 网页加载 | `http` + `flutter_inappwebview` |
| HTML 解析 | `html` |
| AI | OpenAI-compatible Chat Completions |
| Embedding | OpenAI-compatible Embeddings |
| 自有后端 | 无 |

```text
lib/
├── config/          # 主题与路由
├── data/
│   ├── models/      # Article、Settings、Folder、IndexRecord 等
│   ├── repositories/# Hive 数据访问
│   └── services/    # 抓取、AI、索引、召回、备份和处理流水线
├── features/        # Chat、Knowledge、Inbox、Reader、Settings 等页面
└── shared/          # Providers、工具和通用组件
```

## 本地运行

需要 Flutter 和 Dart 3.11 或更高版本。

```bash
flutter pub get
flutter run
```

运行 Android 或 Web：

```bash
flutter run -d <android-device-id>
flutter run -d edge
```

构建 Android APK：

```bash
flutter build apk --release
```

检查代码：

```bash
flutter analyze
flutter test
```

## AI 配置

在设置页面填写：

- Chat Completions Base URL
- API Key
- 模型名称
- 可选的 Embeddings Base URL、API Key 和模型名称；留空时使用内置默认 embedding 服务

接口需要兼容 OpenAI 的请求和响应结构。不同供应商对参数、模型能力和限流策略的实现可能不同。

## 隐私边界

- Article-Hub 不运营内容服务器或 AI 中转服务器。
- 本地文章数据不会因为使用应用而自动上传到 Article-Hub。
- 生成摘要时，提取后的正文会发送到用户选择的聊天模型服务。
- 建立语义索引时，标题、摘要和标签会发送到内置默认 embedding 服务，或用户主动配置的自定义服务。
- 提问时，问题和召回到的摘要会发送到用户选择的聊天模型服务。
- API Key 保存在本机 Hive 设置中，并从 JSON 备份中排除。

## 文档

- [产品概览](docs/OVERVIEW.md)
- [产品需求文档](docs/PRD.md)
- [实施路线图](docs/ROADMAP.md)

---

# English

## Overview

Article-Hub collects articles, videos, and post links scattered across WeChat, Zhihu, Bilibili, Rednote, X, YouTube, Reddit, ChatGPT, and the wider web. It turns them into normalized knowledge cards that can be searched, organized, and queried.

It is designed around a complete knowledge-reuse loop rather than simple URL storage:

```text
Capture a link
  → persist it reliably
  → extract metadata and readable content
  → generate an AI summary, tags, and a folder suggestion
  → build a local index
  → ask questions across the whole library
  → inspect cited cards and return to the original source
```

Article-Hub has no account system, hosted content backend, or AI proxy backend. Articles, summaries, organization data, processing state, and vector indexes remain on the device. Summary and chat requests go directly to the user-configured service; embeddings use either the built-in default service or a custom endpoint.

## Key Features

### Multi-source capture

- Recognizes WeChat, Zhihu, generic web pages, X, Bilibili, Rednote, ChatGPT, YouTube, and Reddit.
- Supports individual URLs, bulk URL input, clipboard detection, and Android system sharing.
- Source filters can be reordered, hidden, and rearranged.

### Reliable knowledge processing

- Links are persisted locally before network or AI processing begins.
- Processing is split into metadata, content, summary, tags, and folder-suggestion stages.
- Stage, error, retry count, and last-processing time are persisted.
- Failed items remain visible in the Inbox and can be retried.

### HTTP 403-resistant extraction

- A fast direct HTTP request is always attempted first.
- HTTP 403 responses, timeouts, network failures, and unusable pages trigger a headless WebView fallback.
- The WebView waits for the dynamic DOM to stabilize, then returns the final HTML to the existing extraction pipeline.
- CAPTCHA, verification, login-blocked, and short error pages are rejected before AI summarization.
- Headless WebView jobs are globally serialized and disposed after every use.

### AI summaries and background regeneration

- Works with user-configured OpenAI-compatible Chat Completions endpoints.
- Long articles use bounded map-reduce summarization.
- Supports concise or detailed summaries and system, Chinese, or English output.
- Regeneration continues after navigating away from the summary screen and saves automatically when complete.
- Navigation does not cancel the job; terminating the app process still stops in-memory work.

### Automated organization with user control

- AI-generated tags are editable.
- AI directly classifies new articles into the best matching folder, creating a new folder when none of the existing ones fit.
- The Progress tab shows in-flight and failed items; the Knowledge tab shows a folder-filter chip when a folder filter is active.
- Includes tags, notes, favorites, folders, nested folders, custom filters, and local search.

### Thinking-model compatibility

- Native support for MiMo (thinking disabled + `max_completion_tokens`).
- Sends both `max_tokens` and `max_completion_tokens` so DeepSeek, o1/o3, and other OpenAI-compatible thinking models work out of the box.
- Short-answer calls (e.g. folder classification) reserve enough tokens for the model's thinking phase and strip `<think>...</think>` tags from the response.

### Local retrieval and RAG chat

- Embedding input is built from the title, summary, and tags.
- Each processed article has one local index record.
- Vector similarity retrieval is preferred, with keyword retrieval as a fallback.
- The chat model receives only the summaries retrieved from the local library.
- Model citations are validated against the candidate article whitelist.
- The UI reports insufficient knowledge instead of fabricating sources.

### Local-first, portable data

- Core data is stored locally with Hive.
- JSON backup and restore covers articles, tags, folders, filters, and settings.
- Chat and embedding API keys are excluded from exported backups.
- Vector indexes are treated as rebuildable derived data.

## Design Mechanics

### 1. Persist first, process second

Every capture path creates a local `Article` record before asynchronous processing starts. Network, extraction, or model failures update the processing state without undoing the saved link.

### 2. One page load shared by multiple stages

Metadata and readable-content extraction reuse the same resilient page result. A site returning HTTP 403 is not fetched separately for title, body, and summary generation.

```text
URL
 ├─ valid direct HTTP result ────────────┐
 └─ HTTP failure → headless WebView ────┤
                                        ↓
                               final URL + HTML
                                ├─ metadata parsing
                                └─ content cleaning
```

### 3. Resumable five-stage state machine

```text
metadata → content → summary → tags → folder suggestion
```

Each stage updates persistent processing state in Hive. Fatal failures stop the pipeline and remain retryable. Tag or folder-suggestion failures do not discard an already generated summary.

### 4. Summary as the initial knowledge unit

The current design uses one article, one summary card, and one retrieval chunk. This keeps storage, API cost, and citation behavior predictable. It is suitable for topic retrieval and synthesis, but it is not equivalent to full-text, multi-chunk factual QA.

### 5. Traceable answers

RAG queries retrieve locally before calling the chat model. Citation numbers are mapped back to real `articleId` values, allowing users to open the cited knowledge card and then the original page.

## Current Capabilities

| Area | Implemented |
|---|---|
| Capture | Single URL, bulk URLs, clipboard detection, Android sharing |
| Processing | Metadata (with cover-image fallback), content, AI summary, auto tags, auto folder classification (creates folders on demand) |
| Reliability | Progress tab, persisted stages, errors, retries, HTTP-to-WebView fallback |
| Library | Search, source filters, tags, notes, favorites, nested folders, active folder-filter chip |
| Retrieval | Local vector index, cosine similarity, keyword fallback |
| Chat | Library-wide RAG, citation cards, insufficient-context handling, feedback |
| Reading | Summary-first view, in-app WebView, external browser access |
| AI compatibility | OpenAI-compatible, MiMo thinking model, DeepSeek/o1/o3-style thinking models |
| Settings | Chinese/English UI, theme, font size, WebView zoom, source management |
| Data | JSON backup/restore, API-key exclusion, rebuildable indexes |

## Platform Status

| Platform | Status |
|---|---|
| Android | Primary development and device-tested platform; system sharing supported |
| iOS | Project retained; system share entry is not complete |
| Web | Project retained for basic execution and UI testing |
| Windows | Project retained |
| macOS | Project retained |
| Linux | Not maintained; platform project removed |

Plugin behavior is not identical across platforms. Android is currently the platform on which the complete extraction, WebView fallback, and background-summary workflow has been validated.

## Technical Architecture

| Concern | Choice |
|---|---|
| Client | Flutter / Dart |
| State management | Riverpod |
| Local storage | Hive with hand-written `TypeAdapter`s |
| Routing | `go_router` |
| Page loading | `http` + `flutter_inappwebview` |
| HTML parsing | `html` |
| Chat AI | OpenAI-compatible Chat Completions |
| Embeddings | OpenAI-compatible Embeddings |
| Hosted backend | None |

```text
lib/
├── config/          # Theme and routes
├── data/
│   ├── models/      # Article, Settings, Folder, IndexRecord, etc.
│   ├── repositories/# Hive persistence
│   └── services/    # Extraction, AI, indexing, retrieval, backup, pipeline
├── features/        # Chat, Knowledge, Inbox, Reader, Settings, etc.
└── shared/          # Providers, utilities, and reusable widgets
```

## Getting Started

Flutter with Dart 3.11 or later is required.

```bash
flutter pub get
flutter run
```

Run on Android or Web:

```bash
flutter run -d <android-device-id>
flutter run -d edge
```

Build an Android APK:

```bash
flutter build apk --release
```

Run project checks:

```bash
flutter analyze
flutter test
```

## AI Configuration

Configure the following in Settings:

- Chat Completions base URL
- API key
- Model name
- Optional embeddings base URL, API key, and model name; the built-in default embedding service is used when these fields are empty

The endpoint must follow an OpenAI-compatible request and response structure. Parameter support, model capabilities, and rate limits vary by provider.

## Privacy Boundary

- Article-Hub does not operate a content server or AI relay.
- Local article data is not automatically uploaded to Article-Hub.
- Extracted article text is sent to the selected chat model when generating summaries.
- Titles, summaries, and tags are sent to the built-in default embedding service or the user-configured custom service when building semantic indexes.
- Questions and retrieved summaries are sent to the selected chat model during RAG conversations.
- API keys are stored in local Hive settings and excluded from JSON exports.

## Documentation

- [Product overview](docs/OVERVIEW.md)
- [Product requirements](docs/PRD.md)
- [Implementation roadmap](docs/ROADMAP.md)
