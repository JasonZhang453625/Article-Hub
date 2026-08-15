# 服务器端 Agent 提示词：账号、自动同步与统一 JSON 协议 v3

你负责记忆海（Memora）服务器端的账号与多设备同步。请直接检查并修改真实后端代码、数据库迁移、接口、测试和部署配置，不要只给设计建议。

## 一、交付目标

实现并验证以下结果：

1. 用户使用同一账号登录不同设备后，可以同步文章、文件夹、筛选组和完整应用设置。
2. 应用设置只同步 AI、Image、Embedding 的 Base URL、模型名等非敏感配置；所有 provider API Key 必须保持设备本地。
3. 同步协议固定为 v3，所有实体使用同一种版本化 JSON 信封格式。
4. 客户端不做同步负载加密。服务端直接接收和保存 JSON；传输必须使用 HTTPS。
5. 同步请求内部仍可分批，但一次自动同步任务必须持续推送和拉取，直到所有页面处理完，不能让用户反复点击“再同步 50 个”。
6. 服务端必须按已认证账号强制隔离数据，绝不能信任客户端提交的 userId/accountId 来决定归属。
7. API Key 属于高敏感数据：服务端必须在写入事件/当前状态前拒绝或剔除密钥字段，并清理历史数据库、日志副本和备份；严禁在 pull/bootstrap 中返回。

## 二、先做代码与部署审计

在修改前先定位并报告：

- 认证中间件、access token 校验、refresh token、设备注册和注销逻辑；
- `/sync/push`、`/sync/pull`、`/sync/bootstrap` 的路由、控制器、service、repository；
- 同步事件表、设备表、账号表的 schema、唯一索引、外键和行级隔离方式；
- 反向代理是否强制 HTTPS，是否会把请求体或 Authorization 写进日志；
- 当前线上协议版本、兼容分支和旧 v2 事件数量；
- 数据库、备份、日志和监控系统分别由谁可访问。

发现真实 API 路径或字段与本文不同时，可以加兼容适配层，但对 Flutter 客户端暴露的 v3 契约必须与本文完全一致。

## 三、统一身份边界

每个同步接口必须按以下顺序处理：

1. 从 `Authorization: Bearer <accessToken>` 验证会话。
2. 从服务端会话得到 `authenticatedUserId` 和当前 `deviceId`。
3. 确认设备存在、属于该账号、未吊销。
4. 所有查询和写入都带 `user_id = authenticatedUserId` 条件。
5. 忽略或拒绝请求体中的 userId/accountId；它们不得覆盖服务端身份。
6. 响应只包含当前账号的数据。

必须覆盖这些越权测试：

- A 账号 token 读取 B 账号游标；
- A 账号 token 推送与 B 账号同 itemId 的记录；
- A 账号 token 使用 B 账号 deviceId；
- 已吊销设备继续 push/pull/bootstrap；
- 无 token、过期 token、伪造 token 调用同步接口。

所有情况都必须失败，且不能通过状态码、数量或时序泄露另一账号是否存在数据。

## 四、同步协议 v3

请求头：

```http
Authorization: Bearer <accessToken>
X-Memora-Sync-Protocol: 3
Content-Type: application/json
```

服务端只接受 `X-Memora-Sync-Protocol: 3` 和请求体 `protocolVersion: 3`。不一致时返回：

```json
{
  "code": "SYNC_PROTOCOL_UNSUPPORTED",
  "message": "This server requires Memora sync protocol 3."
}
```

HTTP 状态码用 426 或项目既有的明确 4xx，不能静默按旧格式解释。

### 4.1 标准事件

upsert 事件：

```json
{
  "clientEventId": "01J...",
  "collection": "articles",
  "itemId": "article-uuid",
  "op": "upsert",
  "revision": 1730000000000,
  "protocolVersion": 3,
  "schemaVersion": 3,
  "entitySchemaVersion": 2,
  "payloadFormat": "memora.sync.json",
  "payload": {
    "format": "memora.sync.entity",
    "schemaVersion": 1,
    "accountId": "account-id",
    "collection": "articles",
    "itemId": "article-uuid",
    "data": {
      "schemaVersion": 2,
      "id": "article-uuid"
    }
  },
  "clientUpdatedAt": "2026-08-04T12:00:00.000Z"
}
```

delete 事件使用相同元数据，但：

```json
{
  "op": "delete",
  "payloadFormat": "memora.sync.json",
  "payload": null
}
```

服务端必须验证：

- `clientEventId`、`collection`、`itemId` 非空且长度受限；
- `op` 只能是 `upsert` 或 `delete`；
- `protocolVersion == 3`；
- `payloadFormat == "memora.sync.json"`；
- upsert 的 payload 是 JSON object，delete 的 payload 为 null；
- 信封 `format == "memora.sync.entity"`、`schemaVersion == 1`；
- payload 中的 accountId、collection、itemId 与已认证账号及外层字段完全一致；
- revision 是有效整数，时间字符串可解析且有长度上限；
- 单请求事件数、请求体大小、payload 深度和字符串长度都有硬限制。

payload 的 `data` 是实体数据。服务端可以做字段级 schema 校验，但不得丢弃未知字段，以便客户端逐步升级。

### 4.2 collection 白名单

v3 首批只允许：

- `articles`
- `folders`
- `filter_groups`
- `app_settings`

未知 collection 返回结构化 4xx，不得写入任意表名或动态 SQL。

### 4.3 app_settings 标准

`app_settings` 固定使用 `itemId = "settings"`。payload.data 只允许保存非敏感配置，例如：

```json
{
  "schemaVersion": 2,
  "aiBaseUrl": "https://api.example.com/v1",
  "aiModel": "model-name",
  "embeddingBaseUrl": "https://embedding.example.com/v1",
  "embeddingModel": "embedding-model"
}
```

还要保留客户端传入的其他非敏感 AppSettings 字段。以下顶层字段无论来自新旧客户端都必须在持久化前剔除，并返回受控校验结果或安全接受净化后的 payload：`aiApiKey`、`chatAiApiKey`、`imageAiApiKey`、`embeddingApiKey`、`tavilyApiKey`。不得把它们复制到事件表、当前状态、冲突表、审计数据或响应。

## 五、接口契约

### 5.1 POST `/sync/push`

请求：

```json
{
  "protocolVersion": 3,
  "deviceId": "current-device-id",
  "baseCursor": 120,
  "events": []
}
```

要求：

- 单批最多 50 条；超出返回 413/422，不能静默截断。
- 在一个数据库事务内校验并写入整批，或者逐条返回清晰结果；禁止半失败但把全批标成成功。
- `(user_id, client_event_id)` 建唯一索引，实现幂等。
- 同一 clientEventId、同一规范化内容重复提交，返回 duplicate，不能生成新 serverSeq。
- 同一 clientEventId 但内容不同，返回 409 `IDEMPOTENCY_CONFLICT`。
- 服务端生成单调递增的 `serverSeq`，客户端 revision 不能代替服务端游标。
- `baseCursor` 仅用于冲突/诊断，push 成功响应不能要求客户端据此跳过 pull。

建议响应：

```json
{
  "accepted": 45,
  "duplicates": 5,
  "latestCursor": 900
}
```

### 5.2 GET `/sync/pull?since=<cursor>&limit=<limit>`

要求：

- `limit` 最大 500；
- 查询条件必须包含当前 user_id；
- 按 serverSeq 升序稳定分页；
- 返回 `serverSeq > since` 的事件；
- 事件字段与 push 标准事件一致，并带来源 `deviceId`；
- `nextCursor` 是本页最后一条 serverSeq；空页保持 since 或返回账号最新游标；
- 如果返回非空 events，nextCursor 必须严格大于 since。

响应：

```json
{
  "protocolVersion": 3,
  "events": [],
  "nextCursor": 900
}
```

Flutter 客户端会持续拉取，直到某页数量小于 limit。因此不要用固定 50 条总上限，也不要在还有后续数据时返回短页。

### 5.3 GET `/sync/bootstrap`

用于新设备首次登录，返回当前账号每个实体的最新有效状态和游标：

```json
{
  "protocolVersion": 3,
  "events": [],
  "latestCursor": 900
}
```

要求：

- 同一 collection + itemId 只返回最新状态；
- 已删除项目可返回 tombstone，确保旧本地记录被删除；
- 大账号不能无限响应：可以稳定分页，但必须与客户端契约一起实现完整遍历；
- app_settings 返回完整的非敏感 data，且不得包含任何 provider API Key；
- bootstrap 完成后，增量 pull 不能漏掉 bootstrap 期间发生的写入。

## 六、数据库建议

推荐事件表（按实际数据库语法调整）：

```text
sync_events
  id                    UUID/ULID primary key
  user_id               account FK, not null
  device_id             device FK, not null
  client_event_id       text, not null
  server_seq            bigint, not null
  collection            text, not null
  item_id               text, not null
  operation             text, not null
  revision              bigint, not null
  protocol_version      integer, not null default 3
  entity_schema_version integer, not null
  payload_format        text, not null
  payload               json/jsonb null
  client_updated_at     timestamptz null
  created_at            timestamptz not null
```

必需约束/索引：

- unique `(user_id, client_event_id)`；
- unique `(user_id, server_seq)`，或保证账号内严格单调；
- index `(user_id, server_seq)`；
- index `(user_id, collection, item_id, server_seq desc)`；
- check operation、protocol_version、payload_format；
- user_id/device_id 外键与设备归属校验。

如果使用物化当前状态表，还要以 `(user_id, collection, item_id)` 为唯一键，并在同一事务中写事件与更新当前状态。

## 七、敏感数据保护

即使新客户端不再上传 API Key，服务端仍必须按高敏感数据边界完成：

- 全站 HTTPS，HTTP 重定向或拒绝，生产环境启用 HSTS；
- 数据库连接 TLS、最小权限账号、生产数据库访问审批；
- 对同步入口做服务端强制字段净化，不能只信任客户端版本；
- 一次性扫描并净化物化状态、事件历史、冲突记录与可检索审计副本；
- 对含历史 Key 的备份制定轮换/到期删除方案，并记录不含明文的迁移计数；
- Web/API/反向代理禁止记录 `/sync/push` 请求体和 `/sync/*` 响应体；
- Authorization、refresh token、OTP、provider API Key 一律脱敏；
- 异常上报只记录 event 数、collection、状态码、耗时，不记录 payload；
- 管理后台默认不展示 payload；排障接口也必须经过同一字段净化；
- 数据导出与账号删除覆盖同步事件、当前状态、设备、token 和备份生命周期。

迁移完成前不得声称服务端“没有”这些 Key。若历史日志或备份可能包含真实凭据，应按安全事件处理并通知用户轮换，而不是仅覆盖最新状态。

## 八、v2 到 v3 迁移

旧 v2 事件的负载由客户端加密，服务器无法转换成 v3 JSON。迁移必须诚实处理：

1. 新部署先支持 v3 表结构和接口，但 v3 pull/bootstrap 不得把旧加密字段伪装成 JSON payload。
2. v3 Flutter 客户端会因为本地协议标记升级而自动重新排队本地完整快照。
3. 老设备登录并完成一次 v3 同步后，服务器获得该账号的 v3 当前状态。
4. 若某账号只剩服务器旧数据、没有任何仍持有本地副本的设备，则服务器无法恢复其内容；必须明确告知用户，不能宣称迁移成功。
5. 迁移期间可保留旧表只读用于回滚；确认账号 v3 快照完整后，再按审批过的保留策略清理旧数据。
6. 用指标统计“已完成 v3 快照的账号数”，但指标标签不得含邮箱、用户 ID、API Key 或正文。
7. 增加一次性凭据净化迁移：先只读统计五个禁用字段在当前状态、事件、冲突/审计表中的数量，再事务化清理；验证 pull/bootstrap、数据库查询和新备份均不再返回这些字段。
8. 服务端必须对不具备无密钥同步契约的旧客户端实施版本门禁，防止迁移后再次上传。

## 九、自动同步与一致性

服务端要配合客户端的自动 drain 行为：

- push 连续收到 50/50/剩余批次时保持幂等和顺序正确；
- pull 连续收到 500/500/剩余页时游标连续、不重不漏；
- 网络中断后客户端重试同一 clientEventId，服务端返回 duplicate；
- 同一设备同时触发前台恢复、网络恢复和手动同步时，即使请求偶发重叠也不能重复写数据；
- 两台设备同时修改同一实体时，按现有 revision/服务端顺序规则确定结果并记录可诊断元数据；
- delete tombstone 不能被更旧 upsert 复活。

## 十、必须实现的测试

至少添加并运行：

### 认证与隔离

- 未登录/过期 token/吊销设备全部失败；
- 两账号相同 itemId 互不影响；
- 任意跨账号读取和写入都失败；
- 请求体伪造 accountId 不改变归属。

### 协议

- v3 article/folder/filter_group/app_settings upsert 与 delete；
- payload 信封身份不一致时拒绝；
- 缺少 payload、错误 payloadFormat、未知 collection、超限 body 时拒绝；
- 五个禁用 Key 字段在 push 时被拒绝或净化，数据库、pull/bootstrap、冲突与日志均不存在其值；
- 旧客户端版本门禁生效，无法在清理后重新写入密钥。

### 幂等与游标

- 同一 clientEventId 重放不产生新事件；
- 同 ID 不同内容返回 `IDEMPOTENCY_CONFLICT`；
- 125 条 push 分为 50/50/25，最终全部存在；
- 超过 1000 条 pull 稳定分页，serverSeq 无重复、无缺口；
- push 响应不导致客户端跳过未拉取事件；
- bootstrap 与并发写入组合不漏数据。

### 双设备验收

使用账号 A 的设备 1 和设备 2 做真实 API 验收：

1. 设备 1 保存文章、文件夹、筛选组和 AI/Embedding 非敏感配置，并为两台设备分别设置不同的测试 Key。
2. 等待自动同步完成，不重复手点按钮。
3. 设备 2 首次登录并 bootstrap。
4. 核对每条记忆的 id、URL、标题、来源、标签、备注、文件夹、记忆内容、处理状态、时间戳及 schemaVersion。
5. 核对 AI/Embedding Base URL、模型名一致；两台设备各自 Key 保持本地值，互不覆盖、互不上传。
6. 设备 2 修改内容，设备 1 自动拉回。
7. 检查数据库只属于账号 A；账号 B 完全不可见。
8. 检查数据库当前状态/历史事件/备份以及后端、代理和 APM 日志，确认找不到测试 API Key。

## 十一、交付报告格式

最终报告必须包含：

1. 修改的文件、数据库迁移和接口清单；
2. 最终 API 请求/响应示例；
3. 数据库约束、索引和账号隔离证据；
4. 自动分批同步、幂等、游标和双设备测试结果；
5. API Key 入口净化、历史迁移、旧版本门禁及数据库/日志/备份检查结果；
6. v2 账号迁移统计和不可恢复场景说明；
7. 尚未完成的风险与上线前阻塞项。

不要在报告、截图、测试输出或日志里粘贴真实 OTP、access token、refresh token 或 AI/Embedding API Key。测试必须使用可随时吊销的专用假 Key。
