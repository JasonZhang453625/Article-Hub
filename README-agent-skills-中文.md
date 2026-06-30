# Agent Skills（智能体技能）

**面向 AI 编程智能体的生产级工程技能。**

技能将高级工程师构建软件时所遵循的工作流程、质量门禁和最佳实践进行编码封装，确保 AI 智能体在开发的每个阶段都能一致地遵循它们。

<a href="https://trendshift.io/repositories/25200" target="_blank"><img src="https://trendshift.io/api/badge/repositories/25200" alt="addyosmani%2Fagent-skills | Trendshift" style="width: 250px; height: 55px;" width="250" height="55"/></a>

![Addy's Agent Skills](https://addyosmani.com/assets/images/addys-agent-skills.jpg)

```
  定义            规划           构建           验证           审查           发布
 ┌──────┐      ┌──────┐      ┌──────┐      ┌──────┐      ┌──────┐      ┌──────┐
 │ 创意 │ ───▶ │ 规格 │ ───▶ │ 代码 │ ───▶ │ 测试 │ ───▶ │ 质量 │ ───▶ │ 上线 │
 │ 精炼 │      │ PRD  │      │ 实现 │      │ 调试 │      │ 门禁 │      │ 运行 │
 └──────┘      └──────┘      └──────┘      └──────┘      └──────┘      └──────┘
  /spec          /plan          /build        /test         /review       /ship
```

---

## 命令

8 个与开发生命周期对应的斜杠命令，每个命令会自动激活相应的技能。

| 你正在做什么 | 命令 | 核心原则 |
|-------------------|---------|---------------|
| 定义要构建什么 | `/spec` | 代码之前先写规格 |
| 规划如何构建 | `/plan` | 小而原子化的任务 |
| 增量构建 | `/build` | 一次一个切面 |
| 验证它是否有效 | `/test` | 测试就是证据 |
| 合并前审查 | `/review` | 改善代码健康度 |
| 审计 Web 性能 | `/webperf` | 先测量再优化 |
| 简化代码 | `/code-simplify` | 清晰优于聪明 |
| 发布上生产 | `/ship` | 越快越安全 |

规格确定后想减少手动步骤？**`/build auto`** 会生成计划并在单次审批通过后自动完成所有任务——你只需审批一次计划，之后它会自主运行。它去掉的是任务之间的人工介入，而非验证环节：每个任务仍然遵循测试驱动，单独提交，遇到失败或风险步骤会暂停。

技能还会根据你正在做的事情自动激活——设计 API 会触发 `api-and-interface-design`，构建 UI 会触发 `frontend-ui-engineering`，依此类推。

---

## 快速上手

**Claude Code（推荐）**

**通过市场安装：**

```
/plugin marketplace add addyosmani/agent-skills
/plugin install agent-skills@addy-agent-skills
```

> **SSH 错误？** 市场通过 SSH 克隆仓库。如果你没有在 GitHub 上设置 SSH 密钥，可以[添加 SSH 密钥](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account)或使用完整 HTTPS 地址强制克隆：
> ```bash
> /plugin marketplace add https://github.com/addyosmani/agent-skills.git
> /plugin install agent-skills@addy-agent-skills
> ```

**本地 / 开发环境：**

```bash
git clone https://github.com/addyosmani/agent-skills.git
claude --plugin-dir /path/to/agent-skills
```

**Cursor**

将任意 `SKILL.md` 文件复制到 `.cursor/rules/` 目录中，或引用整个 `skills/` 目录。详见 [docs/cursor-setup.md](docs/cursor-setup.md)。

**Antigravity CLI**

作为原生插件安装，支持技能、子智能体和斜杠命令。详见 [docs/antigravity-setup.md](docs/antigravity-setup.md)。

**从仓库安装：**

```bash
agy plugin install https://github.com/addyosmani/agent-skills.git
```

**从本地克隆安装：**

```bash
git clone https://github.com/addyosmani/agent-skills.git
agy plugin install ./agent-skills
```

**Gemini CLI**

作为原生技能安装以实现自动发现，或添加到 `GEMINI.md` 以获得持久化上下文。详见 [docs/gemini-cli-setup.md](docs/gemini-cli-setup.md)。

**从仓库安装：**

```bash
gemini skills install https://github.com/addyosmani/agent-skills.git --path skills
```

**从本地克隆安装：**

```bash
gemini skills install ./agent-skills/skills/
```

**Windsurf**

将技能内容添加到你的 Windsurf 规则配置中。详见 [docs/windsurf-setup.md](docs/windsurf-setup.md)。

**OpenCode**

通过 AGENTS.md 和 `skill` 工具使用智能体驱动的技能执行。详见 [docs/opencode-setup.md](docs/opencode-setup.md)。

**GitHub Copilot**

使用 `agents/` 目录中的智能体定义作为 Copilot 角色，技能内容放在 `.github/copilot-instructions.md` 中。详见 [docs/copilot-setup.md](docs/copilot-setup.md)。

**Kiro IDE & CLI**

Kiro 的技能存储在 ".kiro/skills/" 目录下，可以放在项目级别或全局级别。Kiro 也支持 Agents.md。详见 Kiro 文档 https://kiro.dev/docs/skills/

**Codex / 其他智能体**

技能文件是纯 Markdown 格式——它们适用于任何接受系统提示词或指令文件的智能体。详见 [docs/getting-started.md](docs/getting-started.md)。

---

## 全部 24 个技能

上述命令是入口点。本包包含共 24 个技能——23 个生命周期技能加上 `using-agent-skills` 元技能。每个技能都是一个结构化的工作流程，包含步骤、验证门禁和反合理化表格。你也可以直接引用任何技能。

### 元技能 — 确定应用哪个技能

| 技能 | 作用 | 使用场景 |
|-------|-------------|----------|
| [using-agent-skills](skills/using-agent-skills/SKILL.md) | 将当前工作映射到正确的技能工作流，并定义共享操作规则 | 会话开始时或需要确定应用哪个技能时 |

### 定义 — 明确要构建什么

| 技能 | 作用 | 使用场景 |
|-------|-------------|----------|
| [interview-me](skills/interview-me/SKILL.md) | 逐题访谈，挖掘用户真正想要的东西而非他们以为想要的，直到约 95% 置信度 | 需求不够明确，或用户说"采访我"/"拷问我"时 |
| [idea-refine](skills/idea-refine/SKILL.md) | 结构化的发散/收敛思维，将模糊概念转化为具体方案 | 有一个粗略想法需要探索时 |
| [spec-driven-development](skills/spec-driven-development/SKILL.md) | 在编码前撰写涵盖目标、命令、结构、代码风格、测试和边界的 PRD | 启动新项目、新功能或重大变更时 |

### 规划 — 拆解任务

| 技能 | 作用 | 使用场景 |
|-------|-------------|----------|
| [planning-and-task-breakdown](skills/planning-and-task-breakdown/SKILL.md) | 将规格分解为小的、可验证的任务，包含验收标准和依赖排序 | 已有规格，需要可实现的单元时 |

### 构建 — 编写代码

| 技能 | 作用 | 使用场景 |
|-------|-------------|----------|
| [incremental-implementation](skills/incremental-implementation/SKILL.md) | 薄垂直切片——实现、测试、验证、提交。特性开关、安全默认值、易回滚变更 | 任何涉及多个文件的变更 |
| [test-driven-development](skills/test-driven-development/SKILL.md) | 红-绿-重构，测试金字塔（80/15/5），测试规模，DAMP 优于 DRY，Beyonce 规则，浏览器测试 | 实现逻辑、修复 bug 或修改行为时 |
| [context-engineering](skills/context-engineering/SKILL.md) | 在正确的时间向智能体提供正确的信息——规则文件、上下文打包、MCP 集成 | 开始会话、切换任务或输出质量下降时 |
| [source-driven-development](skills/source-driven-development/SKILL.md) | 基于官方文档做出每个框架决策——验证、引用来源、标记未验证部分 | 想要权威的、有出处的代码时 |
| [doubt-driven-development](skills/doubt-driven-development/SKILL.md) | 在运行中对每个重要决策进行对抗式全新上下文审查——声明→提取→质疑→协调→停止，可选用户授权的跨模型升级 | 高风险（生产、安全、不可逆操作）、在不熟悉的代码中工作、或现在验证比以后调试成本更低时 |
| [frontend-ui-engineering](skills/frontend-ui-engineering/SKILL.md) | 组件架构、设计系统、状态管理、响应式设计、WCAG 2.1 AA 无障碍标准 | 构建或修改用户界面时 |
| [api-and-interface-design](skills/api-and-interface-design/SKILL.md) | 契约优先设计、Hyrum 定律、单版本规则、错误语义、边界验证 | 设计 API、模块边界或公共接口时 |

### 验证 — 证明它有效

| 技能 | 作用 | 使用场景 |
|-------|-------------|----------|
| [browser-testing-with-devtools](skills/browser-testing-with-devtools/SKILL.md) | Chrome DevTools MCP 获取实时运行时数据——DOM 检查、控制台日志、网络追踪、性能分析 | 构建或调试任何在浏览器中运行的内容时 |
| [debugging-and-error-recovery](skills/debugging-and-error-recovery/SKILL.md) | 五步排查：复现、定位、缩小范围、修复、防护。停线规则、安全回退 | 测试失败、构建中断或行为异常时 |

### 审查 — 合并前的质量门禁

| 技能 | 作用 | 使用场景 |
|-------|-------------|----------|
| [code-review-and-quality](skills/code-review-and-quality/SKILL.md) | 五轴审查、变更规模（约 100 行）、严重程度标签（挑剔/可选/供参考）、审查速度规范、拆分策略 | 合并任何变更之前 |
| [code-simplification](skills/code-simplification/SKILL.md) | Chesterton 栅栏法则、500 行规则、在不改变行为的前提下降低复杂度 | 代码能工作但难以阅读或维护时 |
| [security-and-hardening](skills/security-and-hardening/SKILL.md) | OWASP Top 10 防护、认证模式、密钥管理、依赖审计、三层边界系统 | 处理用户输入、认证、数据存储或外部集成时 |
| [performance-optimization](skills/performance-optimization/SKILL.md) | 先测量再优化的方法——Core Web Vitals 指标、分析工作流、包分析、反模式检测 | 有性能要求或怀疑性能退化时 |

### 发布 — 自信部署

| 技能 | 作用 | 使用场景 |
|-------|-------------|----------|
| [git-workflow-and-versioning](skills/git-workflow-and-versioning/SKILL.md) | 主干开发、原子提交、变更规模（约 100 行）、提交即保存点模式 | 做任何代码变更时（始终） |
| [ci-cd-and-automation](skills/ci-cd-and-automation/SKILL.md) | 左移、越快越安全、特性开关、质量门禁流水线、失败反馈循环 | 设置或修改构建部署流水线时 |
| [deprecation-and-migration](skills/deprecation-and-migration/SKILL.md) | 代码即负债思维、强制 vs 建议弃用、迁移模式、僵尸代码清理 | 移除旧系统、迁移用户或淘汰功能时 |
| [documentation-and-adrs](skills/documentation-and-adrs/SKILL.md) | 架构决策记录、API 文档、内联文档标准——记录 *为什么* | 做架构决策、更改 API 或发布功能时 |
| [observability-and-instrumentation](skills/observability-and-instrumentation/SKILL.md) | 结构化日志、RED 指标、OpenTelemetry 追踪、基于症状的告警——边构建边埋点 | 添加遥测，或发布任何在生产环境运行的内容时 |
| [shipping-and-launch](skills/shipping-and-launch/SKILL.md) | 发布前检查清单、特性开关生命周期、分阶段上线、回滚流程、监控设置 | 准备部署到生产环境时 |

---

## 智能体角色

预配置的专业角色，用于有针对性的审查：

| 智能体 | 角色 | 视角 |
|-------|------|-------------|
| [code-reviewer](agents/code-reviewer.md) | 高级资深工程师 | 以"资深工程师会批准吗？"为标准进行五轴代码审查 |
| [test-engineer](agents/test-engineer.md) | QA 专家 | 测试策略、覆盖率分析和"证明它"模式 |
| [security-auditor](agents/security-auditor.md) | 安全工程师 | 漏洞检测、威胁建模、OWASP 评估 |
| [web-performance-auditor](agents/web-performance-auditor.md) | Web 性能工程师 | Core Web Vitals 审计，支持快速/深度模式，遵循指标诚实规则；通过 `/webperf` 运行 |

详见 [docs/agents.md](docs/agents.md)，了解决策矩阵、编排规则以及角色如何与技能和斜杠命令组合使用。

---

## 参考检查清单

技能在需要时加载的速查材料：

| 参考文档 | 涵盖内容 |
|-----------|--------|
| [definition-of-done.md](references/definition-of-done.md) | 每个变更都需要清除的项目级标准线，与单任务验收标准对比 |
| [testing-patterns.md](references/testing-patterns.md) | 测试结构、命名、模拟、React/API/E2E 示例、反模式 |
| [security-checklist.md](references/security-checklist.md) | 提交前检查、认证、输入验证、HTTP 头、CORS、OWASP Top 10 |
| [performance-checklist.md](references/performance-checklist.md) | Core Web Vitals 指标、前端/后端检查清单、测量命令 |
| [accessibility-checklist.md](references/accessibility-checklist.md) | 键盘导航、屏幕阅读器、视觉设计、ARIA、测试工具 |
| [observability-checklist.md](references/observability-checklist.md) | 值班问题、结构化日志、RED/USE 指标、追踪、基于症状的告警、发布前门禁 |
| [orchestration-patterns.md](references/orchestration-patterns.md) | 推荐的多角色编排模式、反模式以及"角色不调用角色"规则 |

---

## 技能如何运作

每个技能遵循一致的结构：

```
┌─────────────────────────────────────────────────┐
│  SKILL.md                                       │
│                                                 │
│  ┌─ 前置元数据 ──────────────────────────────┐  │
│  │ name: 小写连字符命名                      │  │
│  │ description: 引导智能体完成[任务]。        │  │
│  │              使用场景…                     │  │
│  └───────────────────────────────────────────┘  │
│  概述             → 此技能的作用                │
│  使用场景         → 触发条件                    │
│  流程             → 分步骤工作流                │
│  合理化借口       → 借口 + 反驳                  │
│  红旗警告         → 出问题的迹象                │
│  验证             → 证据要求                    │
└─────────────────────────────────────────────────┘
```

**关键设计选择：**

- **流程而非散文。** 技能是智能体遵循的工作流，不是供阅读的参考文档。每个技能都有步骤、检查点和退出标准。
- **反合理化。** 每个技能都包含一个常见借口表格（如"我稍后再加测试"）及已文档化的反驳论据。
- **验证不容妥协。** 每个技能结尾都有证据要求——测试通过、构建输出、运行时数据。"看起来没问题"永远不够。
- **渐进式披露。** `SKILL.md` 是入口点。辅助参考资料仅在需要时加载，最大程度降低 token 消耗。

---

## 项目结构

```
agent-skills/
├── skills/                            # 24 个技能（23 生命周期 + 1 元技能）
│   ├── interview-me/                  #   定义
│   ├── idea-refine/                   #   定义
│   ├── spec-driven-development/       #   定义
│   ├── planning-and-task-breakdown/   #   规划
│   ├── incremental-implementation/    #   构建
│   ├── context-engineering/           #   构建
│   ├── source-driven-development/     #   构建
│   ├── doubt-driven-development/      #   构建
│   ├── frontend-ui-engineering/       #   构建
│   ├── test-driven-development/       #   构建
│   ├── api-and-interface-design/      #   构建
│   ├── browser-testing-with-devtools/ #   验证
│   ├── debugging-and-error-recovery/  #   验证
│   ├── code-review-and-quality/       #   审查
│   ├── code-simplification/           #   审查
│   ├── security-and-hardening/        #   审查
│   ├── performance-optimization/      #   审查
│   ├── git-workflow-and-versioning/   #   发布
│   ├── ci-cd-and-automation/          #   发布
│   ├── deprecation-and-migration/     #   发布
│   ├── documentation-and-adrs/        #   发布
│   ├── observability-and-instrumentation/ # 发布
│   ├── shipping-and-launch/           #   发布
│   └── using-agent-skills/            #   元技能：如何使用本技能包
├── agents/                            # 4 个专业角色
├── references/                        # 7 个辅助检查清单
├── hooks/                             # 会话生命周期钩子
├── .claude/commands/                  # 8 个斜杠命令（Claude Code）
├── .gemini/commands/                  # 8 个斜杠命令（Gemini CLI）
├── commands/                          # 8 个斜杠命令（Antigravity CLI）
├── plugin.json                        # Antigravity 插件清单
└── docs/                              # 各工具安装指南
```

---

## 为什么需要 Agent Skills？

AI 编程智能体默认会选择最短路径——这往往意味着跳过规格说明、测试、安全审查以及使软件可靠的那些实践。Agent Skills 为智能体提供了结构化的工作流程，强制执行高级工程师在开发生产代码时所遵循的那些纪律。

每个技能都编码了来之不易的工程判断：*何时*写规格、*测什么*、*如何*审查以及*何时*发布。这些不是通用的提示词——它们是有明确主张的、流程驱动的工作流，能够区分生产级工作和原型级工作。

技能融入了 Google 工程文化中的最佳实践——包括来自[《谷歌软件工程》](https://abseil.io/resources/swe-book)和 Google [工程实践指南](https://google.github.io/eng-practices/)的概念。你会在 API 设计中看到 Hyrum 定律，测试中的 Beyonce 规则和测试金字塔，代码审查中的变更规模和审查速度规范，代码简化中的 Chesterton 栅栏法则，Git 工作流中的主干开发，CI/CD 中的左移和特性开关，以及将代码视为负债的独立弃用技能。这些不是抽象原则——它们直接嵌入到智能体遵循的逐步工作流中。

---

## 与其他方案的比较

想知道它和 [Superpowers](https://github.com/obra/superpowers) 或 [Matt Pocock 的技能](https://github.com/mattpocock/skills) 相比如何？查看 **[docs/comparison.md](docs/comparison.md)**，了解三者差异以及各自的适用场景——其中还包括[对照实验](https://www.linkedin.com/pulse/superpowers-vs-agent-skills-faster-shipping-safer-reasoning-om-mishra-dzakf/)的链接。

---

## 贡献

技能应该做到**具体**（可操作步骤，而非模糊建议）、**可验证**（清晰的退出标准和证据要求）、**实战检验**（基于真实工作流）和**最小化**（只包含引导智能体所需的内容）。

关于格式规范请参见 [docs/skill-anatomy.md](docs/skill-anatomy.md)，贡献指南请参见 [CONTRIBUTING.md](CONTRIBUTING.md)。

---

## 许可证

MIT —— 在你的项目、团队和工具中自由使用这些技能。
