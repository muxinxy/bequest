# 托孤 (bequest)

数字资产保险箱 + 数字遗嘱。管理实体/虚拟资产，号主超时未登录时升级提醒，最终交接给继承人。

## 结构

- `app/` — Flutter Android 客户端（后续扩展 iOS/Web/鸿蒙）
- `server/` — Go 后端（HTTP API + 提醒调度 + 继承交接）
- `docs/` — 架构设计（ADR）与开发进度（交接用）

## 功能

- 资产管理：实体/虚拟资产、预设+自定义分类、敏感字段端到端加密（AES-256-GCM，主密码派生）
- 继承（dead man's switch）：不登录升级提醒（免费 30/60/90/120 天，会员 7/14/30/60 天）→ 触发交接 → 继承人凭 event_key + 访问码双因子领取密钥；三重取消窗口（触发前登录 / 领取前 / 领取后登录反转）
- 提醒：每资产到期提醒（30/7/1 天 + 已到期）、默认/自定义模板、站内信 + 邮件（SMTP）
- 导入导出：JSON（全部/分类/单条，主密码验证）；自托管同步：WebDAV/S3 加密备份（**无需登录**，配置仅存本机）
- 安全：APP 锁（PIN + 生物识别）、免费/会员权益（免费资产上限 50）

## 运行

```bash
# 服务端（Go 1.26+）
cd server && go run .            # 监听 :8080, 首次启动自动建库 server/data/bequest.db

# 客户端（Flutter）
cd app && flutter run            # 模拟器访问后端用 http://10.0.2.2:8080
```

## 部署

### Docker Compose（推荐）

```bash
cd server
# 先创建 .env（必填项）:
#   JWT_SECRET=任意长随机串
#   ENCRYPTION_KEY=32字节密钥（SMTP 密码加密用；不设则用 dev 密钥, 仅限开发）
docker compose up -d --build
```

- 服务监听 `:8080`，数据落在 `server/data/`（容器内 `/data` 卷）
- 多 SMTP / 短信 / 电话负载均衡：挂载 `config.json` 到 `/data/config.json`
  （`{"smtp_servers":[{"host","port","user","password","from_addr"}],"sms_providers":[],"phone_providers":[]}`；不配则回退环境变量 `SMTP_HOST/PORT/USER/PASS/FROM`）

### 二进制

```bash
# Windows（PowerShell, 默认走 goproxy.cn 镜像）
.\scripts\build.ps1            # → dist\bequest-server-dev-windows-amd64.exe 等

# Linux/macOS（交叉编译 5 平台）
VERSION=1.0.0 ./scripts/build.sh   # → dist/bequest-server-1.0.0-<os>-<arch>
```

### 环境变量

| 变量 | 说明 |
|---|---|
| `JWT_SECRET` | JWT 签名密钥（生产必填） |
| `ENCRYPTION_KEY` | SMTP 密码 AES 加密密钥（生产必填，dev 有默认值） |
| `SMTP_HOST/PORT/USER/PASS/FROM` | 系统邮件（单服务器，或多 SMTP 用 `config.json`） |

详细部署文档见 [`server/README-deploy.md`](server/README-deploy.md)。

## 发布（GitHub Actions Release）

打 tag 自动构建二进制 + Docker 镜像并发布到 GitHub Release：

```bash
git tag v0.1.0
git push origin v0.1.0
```

流水线（`.github/workflows/release.yml`）产出：

- **二进制**：GitHub Release 页 assets——`bequest-server-<版本>-{linux,windows,darwin}-{amd64,arm64}`
- **Android APK**：GitHub Release 页 assets——`bequest-v<版本>-{arm64-v8a,armeabi-v7a,x86_64}.apk`（release 签名，可直接覆盖升级安装）
- **Docker 镜像**：`ghcr.io/muxinxy/bequest:<版本>` 与 `:latest`（linux/amd64 + arm64，多架构）
- **版本注入**：`GET /api/v1/version` 返回 tag 版本（`-X main.version=`）

## 发布签名（Secrets）

Android APK 使用固定 release keystore 签名，保证版本升级时无需卸载重装（否则报"签名不一致"）。CI 在构建时从 GitHub Secrets 还原签名文件，**不会**提交 keystore/密码到仓库。

需要在仓库 **Settings → Secrets and variables → Actions** 配置 4 个 Secret：

| Secret | 说明 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | keystore 文件的 base64（见下方生成步骤） |
| `KEYSTORE_PASSWORD` | keystore 口令 |
| `KEY_ALIAS` | 别名（如 `bequest`） |
| `KEY_PASSWORD` | 密钥口令 |

本地生成 keystore（JDK 自带 keytool）：

```bash
keytool -genkeypair -v -keystore bequest-release.jks -storetype JKS -alias bequest \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -storepass '<KEYSTORE_PASSWORD>' -keypass '<KEY_PASSWORD>' \
  -dname 'CN=bequest, OU=bequest, O=bequest, L=Beijing, ST=Beijing, C=CN'

# 导出 base64 填入 ANDROID_KEYSTORE_BASE64(注意保留完整一行):
#   base64 -w 0 bequest-release.jks    # Linux/macOS
#   [Convert]::ToBase64String([IO.File]::ReadAllBytes('bequest-release.jks'))  # Windows
```

> 务必妥善备份 keystore 与密码：一旦丢失或更换，用户无法覆盖升级，只能卸载重装。keystore 生成后请删除本机临时副本。

## 设计要点

- 端到端加密：主密码派生 AES-256 密钥，敏感数据加密后上传，服务端不见明文
- 继承触发后向继承人发放解密密钥（方案 A）
- 三重取消窗口：触发前 / 领取前 / 领取后登录反转
- 免费档继承提醒保证送达（仅邮件），会员更快且多渠道
- 隐私优先：自托管同步凭据仅存本机、数据只存用户自己的存储；提醒邮件可走用户自配 SMTP

架构决策与开发进度见 [`docs/`](docs/progress.md)。
