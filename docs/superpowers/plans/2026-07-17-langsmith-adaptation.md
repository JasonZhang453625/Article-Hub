# LangSmith 适配实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans` 逐任务执行。每完成一个步骤就勾选对应 checkbox；不得跳过 Gate 0 和隐私测试。

**目标：** 在不引入 LangChain、不泄露 LangSmith Service Key、不上传真实用户正文的前提下，为现有 Flutter RAG 增加阶段级 trace、可复现离线评测和后续反馈闭环能力。

**推荐结论：** 第一轮只做“开发/评测环境 LangSmith”。Flutter 通过中立的 `RagTraceSink` 输出 OpenTelemetry，发送到本地或内网 Collector；Collector 再转发到 LangSmith。发布版强制 No-op。生产 tracing 和反馈上传必须等服务端代理、隐私政策和远程 kill switch 就绪后再单独立项。

**架构：** 保留 `RagConversationService` 对 RAG 管线的所有权，在服务边界添加可选追踪端口。应用不依赖 LangChain，不直接调用 LangSmith API。现有 Hive `RetrievalLog` 继续保存本地事实，`RetrievalLog.id` 复用为 LangSmith trace/root run UUID。离线评测以仓库内 synthetic JSONL 为源，由 Python LangSmith SDK 调用一个纯 Dart JSONL worker 执行真实 RAG 服务。

**技术栈：** Flutter/Dart、Riverpod、Hive、现有 OpenAI-compatible `AiService` / `EmbeddingService`、`dartastic_opentelemetry` 0.9.5、OpenTelemetry Collector Contrib 0.153.0、Python `langsmith` 0.10.0。

**架构决策：** `docs/adr/0001-langsmith-observability-boundary.md`

---

## 范围与非目标

本计划交付：

- 开发/评测环境下的 RAG trace 和阶段 span。
- `metadataOnly` 隐私策略以及 synthetic-only 完整内容策略。
- Collector 本地运行配置，LangSmith Key 只放 Collector 环境变量。
- 追踪失败不影响回答的降级机制。
- 30 条 synthetic RAG 数据集、确定性评估器和实验基线。
- 本地反馈日志与 LangSmith trace 的 UUID 关联规则。

本计划不交付：

- LangChain 或 Dart LangChain 迁移。
- 发布版/真实用户流量的 LangSmith tracing。
- Flutter 直连 LangSmith REST API。
- 真实用户提问、文章、答案或历史消息上传。
- 生产反馈上传；当前点赞/点踩仍只写 Hive。
- 替换现有 Hive index、混合检索、RRF、本地重排或引用校验。

## 当前代码基线

现有入口和职责：

- `lib/data/services/rag_conversation_service.dart`：改写、检索、上下文、回答、引用、日志总编排。
- `lib/data/services/rag_context_builder.dart`：本地重排与 token-budget context packing。
- `lib/data/services/retrieval_service.dart`：向量 + 关键词混合检索、RRF、Isolate 计算。
- `lib/data/services/retrieval_log_service.dart`：Hive 本地查询、候选、引用、反馈、点击日志。
- `lib/shared/providers/ai_providers.dart`：生产依赖装配。
- `lib/features/chat/chat_screen.dart`：调用服务并提交本地反馈。

实施时不得覆盖当前工作区里与本计划无关的修改。每个任务开始前运行 `git status --short`，只编辑该任务列出的文件。

## 完成定义

全部条件同时满足才算完成第一轮适配：

1. 未开启追踪和发布模式下，`RagTraceSink` 必须是 No-op。
2. `lib/` 中不存在 `LANGSMITH_API_KEY`、LangSmith Service Key 或直连 LangSmith OTLP/API 的代码。
3. Collector 离线、导出超时、队列满和 exporter 抛错都不改变 RAG outcome/answer。
4. LangSmith 中一条 synthetic 问答可见完整稳定的父子 span 树。
5. `metadataOnly` trace 不含问题、历史、文章标题/URL/正文/记忆、prompt、答案和文章 ID。
6. 30 条 synthetic 数据集能运行实验并产出 retrieval recall、citation precision/recall、outcome accuracy、latency、token usage。
7. citation precision 必须为 1.0；其他阈值见 Task 8。
8. `flutter analyze`、相关测试、全量测试和 `git diff --check` 通过；若存在与本计划无关的已知失败，要记录证据而不是修改无关代码。

---

## 稳定 Trace 合约

| 名称 | 类型 | 起止边界 | 允许上传的字段（metadataOnly） |
| --- | --- | --- | --- |
| `rag.conversation` | `chain` | `ask()` 全流程 | traceId、pipeline/app 版本、平台、环境、模式、文章/候选/引用数量、outcome、失败阶段 |
| `rag.query_rewrite` | `llm` | `HistoryAwareQueryRewriter.rewrite()` | hasHistory、historyTurnCount、rewrittenChanged、fallbackCode、模型、token 数 |
| `rag.retrieve` | `retriever` | `_retrieve()` | method、candidateCount、resultCount、durationMs |
| `rag.context_build` | `chain` | `RagContextBuilder.build()` | candidateCount、selectedCount、tokenBudget、estimatedTokens |
| `rag.answer_generate` | `llm` | answer completion | 模型、temperature、maxTokens、input/output/total token 数、emptyResponse |
| `rag.citation_validate` | `parser` | `extractValidCitations()` | validCitationCount、invalidCitationCount、hasCitation |
| `rag.local_log` | `chain` | `_saveLog()` | saved、durationMs、controlledErrorCode |

共同属性：

```text
langsmith.trace.name
langsmith.span.kind
langsmith.trace.id
langsmith.span.id（root only）
langsmith.span.tags
langsmith.metadata.app_version
langsmith.metadata.pipeline_version
langsmith.metadata.environment
langsmith.metadata.data_policy
gen_ai.system
gen_ai.request.model
gen_ai.request.temperature
gen_ai.request.max_tokens
gen_ai.usage.input_tokens
gen_ai.usage.output_tokens
gen_ai.usage.total_tokens
```

禁止在 `metadataOnly` 设置 `gen_ai.prompt*`、`gen_ai.completion*`、`retrieval.documents.*`、`input.value` 或 `output.value`。错误只允许枚举值，例如 `retrieval_failed`、`empty_completion`、`prompt_load_failed`、`trace_export_failed`，禁止上传 `error.toString()` 和 stack trace。

---

### Task 0：依赖与多平台可行性 Gate

**Files:**

- Modify: `pubspec.yaml`
- Modify: `pubspec.lock`
- Create: `test/observability_dependency_smoke_test.dart`

**目的：** 在改业务代码之前确认 `dartastic_opentelemetry: ^0.9.5` 能被当前 Dart 3.11.1 和项目目标平台编译。该包目前不是官方 Dart OTel SDK，所以这是硬门槛。

- [ ] **Step 1：记录干净基线**

运行：

```powershell
git status --short
flutter test test/rag_conversation_service_test.dart test/rag_context_builder_test.dart test/retrieval_log_test.dart
flutter analyze
```

保存现有失败的完整命令和错误；不要为了通过 Gate 修改无关模块。

- [ ] **Step 2：添加唯一运行时依赖**

在 `dependencies` 增加：

```yaml
dartastic_opentelemetry: ^0.9.5
```

运行 `flutter pub get`。不添加 LangChain、LangSmith Dart 非官方 SDK或通用 Flutter 自动埋点包。

- [ ] **Step 3：写最小编译 smoke test**

测试只验证包可导入、能创建 No-op/内存 tracer 基础对象，不发网络请求。测试名：

```dart
test('OpenTelemetry dependency initializes without network export', () async {
  // Initialize with an in-memory/no-op processor and close it cleanly.
});
```

- [ ] **Step 4：运行支持平台编译门槛**

```powershell
flutter test test/observability_dependency_smoke_test.dart
flutter build web --debug
flutter build windows --debug
flutter build apk --debug
```

如果某个平台的本机工具链未安装，记录为环境限制；如果是 OTel 包本身不兼容，停止本计划、回退 `pubspec` 改动并更新 ADR，不得继续把平台不兼容依赖接入业务代码。

---

### Task 1：建立供应商无关的追踪接口和配置边界

**Files:**

- Create: `lib/config/observability_config.dart`
- Create: `lib/data/services/observability/rag_trace_sink.dart`
- Create: `lib/data/services/observability/noop_rag_trace_sink.dart`
- Test: `test/observability_config_test.dart`
- Test: `test/rag_trace_sink_test.dart`

**Interfaces:**

```dart
enum RagSpanKind { chain, llm, retriever, parser }
enum RagTraceDataPolicy { metadataOnly, syntheticFull }

abstract interface class RagTraceSink {
  Future<T> trace<T>({
    required String traceId,
    required String name,
    required Map<String, Object> attributes,
    required Future<T> Function(RagTraceScope scope) body,
  });

  Future<void> flush({Duration timeout = const Duration(milliseconds: 500)});
}

abstract interface class RagTraceScope {
  Future<T> span<T>({
    required String name,
    required RagSpanKind kind,
    Map<String, Object> attributes = const {},
    required Future<T> Function(RagSpanScope scope) body,
  });

  void setAttribute(String key, Object value);
  void markError(String controlledCode);
}
```

`NoopRagTraceSink.trace()` 必须直接执行并返回 `body` 的结果；不能改变异常语义。所有 attributes 在进入具体 exporter 前都必须经过 allowlist。

- [ ] **Step 1：先写配置失败测试**

覆盖以下规则：

```dart
expect(resolve(isRelease: true, enabled: true).enabled, isFalse);
expect(resolve(endpoint: 'https://api.smith.langchain.com').isValid, isFalse);
expect(resolve(dataPolicy: syntheticFull, environment: 'development').isValid, isFalse);
expect(resolve(sampleRate: 1.2).isValid, isFalse);
```

- [ ] **Step 2：实现纯函数配置解析**

支持以下 `--dart-define`，不支持任何 Key 字段：

```text
LANGSMITH_TRACING=false
OTEL_COLLECTOR_ENDPOINT=http://127.0.0.1:4318
RAG_TRACE_ENV=development
RAG_TRACE_DATA_POLICY=metadataOnly
RAG_TRACE_SAMPLE_RATE=1.0
```

`resolve()` 接收显式 `isRelease`，便于单测；生产调用传 `kReleaseMode`。只接受 localhost、`127.0.0.1`、Android emulator 的 `10.0.2.2` 或 RFC1918 内网 Collector，拒绝 URL user-info、query 中的 token 和 LangSmith 官方域名。

- [ ] **Step 3：写 No-op 行为测试**

断言 body 只执行一次、返回值不变、业务异常原样抛出、`flush()` 立即完成。

- [ ] **Step 4：运行聚焦测试**

```powershell
flutter test test/observability_config_test.dart test/rag_trace_sink_test.dart
```

---

### Task 2：补齐可观测的 LLM 返回元数据

**Files:**

- Modify: `lib/data/services/ai_service.dart`
- Modify: `lib/data/services/rag_conversation_service.dart`
- Modify: `lib/shared/providers/ai_providers.dart`
- Modify: `test/ai_service_test.dart`
- Modify: `test/rag_conversation_service_test.dart`

**目的：** 当前 `RagCompletion` 只返回字符串，无法可靠区分每次 query rewrite 和 answer generation 的 token、响应模型与 finish reason。本任务保留原 `AiService.chat()` API，同时新增结构化返回，避免影响摘要管线。

**Interfaces:**

```dart
class AiChatResult {
  final String content;
  final String? responseModel;
  final String? finishReason;
  final int? inputTokens;
  final int? outputTokens;
  final int? totalTokens;
}

Future<AiChatResult?> chatDetailed(...);
Future<String?> chat(...) async => (await chatDetailed(...))?.content;

class RagCompletionResult {
  final String content;
  final String? responseModel;
  final String? finishReason;
  final int? inputTokens;
  final int? outputTokens;
  final int? totalTokens;
}
```

- [ ] **Step 1：写 `chatDetailed` 解析测试**

Mock OpenAI-compatible 响应，验证 `prompt_tokens`、`completion_tokens`、`total_tokens`、`model`、`finish_reason` 和 content 被解析；缺失 usage 时字段为 null，旧 `chat()` 仍返回文本。

- [ ] **Step 2：实现兼容层**

将 chat 路径的 JSON 解析抽成 detailed result；摘要相关 `_postChat()` 保持字符串接口。现有 `onTokensUsed` 仍以 `totalTokens` 更新本地统计，不能重复计数。

- [ ] **Step 3：更新 RAG completion typedef 和测试 fake**

`HistoryAwareQueryRewriter` 使用 `result?.content`；最终回答使用 content，metrics 交给后续 span。更新所有 `RagCompletion` 测试闭包，不改变原业务断言。

- [ ] **Step 4：运行回归测试**

```powershell
flutter test test/ai_service_test.dart test/rag_conversation_service_test.dart test/summary_regeneration_test.dart test/processing_pipeline_test.dart
```

---

### Task 3：实现 OpenTelemetry 适配器与本地 Collector

**Files:**

- Create: `lib/data/services/observability/opentelemetry_rag_trace_sink.dart`
- Create: `lib/data/services/observability/rag_trace_attribute_policy.dart`
- Create: `lib/data/services/observability/observability_bootstrap.dart`
- Create: `tools/langsmith/docker-compose.yml`
- Create: `tools/langsmith/otel-collector-config.yaml`
- Create: `tools/langsmith/.env.example`
- Create: `tools/langsmith/README.md`
- Modify: `.gitignore`
- Test: `test/rag_trace_attribute_policy_test.dart`
- Test: `test/opentelemetry_rag_trace_sink_test.dart`
- Test: `test/langsmith_collector_contract_test.dart`

**Collector 固定配置：**

- Docker image：`otel/opentelemetry-collector-contrib:0.153.0`
- OTLP HTTP receiver：`0.0.0.0:4318`
- LangSmith exporter endpoint：`https://api.smith.langchain.com/otel/v1/traces`
- Headers：`x-api-key: ${env:LANGSMITH_API_KEY}`、`Langsmith-Project: ${env:LANGSMITH_PROJECT}`
- Processors：`memory_limiter`、`batch`
- 本地 `.env`：必须被 Git 忽略；仓库只提交空值 `.env.example`

- [ ] **Step 1：先写 attribute allowlist 测试**

构造包含 `question`、`prompt`、`answer`、`url`、`articleId`、`apiKey`、`Authorization` 和原始 exception 的 map，断言全部被拒绝；稳定计数、布尔值、模型名、环境和受控错误码被保留。

额外断言：即使调用方错误地传入字符串内容，`metadataOnly` 也不能将未知 key 透传。

- [ ] **Step 2：实现 OTel sink**

要求：

- root span 写入 `langsmith.trace.id=<RetrievalLog.id>` 和 `langsmith.span.id=<RetrievalLog.id>`。
- 每个 span 写入小写 `langsmith.span.kind`。
- 使用同一 OTel context 建立父子关系，不手工拼 `dotted_order`。
- 使用 `ParentBasedSampler(TraceIdRatioSampler(sampleRate))`。
- 使用 `BatchSpanProcessor` 和有界队列；exporter 指向 Collector，不带 LangSmith headers。
- exporter/processor 错误转换成内部日志并丢弃，绝不向业务层抛出。
- `flush()` 有超时；超时后返回，不阻塞应用退出或后台切换。

- [ ] **Step 3：实现 syntheticFull 双重门禁**

完整输入输出只有同时满足以下条件才允许写入：

```text
config.environment == evaluation
config.dataPolicy == syntheticFull
trace request isSynthetic == true
!kReleaseMode
```

任一条件不满足都强制降级为 `metadataOnly`，而不是报错或继续上传。

- [ ] **Step 4：建立 Collector 文件和密钥边界测试**

`langsmith_collector_contract_test.dart` 读取 YAML/compose 文本并断言：

- 官方 OTLP endpoint 和两个 header 名存在。
- header 值来自 `${env:...}`，没有硬编码 Key。
- `4318` receiver 已启用。
- `lib/` 不包含 `LANGSMITH_API_KEY` 或 `api.smith.langchain.com`。
- `.gitignore` 覆盖 `tools/langsmith/.env`。

- [ ] **Step 5：启动本地 Collector 并发送一条 smoke trace**

```powershell
Copy-Item tools\langsmith\.env.example tools\langsmith\.env
# 只在未提交的 .env 中填 LANGSMITH_API_KEY 和 LANGSMITH_PROJECT=memora-rag-dev
docker compose -f tools\langsmith\docker-compose.yml up -d
flutter test test/opentelemetry_rag_trace_sink_test.dart
```

在 LangSmith 确认 project `memora-rag-dev` 出现一条 `rag.smoke`，然后删除该 smoke 数据或标记 `synthetic`。

---

### Task 4：按现有 RAG 边界埋点，不改变业务结果

**Files:**

- Modify: `lib/data/services/rag_conversation_service.dart`
- Modify: `lib/data/services/rag_context_builder.dart`（只在需要暴露 selected count/estimated tokens 时修改，不导入 OTel）
- Modify: `lib/data/services/retrieval_log_service.dart`
- Test: `test/rag_conversation_tracing_test.dart`
- Modify: `test/rag_conversation_service_test.dart`
- Modify: `test/retrieval_log_test.dart`

**接口变化：**

```dart
RagConversationService({
  ...,
  RagTraceSink traceSink = const NoopRagTraceSink(),
  String pipelineVersion = 'rag-v1',
  String modelProvider = 'openai-compatible',
  String modelName = '',
});

extension RetrievalLogTraceId on RetrievalLog {
  String get traceId => id;
}
```

不向 Hive 新增 `traceId` 字段；`id` 与 trace UUID 相同，避免重复和迁移。

- [ ] **Step 1：先写 recording sink 的失败测试**

测试 answer、noResult、retrieval error、empty completion、prompt error 五条路径，断言：

- root 只创建一次并总能结束。
- 实际执行过的阶段才有 span。
- outcome 和 failedStage 正确。
- `traceId == result.logId == savedLog.id`。
- recording sink 抛错时，结果与 No-op 路径完全一致。

- [ ] **Step 2：包裹 root trace**

在创建 `logId` 后立刻开始 `rag.conversation`。所有业务 `try/catch` 保持原语义；追踪只观察结果，不重排控制流。

- [ ] **Step 3：逐段添加子 span**

顺序固定：

```text
query_rewrite -> retrieve -> context_build -> answer_generate
-> citation_validate -> local_log
```

knowledge-only 无结果时只执行到 `retrieve -> local_log`；retrieval 抛错时不伪造后续 span。

- [ ] **Step 4：记录结构化 completion metrics**

query rewrite 和 answer generation 分别记录各自 `AiChatResult` token、response model、finish reason。不得把 content 写入 metadataOnly attributes。

- [ ] **Step 5：让日志失败可观察但不阻塞**

`_writeLog()` 继续吞掉 Hive 分析日志失败，同时将 `rag.local_log` 标记为 `saved=false` 和受控码 `local_log_failed`。禁止上传异常文本。

- [ ] **Step 6：运行聚焦回归**

```powershell
flutter test test/rag_conversation_tracing_test.dart test/rag_conversation_service_test.dart test/rag_context_builder_test.dart test/retrieval_log_test.dart test/rag_citation_test.dart
```

---

### Task 5：Riverpod 装配、启动和生命周期 flush

**Files:**

- Create: `lib/shared/providers/observability_providers.dart`
- Create: `lib/shared/widgets/observability_lifecycle_host.dart`
- Modify: `lib/main.dart`
- Modify: `lib/app.dart`
- Modify: `lib/shared/providers/ai_providers.dart`
- Test: `test/observability_provider_test.dart`
- Modify: `test/widget_test.dart`（只更新必要 wrapper）

**装配规则：**

```dart
final ragTraceSinkProvider = Provider<RagTraceSink>(
  (_) => const NoopRagTraceSink(),
);
```

`main()` 调用 `ObservabilityBootstrap.initialize()`，任何配置/初始化错误都返回 No-op；随后通过 `ProviderScope(overrides: [...])` 注入。`RagConversationService` 从 provider 获取 sink。

- [ ] **Step 1：写 provider 默认 No-op 测试**

无 override、未开启 flag、模拟 release 三种情况都必须得到 No-op；开启 development 配置且 endpoint 合法时才返回 OTel sink。

- [ ] **Step 2：更新 main 装配**

初始化不得读取 Hive 中的 AI Key，也不得因 Collector 不可达阻止 `runApp()`。启动 tracing 的配置全部来自非敏感 `--dart-define`。

- [ ] **Step 3：增加生命周期 host**

在 `paused`、`detached` 时调用 500ms best-effort flush。不得在每次页面切换、每次 token 或每次 span 后同步 flush。

- [ ] **Step 4：更新 AI provider**

向 `RagConversationService` 注入 sink、`settings.aiModel` 和固定 provider 类别 `openai-compatible`。不上传 `aiBaseUrl`、host、API Key。

- [ ] **Step 5：验证三类启动命令**

Windows/macOS/Linux desktop：

```powershell
flutter run -d windows --dart-define=LANGSMITH_TRACING=true --dart-define=OTEL_COLLECTOR_ENDPOINT=http://127.0.0.1:4318 --dart-define=RAG_TRACE_ENV=development
```

Android emulator：

```powershell
$deviceId = (flutter devices --machine | ConvertFrom-Json | Where-Object { $_.targetPlatform -like 'android*' } | Select-Object -First 1).id
flutter run -d $deviceId --dart-define=LANGSMITH_TRACING=true --dart-define=OTEL_COLLECTOR_ENDPOINT=http://10.0.2.2:4318 --dart-define=RAG_TRACE_ENV=development
```

默认/发布：不传任何 tracing define；应无 OTLP 请求。

---

### Task 6：隐私、故障隔离和性能验收

**Files:**

- Create: `test/rag_trace_privacy_test.dart`
- Create: `test/rag_trace_failure_isolation_test.dart`
- Modify: `test/security_test.dart`
- Create: `integration_test/langsmith_trace_smoke_test.dart`
- Create: `docs/LANGSMITH_OPERATIONS.md`

- [ ] **Step 1：建立敏感 canary 测试**

使用以下仅测试字符串贯穿完整 RAG：

```text
question: PRIVATE_QUERY_CANARY
article title: PRIVATE_TITLE_CANARY
article body: PRIVATE_BODY_CANARY
answer: PRIVATE_ANSWER_CANARY
api key: sk-PRIVATE_KEY_CANARY
```

将 exporter 输出捕获为 JSON/attributes，断言五个 canary 均不存在；同时断言 count、outcome、model 和 traceId 存在。

- [ ] **Step 2：建立 exporter 故障矩阵**

模拟 initialize error、start span error、attribute error、queue full、export timeout、flush timeout。每种情况下与 No-op baseline 比较：

```dart
expect(actual.outcome, baseline.outcome);
expect(actual.answer, baseline.answer);
expect(actual.citedIds, baseline.citedIds);
```

- [ ] **Step 3：补安全扫描测试**

扩展 `security_test.dart`：

- `lib/` 不得出现 LangSmith API Key 变量名或直连域名。
- `tools/langsmith/.env` 不得被 Git 跟踪。
- `.env.example` 不得包含非空 secret。
- syntheticFull 的四重门禁有直接测试。

- [ ] **Step 4：测量 No-op 和 enabled overhead**

对纯 fake RAG 跑 1000 次：

- No-op 相对无追踪基线的 p95 增量不高于 1ms。
- 本地 Collector + batch exporter 的 `ask()` p95 增量不高于 5ms。
- Collector 完全离线时 p95 增量不高于 5ms，且没有等待 exporter timeout。

若不达标，先减小 span attributes 和移除关键路径 flush；不得放宽“追踪不阻塞回答”。

- [ ] **Step 5：写运行手册**

`docs/LANGSMITH_OPERATIONS.md` 必须包含：启动/停止 Collector、三平台 endpoint、项目命名、syntheticFull 使用限制、Key 轮换、数据删除、trace 排障、kill switch、禁止上传字段和生产启用门槛。

---

### Task 7：把 RAG 核心改成可由纯 Dart 评测 worker 调用

**Files:**

- Create: `lib/data/services/prompt_loader.dart`
- Modify: `lib/data/services/prompt_service.dart`
- Modify: `lib/data/services/rag_conversation_service.dart`
- Create: `tools/langsmith/eval/file_prompt_loader.dart`
- Create: `tools/langsmith/eval/rag_eval_target.dart`
- Test: `test/prompt_loader_contract_test.dart`
- Test: `test/rag_eval_target_test.dart`

**原因：** 当前 `PromptService` 直接依赖 Flutter `rootBundle`，纯 Dart/Python subprocess 无法复用真实 RAG 服务。只抽象 prompt 加载端口，不改 prompt 内容和业务规则。

**Interfaces:**

```dart
abstract interface class PromptLoader {
  Future<String> load(String path, [Map<String, String>? vars]);
}

class PromptService implements PromptLoader { /* rootBundle */ }
class FilePromptLoader implements PromptLoader { /* assets/prompts */ }
```

- [ ] **Step 1：写两个 loader 的合同测试**

同一 `chat/system.txt` 和变量输入必须得到相同字符串。验证不存在的 prompt 都抛同类受控错误。

- [ ] **Step 2：让 RAG 依赖 `PromptLoader`**

生产仍注入 `PromptService`；现有单测 fake 改为实现 `PromptLoader`。不在 domain service 中导入 `flutter/services.dart`。

- [ ] **Step 3：实现 JSONL worker**

`rag_eval_target.dart` 长驻读取 stdin 一行一个 case，stdout 一行一个 result；stderr 仅写诊断。输入：

```json
{
  "caseId": "rewrite-zh-001",
  "question": "第二点有什么限制？",
  "history": [{"role": "user", "content": "介绍 handoff"}],
  "knowledgeOnly": true,
  "detailedAnswer": false,
  "articles": [{"id": "...", "memory": {}}]
}
```

输出：

```json
{
  "caseId": "rewrite-zh-001",
  "traceId": "uuid",
  "outcome": "answer",
  "answer": "...",
  "rewrittenQuery": "...",
  "method": "hybrid",
  "candidateIds": ["article-a"],
  "citedIds": ["article-a"],
  "latencyMs": 1234,
  "totalTokens": 456
}
```

Worker 从 `MEMORA_EVAL_AI_*` 和 `MEMORA_EVAL_EMBEDDING_*` 环境变量读取模型配置；这些变量只存在于开发机，不进入仓库。文章用 `Article.fromJson()`；文章 embedding 在 worker 生命周期内按 model + fingerprint 缓存；检索复用 `runRetrievalInIsolate()` 和现有 RRF 参数；编排复用 `RagConversationService`。

- [ ] **Step 4：保证协议干净**

测试连续发送两个 case，确认输出恰好两行合法 JSON，日志不污染 stdout，失败 case 返回结构化 `errorCode` 而不是崩溃整个 worker。

---

### Task 8：建立 LangSmith 离线数据集与实验基线

**Files:**

- Create: `evals/rag/dataset.jsonl`
- Create: `evals/rag/README.md`
- Create: `tools/langsmith/eval/requirements.txt`
- Create: `tools/langsmith/eval/upload_dataset.py`
- Create: `tools/langsmith/eval/run_experiment.py`
- Create: `tools/langsmith/eval/evaluators.py`
- Create: `tools/langsmith/eval/test_evaluators.py`
- Modify: `tools/langsmith/README.md`

**数据集：** 名称固定为 `memora-rag-v1`，仓库 JSONL 是 source of truth，只允许 synthetic 内容。首版 30 例：

- 8 条中英文独立问题。
- 6 条中文多轮指代改写。
- 4 条英文多轮指代改写。
- 4 条 knowledge-only 无结果。
- 4 条 lexical/semantic 冲突与重排。
- 4 条引用陷阱（答案有/无合法 `[n]`、伪造编号）。

每例包含 `caseId`、split/tags、输入、`expectedOutcome`、`requiredCandidateIds`、`allowedCitationIds`、`requiredCitationIds`。不得复制任何真实用户文章或聊天记录。

- [ ] **Step 1：写确定性 evaluator 单测**

实现并测试：

```text
outcome_accuracy
retrieval_recall_at_10
citation_precision
citation_recall
no_hallucinated_citation
rewrite_changed_when_expected
latency_ms
total_tokens
```

空集合分母规则必须显式：无应引用来源且实际无引用时 precision/recall 记 1；出现任何不在 allowed set 的引用，precision 低于 1，`no_hallucinated_citation=0`。

- [ ] **Step 2：实现幂等数据集上传**

`requirements.txt` 固定：

```text
langsmith==0.10.0
```

`upload_dataset.py` 以 `caseId` upsert，metadata 写 `schemaVersion=1`、Git commit SHA 和 source `synthetic-repo`。数据变化由 LangSmith 自动形成新 version；脚本输出 dataset ID 和新 version 时间。

- [ ] **Step 3：实现实验 runner**

Python 启动一个 Dart JSONL worker，并以 `max_concurrency=1` 调用 LangSmith `Client.evaluate()`。experiment prefix：

```text
memora-rag-{gitShortSha}-{aiModel}-{embeddingModel}
```

experiment metadata 写 models、pipelineVersion=`rag-v1`、datasetSchemaVersion=1、Git SHA。target 输出包含 `traceId`，便于跳转到对应阶段 trace。

- [ ] **Step 4：运行首个 baseline**

```powershell
python -m venv .venv-langsmith
.\.venv-langsmith\Scripts\python -m pip install -r tools\langsmith\eval\requirements.txt
.\.venv-langsmith\Scripts\python tools\langsmith\eval\upload_dataset.py
.\.venv-langsmith\Scripts\python tools\langsmith\eval\run_experiment.py --dataset memora-rag-v1
```

将 baseline 名称写入 `evals/rag/README.md`，不要把 Key、完整命令环境或 LangSmith 导出的真实内容提交仓库。

- [ ] **Step 5：执行质量阈值**

首版门槛：

```text
outcome_accuracy = 1.00
retrieval_recall_at_10 >= 0.90
citation_precision = 1.00
citation_recall >= 0.85
no_hallucinated_citation = 1.00
worker_success_rate >= 0.95（模型/网络故障单独统计）
p95_latency 相对已登记 baseline 回退 <= 20%
average_total_tokens 相对 baseline 增长 <= 15%
```

任何 prompt、模型、检索阈值、context budget 或重排算法变更，都必须在同一 dataset version 上与 baseline 对比后再合入。

---

### Task 9：反馈策略和生产扩展 Gate（文档化，不在本轮启用）

**Files:**

- Modify: `docs/LANGSMITH_OPERATIONS.md`
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1：记录当前反馈事实来源**

点赞/点踩和引用点击继续由 `RetrievalLogService` 本地保存。`log.id` 即未来反馈使用的 trace/run UUID。第一轮不增加网络反馈调用。

- [ ] **Step 2：记录未来 presigned feedback 流程**

只有服务端能使用 LangSmith Service Key 为指定 run + feedback key 签发短期 presigned token 后，Flutter 才能上传 `user_helpfulness`。Flutter 永远不接收 Service Key。token 一次性/短时有效，失败仍以本地 Hive 记录为准并可稍后重试。

- [ ] **Step 3：给生产 tracing 建硬 Gate**

ROADMAP 加入：服务端代理、隐私同意、保留/删除策略、remote kill switch、10% 采样、多平台功耗与流量基准、metadataOnly 泄漏测试。未全部完成前发布版保持 No-op。

---

### Task 10：最终验证与交付

**Files:**

- Review all files above.

- [ ] **Step 1：格式化**

```powershell
dart format lib\config\observability_config.dart lib\data\services\ai_service.dart lib\data\services\prompt_loader.dart lib\data\services\prompt_service.dart lib\data\services\rag_conversation_service.dart lib\data\services\rag_context_builder.dart lib\data\services\retrieval_log_service.dart lib\data\services\observability lib\main.dart lib\app.dart lib\shared\providers\ai_providers.dart lib\shared\providers\observability_providers.dart lib\shared\widgets\observability_lifecycle_host.dart test\observability_dependency_smoke_test.dart test\observability_config_test.dart test\rag_trace_sink_test.dart test\rag_trace_attribute_policy_test.dart test\opentelemetry_rag_trace_sink_test.dart test\langsmith_collector_contract_test.dart test\rag_conversation_tracing_test.dart test\rag_trace_privacy_test.dart test\rag_trace_failure_isolation_test.dart test\prompt_loader_contract_test.dart test\rag_eval_target_test.dart integration_test\langsmith_trace_smoke_test.dart tools\langsmith\eval\file_prompt_loader.dart tools\langsmith\eval\rag_eval_target.dart
```

只格式化本计划实际改动的 Dart 文件；不要机械格式化整个已有脏工作区。

- [ ] **Step 2：运行聚焦测试**

```powershell
flutter test test/observability_dependency_smoke_test.dart test/observability_config_test.dart test/rag_trace_sink_test.dart test/rag_trace_attribute_policy_test.dart test/opentelemetry_rag_trace_sink_test.dart test/langsmith_collector_contract_test.dart test/rag_conversation_tracing_test.dart test/rag_trace_privacy_test.dart test/rag_trace_failure_isolation_test.dart test/rag_eval_target_test.dart
```

- [ ] **Step 3：运行 RAG 回归**

```powershell
flutter test test/rag_conversation_service_test.dart test/rag_context_builder_test.dart test/rag_citation_test.dart test/retrieval_log_test.dart test/embedding_retrieval_test.dart test/retrieval_query_set_test.dart test/chat_screen_widget_test.dart
```

- [ ] **Step 4：运行广泛检查**

```powershell
flutter analyze
flutter test
python tools\langsmith\eval\test_evaluators.py
git diff --check
git status --short
```

- [ ] **Step 5：手工 LangSmith 验收**

使用 synthetic case 完成一次 answer、noResult 和模型错误：

- trace 树名称和父子关系符合合约。
- `traceId` 与本地 RetrievalLog id 相同。
- attributes 中没有 canary 或真实内容。
- Collector 停止后 app 回答行为不变。
- baseline experiment 能按模型、Git SHA、pipeline version 分组比较。

- [ ] **Step 6：审查改动边界**

确认没有 LangChain 依赖、没有 LangSmith Key、没有真实数据集、没有把 `tools/langsmith/.env` 加入 Git、没有修改本计划之外的用户工作区改动。

---

## 分阶段发布顺序

1. **PR A：追踪基础设施** — Task 0-3；只交付 No-op、OTel sink、Collector 和安全测试。
2. **PR B：RAG 埋点** — Task 4-6；开启 synthetic dev trace，业务结果必须零变化。
3. **PR C：离线评测** — Task 7-8；数据集、worker、实验 baseline。
4. **文档 Gate：生产扩展** — Task 9；不在前三个 PR 中启用生产上传。

每个 PR 都可独立回滚。PR A/B/C 不允许顺带重构 UI、存储格式、处理管线或同步模块。

## 官方依据

- LangSmith 支持非 LangChain 应用通过标准 OpenTelemetry client 追踪，并定义 `langsmith.span.kind`、trace/run UUID、GenAI token 和 retriever 映射：<https://docs.langchain.com/langsmith/trace-with-opentelemetry>
- 官方 Collector 示例使用 `https://api.smith.langchain.com/otel/v1/traces`、`x-api-key` 和 `Langsmith-Project`：<https://docs.langchain.com/langsmith/trace-with-opentelemetry>
- LangSmith 支持隐藏/掩码输入输出和敏感请求的 conditional tracing：<https://docs.langchain.com/langsmith/mask-inputs-outputs>
- LangSmith 建议用数据集、evaluators、experiments 进行离线回归，并支持数据集版本：<https://docs.langchain.com/langsmith/evaluation>、<https://docs.langchain.com/langsmith/manage-datasets>
- 客户端反馈不应暴露 API Key，应使用 presigned feedback token：<https://docs.langchain.com/langsmith/attach-user-feedback>
- Dart OTel 候选包提供 Flutter 多平台、OTLP/HTTP、batch processor 和 sampler：<https://pub.dev/packages/dartastic_opentelemetry>
