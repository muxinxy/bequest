# 托孤 (bequest) — 开发进度

> 交接用：记录阶段划分、当前状态、最近完成事项。架构决策见 `docs/architecture.md`。

## 阶段划分

| 阶段 | 内容 | 状态 |
|---|---|---|
| 环境 | Flutter 3.44.9 / JDK 17 / Android SDK 36 / Go 1.26 安装配置（国内镜像） | ✅ 完成 |
| 骨架 | monorepo 结构、Git 初始化、首次提交 | ✅ 完成 |
| P0 | 账号注册/登录（JWT + argon2id）、SQLite 接入、主密码派生 + 密钥安全存储 | 🔄 进行中 |
| P1 | 资产 CRUD、分类、端到端加密备份/同步、APP 锁 | ⏳ |
| P2 | 过期提醒、不登录升级阶梯、继承状态机 + 三重取消窗口、继承人设置、密钥发放、审计日志 | ⏳ |
| P3 | JSON 导入导出、免费/会员权益、提醒渠道抽象（短信/电话接口预留） | ⏳ |
| 后置 | 多继承人优先级、定时释放、生前共享、数字遗言、Excel 导出、Web/iOS/鸿蒙 | ⏳ |

## 当前状态（P0 进行中）

**已就绪**：
- 后端 `server/`：healthz、migrations/001_init.sql（6 张表：users/inheritors/categories/assets/reminder_templates/audit_logs）
- 客户端 `app/`：Flutter Android 工程，应用名「托孤」
- 远程仓库：`origin` → https://github.com/muxinxy/bequest.git（main 分支已推送）
- 本机 git 走代理 `127.0.0.1:7897`（Clash），Go 模块走 `goproxy.cn`，Flutter/Dart 走 `storage.flutter-io.cn`

**P0 拆分**：
- 后端：`POST /api/v1/auth/register`、`/login`、`GET /api/v1/me`；JWT HS256 24h；argon2id；SQLite 自动迁移
- 前端：注册/登录页、主密码 Argon2id 派生、WK 包装 MK、flutter_secure_storage 存密钥

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
