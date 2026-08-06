# APK 国内下载服务：服务器 Agent 执行 Prompt

下面内容可以原样交给运行在 `api.memora.wang` 服务器上的 Agent。

---

你正在维护 Memora（记忆海）的生产服务器。请直接完成 APK 国内下载服务部署，不要只返回方案。现有业务 API 已在线，`https://api.memora.wang/health` 必须始终保持正常；不得修改数据库、Auth/Sync API、业务环境变量、现有证书或其他无关服务。

## 已知仓库与版本

- App 仓库：`git@github.com:JasonZhang453625/Article-Hub.git`
- App 分支：`main`
- Landing 仓库：`git@github.com:JasonZhang453625/Memora-Landing-Page.git`
- Landing 分支：`master`
- 当前正式目标版本：`2.1.4`
- 当前 Tag：`v2.1.4`
- Landing 至少应包含提交：`1de3e2b`
- App 仓库已经包含：
  - `.github/workflows/release.yml`
  - `deploy/memora-publish-apk`
  - `docs/APK_DISTRIBUTION_SERVER.md`

## 目标公网契约

部署完成后必须支持：

```text
GET https://api.memora.wang/downloads/android/latest.json
GET https://api.memora.wang/downloads/android/latest.apk
GET https://api.memora.wang/downloads/android/releases/v2.1.4/Memora-v2.1.4.apk
```

`latest.json` 必须允许 Landing 跨域读取，APK 必须支持 Range 请求。版本化 APK 不覆盖；`latest.apk` 和 `latest.json` 只在文件 SHA-256、大小与清单全部验证后原子切换。

## 执行任务

### 1. 拉取并核对仓库

找到服务器上真实的 App 和 Landing 工作目录。保留所有服务器专用配置，不覆盖 `.env`、证书、数据库或未提交修改。

```bash
git -C <APP_DIR> fetch origin --prune
git -C <APP_DIR> pull --ff-only origin main
git -C <APP_DIR> rev-parse --short HEAD

git -C <LANDING_DIR> fetch origin --prune
git -C <LANDING_DIR> pull --ff-only origin master
git -C <LANDING_DIR> rev-parse --short HEAD
```

如果工作区有冲突或会覆盖服务器本地修改，立即停止该仓库的 pull，列出具体文件；继续完成其他不受影响的服务器任务。

### 2. 部署 Landing

```bash
cd <LANDING_DIR>
npm ci
npm run build
```

把生成的 `dist/` 按服务器现有方式原子部署到 `https://memora.wang` 的站点目录。不要猜测目录；先检查当前 Caddy 配置和站点 root。部署后确认网页源码包含：

```text
国内服务器下载
GitHub Release 下载
api.memora.wang/downloads/android/latest.json
```

### 3. 创建受限 APK 发布用户和目录

```bash
id -u memora-deploy >/dev/null 2>&1 || \
  sudo useradd --create-home --shell /bin/bash memora-deploy

sudo install -d -o memora-deploy -g memora-deploy -m 0755 \
  /srv/memora-downloads/android

sudo install -m 0755 \
  <APP_DIR>/deploy/memora-publish-apk \
  /usr/local/bin/memora-publish-apk
```

确认服务器有 `bash`、`jq`、`sha256sum`、`stat`、`install`。发布用户只能写 APK 目录和自己的 `.memora-apk-incoming`，不得授予数据库、业务环境变量或应用目录写权限。

### 4. 配置 SSH 发布入口

为 `memora-deploy` 创建 `~/.ssh` 和 `authorized_keys`，权限必须为：

```text
~/.ssh                 700
authorized_keys        600
owner                  memora-deploy:memora-deploy
```

如果我没有提供 GitHub Actions 部署公钥，不要自行生成或回传私钥。完成目录和权限准备，然后明确报告“等待部署公钥”。

输出供 GitHub Environment 使用的以下信息：

```text
APK_DEPLOY_HOST
APK_DEPLOY_PORT
APK_DEPLOY_USER=memora-deploy
APK_DEPLOY_KNOWN_HOSTS（完整 known_hosts 行，不只是指纹）
SSH Host Key SHA-256 指纹
```

Host Key 必须来自本机真实 `/etc/ssh/ssh_host_*_key.pub` 并报告指纹，不得关闭 StrictHostKeyChecking。

### 5. 配置 Caddy 静态下载路由

先备份当前 Caddy 配置。把下列路由加入现有 `api.memora.wang` 站点，并确保它位于业务 API 反向代理之前：

```caddyfile
handle_path /downloads/android/* {
    root * /srv/memora-downloads/android
    header Access-Control-Allow-Origin "*"
    header X-Content-Type-Options "nosniff"
    file_server
}
```

保留现有 API 的 `handle` / `reverse_proxy`。随后执行：

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
sudo systemctl is-active caddy
curl -fsS https://api.memora.wang/health
```

如果服务器并非使用 `/etc/caddy/Caddyfile`，先通过 systemd unit 和进程参数定位真实配置路径，再修改真实配置。

### 6. 在正式 APK 上传前验证静态路由

以 `memora-deploy` 身份临时创建一个小型探针文件，通过公网 URL 验证路由、CORS 和文件读取权限；验证后只删除该探针文件，不删除任何其他文件。

```bash
sudo -u memora-deploy sh -c \
  'printf "{\"ready\":true}\n" > /srv/memora-downloads/android/ready.json'

curl -i https://api.memora.wang/downloads/android/ready.json

sudo -u memora-deploy rm -f /srv/memora-downloads/android/ready.json
```

期望状态码 `200`，响应中必须包含 `Access-Control-Allow-Origin`。

不要手工伪造 `latest.json`，也不要把 GitHub v2.1.3 冒充为 v2.1.4。服务器准备完成后，由用户配置 GitHub Secrets 并重新运行 `v2.1.4` 的 Release APK 工作流，流水线会上传、校验并原子激活真实 APK。

## 最终报告格式

完成后返回以下表格，并附关键命令的实际输出摘要：

| 检查项 | 结果 | 证据 |
|---|---|---|
| App 仓库 main 已同步 | 通过/失败 | HEAD |
| Landing master 已同步 | 通过/失败 | HEAD，至少 `1de3e2b` |
| Landing 构建和部署 | 通过/失败 | build 结果，网页文本 |
| `memora-deploy` 用户 | 通过/失败 | uid、目录权限 |
| 发布脚本安装 | 通过/失败 | 路径、权限、依赖 |
| SSH 发布入口 | 通过/等待公钥/失败 | host、port、known_hosts、指纹 |
| Caddy 配置校验 | 通过/失败 | validate、active |
| 原业务 API | 通过/失败 | `/health` 状态 |
| 静态路由探针 | 通过/失败 | HTTP 状态、CORS |
| 正式 v2.1.4 APK | 等待 Actions/通过/失败 | 三个下载 URL |

任何密钥、私钥、token、OTP、数据库密码不得出现在输出或日志中。

---
