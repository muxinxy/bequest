# 托孤 (bequest)

数字资产保险箱 + 数字遗嘱。管理实体/虚拟资产，号主超时未登录时升级提醒，最终交接给继承人。

> English: [README.en.md](README.en.md)

## 结构

- `app/` — Flutter 客户端（Android + Web，同一套代码编译两个平台）
- `server/` — Go 后端（HTTP API + 提醒调度 + 继承交接）
- `docs/` — 架构设计（ADR）与开发进度（交接用）

## 功能

- Web 客户端：同一套 Flutter 代码编译 Web，由 Go 服务端同源托管（`go run .` 自动探测并服务 `app/build/web`），浏览器打开 `http://localhost:8080` 即用；argon2 换 hash-wasm WASM（自托管 `app/web/assets/hash-wasm.js`），解锁 ~0.3s；默认相对路径（同源免 CORS），服务端带 CORS 中间件支持独立部署/Flutter dev server
- 资产管理：实体/虚拟资产、预设+自定义分类、敏感字段端到端加密（AES-256-GCM，每资产独立密钥 AK，主密钥/继承密钥包装；老资产自动回退主密钥解密）；主页**分组视图**（按分类分组、可折叠），搜索支持**分组名和资产名**
- 继承（dead man's switch）：不登录升级提醒（免费 30/60/90/120 天，会员 7/14/30/60 天）→ 触发交接 → 继承人凭 event_key + 访问码双因子领取密钥；三重取消窗口（触发前登录 / 领取前 / 领取后登录反转）；**资产级 + 分组级继承**：资产/分组可绑定多个继承人并各自设置触发天数，触发按资产/分组产生事件，继承人领取只拿指定资产密钥；**全局继承开关**（设置页一键开关全部继承）
- 提醒：每资产到期提醒（30/7/1 天 + 已到期）、默认/自定义模板、站内信 + 邮件（SMTP）
- 导入导出：JSON（全部/分类/单条，主密码验证）；加密导出 `.beq`（主密码加密）、导入可选覆盖现有；自托管同步：WebDAV/S3 加密备份（**无需登录**，配置仅存本机）
- 主密码：支持**修改**与**重置**（忘记时用账户密码验证；重置后旧凭据不可恢复）；**跨设备恢复**——新设备登录凭「主密码 + 盐」重新派生（注册时盐上传服务端，明文不敏感）
- 账号：设置页可**修改用户名/邮箱**与**修改登录密码**（改后所有设备强制重新登录）；登录支持用户名**或邮箱**；注册用户名/邮箱**实时查重**（防枚举）；**忘记密码**邮箱验证码重置（6 位、10 分钟有效、5 次错误作废、限流）；注册双密码输入 + 主密码提示语 + 主密码≠登录密码
- 安全：APP 锁（PIN + 生物识别，含 Web 端锁定）、手动锁定（主页 AppBar 一键锁定）、免费/会员权益（免费资产上限 50）、**注册/登录算术验证码**（防机器人）、**按 IP 频率限制**（登录/注册 5 次/分，其他 300 次/分）、**管理后台 2FA (TOTP)**
- 继承交接：继承人可访问 `http://服务器/claim` 凭 event_key + 访问码**网页领取**密钥；领取后 72h 内号主登录可反悔
- 本地模式：**多本地账户**（各自独立主密码与加密数据），进入需验证账户主密码，云端/本地密钥隔离互不覆盖
- 分组：自定义排序、删除保护（资产移入目标分组/合并）、未分类批量整理、30 天内到期预警

## 数据库

后端支持 **SQLite(默认)**、**MySQL 8 / MariaDB**、**PostgreSQL**。通过 `DB_DRIVER` 选择后端，连接参数用 `DB_DSN` 或 `DB_HOST/DB_PORT/DB_USER/DB_PASS/DB_NAME`。迁移脚本按方言分目录，启动时自动执行（已编译进二进制）。详见 [`server/README-deploy.md`](server/README-deploy.md)。

```bash
# 例:PostgreSQL
DB_DRIVER=postgres DB_USER=bequest DB_PASS=secret DB_NAME=bequest go run .
# 例:MySQL
DB_DRIVER=mysql DB_HOST=127.0.0.1 DB_PORT=3306 DB_USER=bequest DB_PASS=secret DB_NAME=bequest go run .
```

## 界面语言

客户端、Web 管理后台、继承人领取页与 API 错误消息均支持**中英文**：
- App:设置 → 语言 切换简体中文/English（或跟随系统）
- 管理后台 / 领取页:页面右上角 中文/English 切换（记忆选择）
- API 错误消息:按请求 `Accept-Language` 头返回中文或英文

## 运行

```bash
# 服务端（Go 1.26+）
cd server && go run .            # 监听 :8080, 首次启动自动建库 server/data/bequest.db

# 客户端（Flutter，Android/Web）
cd app && flutter run            # 模拟器访问后端用 http://10.0.2.2:8080
# 自托管 http://IP:8080 可直接连接：release 包已含网络权限与明文 HTTP 支持

# Web 客户端（同源托管，浏览器即用）
cd app && flutter build web      # 构建到 app/build/web
cd ../server && go run .         # 自动探测并服务 app/build/web，浏览器打开 http://localhost:8080
```

## 管理后台

浏览器打开 `http://localhost:8080/admin`（单页内嵌，Go 同源托管，无需构建）。

- **首个管理员**：启动时设置环境变量自动创建/提升
  `ADMIN_USERNAME=admin ADMIN_PASSWORD=<强密码> go run .`
  （用户名已存在则只提升为管理员，不覆盖密码）
- **两步验证 (2FA)**：管理员可在配置页启用 TOTP（Google Authenticator/Authy 等），登录需动态码
- **功能**：仪表盘统计（用户/资产/继承人/待领取继承事件）、用户管理（搜索、会员开通、管理员任命、禁用/启用、删除、资产明细）、系统配置（SMTP/SMS/电话服务商 + 免费资产上限，写入 `config.json` 热重载）、全量审计日志（可导出 CSV）
- 管理员也是普通用户（可登录 App）；管理操作均写入审计日志（含登录、2FA 启用/停用）

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
| `DB_DRIVER` | 数据库驱动:`sqlite`(默认)/ `mysql` / `postgres` |
| `DB_DSN` | 完整连接串(设置后忽略下方 DB_* 单变量) |
| `DB_HOST/DB_PORT/DB_USER/DB_PASS/DB_NAME` | MySQL/PostgreSQL 连接参数 |
| `JWT_SECRET` | JWT 签名密钥（生产必填） |
| `ENCRYPTION_KEY` | SMTP 密码 AES 加密密钥（生产必填，dev 有默认值） |
| `SMTP_HOST/PORT/USER/PASS/FROM` | 系统邮件（单服务器，或多 SMTP 用 `config.json`） |
| `ADMIN_USERNAME/ADMIN_PASSWORD` | 启动时引导首个管理员（不存在则创建，存在则提升；见「管理后台」） |

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
- 资产级密钥隔离：每资产独立加密密钥 AK，内容用 AK 加密，AK 分别被主密钥与继承包装密钥 WK 包装，资产间密钥互不可见，继承只交接指定资产
- 继承触发后向继承人发放解密密钥（方案 A）
- 三重取消窗口：触发前 / 领取前 / 领取后登录反转
- 免费档继承提醒保证送达（仅邮件），会员更快且多渠道
- 隐私优先：自托管同步凭据仅存本机、数据只存用户自己的存储；提醒邮件可走用户自配 SMTP

架构决策与开发进度见 [`docs/`](docs/progress.md)。
