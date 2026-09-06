# AGENTS.md — 托孤(bequest)

数字资产保管库 + 数字遗嘱("死人开关"式继承交接)。Monorepo:Go 后端 + Flutter 客户端(Android + Web)。**所有用户可见 UI、API 错误、文档均为中英双语(默认中文 + 英文)。** 截至 v0.9.1,仓库已完成全量国际化。

## 目录结构

- `server/` — Go 后端(单二进制,标准库 net/http,Go 1.26)。HTTP API、提醒调度器、继承引擎、内嵌管理页(`admin.html`)与领取页(`claim.html`)、内嵌 Flutter Web 构建。
- `app/` — Flutter 客户端(一套代码 → Android + Web)。`flutter_localizations` + 手写的字典式 L10n。
- `docs/` — `architecture.md`(+ `.en.md`)ADR 决策记录;`progress.md`(中文开发日志)。**改继承/安全相关逻辑前先读 `architecture.md`。**
- `scripts/` — `build.sh`/`build.ps1`(交叉编译)、`test-all-dbs.sh`(三方言回归)。
- `CHANGELOG.md` — 每次发版的中文说明(发版时更新;最新为 v0.9.1)。

## 构建与测试

后端(`server/`):
- `go build ./...`、`go test ./...` — 默认 SQLite,离线,约 20 秒。三方言全绿靠 `TEST_DB_DRIVER=mysql|postgres` + `TEST_DB_HOST/PORT/USER/PASS/NAME`(或 `TEST_PG_*`);本机测试实例:MariaDB 127.0.0.1:3307、PostgreSQL 127.0.0.1:5433(用户/密码/库均为 `bequest`)。全量回归:`../scripts/test-all-dbs.sh`。
- `go vet ./...` 和 `gofmt` 要求保持干净。

Flutter(`app/`):
- `flutter analyze`(忽略约 11 个既有的 web-only 报错:`dart:js_util` 的 URI 误报 + web lint —— "以 flutter build web 为准")。
- `flutter test`(171 个测试)、`flutter build web`、`flutter build apk --debug|--release`。
- Windows 控制台显示 UTF-8 输出会乱码;python 用前先 `$env:PYTHONIOENCODING='utf-8'`,文件检查优先用 Read 工具。

## 数据库架构(关键)

- 三个后端:SQLite(默认)/ MySQL / PostgreSQL。由 `DB_DRIVER` 选择;DSN 用 `DB_DSN` 或 `DB_HOST/PORT/USER/PASS/NAME`。
- 迁移脚本**按方言分目录**:`server/migrations/{sqlite,mysql,postgres}/*.sql`(各 25 个,`//go:embed` 内嵌)。新增 schema 变更必须在**三个目录各加同一个迁移文件**,SQL 要按方言适配(类型/默认值/引号各不相同)。
- 时间戳统一存 TEXT `"2006-01-02 15:04:05"` UTC —— **绝不引入原生 DATETIME/TIMESTAMP 列**;比较都是字符串比较。
- 应用层 SQL 按 SQLite 风格写 `?` 占位符;`server/pgx.go` 注册了 `pgxrw` 驱动,在 PostgreSQL 上于驱动层把 `?` 重写为 `$N`(**不要手写 `$N`**)。方言助手在 `server/db.go`:`dbNow()`、`dbNowAdd()`、`dbMonth()`、`dbGroupConcat()`、`dbDateOneDayLater()`、`uniqueViolation()` —— 日期/字符串函数的 SQL 一律走这些助手,不要裸写 `datetime('now')`、`substr`、`GROUP_CONCAT`、`ON CONFLICT` 等。
- 需要拿新行 id 的 insert:用 `execInsert(db, ...)`(处理 PG 的 `RETURNING id`);PG 上**绝不用** `LastInsertId`。
- `bequest-server backup` 子命令仅支持 SQLite(`VACUUM INTO`);MySQL/PG 用 `mysqldump`/`pg_dump`。
- MySQL 连接需要 `clientFoundRows=true`(幂等更新依赖"匹配行数"语义);`db.go` 和 `auth_test.go` 里的 DSN 构造已带上。

## i18n 约定

- **Flutter**:所有用户可见字符串走 `L10n.tr('中文')` / `L10n.trp('...{x}...', {...})`(在 `app/lib/l10n/app_l10n.dart`)。字典以中文原文为 key,按模块拆分(`_core` 在 app_l10n.dart + `en_pages_{account,asset,inherit,misc,sync}.dart`)。新包的字符串必须加为字典 key;未翻译的 key 优雅降级显示中文。数据格式字符串(导出 JSON/CSV 的 key、文件名、协议字段)**有意不翻译**。语言切换在 设置 → 语言;`api_client.dart` 按界面 locale 发送对应的 `Accept-Language`。
- **服务端 API 错误**:`writeError` 按 `Accept-Language` 头(由 `localize` 中间件解析)经 `server/i18n.go` 的 `errEn` 映射本地化。新增中文错误消息要同步加进 `errEn`,并确保请求经过了 `localize`。
- **调度器/邮件文案**:按用户语言(`users.lang`,迁移 025;API `GET/PUT /api/v1/settings/lang`)。`server/i18n.go` 的 `userLang(db, uid)` + `userMsg(lang, zh)` 本地化兜底文案;主路径是 renderTemplate + 数据库模板。
- **服务端页面**:`admin.html` / `claim.html` 双语,内联 `I18N = {zh:{},en:{}}` 字典 + `data-i18n` 属性 + 中文/English 切换(localStorage `*_lang`)。加字符串时两个字典要同步;内联 JS 提取后用 `node --check` 校验。
- **文档**:用户文档成对出现 `X.md`(中)+ `X.en.md`(英),顶部互链。内部日志(`docs/progress.md`、`CHANGELOG.md`)保持中文 + 英文头部说明 —— 不要整篇翻译。

## 约定与坑

- 后端是 package `main`,单模块 `bequest/server`;`*sql.DB` 显式传进每个 handler 构造器(`newMux(db)`)—— 不用全局应用状态。中间件链在 `main.go`:`localize(cors(rateLimit(newMux(db))))`。
- Go 代码注释通篇中文 —— 新增注释保持同一风格。
- Windows 开发环境:git push 走 Clash 代理 127.0.0.1:7897(已在 git config);Go 模块走 `goproxy.cn`;Flutter pub 走 `storage.flutter-io.cn`。
- **Windows shell**:用 `pwsh`(PowerShell 7,Scoop 安装在 `D:\Scoop\shims\pwsh.exe`)—— 别用 Windows PowerShell 5.1 或 cmd。这里的 Bash 工具是 Windows 上的 BusyBox:不支持 `;` 连接 `&&`、缺它没有的 awk/sed 参数;带嵌套引号的多行 PowerShell `-Command` 字符串会炸 —— 优先写成临时 `.py`/`.ps1` 文件再跑,文件检查用 Read/Edit 工具而非 shell 文本处理。
- **命令链静默中断(重要踩坑)**:多步 `&&` 长链(如 `git add ... && git commit ... && git add ... && git commit ...`)在本机会**中途断掉且不报错**,曾导致发版提交丢失、tag 打在错误提交上。重要操作(commit/tag/push/删除)一律**单条 Bash 分开执行**,事后用 `git log`/`git status` 核实。同理,`gh` 的长数字参数、`--jq` 复杂引号表达式、`for`/`$(...)` 循环会被 shell→cmd 层弄坏(典型报错 `unknown shorthand flag: 'N' in -N`),必须写成临时 `.sh`/`.ps1` 文件执行。
- **控制台乱码 ≠ 文件损坏**:GBK 终端把 UTF-8 输出显示为 `鍚`/`鏂板` 等乱码只是显示问题;内容是否真的异常(如 Release 说明里混入字面 `\n`)要做字节级核实(`git show`、写临时脚本 grep),不要凭乱码"修"文件。
- 发版流程:推 `v*` tag 触发 `.github/workflows/release.yml`(构建二进制 + Docker 多架构 + Android APK + GitHub Release)。**tag 必须打在同时包含 CHANGELOG `## vX.Y.Z` 小节与 `app/lib/pages/about_page.dart` 版本常量更新的提交上**——Release 说明从 tag 处的 CHANGELOG 提取,APK 内「关于」页版本号构建时烘焙,漏一样产物就是错的。Docker 构建前 `app/build/web` 必须存在(workflow 内已自建)。Android APK 用 GitHub Secrets 里的密钥 release 签名(`ANDROID_KEYSTORE_BASE64` 等)—— **绝不提交 keystore**。CI 监控用后台轮询脚本(`gh run view --json status,conclusion` 每 60s),别用 `gh run watch`(参数会被 shell 弄坏)。
- `server/config.json`(系统 SMTP/短信服务商/额度)是 gitignore 的运行时配置;管理后台可在线改写。仅当 config.json 不存在时 `SMTP_*` 环境变量才生效。
- BLOB 列存的是客户端加密后的密文;服务端永远见不到明文(E2E)。不要在服务端解密。
