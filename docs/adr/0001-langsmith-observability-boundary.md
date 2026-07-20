# ADR-0001：通过 OpenTelemetry Collector 适配 LangSmith

- 状态：Proposed
- 日期：2026-07-17
- 决策人：Article-Hub / Memora 项目
- 关联计划：`docs/superpowers/plans/2026-07-17-langsmith-adaptation.md`

## 背景

Memora 的 RAG 已经由本地 Dart 服务完成完整编排：历史问题改写、混合检索、本地重排、上下文预算、答案生成、引用校验和本地检索日志。当前最需要补充的是跨阶段可观测性、可比较的离线评测和失败样本闭环，而不是再引入一套 RAG 编排框架。

应用是 local-first Flutter 客户端，保存的文章、用户提问、对话历史和生成答案都可能包含私人内容。LangSmith Service Key 不能进入 Flutter 源码、构建参数、安装包或本地 Hive。Flutter/Dart 也没有官方 LangSmith SDK，因此不能照搬 Python/TypeScript 的直接 SDK 接入方式。

## 决策

采用“领域无关追踪接口 + OpenTelemetry 实现 + 本地/内网 Collector 转发”的结构：

```text
RagConversationService
        |
        v
RagTraceSink（项目内中立接口）
        |
        +-- NoopRagTraceSink（默认、发布版）
        |
        +-- OpenTelemetryRagTraceSink（开发/评测）
                    |
                    v
          OTLP/HTTP Collector
                    |
                    v
               LangSmith
```

具体约束如下：

1. 不引入 LangChain，不改变现有 RAG 编排所有权。
2. `RagConversationService` 只依赖项目内的 `RagTraceSink`，不直接依赖 LangSmith 或 OpenTelemetry 类型。
3. 第一阶段仅在开发和离线评测环境启用追踪；发布构建无条件使用 No-op。
4. Flutter 只向受信任的 Collector 地址发送 OTLP，不持有 `LANGSMITH_API_KEY`，也不直接请求 `api.smith.langchain.com`。
5. Collector 使用环境变量持有 LangSmith Key，并通过官方 OTLP 端点 `https://api.smith.langchain.com/otel/v1/traces` 转发。
6. 默认数据策略为 `metadataOnly`：不发送原始问题、历史消息、文章标题、URL、正文、记忆内容、提示词或答案。
7. 只有标记为 synthetic 的离线评测数据可以在显式开启 `syntheticFull` 后发送完整输入输出；真实用户数据不允许使用该模式。
8. 追踪失败、队列满、Collector 离线或 LangSmith 不可用时，必须丢弃遥测并继续返回原 RAG 结果。
9. 现有 `RetrievalLog.id` 同时作为 LangSmith trace UUID 和 root run UUID，不新增重复存储字段。
10. 用户点赞/点踩继续以 Hive 本地日志为事实来源。生产反馈上传要等服务端能够签发 LangSmith presigned feedback token 后再启用。

## Trace 合约

根 trace 名称为 `rag.conversation`，类型为 `chain`。子 span 使用以下稳定名称：

| Span | LangSmith 类型 | 主要指标 | 禁止字段 |
| --- | --- | --- | --- |
| `rag.query_rewrite` | `llm` | 是否有历史、是否发生改写、回退原因、耗时 | 原问题、历史、改写文本 |
| `rag.retrieve` | `retriever` | 检索方式、候选数量、命中数量、耗时 | 查询文本、文章 ID、文档内容 |
| `rag.context_build` | `chain` | 输入候选数、选中文章数、估算 token、预算 | 标题、正文、结构化记忆 |
| `rag.answer_generate` | `llm` | provider 类别、模型、max tokens、temperature、token 用量、耗时 | system/user prompt、答案 |
| `rag.citation_validate` | `parser` | 引用数量、非法引用数量、是否零引用 | 文章 ID、引用原文 |
| `rag.local_log` | `chain` | 是否成功、耗时 | Hive 内容、原始错误字符串 |

根 trace 记录 `outcome`、`knowledgeOnly`、`detailedAnswer`、文章总数、候选数、引用数、pipeline 版本、app 版本、平台和环境。错误只记录受控错误码与失败阶段，不记录可能包含响应正文或密钥的原始异常文本。

## 采样与性能

- 未显式开启：0%。
- 本地开发、synthetic 评测：100%。
- 将来生产环境：默认 10%，并使用 parent-based trace-id ratio sampling；是否启用必须经过新的隐私审查。
- 使用批处理和有界队列。导出不进入回答关键路径；关闭或进入后台时只做有上限的 best-effort flush。
- 根 trace 与全部子 span 使用同一采样决定，避免父 span 未导出导致 LangSmith 丢弃子 span。

## 备选方案

### 方案 A：Flutter 直接调用 LangSmith REST API

未采用。它会迫使客户端持有长期 Service Key，或者额外实现签名代理；同步直传还会增加 RAG 延迟和失败耦合。

### 方案 B：在 Flutter 内使用非官方 LangSmith SDK

未采用。当前没有官方 Dart SDK，依赖非官方的供应商专用实现会把领域代码与 LangSmith 绑定，并增加兼容风险。

### 方案 C：先接入 LangChain，再利用自动 tracing

未采用。现有 RAG 编排已经清晰、可测试，引入 LangChain 不会解决密钥与隐私边界，反而会增加迁移面。

### 方案 D：完全依赖现有 Hive 检索日志

保留但不单独采用。Hive 日志适合本地反馈与轻量统计，却无法提供跨阶段耗时树、实验比较和 LangSmith 数据集/评测能力。

## 后果

正面影响：

- 现有 RAG 不需要改写成 LangChain。
- Service Key 不进入安装包。
- 可在 LangSmith 中看到稳定的阶段树、耗时、错误阶段和模型配置。
- 同一套中立追踪接口以后可以切换到其他 OTel 后端。
- 本地日志、LangSmith trace 和离线评测可通过同一个 UUID 关联。

代价与风险：

- 增加一个 Dart OpenTelemetry 依赖和开发用 Collector。
- `dartastic_opentelemetry` 不是 Flutter/Dart 官方 SDK，必须先通过依赖与多平台 smoke gate。
- `metadataOnly` 保护隐私，但无法直接在 LangSmith 查看真实问答文本；完整内容调试只允许 synthetic 数据。
- 生产反馈和生产 tracing 需要服务端/代理能力，当前不会随第一阶段交付。

## 推进门槛

只有同时满足以下条件，才能把追踪从开发/评测扩展到发布版：

1. 有受控服务端代理或私有 Collector，客户端不持有 LangSmith Service Key。
2. 用户隐私说明、数据保留周期、删除机制和地区合规完成评审。
3. 生产 trace 保持 `metadataOnly`，并通过敏感数据泄漏测试。
4. 采样、队列和网络耗电在 Android、iOS、Windows、Web 上通过基准验证。
5. 增加远程 kill switch，并能在不发版的情况下停止采集。

## 回滚

将 `LANGSMITH_TRACING` 设为 false 或移除 Provider override 即回到 `NoopRagTraceSink`。领域层接口保留不会影响 RAG；若 OpenTelemetry 依赖本身造成构建问题，可删除适配器和依赖，现有业务测试仍应全部通过。
