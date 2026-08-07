# APK 国内下载源部署契约

App 的业务 API 已部署在 `https://api.memora.wang`，但 APK 下载源是独立的静态文件能力。发布流水线约定使用以下公网地址：

- `GET /downloads/android/latest.json`
- `GET /downloads/android/latest.apk`
- `GET /downloads/android/releases/v{version}/Memora-v{version}.apk`

## 服务器目录

生产机默认目录为 `/opt/memora-apk/android`：

```text
/opt/memora-apk/android/
├── app-release.apk
├── latest.apk
├── latest.json
└── releases/
    └── v2.1.6/
        └── Memora-v2.1.6.apk
```

`latest.apk` 与兼容旧链接的 `app-release.apk` 都指向当前正式版本；版本目录中的 APK 不覆盖、不原地修改。

## 发布用户

创建非 root 的受限用户，例如 `memora-deploy`，并完成以下配置：

1. 将脚本安装为服务器命令：

   ```bash
   sudo install -m 0755 -o memora-deploy -g memora-deploy \
     deploy/memora-publish-apk /opt/memora-apk/memora-publish-apk
   ```
   正常发布时，GitHub Actions 会在 staging 前自动同步这份脚本，避免服务器脚本与仓库漂移。
2. 将 `/opt/memora-apk` 所有权授予发布用户。
3. 确保服务器安装 `bash`、`jq`、`sha256sum` 和 `stat`。
4. 只给该用户写入 APK 目录所需的权限，不授予应用数据库、环境变量或业务日志权限。
5. 将发布 SSH 公钥加入该用户的 `authorized_keys`。

发布命令分为三个阶段：

```bash
/opt/memora-apk/memora-publish-apk prepare 2.1.6
/opt/memora-apk/memora-publish-apk verify 2.1.6 SHA256 SIZE
/opt/memora-apk/memora-publish-apk activate 2.1.6 SHA256 SIZE
```

GitHub Release 发布前只执行 `prepare` 和 `verify`。GitHub Release 成功公开后才执行 `activate`，因此失败的上传不会替换当前下载版本。

## Caddy 静态路由

在现有 `api.memora.wang` 站点中，把静态下载路由放在 API 反向代理之前：

```caddyfile
handle_path /downloads/* {
    # 宿主机 /opt/memora-apk 挂载到 Caddy 容器 /srv/downloads
    root * /srv/downloads
    header Access-Control-Allow-Origin "*"
    header X-Content-Type-Options "nosniff"
    file_server
}

handle {
    reverse_proxy 127.0.0.1:YOUR_API_PORT
}
```

服务器需要让 `.apk` 返回 `application/vnd.android.package-archive`，允许 Range 请求，并确保 `latest.json` 不被长期缓存。版本化 APK 可以使用长期不可变缓存。

## GitHub Environment

在 App 仓库创建 `production-download` Environment，并配置：

- `KEYSTORE_B64`
- `KEY_PROPERTIES_B64`
- `APK_DEPLOY_HOST`
- `APK_DEPLOY_PORT`
- `APK_DEPLOY_USER`
- `APK_DEPLOY_SSH_KEY`
- `APK_DEPLOY_KNOWN_HOSTS`

`APK_DEPLOY_KNOWN_HOSTS` 必须保存已经人工核验的服务器 Host Key；发布流水线不会关闭 SSH Host Key 校验。

## 验收

```bash
curl -fsS https://api.memora.wang/downloads/android/latest.json | jq .
curl -I https://api.memora.wang/downloads/android/latest.apk
curl -I https://api.memora.wang/downloads/android/app-release.apk
curl -I https://api.memora.wang/downloads/android/releases/v2.1.6/Memora-v2.1.6.apk
```

manifest 必须返回 `Access-Control-Allow-Origin: *`，三个 APK 地址必须支持 Range 请求。全部正常后，服务器端 APK 下载任务才算完成。仅 `/health` 返回 200 代表业务 API 在线，不代表下载源已部署。
