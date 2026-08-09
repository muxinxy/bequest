# 托孤 (bequest) — 开发进度

> 交接用：记录阶段划分、当前状态、最近完成事项。架构决策见 `docs/architecture.md`。

## 阶段划分

| 阶段 | 内容 | 状态 |
|---|---|---|
| 环境 | Flutter 3.44.9 / JDK 17 / Android SDK 36 / Go 1.26 安装配置（国内镜像） | ✅ 完成 |
| 骨架 | monorepo 结构、Git 初始化、首次提交 | ✅ 完成 |
| P0 | 账号注册/登录（JWT + argon2id）、SQLite 接入、主密码派生 + 密钥安全存储 | ✅ 完成 |
| P1 | 资产 CRUD、分类、端到端加密备份/同步、APP 锁 | ✅ 完成 |
| P2 | 过期提醒、不登录升级阶梯、继承状态机 + 三重取消窗口、继承人设置、密钥发放、审计日志 | ✅ 完成 |
| P3 | JSON 导入导出、免费/会员权益、提醒渠道抽象（短信/电话接口预留）、审计日志页 | ✅ 完成 |
| 后置 | 自托管同步（WebDAV/S3）、自定义 SMTP、多渠道负载均衡、Docker + Release | ✅ 完成 |
| 双模 | 云/本地双模存储、不登录本地模式、跨设备恢复（密码+盐）、三层权益、服务器地址可配置、Release 含 Android APK | ✅ 完成 |
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

## 当前状态（P2 完成，下一步 P3）

**P2 已交付（产品灵魂：提醒 + 继承）**：
- 迁移 002：`inheritance_events`（事件状态机）+ `reminders`（dedup_key 唯一索引防重复）+ 3 个系统提醒模板种子
- 调度器（scheduler.go，60s tick 后台 goroutine + 可测 `scan(db, now)`）：
  - 过期提醒：到期前 30/7/1 天 + 已到期，按资产逐个触发，dedup 防重
  - 升级阶梯：免费 `[30,60,90,120]` 天 / 会员 `[7,14,30,60]` 天；**level 映射 1-based 计数并封顶为 `len-1`**（40 天→1 级、130 天→3 级+触发继承，测试锁死）
  - 触发继承：随机 16 字节 event_key + 继承人访问码哈希快照 → 事件 pending、stage=triggered、审计记录 event_key、SMTP 邮件（未配置则跳过记日志）
- 继承 API：`inheritors` CRUD（访问码仅存 sha256）、`reminder-templates` CRUD（系统模板只读）、`reminders` 站内信 + 已读、`inheritance/claim`（**无需 JWT**，event_key+访问码双因子 → 返回 master_key_wrapped）、`inheritance/status`、`audit-log`
- **登录重置**：号主登录 → last_login_at 刷新 + stage 复位 inactive + escalation 清零 + pending/claimed 事件全部 reversed + 审计（第三重取消窗口）
- 前端：继承人管理页（访问码生成+线下交付提示）、提醒收件箱（未读徽标/类型图标/标记已读）、继承状态页（stage/事件/三重窗口说明）、提醒模板管理页、资产编辑新增「到期提醒提前天数」（存加密载荷，零 API 变更）
- 验证：后端 15 测试全绿；**端到端时间旅行实测**——130 天未登录→调度器触发→claim 返回与注册一致的密钥→重复 409→错码 401→登录后 stage=inactive 事件 reversed

## 当前状态（P3 完成，MVP 闭环）

**P3 已交付**：
- 后端：
  - **免费配额**：免费用户资产上限 50 条，超出 → 403「免费用户最多 50 条资产,升级会员可解锁」；会员不限（`notifyUser` 单点分发：站内信+邮件全档，短信/电话会员档空实现预留，用户表暂无手机字段）
  - 调度器改走 `notifyUser`（过期/升级提醒）；继承触发邮件保持直发继承人
  - 配额 4 测试 + 原有 14 = 18 全绿；端到端实测 50 条 201 → 第 51 条 403
- 前端：
  - **JSON 导出**（全部/当前筛选分类）：主密码验证（派生比对存储 MK）→ 拉取解密 → 构建 v1 格式 → 临时文件 share_plus 分享
  - **JSON 导入**：file_picker 选文件 → 主密码验证 → 解析校验（app/version/assets）→ 分类名映射（预设→null、自定义→匹配/创建）→ 逐条加密回写，进度 + 成功/失败统计
  - **主密码验证补洞**：P0 未存 salt，现注册时一并保存 `bequest_master_salt`（未上线无兼容问题）
  - 审计日志页（action/actor 中文标签映射）
  - 新增 `export_format.dart`（纯函数契约层）+ `master_password.dart`；9 新测试 → 15 全绿

**导出文件契约 v1**：`{"app":"bequest","version":1,"exported_at":"ISO8601","assets":[{"name","asset_type","category"?, "expiry_date"?,"credentials","notes","advance_days"?}]}`——纯客户端加解密，服务端永不见明文；Excel 导出留作会员权益（后置）

## 当前状态（后置功能完成）

**后置功能已交付**：
- **用户自定义 SMTP**：迁移 003 `user_smtp` 表；`GET/PUT/DELETE /api/v1/settings/smtp`（密码 AES-256-GCM 加密存 BLOB，`ENCRYPTION_KEY` env，dev 默认密钥 + 一次性警告；GET 永不返回密码；空密码 PUT 保留旧值；首次设置必填密码）；调度器 `notifyUser` 优先用用户自己的 SMTP 发提醒邮件，未配置/禁用回退系统 SMTP；继承触发邮件（发给继承人）保持系统 SMTP
- **多渠道负载均衡**：可选 `server/config.json`（`smtp_servers[]` 多 SMTP 轮询 + `sms_providers[]`/`phone_providers[]` 预留），缺失则回退 env `SMTP_*` 单服务器；`sendMailSystem` 轮询逐个尝试
- **version 端点**：`GET /api/v1/version`（`-X main.version=` 注入，Release 时自动带上 tag 版本）
- **自托管同步（隐私第一）**：同步配置**仅存本机**（secure_store），凭据绝不经过托孤服务端；WebDAV + S3 两个实现（**纯手写**：webdav_client 内部用 dio 无法注入 MockClient 测试、aws_s3 包无 null safety——SigV4 用 package:crypto 手写并用 AWS 官方测试向量锁定）；FTP/SFTP 界面预留"即将支持"
- 备份 = 全量数据（资产密文 + 分类 + 模板 + 继承人）→ 主密钥 AES-GCM 加密单文件 → 上传用户自己的存储；恢复 = 下载 → 解密 → 逐条重建（分类按名解析：预设→null、自定义→匹配/创建）
- **SMTP 设置页**：自定义发件服务器（提醒邮件走用户自己的邮箱）
- **部署**：`server/Dockerfile`（多阶段 alpine，非 root，WORKDIR=/data 落卷）+ `docker-compose.yml` + `scripts/build.sh`（5 平台交叉编译）/`build.ps1` + `.github/workflows/release.yml`（tag v* 触发：矩阵构建 + buildx 双架构推 GHCR `ghcr.io/muxinxy/bequest` + softprops 发 Release 资产，`"on":` 加引号规避 YAML 1.1 布尔陷阱）
- 验证：后端 22 测试全绿（+4：SMTP CRUD 加密存取、version、无配置轮询、用户 SMTP 优先不 panic）；前端 29 测试全绿（+14：备份 round-trip/篡改、WebDAV MockClient、SigV4 AWS 向量、SMTP 设置）；端到端实测 SMTP API 全链路（密码不泄露、空密码保留旧值、version dev）

**仍后置**：FTP/SFTP 同步真实现、SMS/电话 API 真接入、网盘扩展（坚果云/百度云等走 WebDAV 即可）、Excel 导出、多继承人优先级、定时释放、生前共享、数字遗言、Web/iOS/鸿蒙、会员开通后台

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
- 2026-08-09：**自托管同步无需登录**——新增 LocalVault（本地加密快照 `vault.bq`，主密钥 AES-GCM）；同步优先读本地快照、恢复未登录时落本地；登录页新增「自托管同步(无需登录)」入口；README 补齐部署/Release 文档
- 2026-08-09：**发布 v0.1.0**——tag 推送触发 GitHub Actions（5 平台二进制 + GHCR 双架构镜像 + Release 资产）
- 2026-08-09：**云/本地双模存储**——`AssetRepository` 抽象（Cloud/Local 双实现）+ `RepositoryFactory`；不登录可进本地模式（设置主密码 → 本地加密库全量 CRUD）；登录页新增「进入本地模式」；`ApiConfig` 服务器地址可配置（设置页保存 + 测试连接）；`extractBackupJsonAny` 支持「主密码 + 备份内 salt」跨设备恢复；三层权益矩阵（访客 20 条/免费 50 条/会员不限）UI 徽章 + 资产上限拦截；云↔本地切换迁移（拉取/上传 + 进度提示）；Release 新增 android job（Flutter APK 三 ABI → Release 资产）
