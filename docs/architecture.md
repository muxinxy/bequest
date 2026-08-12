# 托孤 (bequest) — 架构与设计决策

> 交接第一手资料。本文档记录稳定的架构决策，进度类信息见 `docs/progress.md`。

## 产品定位

数字资产保险箱 + 数字遗嘱：管理实体/虚拟资产，号主超时未登录时升级提醒，最终将解密密钥交接给继承人。

## 技术栈

| 层 | 选型 | 说明 |
|---|---|---|
| 客户端 | Flutter 3.44 (Dart) | 同一套代码编译 Android + Web（flutter_ohos 后续） |
| 本地存储 | SQLite (drift) + 字段级 AES-256-GCM | 敏感字段密文，非敏感字段明文 |
| 密钥派生 | Argon2id → AES-256 主密钥 | 主密码 ≠ 账户密码，忘记主密码 = 数据丢失（有意为之） |
| 后端 | Go (标准库 net/http) | 单二进制；1.22+ 路由模式 |
| 数据库 | SQLite (modernc.org/sqlite，纯 Go) | 起步；后续迁移 PostgreSQL |
| 认证 | JWT (golang-jwt) | 账户密码 argon2id 哈希 |
| 推送/邮件 | FCM + SMTP | 免费档只需这两条渠道 |

## 目录结构

```
bequest/
├── app/                          # Flutter 客户端（Android + Web）
│   └── lib/
│       ├── main.dart             # 入口：登录态路由
│       ├── api/                  # HTTP 客户端
│       ├── crypto/               # 主密码派生、加解密
│       ├── platform/             # 平台抽象：string_store/file_share（io/web 双实现）
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
- 会员开通方式：管理后台（ADR-16）用户管理页直接改 tier；或 `UPDATE users SET tier='member'`

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

### ADR-11 云/本地双模存储与权益

- **存储抽象**：`AssetRepository`（8 个 CRUD 方法）——`CloudAssetRepository`（ApiClient，jwt）+ `LocalAssetRepository`（LocalVault 加密本地库，主密钥）；`RepositoryFactory.resolve(jwt, masterKeyB64)` 按存储模式选择；页面一律走仓储，服务端地址可配置（`ApiConfig.baseUrl()`，设置页保存/测试）
- **不登录本地模式**：登录页「进入本地模式」→ 首次设置主密码（salt 派生 MK 存 secure_store + 初始化 vault）→ 本地全量 CRUD；退出本地模式不清空本机数据
- **跨设备恢复**：同步负载含 `salt`（明文，不敏感）；`extractBackupJsonAny` 先试本机 MK、失败用「主密码 + 负载盐」派生重试；恢复后可设置本机主密钥
- **三层权益**：访客（20 条、无云同步/继承、本地可用）/ 免费（50 条、云同步+继承）/ 会员（不限）；UI 徽章 + 创建时资产上限拦截
- **模式切换**：云→本地（拉取全量写 vault）/ 本地→云（需登录，逐条上传，分类按名去重）——复制式迁移，非连续同步（ponytail: 后续可升级为双向增量）
- **发布**：Release 含 Android APK（`flutter build apk --release --split-per-abi`，三 ABI 上传 assets）
- Android 网络：主 manifest 加 `INTERNET` 权限 + `usesCleartextTraffic`（自托管 HTTP 必需；debug/profile 构建的权限/配置不继承到 release）

- 二进制：`scripts/build.sh`（5 平台）/ `build.ps1`（本地 Windows）；Docker：多阶段 alpine 非 root，`WORKDIR=/data` 使相对路径 `data/bequest.db` 落在卷上
- 发布：tag `v*` 触发 GitHub Actions——矩阵构建 + buildx 双架构推 `ghcr.io/muxinxy/bequest` + Release 资产；workflow 用 `"on":` 加引号规避 YAML 1.1 解析器布尔化问题
- 迁移部署：SQL 迁移通过 `go:embed` 编译进二进制，Docker 运行时不依赖外部 `migrations/` 目录；仅将 `/data` 作为数据库持久化卷

### ADR-12 资产级密钥隔离

- 每资产独立随机 AK（AES-256），资产密文改用 AK 加密；AK 分别被 MK（号主）与 WK（继承人）包装为 `asset_key_wrapped_mk` / `asset_key_wrapped_wk` 上传（`assets` 表新增两列，迁移 005）
- 新增 `asset_inheritors` 表：`asset_id × inheritor_id × priority × trigger_days`（`UNIQUE(asset_id, inheritor_id)`）；绑定即资产级继承，`trigger_days` 独立判定，否则沿用全局升级线
- `inheritance_events` 加 `asset_id` 列（NULL = 全量事件）；调度器 `triggerInheritance` 先按 `asset_inheritors` 逐资产创建事件，全部资产有绑定则跳过全量事件
- 继承人 claim：资产级事件返回 `{"asset_key_wrapped_wk","asset_id","status"}`——只拿被指定的资产，拿不到 `master_key_wrapped`
- 老资产渐进兼容：客户端 `decryptAssetData` 有 `asset_key_wrapped_mk` 则解 AK 再解密，否则回退 MK 直解（历史数据不受影响）
- 管理：`server/asset_inheritors.go` 三 handler（list/create/delete），校验继承人属于同一用户；API `GET/POST /api/v1/assets/{id}/inheritors`、`DELETE /api/v1/assets/{id}/inheritors/{iid}`
- 分组（分类）级继承（迁移 007 `category_inheritors`：`category_id × inheritor_id × priority × trigger_days`，`UNIQUE(category_id, inheritor_id)`）：分组绑定 = 该分组下未资产级绑定的资产的默认继承人，资产级绑定优先级更高
- 调度器 `triggerInheritance`：资产无资产级绑定时按所属分组 `category_inheritors` 交接（JOIN inheritors/assets，`NOT EXISTS` 过滤已资产级绑定的资产）；分组绑定资产同样逐资产建事件、计入 boundAssets；有资产级/分组级配置的资产不进全量事件
- 「继承人绑定资产」列表返回**绑定条目实体**（分组一行 + 资产一行，不再把分组展开成逐资产）：分组行含 `asset_count`（经该分组继承的资产数，排除已资产级绑定），空分组同样可见、可解绑

### ADR-13 Web 客户端

- 同一套 Flutter 代码编译 Web；服务端静态托管 `build/web` + SPA 回退（`web.go` 的 `webDir()`：`WEB_DIR` env > 自动探测；`spaHandler` 真实文件直出、`/api/*` 返回 404、其余回退 `index.html`）
- CORS 中间件：`Allow-Origin *`（Bearer 认证无 cookie，`*` 可接受）、`OPTIONS` 预检 204
- Web 端 argon2id 派生：自托管 WASM（`web/assets/hash-wasm.js`，约 0.3s，纯 JS 约 33s）；条件导入 `key_derivation_io.dart`（pointycastle）/ `key_derivation_web.dart`（hash-wasm）
- 平台存储抽象：`string_store`（文件 / localStorage）、`file_share`（系统分享 / 浏览器下载）——`platform/` 下 io、web 双实现
- `local_auth` Web 禁用（网页无生物识别）；Web 默认相对路径请求（同源免 CORS）
- Web 锁定修复：AppLockScreen 自动放行条件加 `!_hasMasterKey`（主密码也是可校验方式，只设主密码的用户不能自动放行）；`LockGate.lockNow` 无条件锁定，锁屏自身处理无凭据场景（无任何解锁方式才自动放行）——修复 web 端手动锁定立即失效的根因

### ADR-14 继承开关（全局）

- 迁移 006：`users.inheritance_enabled`（默认 1）；关闭 = 调度器跳过升级提醒与继承触发
- API：`GET /api/v1/settings/inheritance`（读 `{"enabled":bool}`）、`PUT /api/v1/settings/inheritance`（写开关）
- 调度器 `processEscalation` 查询加 `AND inheritance_enabled = 1`；客户端设置页 SwitchListTile 开关（settings_page.dart）

### ADR-15 重置主密码

- 复用 `PUT /api/v1/settings/master-key`（账户密码验证 + 换 `master_key_wrapped`，零新增后端端点）
- 客户端 `reset_master_password.dart`：派生新 MK/新 WK/新 salt → 更新云端 `master_key_wrapped` → 云端资产逐条保留元数据（name/分类/到期）、凭据清空、换新 AK 重加密 → 本地 vault 重建空库 → 更新本机密钥
- 端到端加密固有代价：旧凭据不可恢复（页面明示用户）

### ADR-16 管理后台

- 迁移 009：`users.role`（'user'/'admin'，默认 user）+ `users.disabled`（禁用标记）
- **管理员引导**：`ADMIN_USERNAME`/`ADMIN_PASSWORD` env，启动 `ensureAdmin`——用户名不存在则建号（邮箱 `user@admin.local`），存在则仅提升 role；不触碰已存在用户的密码
- **鉴权**：`requireAdmin`（= requireAuth + DB 实时查 role/disabled，无 JWT claim 过期问题）；普通 `requireAuth` 同步拒绝 disabled 账号（登录接口 403、存量 token 403）
- **管理 API**（前缀 `/api/v1/admin`，全部 requireAdmin）：`stats`（用户/会员/资产/继承人/待领取事件等计数）、`users` 列表（q/role/tier 筛选 + 分页 + 资产/继承人计数）、`users/{id}` 详情、`PUT users/{id}`（role/tier/disabled 单项更新）、`DELETE users/{id}`（级联删资产等；**自保护**：不能降级/禁用/删除自己）、`audit-log`（全量 + user_id 筛选）、`config` GET/PUT（系统 SMTP 服务器 + `free_asset_quota`；密码不回显、PUT 留空=保留原值，写入 `config.json` 后 `loadConfig()` 热重载）
- **前端**：`server/admin.html` 内嵌单页（`//go:embed`，零新依赖、无构建），`GET /admin` 同源托管；登录复用 `POST /auth/login` + `/me` 的 role 校验；仪表盘/用户/配置/审计四个标签页，vanilla JS + fetch
- 管理员操作写审计日志（actor='admin'）；config.json 的 `from_addr` 依赖 smtpServer json tag 修复（Go 大小写折叠匹配跨不过下划线）
- 说明：管理员也是普通用户（占配额、可登录 App）；删除用户遗留 reminders/inheritance_events 孤儿行的场景暂不处理（按 user_id 过滤，无实际影响）

### ADR-17 算术验证码（注册/登录）

- **选型**：算术验证码（`3 + 7 = ?`）——最简单又有效：零外部依赖、无图像库/验证码服务、防机器人/防爆破足够（暴力尝试由 ADR-18 限流兜底）
- `GET /api/v1/auth/captcha` 生成随机 0-9 加法算式，**答案 sha256 哈希**存内存缓存（5 分钟过期）
- 登录/注册请求体携带 `captcha_id + captcha`，`verifyCaptcha` 校验并**一次性消费**（删除条目，防重放）
- 单机内存缓存（`captcha.go` map + mutex）；多实例部署需换共享存储（本项目单二进制）
- 前端：登录/注册页算式卡片（点击刷新），验证码错误自动刷新重试

### ADR-18 按 IP 频率限制

- 内存滑动窗口中间件（`rate_limit.go`）：**登录/注册 5 次/分钟/IP**，其他 API 120 次/分钟/IP
- 超限返回 429「请求过于频繁」；窗口过期自动恢复（`reset` 清理陈旧条目防内存增长）
- 取 IP：优先 `X-Forwarded-For`（反代场景），否则 `RemoteAddr`
- 包裹顺序：`cors(rateLimit(newMux(db)))`——限流在路由之前，未鉴权请求也受限（防未认证刷接口）
- 单机内存实现；多实例需共享存储（同 ADR-17）

### ADR-13 补充 Web 端派生修复

- **根因**：web argon2 绑定 `js_util.callMethod(argon2id, 'call', [options])` 编译为 `argon2id.call(options)`，JS `.call()` 把 options 当 **thisArg** 而非参数，hash-wasm 收到空参数抛 `Invalid options parameter`——注册与本地模式设置主密码（都调 `deriveMasterKey`）因此失败
- **修复**：`callMethod(hashwasm, 'argon2id', [options])`（= `hashwasm.argon2id(options)`）；用 Node 加载 Dart 编译产物验证派生结果与锚值逐字节一致
- 教训：web 专属绑定逻辑需真实执行验证（`dart compile js` + Node 跑），仅 `flutter build web` 编译通过不够（dart2js 不校验运行时参数语义）

### ADR-17 跨设备密钥恢复

- 背景：主密钥 MK/盐/WK 只在注册时写入本机（ADR-1），换设备登录后只有 JWT——资产详情解密失败、保存缺 WK
- 迁移 010：`users.master_salt`（明文不敏感，ADR-11 同款）；注册上传、登录返回
- 恢复（`crypto/recover_keys.dart`）：主密码 + 盐 → 重新派生 MK（与注册逐字节一致）→ 用任一资产的 `asset_key_wrapped_mk` 做 AES-GCM 认证校验主密码 → 保存 MK/盐；WK 缺失 → 生成新 WK → 账户密码验证更新 `master_key_wrapped`（复用 PUT /settings/master-key）→ 逐资产把 AK 用新 WK 重包装（凭据密文原样保留，非破坏性）→ 保存新 WK。号主需重新线下交付新 WK
- 老账号回填：`PUT /api/v1/settings/master-salt`——本机有盐而服务端缺（注册早于本 ADR）时登录自动上传
- 触发：登录页检测「本机无主密钥且服务端有盐」→ 弹「恢复加密密钥」对话框（主密码 + 账户密码）；取消/失败 → 清凭据留在登录页

### ADR-18 管理后台 2FA 与继承安全增强

- **claim 限流 + 审计**：`/inheritance/claim`、`/auth/2fa/verify` 与登录/注册同窗(5 次/分/IP)；claim 失败审计(未知 event_key → actor 'system'、错误访问码 → actor 'inheritor')
- **管理员登录审计**：完整登录(含 2FA 通过)记 `admin_login`(detail=来源 IP)
- **TOTP 2FA**：`users.totp_secret`(迁移 011, base32)；RFC 6238 纯标准库(HMAC-SHA1, 30s, ±1 步)；登录两步：账号密码 → `{totp_required, pending_token}`(5 分钟、带 `pending_2fa` claim 的待验证令牌) → `POST /auth/2fa/verify` 换正式令牌；requireAuth/requireAdmin 拒绝 pending 令牌(不能当会话用)；启用流程 setup(返回密钥,不落库)→ confirm(动态码验证后落库)/disable(动态码验证后清空)
- **72h 反悔窗口**：claim 时落 `reversable_until = claimed_at + 72h`(迁移 011)；号主登录撤销的第三重窗口改为窗口内可撤销、超期后交接最终完成；状态接口返回 `reversable_until`
- **继承人领取页**：`GET /claim` 内嵌单页(无鉴权,领取校验在 API),继承人不需装 App 即可领取密钥
- **运维**：`/healthz` 实际 `PingContext` 查 DB；`bequest-server backup` 子命令 `VACUUM INTO` 一致性快照;`PORT` env 可换监听端口

### ADR-19 多本地账户与密钥隔离

- 背景：本地模式原为单账户（标准密钥槽 + vault.bq 共用）；进入本地会覆盖云端密钥槽、再次进入自动放行无验证
- **账户体系**（SecureStore）：`bequest_local_profiles`=[{id,name}]、账户密钥入专属槽 `bequest_local_{mk,salt,wk,hint}_<id>`；创建/切换账户时把该账户密钥写入标准槽（现有本地代码无感），进入前把原标准槽暂存到 `bequest_pre_local_*`，退出（`deactivateLocalProfile`）恢复——云端与本地密钥互不覆盖
- **数据隔离**：LocalVault 按当前账户选文件——legacy 账户沿用 `vault.bq`（旧版单账户自动迁移，零数据移动），新账户 `vault_<id>.bq`；云端备份（无当前账户）仍用 vault.bq
- **进入流程**：本地模式入口 = 账户选择 → 验证该账户主密码（账户盐派生比对）→ 激活进入；冷启动恢复本地会话同样过账户选择页（不再自动放行）
- 本地模式排序/批量移动直接在 vault 内操作（仓储实现,无网络依赖）

### ADR-20 账户密码安全

- **登录后修改密码**：`PUT /api/v1/me/password`（当前密码校验 → argon2id 新哈希 → 审计）
- **token_version（迁移 013）**：改密/重置时递增；JWT 携带签发时版本，requireAuth/requireAdmin 与 DB 比对——改密后所有旧 token 立即失效（不再依赖 24h TTL）
- **忘记密码加固**：`reset-request`/`reset` 纳入严格限流窗口；验证码 5 次错误自动作废（`password_resets.attempts`）；验证码 sha256 哈希存储、10 分钟、一次性、防枚举（不存在邮箱也返回 200）
- **主密码盐同步**：修改/重置主密码生成新盐时必须 `PUT /settings/master-salt` 同步服务端,否则新设备跨设备恢复用旧盐派生 → 误报主密码错误（ADR-17 的配套不变量）
- **主密码修改非破坏性**：逐资产用新 MK 重包 `asset_key_wrapped_mk`（凭据密文与 WK 包装原样保留）——与重置（破坏性、凭据清空）形成「记得旧密码用修改、忘记用重置」两条路径

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
  - `GET /api/v1/auth/captcha`（算术验证码：`{"captcha_id","question"}`）
  - `POST /api/v1/auth/register`、`POST /api/v1/auth/login`（带 captcha_id/captcha）、`GET /api/v1/me`、`PUT /api/v1/me`（改用户名/邮箱）
  - `GET /api/v1/auth/check?username=`、`GET /api/v1/auth/check-email?email=`（注册实时查重）
  - `POST /api/v1/auth/reset-request`（邮箱验证码）、`POST /api/v1/auth/reset`（验证码重置密码）
  - `GET|POST /api/v1/categories`、`DELETE /api/v1/categories/{id}`（删除后资产 category_id 自动置空）
  - `GET|POST /api/v1/assets`、`GET|PUT|DELETE /api/v1/assets/{id}`、`GET|POST /api/v1/assets/{id}/inheritors`、`DELETE /api/v1/assets/{id}/inheritors/{iid}`
  - `GET|POST|PUT|DELETE /api/v1/inheritors`（访问码仅存 sha256，返回不含）
  - `GET /api/v1/inheritors/{id}/assets`（该继承人绑定的所有资产：资产级 + 经分组，含 binding_id/binding_type 供解绑）
  - `GET|POST /api/v1/categories/{id}/inheritors`、`DELETE /api/v1/categories/{id}/inheritors/{iid}`（分组级继承人，校验分类归属同一用户）
  - `GET|PUT /api/v1/settings/inheritance`（全局继承开关）
  - `GET|POST|PUT|DELETE /api/v1/reminder-templates`（is_preset=1 系统模板只读）
  - `GET /api/v1/reminders`、`POST /api/v1/reminders/{id}/read`
  - `POST /api/v1/inheritance/claim`（无 JWT，event_key+access_code）→ 资产级事件返回 `{"asset_key_wrapped_wk","asset_id","status"}`，全量事件返回 `{"master_key_wrapped","status"}`
  - `GET /api/v1/inheritance/status`、`GET /api/v1/audit-log`
  - `GET /api/v1/admin/stats`、`GET /api/v1/admin/users`、`GET|PUT|DELETE /api/v1/admin/users/{id}`、`GET /api/v1/admin/audit-log`、`GET|PUT /api/v1/admin/config`（requireAdmin）
  - `GET /admin`（内嵌管理后台单页，无鉴权——页面本身只是静态壳，数据全靠 API 鉴权）
- 资产列表不含 `encrypted_data`（元数据），单条含密文 base64；`encrypted_data` 为客户端 AES-256-GCM 加密后的 `base64(nonce‖ciphertext‖tag)`
- 资产请求/响应含可选字段 `asset_key_wrapped_mk` / `asset_key_wrapped_wk`（空串经 nullable() 转 NULL）
- 预设分类为客户端常量（不落库），自定义分类走 API；预设选中即 `category_id=null`（升级路径：服务端种子分类）

## 关键数据流

**注册**：客户端派生 MK → 生成 WK → 包装 MK → 取验证码 → 上传 `{username, email, password, master_key_wrapped, captcha_id, captcha}` → 服务端校验验证码 + 存 argon2id 密码哈希 + 包装密钥

**登录**：取验证码 → `{username|email, password, captcha_id, captcha}` → JWT → 客户端用主密码解出 MK 解锁本地库

**继承触发**（P2）：服务端调度器检测超时 → 升级提醒 → 触发后邮件继承人（含访问码）→ 凭码领取 `master_key_wrapped`
