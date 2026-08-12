# 托孤(bequest)服务器部署文档

> 仓库: https://github.com/muxinxy/bequest | 镜像: `ghcr.io/muxinxy/bequest`
> 服务器: Go 1.26, 单二进制, 默认监听 8080, SQLite 数据库 `data/bequest.db`(运行时自动创建)。

---

## 1. 构建二进制

版本号通过 `-ldflags "-X main.version=<版本>"` 在编译期注入, `GET /api/v1/version` 会返回该版本。

### Windows(PowerShell)

```powershell
# 在仓库根目录执行
.\scripts\build.ps1                 # 版本为 dev
$env:VERSION = "1.0.0"
.\scripts\build.ps1                 # 版本为 1.0.0
```

- 默认构建 `windows/amd64` 与 `linux/amd64` 两个平台;
- 默认 `GOPROXY=https://goproxy.cn,direct`(国内网络), 可用 `$env:GOPROXY` 覆盖;
- 产物: `dist\bequest-server-<版本>-windows-amd64.exe`、`dist\bequest-server-<版本>-linux-amd64`(版本默认 `dev`, 可用 `$env:VERSION` 指定)。

### Linux / macOS

```bash
# 在仓库根目录执行
./scripts/build.sh                 # 版本为 dev
VERSION=1.0.0 ./scripts/build.sh   # 版本为 1.0.0
GOPROXY=https://goproxy.cn,direct ./scripts/build.sh   # 国内网络可覆盖代理
```

交叉编译 5 个平台: `linux/amd64`、`linux/arm64`、`windows/amd64`(带 `.exe`)、`darwin/amd64`、`darwin/arm64`, 产物在 `dist/`(文件名含版本, 如 `bequest-server-1.0.0-linux-amd64`)。

---

## 2. 通过 Docker Compose 运行

```bash
cd server
# 创建 .env(必填 JWT_SECRET / ENCRYPTION_KEY)
#   JWT_SECRET=请替换为随机长字符串
#   ENCRYPTION_KEY=请替换为随机长字符串
docker compose up -d --build
```

- 服务监听宿主机 `8080` 端口;
- 数据库落在宿主机 `server/data/`(`./data:/data` 卷挂载);
- 容器内 `WORKDIR=/data`, 数据库写入卷中的 `data/bequest.db`; SQL 迁移文件已嵌入服务器二进制, 无需在容器内挂载 `migrations/` 目录;
- `config.json` 同理: 服务器从 CWD 读取 `config.json`, 将宿主机配置文件挂载到容器即可(取消 `docker-compose.yml` 中对应注释):

```yaml
volumes:
  - ./data:/data
  - ./config.json:/data/config.json   # 取消注释即生效
```

---

## 3. config.json(多 SMTP 示例)

> 说明: 当前代码仍以 `SMTP_*` 环境变量提供单 SMTP 支持; 多 SMTP 通过 `config.json` 配置。

```json
{
  "smtp_servers": [
    {
      "host": "smtp.qq.com",
      "port": 465,
      "user": "noreply@qq.com",
      "password": "SMTP 授权码",
      "from_addr": "noreply@qq.com"
    },
    {
      "host": "smtp.163.com",
      "port": 465,
      "user": "noreply@163.com",
      "password": "SMTP 授权码",
      "from_addr": "noreply@163.com"
    }
  ]
}
```

> 端口: 465 为隐式 TLS, 587 为 STARTTLS, 均支持。QQ/163 等需在邮箱设置中获取「授权码」而非登录密码。

将以上内容保存为 `server/config.json`(或按上文挂载为 `/data/config.json`)即可, 服务器启动时会自动读取 CWD 下的 `config.json`。

---

## 4. 环境变量

| 变量 | 必填 | 说明 |
|------|------|------|
| `JWT_SECRET` | 是 | JWT 签名密钥, 生产环境必须为高强度随机值 |
| `ENCRYPTION_KEY` | 是 | 加密密钥, 生产环境必须为高强度随机值 |
| `SMTP_HOST` | 否 | SMTP 服务器地址(如 `smtp.qq.com`) |
| `SMTP_PORT` | 否 | SMTP 端口(如 465/587) |
| `SMTP_USER` | 否 | SMTP 用户名 |
| `SMTP_PASS` | 否 | SMTP 密码/授权码 |
| `SMTP_FROM` | 否 | 发件人地址 |
| `DATA_DIR` | 否 | 数据目录(镜像内默认为 `/data`) |

---

## 5. 发布流程(Release 工作流)

`.github/workflows/release.yml` 在**推送 `v*` 标签**时自动触发, 例如:

```bash
git tag v1.0.0
git push origin v1.0.0
```

触发后依次执行三个 job:

1. **build** — 在 `ubuntu-latest` 上交叉编译 5 平台二进制(版本号取自标签, 去掉 `v` 前缀, 通过 `-X main.version=1.0.0` 注入), 产物上传为 workflow artifact;
2. **docker** — `docker/build-push-action` 构建 `linux/amd64` + `linux/arm64` 多架构镜像, 推送到 `ghcr.io/muxinxy/bequest`, 标签为 `1.0.0`(semver)与 `latest`;
3. **android** — 构建 3 个 ABI 的 release 签名 APK(文件名含版本, 如 `bequest-v1.0.0-arm64-v8a.apk`);
4. **release** — `softprops/action-gh-release` 将二进制与 APK 产物附加到 GitHub Release(draft: false, 自动生成发布说明)。

也可以在工作流页面手动触发(workflow_dispatch), 此时版本为 `dev`, 仅构建并推送镜像, 不创建 Release。

---

## 6. Android 发布签名(Secrets)

APK 使用固定 release keystore 签名(保证版本升级无需卸载重装)。CI 构建时从 GitHub Secrets 还原签名文件, 仓库不保存 keystore/密码。

需在仓库 **Settings → Secrets and variables → Actions** 配置 4 个 Secret: `ANDROID_KEYSTORE_BASE64`(keystore 文件 base64)、`KEYSTORE_PASSWORD`、`KEY_ALIAS`、`KEY_PASSWORD`。本地生成 keystore 的方法见根目录 [`README.md`](../README.md#发布签名secrets)。
