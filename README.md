# 记忆海

**仿生记忆提取 · AI 信息强化 · Agent-friendly 知识存储**

> 一键分享即知识化。对话即联想检索。原文始终可追溯。<br>
> One share to know. One question to recall. Every answer traceable to its source.

[中文](#中文) · [English](#english) · [产品文档 / Product docs](docs/OVERVIEW.md)

---

# 中文

## 产品介绍

记忆海把散落在微信、知乎、Bilibili、小红书、X、YouTube、Reddit 和普通网页中的文章、视频与帖子链接收集起来，并自动将它们转化为统一、可搜索、可提问的个人知识卡片。

人类的记忆不靠全量保存。大脑自动过滤噪声、提取结构、只在需要时通过联想唤起——一条模糊印象就足以调出整段经历。记忆海模拟这套认知逻辑：

- **仿生记忆提取**：不存整页广告与推荐流，只提取标题、关键观点、标签与原文入口——像大脑记住"这件事很重要"一样，保留信息密度最高的那一层。
- **信息密度 AI 强化**：原页面信息稀释，AI 记忆将长文压缩为高密度知识颗粒——一条知识卡片就是一个可直接调用的记忆单元。
- **Agent-friendly 标准化存储**：所有内容统一为"结构化记忆 + 向量索引"的知识卡片，人可浏览，AI Agent 也可语义召回、推理与问答。

> 你不需要记住"保存在哪"，只需要知道自己"学过这个"。

它不只是保存 URL，而是围绕下面的知识化闭环工作：

```text
收集链接
  → 可靠保存
  → 提取元数据与正文
  → 生成 AI 记忆、标签和文件夹建议
  → 建立本地索引
  → 向整个知识库提问
  → 查看引用卡片并返回原文
```

## 项目全景（开发者 / Agent）

Memora 是一个多组件产品。这个仓库以 Flutter 客户端为主，但一次完整迭代可能同时涉及 Landing、生产后端、数据库、Hosted Agent、Admin 和发布链路。

| 组件 | 源码与职责 | 运行位置 / 入口 |
|---|---|---|
| Flutter App | 本仓库 `lib/`、`test/` 与各平台目录；本地知识库、采集/处理、检索/RAG、账号与同步客户端 | Android 为主要验收平台；默认后端 `https://api.memora.wang` |
| Landing Page | `landing-page/` 中的独立 Astro Git 工作区；官网、产品介绍、下载入口 | `https://memora.wang`；独立仓库 `Memora-Landing-Page`，分支 `master` |
| Backend API | 生产机 `/opt/memora-backend` 中的独立 TypeScript/Fastify Git 仓库 | `https://api.memora.wang`，API 文档 `/docs` |
| PostgreSQL | 后端 Prisma schema 与 migrations；账号、设备、同步事件、Agent runs、订阅/反馈等 | 后端 Compose 的 PostgreSQL 服务 |
| Hosted Agent | 后端 `src/agent/`、`config/agent.toml`、`skills/` 和 `/ai/runs` | 登录后经 SSE/持久化 run 支持断线和进程重启恢复 |
| Admin | 后端 `src/routes/admin*.ts` 提供页面和受保护 API | `/admin`；凭据只保存在安全的运维边界中 |
| 发布与下载 | 本仓库 `.github/workflows/release.yml`、`deploy/`、`tools/` | GitHub Release、国内 APK 下载源、Landing 自动部署 |

几个容易混淆的源码边界：

- `landing-page/` 在主仓库中表现为 gitlink，但当前没有 `.gitmodules`；它有自己的 Git 状态、远端和发布流程，不要直接假设 `git submodule` 命令可用。
- 后端源码不作为本仓库的受跟踪目录。`scratchpad/pi-backend-edit/` 可能是本机独立工作副本，可能包含其他会话的未完成修改；它不是生产真相，使用前必须分别检查其 Git 状态并与 `/opt/memora-backend` 对比。
- 客户端接口、服务端部署和真实登录/设备验收是三层不同证据。`/health` 返回 200 只能证明 API 可达，不能证明 Agent、Admin、APK 下载或双设备同步已经验收。

### 修改与迭代方式

开始任何任务前先阅读 [AGENTS.md](AGENTS.md)，并在涉及组件中先执行只读检查：主仓库、`landing-page/`、后端工作副本各自有独立 Git 状态，不能互相覆盖。

Flutter 客户端通常按“定位真实 service/provider/model 路径 → 增加或更新测试 → 定向测试 → `flutter analyze` → 必要时 debug 构建/实机验收”迭代。Landing 在其目录运行：

```powershell
cd landing-page
npm install
npm run dev
npm run build
```

生产后端的 SSH 路由只保存在被 Git 忽略的 `.codex/access.local.md`。需要连接时先读取该文件，再使用 Windows OpenSSH、公钥、批处理探测和严格 Host Key 校验；仓库文档不保存真实主机、密码、私钥或 token：

```powershell
ssh -i <identity-from-access.local.md> -o BatchMode=yes -o StrictHostKeyChecking=yes <target-from-access.local.md>
```

连接后从 `/opt/memora-backend` 的 `git status`、当前提交、`package.json`、`scripts/deploy.sh`、Prisma migrations 和 Compose 状态开始检查。后端变更先在隔离工作副本中完成定向测试、`npm run build` 与相关 lint/test；数据库修改必须通过新 migration 和备份/回滚方案完成。只有在明确要求部署时才运行当前服务器的部署流程，并在部署后分别验证公网健康、功能 API 和真实账号/设备路径。

当前配置好的 Codex 工作区可用本机 `build-pipeline` 技能执行 App 生产发布：

```powershell
dart run tools/release_pipeline.dart "type(scope): description"
```

该包装脚本与技能是本机忽略文件；干净 clone 应以受跟踪的 `tools/release.dart`、`tools/verify_release.dart`、`.github/workflows/release.yml` 和发布文档为准。完整发布必须经过 CI 全量测试与签名 APK、GitHub Release、国内下载 manifest/CORS/Range/hash 校验，并在 Landing 变更时完成浏览器检查。

文章、记忆、标签、文件夹、处理状态和向量索引默认保存在本机。可选账号同步会把选定实体通过 HTTPS 发送到记忆海服务端，当前同步负载并非端到端加密；BYOK 模式直接请求用户配置的兼容服务，Hosted Agent 模式经记忆海后端执行。Embedding 只使用用户配置的服务，未配置时降级为本地关键词检索。

## 核心特点

### 跨来源收集

- 识别 WeChat、Zhihu、Web、X、Bilibili、Rednote、ChatGPT、YouTube 和 Reddit。
- 支持单个 URL、批量 URL、剪贴板链接检测和 Android 系统分享。
- 来源筛选项可以排序、隐藏和拖拽调整。

### 可靠的知识化流水线

- 链接先写入本地存储，再执行网络请求和 AI 处理。
- 处理过程分为元数据、正文、记忆、标签和文件夹建议五个阶段。
- 每个阶段都记录状态、错误、重试次数和最后处理时间。
- 失败条目进入待处理箱，可以查看原因并重新执行，不会直接丢失。

### 抗 403 的正文提取

- 默认先使用快速 HTTP 请求抓取页面。
- 遇到 HTTP 403、超时、网络失败或无效页面时，自动启动无界面 WebView。
- WebView 等待动态 DOM 稳定后读取最终 HTML，再复用正文清洗逻辑。
- 验证码、安全验证、登录拦截和过短错误页不会进入 AI 记忆。
- 后台 WebView 全局串行执行，并在每次使用后释放。

### AI 记忆与后台生成

- 支持用户配置的 OpenAI-compatible Chat Completions 接口。
- 长文章通过分块记忆再合成，避免一次请求超过上下文限制。
- 可选择精简或详细记忆，以及跟随系统、中文或英文输出。
- 点击“重新生成”后可以离开记忆页面，任务仍会继续并自动保存结果。
- 页面退出不会取消任务；应用进程被系统终止时，当前内存任务仍会停止。

### 自动整理，但保留用户控制

- AI 标签可以自动写入，用户仍可编辑。
- AI 直接把新文章自动分类到合适的文件夹，匹配不到现有文件夹时自动创建新文件夹。
- 进程页可以看到正在处理与失败的条目，从知识库切换文件夹查看时支持当前过滤可视化。
- 支持标签、备注、收藏、文件夹、嵌套文件夹、自定义筛选和全文字段搜索。

### 思考模型兼容

- 支持 MiMo（关闭思考模式 + `max_completion_tokens`）。
- 按模型能力只发送一个 token 上限字段：MiMo、GPT-5、o1/o3/o4 使用 `max_completion_tokens`，其他 OpenAI-compatible 模型使用 `max_tokens`。
- 文件夹分类等短回答类调用为思考过程预留 token，并自动剥离 `<think>...</think>` 标签。

### 本地检索与 RAG 对话

- 标题、记忆和标签组成 embedding 输入。
- 每篇完成知识化的文章对应一个本地索引记录。
- 优先使用向量相似度召回；embedding 不可用时降级为关键词检索。
- 对话模型只接收召回到的知识卡片记忆。
- 模型引用会经过候选文章白名单校验，未知或已删除的引用会被过滤。
- 知识库不足以回答时，界面明确提示信息不足，而不是伪造来源。

### 本地优先与可迁移数据

- 核心数据使用 Hive 保存在设备本地。
- JSON 备份支持文章、标签、文件夹、筛选和设置的导出与恢复。
- AI、embedding 与联网搜索 Key 不进入账号同步；用户主动导出的完整 JSON 备份会包含这些 Key，必须安全保管。
- 向量索引属于可重建数据，不作为核心备份内容。

### 记忆共享

记忆不应该只锁在一人之脑。

- **导出个人记忆**：一键将知识卡片、标签、文件夹结构导出为标准 JSON 格式，脱离应用仍可用。
- **社区共享记忆**：把精选的知识卡片集分享给团队或社群——像把你读过、提炼过的认知体系"开源"给他人。
- **Agent 可直接消费**：导出的记忆包采用 Agent-friendly 格式，可导入其他人的记忆海，也可被外部 AI Agent 直接作为知识库。
- **所有权永归个人**：导出的内容是你的私有财产，分享授权、范围和用途完全由你决定。

## 机制设计

### 1. 先保存，再处理

收集入口首先创建本地 `Article` 记录，然后异步启动处理流水线。网络、正文提取或 AI 失败只会改变处理状态，不会撤销已经保存的链接。

### 2. 一次加载，多阶段复用

元数据服务和正文提取器共享同一次弹性页面加载结果。对于返回 403 的页面，不会分别为标题、正文和记忆重复请求同一个站点。

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

每个阶段都会更新 Hive 中的处理状态。致命错误会停止后续阶段并进入失败状态；标签和文件夹建议属于非关键阶段，其失败不会销毁已经生成的记忆。

### 4. 记忆作为首版知识单元

当前设计采用“一篇文章、一张记忆卡片、一个检索 chunk”。这样可以控制存储和 API 成本，并保持引用粒度清晰。它适合主题召回和观点归纳，但不等同于基于全文多 chunk 的精细事实问答。

### 5. 可追溯回答

RAG 流程先在本地召回，再把候选记忆交给聊天模型。回答中的引用编号会映射回真实 `articleId`，用户可以继续打开记忆卡片和原页面。

## 当前功能

| 模块 | 已实现能力 |
|---|---|
| 收集 | 单 URL、批量 URL、剪贴板检测、Android 分享 |
| 知识化 | 元数据（含封面回退）、正文、AI 记忆、自动标签、自动文件夹分类（必要时新建文件夹） |
| 可靠性 | 进程页、阶段状态、错误展示、重试、HTTP → WebView 兜底 |
| 知识库 | 搜索、来源筛选、标签、备注、收藏、文件夹、嵌套文件夹、当前文件夹过滤 chip |
| 检索 | 本地向量索引、余弦相似度、关键词降级 |
| 对话 | 全库 RAG、引用卡片、信息不足提示、回答反馈 |
| 阅读 | 记忆优先页面、应用内 WebView、外部浏览器入口 |
| AI 兼容 | OpenAI-compatible、MiMo 思考模型、DeepSeek/o1/o3 等思考模型自动兼容 |
| 设置 | 中英文界面、主题、字体、WebView 缩放、来源排序与隐藏 |
| 数据 | JSON 完整备份恢复、账号同步密钥隔离、索引可重建 |

## 平台状态

| 平台 | 状态 |
|---|---|
| Android | 主要开发与实机验证平台，支持系统分享 |
| iOS | 工程保留；系统分享入口尚未完成 |
| Web | 工程保留，可用于基础运行与界面调试 |
| Windows | 工程保留 |
| macOS | 工程保留 |
| Linux | 当前不维护，平台工程已移除 |

不同平台的插件能力并不完全一致。Android 是目前经过完整内容抓取、WebView 兜底和后台记忆流程验证的平台。

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
| 托管后端 | 可选账号同步、认证与 Hosted Agent；核心知识库仍以本地数据为准 |

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

本地调试构建 Android APK：

```bash
flutter build apk --debug
```

只有明确需要本地 release 产物时才手动执行 `flutter build apk --release`，并遵守版本号规则；正式生产发布使用上面的发布流水线，由 CI 构建和签名。

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
- 可选的 Embeddings Base URL、API Key 和模型名称；未配置 Key 时使用本地关键词检索

接口需要兼容 OpenAI 的请求和响应结构。不同供应商对参数、模型能力和限流策略的实现可能不同。

## 隐私边界

- 记忆海不把抓取的文章正文作为公共内容服务器托管；但可选账号同步、Hosted AI/Agent、Admin 与 APK 下载由记忆海后端提供。
- 本地文章数据不会因为使用应用而自动上传到 记忆海。
- 生成记忆时，提取后的正文会发送到用户选择的聊天模型服务。
- 用户配置 embedding 服务后，建立语义索引时会向该服务发送标题、记忆和标签；未配置时不发送并降级为本地关键词检索。
- 提问时，问题和召回到的记忆会发送到用户选择的聊天模型服务。
- API Key 保存在本机 Hive 设置中，不进入账号同步；用户主动导出的完整 JSON 备份包含 Key，应视为敏感文件。

## 文档

- [Agent 项目与迭代说明](AGENTS.md)
- [产品概览](docs/OVERVIEW.md)
- [产品需求文档](docs/PRD.md)
- [实施路线图](docs/ROADMAP.md)
- [认证、同步与后端交接契约](docs/SERVER_AUTH_SYNC_AGENT_PROMPT.md)
- [Hosted Agent 客户端工具契约](docs/MEMORA_PI_CLIENT_TOOLS.md)
- [APK 国内下载源契约](docs/APK_DISTRIBUTION_SERVER.md)
- [发布自动化环境说明](docs/RELEASE_AUTOMATION_SETUP.md)

---

# English

## Overview

Memora collects articles, videos, and post links scattered across WeChat, Zhihu, Bilibili, Rednote, X, YouTube, Reddit, ChatGPT, and the wider web. It automatically transforms them into unified, searchable, queryable personal knowledge cards.

Human memory doesn't store everything. The brain filters noise, extracts structure, and recalls through association — a faint impression is enough to retrieve an entire experience. Memora maps this cognitive logic onto digital content:

- **Bionic memory extraction**: Instead of saving full pages with ads and recommendation feeds, Memora captures only the skeleton — title, key points, tags, and source link — the highest-density layer, just as the brain remembers "this matters."
- **AI-enhanced information density**: Raw pages are information-dilute. AI summaries compress long-form content into high-density knowledge granules — each card is a directly retrieve-and-recall memory unit.
- **Agent-friendly standardized storage**: Everything becomes a "structured summary + vector index" knowledge card. Humans can browse; AI Agents can semantically retrieve, reason, and answer. Your knowledge base is both personal memory and Agent-callable cognitive resource.

> You don't need to remember *where* you saved it. You just need to know you *learned it*.

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

## Project Topology (Developers / Agents)

Memora is a multi-component product. This repository primarily owns the Flutter client, while a complete change may also involve the landing site, production backend, PostgreSQL, Hosted Agent, Admin, and delivery infrastructure.

| Component | Source and responsibility | Runtime / entry point |
|---|---|---|
| Flutter App | This repository's `lib/`, `test/`, and platform directories; local library, capture/processing, retrieval/RAG, auth and sync client | Android is the primary acceptance platform; backend defaults to `https://api.memora.wang` |
| Landing Page | Independent Astro Git worktree under `landing-page/`; website and download UI | `https://memora.wang`; separate `Memora-Landing-Page` repository on `master` |
| Backend API | Independent TypeScript/Fastify Git repository at production `/opt/memora-backend` | `https://api.memora.wang`; API docs at `/docs` |
| PostgreSQL | Backend Prisma schema and migrations; accounts, devices, sync events, Agent runs, subscriptions and feedback | PostgreSQL service in the backend Compose stack |
| Hosted Agent | Backend `src/agent/`, `config/agent.toml`, `skills/`, and durable `/ai/runs` | Authenticated execution with persisted runs and SSE recovery |
| Admin | Backend `src/routes/admin*.ts` page and protected APIs | `/admin`; credentials remain inside the secure operations boundary |
| Delivery | `.github/workflows/release.yml`, `deploy/`, and tracked release tools | GitHub Release, China APK source, and landing deployment |

Important source boundaries:

- `landing-page/` is recorded as a gitlink, but this repository currently has no `.gitmodules`. It has independent Git state and delivery; do not assume ordinary submodule commands will work.
- Backend source is not a tracked directory in this repository. `scratchpad/pi-backend-edit/` may be a local, independently dirty working copy and is not production truth. Inspect its own Git state and compare it with `/opt/memora-backend` before use.
- Client code/tests, deployed service reachability, and real authenticated/device or two-device acceptance are separate evidence levels. A 200 response from `/health` does not validate Agent, Admin, APK delivery, or sync behavior.

Read [AGENTS.md](AGENTS.md) before changing the project. It documents the component-specific workflow, safe SSH entry through the ignored machine-local `.codex/access.local.md`, database migration rules, validation boundaries, and the configured release pipeline. Never place hosts, passwords, private keys, tokens, `.env` values, or credential-bearing commands in tracked documentation.

Articles, summaries, organization data, processing state, and vector indexes are stored locally by default. Optional account sync sends selected entities to Memora's backend over HTTPS; its payload is not currently end-to-end encrypted. BYOK calls go directly to the configured provider, while Hosted Agent calls run through Memora's backend. Embeddings require a user-configured provider and otherwise fall back to local keyword retrieval.

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
- Sends exactly one model-appropriate token limit: `max_completion_tokens` for MiMo, GPT-5, and o1/o3/o4; `max_tokens` for other OpenAI-compatible models.
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
- AI, embedding, and web-search keys are excluded from account sync. User-requested full JSON backups include them and must be stored securely.
- Vector indexes are treated as rebuildable derived data.

### Memory sharing

Knowledge shouldn't stay locked in one mind.

- **Export personal memory**: One tap to export knowledge cards, tags, and folder structures in standard formats (JSON) — usable outside the app.
- **Community memory sharing**: Share curated knowledge card collections with teams or communities — effectively open-sourcing the cognitive framework you've read, refined, and organized.
- **Agent-consumable**: Exported memory packs use Agent-friendly formats. Import them into another Memora instance, or load them into external AI Agents as a knowledge base.
- **Ownership is yours forever**: Exported content is your private property. You control what to share, with whom, and for what purpose.

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
| Data | Full JSON backup/restore, account-sync key isolation, rebuildable indexes |

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
| Hosted backend | Optional auth/account sync and Hosted Agent; the local library remains authoritative |

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

Build a local Android debug APK:

```bash
flutter build apk --debug
```

Run `flutter build apk --release` manually only when a local release artifact is explicitly needed and the version contract has been observed. Production releases use the configured pipeline and CI-owned test, signing, publishing, server activation, and landing checks described in [AGENTS.md](AGENTS.md).

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
- Optional embeddings base URL, API key, and model name; local keyword retrieval is used when no embedding key is configured

The endpoint must follow an OpenAI-compatible request and response structure. Parameter support, model capabilities, and rate limits vary by provider.

## Privacy Boundary

- Memora does not host extracted article bodies as a public content server; optional account sync, Hosted AI/Agent, Admin, and APK delivery are operated by the Memora backend.
- Local article data is not automatically uploaded to Memora.
- Extracted article text is sent to the selected chat model when generating summaries.
- When an embedding provider is configured, titles, summaries, and tags are sent to it while building semantic indexes; otherwise nothing is sent and retrieval falls back to local keywords.
- Questions and retrieved summaries are sent to the selected chat model during RAG conversations.
- API keys are stored in local Hive settings and excluded from account sync. User-requested full JSON backups contain them and must be treated as sensitive files.

## Documentation

- [Agent project and iteration guide](AGENTS.md)
- [Product overview](docs/OVERVIEW.md)
- [Product requirements](docs/PRD.md)
- [Implementation roadmap](docs/ROADMAP.md)
- [Auth, sync, and backend handoff contract](docs/SERVER_AUTH_SYNC_AGENT_PROMPT.md)
- [Hosted Agent client-tool contract](docs/MEMORA_PI_CLIENT_TOOLS.md)
- [China APK distribution contract](docs/APK_DISTRIBUTION_SERVER.md)
- [Release automation setup](docs/RELEASE_AUTOMATION_SETUP.md)
