# Memora 发布全自动化：GitHub Secrets 配置

## 生成 Actions 部署密钥对

在**本地开发机**生成一对专用 ed25519 密钥（不要覆盖现有 SSH 密钥）：

```bash
ssh-keygen -t ed25519 -f ~/.ssh/memora_actions -C "github-actions-deploy"
```

- 私钥：`~/.ssh/memora_actions` → 存入 GitHub Secrets（`APK_DEPLOY_SSH_KEY`）
- 公钥：`~/.ssh/memora_actions.pub` → 追加到服务器 `memora-deploy` 用户的 `~/.ssh/authorized_keys`

> **安全**：私钥只进 GitHub Secrets，永不提交仓库、永不写进服务器。公钥才进服务器。

## 服务器侧配置（memora-deploy 用户）

```bash
sudo -u memora-deploy mkdir -p ~memora-deploy/.ssh
sudo -u memora-deploy chmod 700 ~memora-deploy/.ssh
echo 'ssh-ed25519 AAAA...your-public-key...' | sudo -u memora-deploy tee -a ~memora-deploy/.ssh/authorized_keys >/dev/null
sudo -u memora-deploy chmod 600 ~memora-deploy/.ssh/authorized_keys
```

## GitHub Secrets 配置

两个仓库（`Article-Hub` 与 `Memora-Landing-Page`）都进入：

`Settings → Environments → production-download`（没有则新建）→ Add secret

| Secret | 值 |
|---|---|
| `APK_DEPLOY_HOST` | `47.103.95.241` |
| `APK_DEPLOY_PORT` | `22` |
| `APK_DEPLOY_USER` | `memora-deploy` |
| `APK_DEPLOY_SSH_KEY` | `~/.ssh/memora_actions` **私钥全文**（含 `-----BEGIN OPENSSH PRIVATE KEY-----`） |
| `APK_DEPLOY_KNOWN_HOSTS` | 服务器完整 known_hosts 行（见下方，需人工核验指纹） |

> `KEYSTORE_B64` / `KEY_PROPERTIES_B64` 已配置则保持不动。

## 验证密钥

```bash
# 本地：用 actions 私钥测试连接（已知主机后）
ssh -i ~/.ssh/memora_actions -p <端口> memora-deploy@47.103.95.241 'echo ok'
```

## 服务器端脚本安装

服务器 agent 需把主仓库 `deploy/memora-deploy-landing` 装为命令：

```bash
sudo install -m 0755 deploy/memora-deploy-landing /usr/local/bin/memora-deploy-landing
```

脚本默认路径已对齐服务器实际（`/opt/memora-landing-page`、`/opt/memora-landing`），无需额外环境变量。

## 触发验证

1. **APK 线**：`/build` 或手动 `git tag v2.1.6 && git push origin v2.1.6`，确认 Actions run 全绿，`latest.json` / `latest.apk` 公网可下载。
2. **Landing 线**：`cd landing-page && git push origin master`，确认 deploy.yml 触发、服务器 dist 更新。
