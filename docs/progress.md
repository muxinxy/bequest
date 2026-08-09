# 托孤 (bequest) — 开发进度

> 交接用：记录阶段划分、当前状态、最近完成事项。架构决策见 `docs/architecture.md`。

## 阶段划分

| 阶段 | 内容 | 状态 |
|---|---|---|
| 环境 | Flutter 3.44.9 / JDK 17 / Android SDK 36 / Go 1.26 安装配置（国内镜像） | ✅ 完成 |
| 骨架 | monorepo 结构、Git 初始化、首次提交 | ✅ 完成 |
| P0 | 账号注册/登录（JWT + argon2id）、SQLite 接入、主密码派生 + 密钥安全存储 | ✅ 完成 |
| P1 | 资产 CRUD、分类、端到端加密备份/同步、APP 锁 | ✅ 完成 |
| P2 | 过期提醒、不登录升级阶梯、继承状态机 + 三重取消窗口、继承人设置、密钥发放、审计日志 | ⏳ |
| P3 | JSON 导入导出、免费/会员权益、提醒渠道抽象（短信/电话接口预留） | ⏳ |
| 后置 | 多继承人优先级、定时释放、生前共享、数字遗言、Excel 导出、Web/iOS/鸿蒙 | ⏳ |

## 当前状态（P1 完成，下一步 P2）

**P1 已交付**：
- 后端：categories/assets CRUD（8 个路由，全部鉴权 + 用户隔离）；列表不含 `encrypted_data`、单条含密文 base64 round-trip；分类删除自动置空资产引用（ON DELETE SET NULL）；`resources_test.go` 6 用例全过
- 前端：
  - 资产列表（分类筛选）+ 资产编辑页（名称/类型/分类/凭据/备注/到期日，日期选择器）
  - 资产敏感字段加密：`encryptSensitiveData`/`decryptSensitiveData`（AES-256-GCM 完整 tag，可解密）——注意与 `wrapMasterKey`（剥 tag，继承用）不同
  - 预设分类客户端常量（实体 5 类 + 虚拟 5 类），自定义分类走 API；`ponytail:` 预设分类无服务端 id，选中即 category_id=null（升级路径：服务端种子分类）
  - APP 锁：PIN（4-6 位，sha256(salt+pin) 哈希存储）+ 生物识别（local_auth）+ 后台/切出即锁（AppLifecycleListener + LockGate）；锁设置页
  - `crypto_test.dart` 新增 4 用例（加密解密 round-trip、篡改检测、过短密文、PIN 哈希）；analyze 0 问题 + 6 测试全过
- 端到端联调已验证：分类/资产 CRUD 全链路、密文 round-trip、未认证 401、更新置 null 均符合契约

**P0 已交付（历史）**：
- 后端：`POST /api/v1/auth/register`、`/login`、`GET /api/v1/me`；JWT HS256 24h（`JWT_SECRET` 环境变量）；argon2id PHC 哈希；SQLite（modernc 纯 Go）自动迁移（schema_migrations 表）
- 前端：登录/注册/主页；注册时 Argon2id 派生主密钥（3/65536/4 → 32B）→ 随机 WK 包装 MK → 上传 `master_key_wrapped`；JWT/MK/WK 存 flutter_secure_storage（Keystore）

**实现偏差与踩坑（长期有效）**：
- `argon2` 锁定 `^1.0.1`（pub 镜像无新版），用底层 `Argon2Parameters(ARGON2_id)` API，参数不变
- `package:crypto` 无 AES，GCM 走 `pointycastle`；继承用 `wrapMasterKey` 按契约 `base64(nonce‖ciphertext)` 剥 tag（不可解），资产用 `encryptSensitiveData` 保留完整 tag（可解）——勿混用
- PowerShell 5.1 向 curl.exe 传含双引号的 `-d '{"json"...}'` 会被转义破坏，联调用 `-d "@file.json"` 或 Invoke-RestMethod
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
