# 托孤 (bequest) — 架构与设计决策

> 交接第一手资料。本文档记录稳定的架构决策，进度类信息见 `docs/progress.md`。

## 产品定位

数字资产保险箱 + 数字遗嘱：管理实体/虚拟资产，号主超时未登录时升级提醒，最终将解密密钥交接给继承人。

## 技术栈

| 层 | 选型 | 说明 |
|---|---|---|
| 客户端 | Flutter 3.44 (Dart) | 当前仅 Android；后续 iOS/Web/鸿蒙(flutter_ohos) 同一套代码 |
| 本地存储 | SQLite (drift) + 字段级 AES-256-GCM | 敏感字段密文，非敏感字段明文 |
| 密钥派生 | Argon2id → AES-256 主密钥 | 主密码 ≠ 账户密码，忘记主密码 = 数据丢失（有意为之） |
| 后端 | Go (标准库 net/http) | 单二进制；1.22+ 路由模式 |
| 数据库 | SQLite (modernc.org/sqlite，纯 Go) | 起步；后续迁移 PostgreSQL |
| 认证 | JWT (golang-jwt) | 账户密码 argon2id 哈希 |
| 推送/邮件 | FCM + SMTP | 免费档只需这两条渠道 |

## 目录结构

```
bequest/
├── app/                          # Flutter 客户端
│   └── lib/
│       ├── main.dart             # 入口：登录态路由
│       ├── api/                  # HTTP 客户端
│       ├── crypto/               # 主密码派生、加解密
│       ├── pages/                # 页面
│       └── widgets/
├── server/                       # Go 后端
│   ├── main.go                   # 装配：db、路由、启动
│   ├── db.go                     # SQLite 打开 + 迁移执行
│   ├── auth.go                   # 注册/登录 + JWT 签发
│   ├── middleware.go             # 认证中间件
│   └── migrations/001_init.sql   # 建库脚本（embed 自动执行）
├── docs/
│   ├── architecture.md           # 本文档
│   └── progress.md               # 开发进度
└── README.md
```

## 核心设计决策 (ADR)

### ADR-1 端到端加密（方案 A：继承时发放密钥）

- 客户端主密码 → Argon2id → 主密钥 MK（AES-256-GCM）
- 资产敏感数据（凭据/备注）用 MK 加密后上传，**服务端永不见明文**
- 注册时客户端生成随机「继承包装密钥 WK」，`master_key_wrapped = encrypt(WK, MK)` 上传存储
- 继承触发后，服务端把 `master_key_wrapped` 发放给继承人，继承人凭 WK 解出 MK
- WK 由号主预先交给继承人（离线渠道，如当面/纸质）

### ADR-2 继承状态机与三重取消窗口

状态：`inactive → warning → triggered → claimed → reversed`

1. 号主超时未登录 → 提醒升级（升级阶梯：免费 30/60/90/120 天，会员 7/14/30/60 天；每档一次站内信，L3+ 邮件）→ 号主登录即取消（重置阶梯）
2. `triggered`：调度器创建 `inheritance_events`（随机 16 字节 event_key + 继承人访问码哈希快照），stage→triggered，event_key 经 SMTP 邮件发给继承人（未配 SMTP 时记录在审计日志）
3. `claimed`：继承人凭 **event_key + 预设访问码双因子** claim（无需账号）→ 拿到 `users.master_key_wrapped`；号主登录 → 事件 `reversed`（第三重窗口，72h 反悔期的服务端实现为「登录即反转」，未做倒计时到期自动完成——交接后 72h 倒计时为后续增强）

### ADR-3 免费/会员差异化

- 免费配额：资产上限 50 条（403），会员不限；`assetCount` 检查在创建时执行
- 提醒渠道：免费 = 站内信 + 邮件（SMTP 配置后）；会员 = 站内信 + 邮件 + 短信/电话（`notifyUser` 分发，短信/电话为预留空实现，用户表暂无手机字段）
- 继承升级间隔：免费 30/60/90/120 天，会员 7/14/30/60 天
- 权益门槛：导出格式（免费 JSON，Excel 会员后置）、自定义模板（当前免费开放，后续可收紧）
- 会员开通方式：当前无管理后台，`UPDATE users SET tier='member'` 手动开通（文档记录）

### ADR-8 自托管同步（隐私第一，客户端直连）

- 用户因隐私顾虑可把加密备份同步到自己的 WebDAV/S3（FTP/SFTP 预留）
- 同步凭据**仅存本机**（secure_store），绝不经过托孤服务端；同步动作客户端直连远端
- 备份 = 全量数据（资产密文 + 分类 + 模板 + 继承人）打包后主密钥 AES-GCM 加密单文件
- 实现为纯手写：`webdav_client` 内部用 dio（无法注入 http.Client/MockClient 测试）、`aws_s3` 无 null safety；SigV4 用 package:crypto 实现并以 AWS 官方测试向量锁定

### ADR-9 自定义发件与多渠道负载均衡

- 用户可配置自己的 SMTP（迁移 003 `user_smtp`），调度器 `notifyUser` 优先用户 SMTP，回退系统 SMTP——解决"怕产品方邮件服务"的隐私顾虑
- SMTP 密码 AES-256-GCM 加密存储（`ENCRYPTION_KEY` env；dev 默认密钥仅限开发，生产必须设置）
- 系统多渠道：可选 `server/config.json`（`smtp_servers[]` 轮询 + `sms_providers[]`/`phone_providers[]` 预留），缺失回退 env `SMTP_*`；`sendMailSystem` 轮询逐个尝试
- 版本：`GET /api/v1/version`，Release 构建用 `-X main.version=<tag>` 注入

### ADR-10 部署与发布

- 二进制：`scripts/build.sh`（5 平台）/ `build.ps1`（本地 Windows）；Docker：多阶段 alpine 非 root，`WORKDIR=/data` 使相对路径 `data/bequest.db` 落在卷上
- 发布：tag `v*` 触发 GitHub Actions——矩阵构建 + buildx 双架构推 `ghcr.io/muxinxy/bequest` + Release 资产；workflow 用 `"on":` 加引号规避 YAML 1.1 解析器布尔化问题

### ADR-7 导入导出（纯客户端 E2E）

- 导出/导入完全在客户端完成：拉取密文 → 主密码验证（派生比对本地 MK，salt 于注册时保存 `bequest_master_salt`）→ 解密/加密 → JSON v1 文件
- 服务端永不见明文（符合 ADR-1）；分类按名称映射（预设→null、自定义→匹配/创建）
- 导出范围：全部 / 当前筛选分类（单条可复用同一构建函数）

### ADR-6 提醒渠道与邮件

- 站内信（reminders 表）为默认渠道，App 拉取即用，零外部依赖
- SMTP 邮件经 `net/smtp` 标准库，env `SMTP_HOST/PORT/USER/PASS/FROM` 未配置则跳过记日志（免费档继承提醒=邮件渠道，需配置 SMTP 才能对外送达）
- 推送/短信/电话：渠道抽象预留，P3 接 FCM/短信 API

### ADR-4 资产存储模型

- `name` 明文（列表展示/搜索）；`encrypted_data` 密文（凭据/备注/关键描述）
- `reminder_settings` JSON：每资产独立提醒配置（提前天数/渠道/模板引用）
- 到期/续费日 `expiry_date` 明文，供服务端调度过期提醒

### ADR-5 审计日志

- 服务端事件记录（谁/何时/做了什么），继承类产品信任基石
- actor: `owner` / `inheritor:<id>` / `system`

## API 约定

- REST，前缀 `/api/v1`
- 认证：`Authorization: Bearer <JWT>`（除 register/login 外全部需要）
- 错误响应：`{"error": "..."}`
- 用户隔离：所有查询按 JWT 中 user_id 过滤，越权一律 404/401
- 端点：
  - `GET /healthz`
  - `POST /api/v1/auth/register`、`POST /api/v1/auth/login`、`GET /api/v1/me`
  - `GET|POST /api/v1/categories`、`DELETE /api/v1/categories/{id}`（删除后资产 category_id 自动置空）
  - `GET|POST /api/v1/assets`、`GET|PUT|DELETE /api/v1/assets/{id}`
  - `GET|POST|PUT|DELETE /api/v1/inheritors`（访问码仅存 sha256，返回不含）
  - `GET|POST|PUT|DELETE /api/v1/reminder-templates`（is_preset=1 系统模板只读）
  - `GET /api/v1/reminders`、`POST /api/v1/reminders/{id}/read`
  - `POST /api/v1/inheritance/claim`（无 JWT，event_key+access_code）→ `{"master_key_wrapped","status"}`
  - `GET /api/v1/inheritance/status`、`GET /api/v1/audit-log`
- 资产列表不含 `encrypted_data`（元数据），单条含密文 base64；`encrypted_data` 为客户端 AES-256-GCM 加密后的 `base64(nonce‖ciphertext‖tag)`
- 预设分类为客户端常量（不落库），自定义分类走 API；预设选中即 `category_id=null`（升级路径：服务端种子分类）

## 关键数据流

**注册**：客户端派生 MK → 生成 WK → 包装 MK → 上传 `{username, email, password, master_key_wrapped}` → 服务端存 argon2id 密码哈希 + 包装密钥

**登录**：`{username, password}` → JWT → 客户端用主密码解出 MK 解锁本地库

**继承触发**（P2）：服务端调度器检测超时 → 升级提醒 → 触发后邮件继承人（含访问码）→ 凭码领取 `master_key_wrapped`
