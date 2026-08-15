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
| UX 反馈 | 分类类型化（实体/虚拟）+ 可编辑/删除（预设转服务端种子）、资产删除、类型筛选、搜索、设置收纳二级页、锁增强（退出/超时时机 + 图案锁 + 解锁免主密码） | ✅ 完成 |
| UX 反馈 2 | 移除实体/虚拟 UI、锁设置改名应用锁、生物识别失败原因提示、应用锁/主密钥限次（5 次→60s）、主密码提示语、日志增强（按天轮转 + 请求日志 + 埋点）、Asset id 往返修复 | ✅ 完成 |
| UX 反馈 3 | MainActivity→FlutterFragmentActivity（修生物识别 no_fragment_activity 根因）、图案限流修复（<4 点也计数）、应用锁主密码绕过、修改主密码/提示语（本地重加密 + 云端 master_key_wrapped 更新 API） | ✅ 完成 |
| 后置 | 多继承人优先级、定时释放、生前共享、数字遗言、Excel 导出、Web/iOS/鸿蒙 | ⏳ |
| Web 客户端 + 资产级继承 | Web 编译(Android+Web)、服务端同源托管、web 派生 WASM 性能、资产级密钥隔离、手动锁定、加密导出/覆盖导入、客户端时区、模板变量提示 | ✅ 完成 |
| v0.4.1 | 分组继承 + 重置主密码 | Android 网络权限修复、Web 锁定修复、分组视图与搜索、分组继承人、继承开关、继承人绑定资产多选解绑、账号密码重置主密码 | ✅ 完成 |
| v0.5.0 | 管理后台 + 验证码 + 限流 + 账号功能 | 管理后台（ADR-16）、账号禁用/角色、算术验证码（ADR-17）、按 IP 限流（ADR-18）、改用户名/邮箱、邮箱登录、忘记密码验证码重置、注册实时查重/双密码/提示语、登录预检、服务器地址记忆、web 注册/本地模式修复 | ✅ 完成 |
| v0.6.1 | 跨设备/邮件修复批次 | 同设备重复登录不再弹恢复密钥（退出登录可选清除密钥）、SMTP 465 隐式 TLS + 信封裸邮箱 + From/To RFC5322（修 QQ 550）、用户自配 SMTP 失败回退系统、重置验证码优先用户 SMTP、发送验证码 60s 冷却 + 防重复点击、多端密钥不一致解密失败提示重登 | ✅ 完成 |
| v0.6.2 | 本地模式/应用锁/提示语修复批次 | 本地模式列表可返回登录页、未分类批量移动修复（字符串分组 id）、退出本地模式清应用锁、锁屏跳过按钮（独立 Navigator 导航架构修复）、主密码提示语（标准槽同步 + 锁屏主界面显示 + 本地账户兜底）、应用锁设置页开关 | ✅ 完成 |
| v0.6.3 | 同步/备份增强批次 | 备份文件名自动生成、恢复弹窗文件列表（PROPFIND/List + 删除）、自动备份调度（间隔/开退应用触发）、备份轮转、同步配置按账户隔离、WebDAV/S3 列文件与删除、测试连接单请求提速、阿里云盘网关兼容（大写 D: 前缀、302 重定向 no-referrer 绕过防盗链）、web 启动白屏修复 | ✅ 完成 |
| v0.6.4 | S3 修复 + FTP/SFTP | FTP/SFTP 同步（桌面/移动端,Web 隐藏）、S3 对齐 WebDAV（下载/列表走平台请求）、S3 下载 403（CORS preflight,GET 去 Content-Type）、S3 列表 403（SigV4 query 签名修复）、备份文件名用本地账户名称、保存配置合并（WebDAV↔S3 互不覆盖） | ✅ 完成 |

## 当前状态（v0.6.4：S3 修复批次完成）

**v0.6.4 已交付**：
- **S3 对齐 WebDAV**：S3 download/listFiles 走共享平台请求（302 跟随 + web 端 no-referrer）,兼容 S3 兼容网关（如阿里云盘 S3 端点经 CDN 重定向 + OSS 防盗链）
- **S3 下载 403 修复（CORS preflight）**：`_signedHeaders` 原固定带 `Content-Type: application/json`——GET 无 body 却带此头 → web fetch 非简单请求 → 强制 preflight → 跨域 OSS 签名地址 preflight 失败 403。upload 才带 Content-Type,GET/DELETE 不带
- **S3 列表 403 修复（SigV4 签名 bug）**：`listFiles` 带 query,原签名把 query 拼进 canonical URI（规范要求独立一行）→ 验签不匹配。`s3AuthorizationHeader` 加 `canonicalQuery` 参数,query 按键排序 + 键值编码
- **备份文件名用本地账户名称**：`currentAccountName` 共享函数——云端用户名优先,本地模式取当前激活账户名（如"张三"）;auto_backup 复用
- **保存配置合并**：`_save` 与已存配置合并,WebDAV/S3 两套字段互不覆盖（此前保存 S3 会丢 WebDAV 配置）
- 验证：Flutter 152 测试全过（新增 S3 302 下载、带 query 签名、download 无 Content-Type、currentAccountName、配置合并）;web 构建成功


**v0.6.3 已交付**：
- **备份文件名自动生成**：`bequest_<用户名>_<设备名>_<时间戳>.json`（用户名从 /me 获取、本地回退 local;设备名取 Platform.localHostname、web 回退 web;特殊字符清洗）——移除手动文件名输入
- **恢复弹窗文件列表**：点恢复 → 列出远端备份（文件名/修改时间/大小）+ 恢复/删除按钮,删除后刷新;列表不可用回退手动输入（预填最近备份名）
- **自动备份**：间隔 12 档（关/1m/5m/15m/30m/1h/2h/6h/12h/24h/开应用/退应用）+ 最大数量 6 档（1/3/5/10/20/50）;调度器（auto_backup.dart）后台 Timer + 生命周期钩子,main() 启动;备份失败静默记日志
- **备份轮转**：超过最大数量删最旧（手动/自动均执行）
- **WebDAV/S3 列文件与删除**：WebDAV PROPFIND Depth:1 + DELETE（兼容大写 D: 命名空间、href URL 解码）;S3 ListObjectsV2 + DeleteObject（SigV4）
- **同步配置按本地账户隔离**：此前所有本地账户共享同一份配置;现 `bequest_sync_config_<账户id>` 独立,云端模式用全局键
- **测试连接提速**：单请求 PUT probe 5s 必达（原串行 MKCOL+PUT+DELETE 最坏 20s）;401/403 明确报认证失败,409 视为可达
- **阿里云盘 WebDAV 网关兼容**：OpenList 返回大写 `<D:>` 前缀（解析正则原只认小写 d: → 列表恒空）;文件 GET 302 到 OSS 签名地址——Web 端原生 fetch + `referrerPolicy: 'no-referrer'` + redirect follow（跨域剥 Authorization、无 Referer → 绕过 OSS 防盗链 403）,桌面端手动跟随;web 启动白屏修复（`WidgetsFlutterBinding.ensureInitialized()`）
- 验证：Flutter 146 测试全过（新增 PROPFIND 大写 D: 解析、list/delete、302 下载、文件名生成、自动备份配置、同步配置隔离）;web 构建成功

**v0.6.2 已交付**：
- **本地模式列表可返回登录页**：入口页移除 PopScope 禁用返回 + 恢复 AppBar 返回箭头;进入本地主页后仍只能走「退出本地模式」
- **未分类批量移动修复**：`AssetRepository.moveAssets`/`deleteCategory` 的 categoryId/moveTo 改为字符串 id——云端 int64 与本地 `'L<时间戳><序号>'` 的格式差异此前被 `int.tryParse` 抹平成 null,导致本地模式移动/删除分组时资产被误置未分类
- **退出本地模式清应用锁**：`_exitLocal` 与锁屏跳过调用 `clearAppLock()`(新增,清 PIN/图案/开关),回登录页不再被锁屏拦截;本地账户数据保留
- **主密码提示语全链路**：创建/激活本地账户同步 hint 到标准槽,退出恢复云端提示语(含 pre-local hint 槽位);锁屏主界面直接显示提示语(不再只依赖弹窗);读取时标准槽为空回退当前激活本地账户(覆盖旧版账户)
- **应用锁设置页开关**：SwitchListTile 总开关——关闭即清除全部解锁凭据并禁用
- **锁屏跳过按钮**：忘记解锁方式不再锁死——跳过 = 退出登录(云端)/退出本地模式(本地)回登录页;架构修复:锁屏在独立 Navigator 覆盖层无法操作主 Navigator,新增全局 `appNavigatorKey` + `LockGate.exitToLogin()`
- 验证：Flutter 130 测试全过(新增提示语兜底/主界面显示/跳过按钮/字符串 id 移动/删除/hint 槽位/clearAppLock)

## 当前状态（v0.6.1：跨设备/邮件修复批次完成）

**v0.6.1 已交付**：
- **登录不再重复恢复密钥**：根因——退出登录 `clearAll()` 把主密钥/盐/WK 全删，同设备每次登录都被当成"新设备"弹恢复对话框。修复：加密凭据与服务器地址同属设备级状态，退出登录保留；恢复对话框触发条件改为「无 MK（真新设备）或本机盐 ≠ 服务端盐（主密码已在其他设备改过）」
- **退出登录可选清除密钥**：主页退出弹确认框——「保留密钥」（默认，下次登录免恢复）或「清除密钥」（公共电脑/彻底退出，下次登录重新恢复）；锁屏退出出口本就是"无主密钥"分支，无需弹窗
- **SMTP 465 隐式 TLS**：`net/smtp.SendMail` 只支持 STARTTLS，QQ/163 授权码默认 465 端口直接失败；重写 `sendViaServer` 手动拨号——465 走 `tls.Dial`，587 走 STARTTLS，完整 client 流程替代 SendMail
- **QQ 550 From header 修复**：`buildMessage` 原先把 From/To 头整体 RFC2047 编码（无裸邮箱，QQ 严格校验拒收）；改为仅编码显示名、保留可解析邮箱（`From: =?UTF-8?B?名?= <noreply@qq.com>`）；信封 `MAIL FROM` 剥离显示名
- **用户 SMTP 失败回退系统**：`sendMailCustom` 原吞错误、`sendCustomForUser` 无条件返回 true——用户自配 SMTP 失效时系统 SMTP 没机会尝试；改为仅真发送成功才 true，失败回退
- **忘记密码验证码优先用户 SMTP**：reset-request 与提醒邮件同策略（用户自配 → 系统回退）；未知邮箱仍返回 200 不发码（防枚举，刻意保留）
- **防重复点击/冷却**：发送验证码按钮 60s 倒计时；SMTP 设置保存、同步页 4 个操作按钮补 `_busy`/`_saving` 守卫
- **多端密钥不一致提示重登**：云端资产解密失败（主密码已在其他设备改）弹「退出登录重新登录」对话框，登录后走恢复流程重派生密钥
- 验证：Flutter 123 测试全过（新增 clearAll keepKeys 两态、退出保留/清除）、Go 全测试过（新增假 SMTP 服务器完整会话、RFC5322 From 头、错误传播、回退链、reset-request 防枚举）

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
- 后端：`POST /api/v1/auth/register`、`/login`、`GET /api/v1/me`；JWT HS256 24h（`JWT_SECRET` 环境变量）；argon2id PHC 哈希；SQLite（modernc 纯 Go）自动迁移（schema_migrations 表），迁移 SQL 通过 `go:embed` 编译进二进制
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
- **迁移部署**：SQL 迁移通过 `go:embed` 编译进后端二进制，Docker 运行时无需挂载 `migrations/` 目录；仅需持久化 `/data` 数据卷
- **部署**：`server/Dockerfile`（多阶段 alpine，非 root，WORKDIR=/data 落卷）+ `docker-compose.yml` + `scripts/build.sh`（5 平台交叉编译）/`build.ps1` + `.github/workflows/release.yml`（tag v* 触发：矩阵构建 + buildx 双架构推 GHCR `ghcr.io/muxinxy/bequest` + softprops 发 Release 资产，`"on":` 加引号规避 YAML 1.1 布尔陷阱）
- 验证：后端 22 测试全绿（+4：SMTP CRUD 加密存取、version、无配置轮询、用户 SMTP 优先不 panic）；前端 29 测试全绿（+14：备份 round-trip/篡改、WebDAV MockClient、SigV4 AWS 向量、SMTP 设置）；端到端实测 SMTP API 全链路（密码不泄露、空密码保留旧值、version dev）

**仍后置**：FTP/SFTP 同步真实现、SMS/电话 API 真接入、网盘扩展（坚果云/百度云等走 WebDAV 即可）、Excel 导出、多继承人优先级、定时释放、生前共享、数字遗言、Web/iOS/鸿蒙、会员开通后台

## 当前状态（v0.4.0：Web 客户端 + 资产级继承完成）

**v0.4.0 已交付**：
- **Web 客户端**：`flutter create --platforms=web` 生成 web/ 平台，`flutter build web` 编译成功；Go 服务端 `web.go` 静态托管 build/web（`webDir` 自动探测 `WEB_DIR`/web/app/build/web，`spaHandler` 真实文件直出 + `/api/*` 404 + SPA 回退 index.html）；CORS 中间件（middleware.go）；Dockerfile/compose/release.yml context 改仓库根 + CI 先 `flutter build web`；端到端 Chrome 无头验证 flutter-view 渲染
- **web 派生性能**：根因 argon2 pointycastle `Register64` 纯 JS 实测 33s/次（注册/导出/导入卡死）；改自托管 hash-wasm WASM（web/assets/hash-wasm.js，UMD 单文件无 CDN），实测 ~0.3s（快 113 倍）；条件导入 `key_derivation_io.dart`（VM pointycastle）/`key_derivation_web.dart`（web WASM）；`deriveMasterKey` 改 async，6 处调用方加 await；锚值测试 `web_argon2_compat_test.dart` 锁定派生结果与旧实现逐字节一致
- **资产级密钥隔离（ADR-12）**：迁移 005；每资产 AK，内容用 AK 加密，AK 双包装（`asset_key_wrapped_mk` 号主/`asset_key_wrapped_wk` 继承人）；`asset_inheritors` 表 + CRUD API；`triggerInheritance` 按资产建事件（trigger_days 独立或全局线）；claim 资产级事件只发 `asset_key_wrapped_wk`（端到端实测验证：领取只拿指定资产密钥）；老资产渐进兼容（`decryptAssetData` 回退 MK）；客户端 AssetInheritorsPage UI（资产编辑页 AppBar 入口）；`asset_key_isolation_test.dart` 4 测试
- **手动锁定**：`LockGate.lockNow()` 静态入口（有凭据即锁，忽略 lock_enabled 开关）+ home_page AppBar 锁定按钮
- **加密导出/覆盖导入**：export_page encrypt 参数（.beq，`encryptSensitiveData` 复用）；import_page overwrite 参数 + 加密文件自动解密检测（`parseExportFile` 失败再试 decrypt）；settings_page 两个确认框
- **客户端时区**：utils/time_format.dart `formatServerTime`（UTC 无标记 +Z→toLocal）；替换 audit_page/inheritance_status_page/reminders_page 共 5 处；expiry_date 纯日期不转
- **模板变量提示**：reminder_templates_page 编辑弹窗加 {name}/{date}/{days} 说明
- 验证：Flutter 119 测试（新增 asset_key_isolation 4 + web_argon2_compat 1）、Go 全测试、flutter build web、端到端（注册→资产双包装→绑定继承人→130 天触发→claim 拿资产密钥）

**实现偏差与踩坑（v0.4.0）**：
- hash-wasm 采用**下载后自托管**（web/assets/hash-wasm.js，UMD 单文件），避免运行时依赖 CDN（内网/离线部署不可用）
- `dart:js_util` 在 flutter analyze 的 VM 视角误报（`unavailable` 提示），但 web 编译正常——以 `flutter build web` 为准

## 当前状态（v0.4.1：分组继承 + 重置主密码完成）

**v0.4.1 已交付**：
- **Android 网络权限修复**：release 包无网络——main AndroidManifest 缺 INTERNET（debug/profile 有）+ Android 9+ 禁明文 HTTP。修复：main manifest 加 `uses-permission INTERNET` + application `usesCleartextTraffic="true"`。这是"手机浏览器能访问但 APP 连接失败"的根因
- **Web 锁定修复**：AppLockScreen 自动放行条件缺 `_hasMasterKey`（仅设主密码的用户点锁定立即自动解锁=锁定无效）；`LockGate.lockNow` 改为无条件锁定（锁屏自身处理无凭据）
- **分组视图**：home_page 资产按分组展示（`_GroupedAssetList` + `_collapsedGroups` 折叠），分组标题显示资产数
- **搜索增强**：`filterAssets` 加 `categoryNames` 参数，搜索同时匹配分组名和资产名
- **分组继承人**：迁移 007 `category_inheritors` + CRUD API（GET/POST/DELETE `/categories/{id}/inheritors`）+ 调度器集成（资产无资产级绑定时按分组交接）+ CategoryInheritorsPage（分类管理页入口）
- **继承开关**：迁移 006 `users.inheritance_enabled` + GET/PUT `/settings/inheritance` + 调度器 `processEscalation` 过滤 `inheritance_enabled=1` + 设置页 SwitchListTile（本地模式禁用）
- **继承人绑定资产**：GET `/inheritors/{id}/assets`（UNION 资产级+分组级，含 binding_id/binding_type）+ InheritorAssetsPage（选择继承人→资产列表→多选解绑）
- **重置主密码**：`reset_master_password.dart` + 页面（账户密码→新 MK/WK/salt→更新云端 master_key_wrapped→云端资产保留元数据清空凭据换新 AK→本地 vault 重建）→ 复用 PUT `/settings/master-key` 零后端新增
- 验证：Flutter 119 测试全过、Go 全测试过、`flutter build web` 成功；继承开关 API 端到端 GET/PUT 200；分组继承绑定关系 SQL 验证正确
- 备注：完整"分组继承触发→claim"端到端当时卡在测试环境（旧进程占 8080 端口，新进程 scheduler 未接管），非代码问题——分组继承 SQL/逻辑已单独验证

## 当前状态（v0.5.0：管理后台 + 验证码 + 限流 + 账号功能完成）

**v0.5.0 已交付**：
- **管理后台（ADR-16）**：`/admin` 内嵌单页（Go 托管，零新依赖、无构建）；用户/会员/管理员/资产等统计仪表盘；用户搜索/会员开通/管理员任命/禁用/删除（自保护）；系统配置（SMTP 列表 + 免费资产上限，热重载）；全量审计日志；`ADMIN_USERNAME`/`ADMIN_PASSWORD` 引导首个管理员；`users.role`/`users.disabled` + `requireAdmin`（DB 实时校验）；禁用账号拒绝登录与全部 API
- **算术验证码（ADR-17）**：注册/登录加验证码（`7 + 7 = ?`），服务端生成、答案 sha256 哈希存内存（5 分钟过期、一次性防重放）；前端算式卡片点击刷新、错误自动刷新重试
- **按 IP 限流（ADR-18）**：内存滑动窗口中间件——登录/注册 5 次/分钟/IP，其他 API 120 次/分钟/IP；429 + 窗口自动恢复；支持 X-Forwarded-For
- **账号功能**：设置页改用户名/邮箱（PUT /me，409 冲突提示）；登录支持用户名或邮箱；注册页用户名/邮箱实时查重（GET /auth/check、/auth/check-email，防枚举）；忘记密码邮箱验证码重置（6 位、10 分钟、哈希存储；POST /auth/reset-request + /auth/reset）
- **注册表单增强**：登录密码/主密码均输入两次；主密码提示语；主密码≠登录密码；格式边输边即时校验
- **登录/注册预检**：点击后先 GET /healthz（2s 超时），服务器不可达立即提示，不再转圈
- **服务器地址记忆**：最近 5 条 chip 快捷填入/清除；去掉测试连接按钮，进入/保存时自动测，绿/红指示灯
- **Web 注册/本地模式设置主密码修复**：根因 web argon2 绑定 `js_util.callMethod(argon2id,'call',[options])` → JS `.call()` 把参数当 thisArg 丢参，hash-wasm 收空报 `Invalid options parameter`；改 `callMethod(hashwasm,'argon2id',[options])`，Node 加载编译产物验证锚值一致
- 验证：Flutter 119 测试全过、Go 全测试过（测试 helper 自动注入验证码）、`flutter build web` 成功；端到端——验证码错 400/对 201、连续登录第 4 次 429、65s 后恢复、改用户名 200、错误重置码 401

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

# Web 客户端（同套代码编译，服务端同源托管）
cd D:\Documents\Code\bequest\app
flutter build web
cd D:\Documents\Code\bequest\server
go run .                    # 浏览器访问 http://localhost:8080
```

## 决策变更记录

- 2026-08-09：锁定方案 A（继承时发放密钥）、免费继承保证送达、MVP 仅 Android
- 2026-08-09：产品定名「托孤」（英文 bequest），monorepo 结构（app/ + server/）
- 2026-08-09：P0 完成——账号注册/登录、JWT + argon2id、主密码派生 + 密钥安全存储、SQLite 自动迁移
- 2026-08-09：**自托管同步无需登录**——新增 LocalVault（本地加密快照 `vault.bq`，主密钥 AES-GCM）；同步优先读本地快照、恢复未登录时落本地；登录页新增「自托管同步(无需登录)」入口；README 补齐部署/Release 文档
- 2026-08-09：**发布 v0.1.0**——tag 推送触发 GitHub Actions（5 平台二进制 + GHCR 双架构镜像 + Release 资产）
- 2026-08-09：**云/本地双模存储**——`AssetRepository` 抽象（Cloud/Local 双实现）+ `RepositoryFactory`；不登录可进本地模式（设置主密码 → 本地加密库全量 CRUD）；登录页新增「进入本地模式」；`ApiConfig` 服务器地址可配置（设置页保存 + 测试连接）；`extractBackupJsonAny` 支持「主密码 + 备份内 salt」跨设备恢复；三层权益矩阵（访客 20 条/免费 50 条/会员不限）UI 徽章 + 资产上限拦截；云↔本地切换迁移（拉取/上传 + 进度提示）；Release 新增 android job（Flutter APK 三 ABI → Release 资产）
- 2026-08-11：**v0.4.0**——Web 客户端（同套代码编译，服务端托管）、资产级密钥隔离（ADR-12，每资产独立密钥+继承人绑定+按资产领取）、web 派生 WASM 性能修复、手动锁定/加密导出/覆盖导入/时区/模板提示
- 2026-08-11：**v0.4.1**——Android release 网络权限修复（INTERNET+明文 HTTP）、Web 锁定修复、分组视图/搜索、分组继承人（ADR-12 扩展）、继承开关（ADR-14）、重置主密码（ADR-15）、继承人绑定资产
- 2026-08-12：**v0.5.0**——管理后台（ADR-16）、算术验证码、IP 限流、忘记密码、账号资料修改、Web argon2 派生修复
- 2026-08-12：**v0.6.0**——跨设备密钥恢复（ADR-17）、管理后台 2FA 与继承安全（ADR-18）、本地多账户（ADR-19）、分组增强（排序/删除保护/合并/批量整理/继承预览）、密码体系（登录后改密 + token_version 失效、忘记密码加固、主密码修改/重置盐同步修复）、继承人 Web 领取页（/claim）、72h 反悔窗口、管理后台增强（用户资产明细/CSV 导出/provider 配置/时区显示）、运维（healthz 查 DB/备份命令/PORT env）
- 2026-08-12：**v0.6.1**——同设备登录免重复恢复密钥（加密凭据随退出保留 + 可选清除）、SMTP 465 隐式 TLS 与信封裸邮箱、From/To RFC5322 头（修 QQ 550）、用户 SMTP 失败回退系统、重置验证码优先用户 SMTP、发送验证码 60s 冷却、同步/SMTP 按钮防连点、多端密钥不一致解密失败提示重登
- 2026-08-13：**v0.6.2**——本地模式入口可返回登录页、未分类批量移动/删除分组 moveTo 改字符串 id（修本地模式误置未分类）、退出本地模式清应用锁、锁屏跳过按钮（全局 appNavigatorKey + LockGate.exitToLogin 修独立 Navigator 导航）、主密码提示语（标准槽同步 + 锁屏主界面显示 + 本地账户兜底）、应用锁设置页开关
- 2026-08-14：**v0.6.3**——备份文件名自动生成（bequest_用户名_设备名_时间戳）、恢复弹窗文件列表（WebDAV PROPFIND / S3 ListObjectsV2 + 删除）、自动备份调度（12 档间隔 + 开退应用触发 + 最大数量轮转）、同步配置按本地账户隔离、测试连接单请求提速、阿里云盘网关兼容（大写 D: 前缀解析、302 重定向 no-referrer 绕过 OSS 防盗链）、web 启动白屏修复（WidgetsFlutterBinding.ensureInitialized）
- 2026-08-14：**v0.6.4**——S3 对齐 WebDAV（下载/列表走平台请求,302 跟随 + no-referrer）、S3 下载 403（GET 去 Content-Type 避免 CORS preflight）、S3 列表 403（SigV4 canonical query 独立一行修复）、备份文件名用本地账户名称（currentAccountName）、保存配置合并（WebDAV/S3 字段互不覆盖）
- 2026-08-15：**v0.6.4**——FTP/SFTP 同步（桌面/移动端,Web 条件导入排除）、S3 修复（CORS preflight 去 Content-Type、SigV4 query 签名）、备份文件名用本地账户名、保存配置合并
