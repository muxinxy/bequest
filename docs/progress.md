# 托孤 (bequest) — 开发进度

> 交接用：记录阶段划分、当前状态、最近完成事项。架构决策见 `docs/architecture.md`。

## 阶段划分

| 阶段 | 内容 | 状态 |
|---|---|---|
| 环境 | Flutter 3.44.9 / JDK 17 / Android SDK 36 / Go 1.26 安装配置（国内镜像） | ✅ 完成 |
| 骨架 | monorepo 结构、Git 初始化、首次提交 | ✅ 完成 |
| P0 | 账号注册/登录（JWT + argon2id）、SQLite 接入、主密码派生 + 密钥安全存储 | ✅ 完成 |
| P1 | 资产 CRUD、分类、端到端加密备份/同步、APP 锁 | ⏳ |
| P2 | 过期提醒、不登录升级阶梯、继承状态机 + 三重取消窗口、继承人设置、密钥发放、审计日志 | ⏳ |
| P3 | JSON 导入导出、免费/会员权益、提醒渠道抽象（短信/电话接口预留） | ⏳ |
| 后置 | 多继承人优先级、定时释放、生前共享、数字遗言、Excel 导出、Web/iOS/鸿蒙 | ⏳ |

## 当前状态（P0 完成，下一步 P1）

**P0 已交付**：
- 后端 `server/`：`POST /api/v1/auth/register`、`/login`、`GET /api/v1/me`；JWT HS256 24h（`JWT_SECRET` 环境变量）；argon2id PHC 哈希；SQLite（modernc 纯 Go）自动迁移（schema_migrations 表）；`auth_test.go` 3 用例全过
- 前端 `app/`：登录/注册/主页三页；注册时 Argon2id 派生主密钥（3/65536/4 → 32B）→ 随机 WK 包装 MK（AES-256-GCM）→ 上传 `master_key_wrapped`；JWT/MK/WK 存 flutter_secure_storage（Keystore）；analyze 0 问题 + widget test 通过
- 端到端联调已验证：注册/登录/me/409 重复/401 错误密码 全部符合契约

**P0 实现偏差（镜像约束）**：
- `argon2` 依赖锁定 `^1.0.1`（pub 镜像无新版），用底层 `Argon2Parameters(ARGON2_id)` API，参数不变
- `package:crypto` 无 AES，GCM 改用 `pointycastle`（转为直接依赖）；输出按契约 `base64(nonce‖ciphertext)` 丢弃 MAC tag——后续做解包时契约需改为含 tag

**踩坑记录**：
- PowerShell 5.1 向 curl.exe 传含双引号的 `-d '{"json"...}'` 会被转义破坏，后端报 "invalid JSON body"。联调时用 `-d "@file.json"` 或 Invoke-RestMethod
- 本机 git 走代理 `127.0.0.1:7897`（Clash），无代理时 GitHub push 会 SSL 失败
- Flutter/Dart 走 `storage.flutter-io.cn` 镜像；Go 模块临时设 `$env:GOPROXY="https://goproxy.cn,direct"`

## 如何运行（交接用）

```powershell
# 后端（需 Go；模块走 goproxy.cn 镜像）
cd D:\Documents\Code\bequest\server
$env:GOPROXY = "https://goproxy.cn,direct"
go run .                    # 监听 :8080，首次启动自动建库 server/data/bequest.db

# 客户端（需 Flutter；已配国内镜像）
cd D:\Documents\Code\bequest\app
flutter pub get
flutter run                 # Android 模拟器访问后端用 http://10.0.2.2:8080
```

## 决策变更记录

- 2026-08-09：锁定方案 A（继承时发放密钥）、免费继承保证送达、MVP 仅 Android
- 2026-08-09：产品定名「托孤」（英文 bequest），monorepo 结构（app/ + server/）
- 2026-08-09：P0 完成——账号注册/登录、JWT + argon2id、主密码派生 + 密钥安全存储、SQLite 自动迁移
