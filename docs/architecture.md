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

1. 号主超时未登录 → 提醒升级（L1 推送 → L2 推送+邮件 → L3 警告）→ 号主登录即取消
2. `triggered`：继承人收到「领取资格」+ 预设访问码，凭码领取
3. `claimed`：交接冻结 72h 反悔期，号主登录即 `reversed` 冻结交接

### ADR-3 免费/会员差异化

- 继承提醒：免费保证送达但仅邮件、升级间隔长；会员多渠道（短信/电话）、间隔短
- 权益门槛：资产/分类数量、导出格式（免费仅 JSON）、自定义模板、同步频率

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
- 资产列表不含 `encrypted_data`（元数据），单条含密文 base64；`encrypted_data` 为客户端 AES-256-GCM 加密后的 `base64(nonce‖ciphertext‖tag)`
- 预设分类为客户端常量（不落库），自定义分类走 API；预设选中即 `category_id=null`（升级路径：服务端种子分类）

## 关键数据流

**注册**：客户端派生 MK → 生成 WK → 包装 MK → 上传 `{username, email, password, master_key_wrapped}` → 服务端存 argon2id 密码哈希 + 包装密钥

**登录**：`{username, password}` → JWT → 客户端用主密码解出 MK 解锁本地库

**继承触发**（P2）：服务端调度器检测超时 → 升级提醒 → 触发后邮件继承人（含访问码）→ 凭码领取 `master_key_wrapped`
