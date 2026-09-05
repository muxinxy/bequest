# 托孤 (bequest) 服务端

Go 编写的数字资产保险箱 + 数字遗嘱后端：HTTP API、提醒调度、继承交接、管理后台。单二进制，SQLite / MySQL / PostgreSQL 三种数据库可选，中英文界面与错误消息。

> English: [README.en.md](README.en.md) · 部署详文: [README-deploy.md](README-deploy.md) · 仓库总览见 [../README.md](../README.md)

## 快速开始

```bash
# 本地开发(默认 SQLite,监听 :8080,首次启动自动建库 data/bequest.db)
go run .

# 指定数据库(见下方「数据库」)
DB_DRIVER=postgres DB_USER=bequest DB_PASS=secret DB_NAME=bequest go run .

# 浏览器入口
#   http://localhost:8080        Flutter Web 客户端(需先 cd ../app && flutter build web)
#   http://localhost:8080/admin  管理后台
#   http://localhost:8080/claim  继承人领取页(无需登录)
```

## 数据库

`DB_DRIVER` 选择后端，默认 `sqlite`；迁移脚本按方言内嵌于二进制，启动自动执行（记录于 `schema_migrations`）。

| 变量 | 默认 | 说明 |
|---|---|---|
| `DB_DRIVER` | `sqlite` | `sqlite` / `mysql` / `postgres` |
| `DB_DSN` | 空 | 完整连接串；设置后忽略下方 `DB_*` |
| `DB_HOST` / `DB_PORT` | `127.0.0.1` / `3306`(mysql) `5432`(pg) | 地址 |
| `DB_USER` / `DB_PASS` | `bequest` / 空 | 账号 |
| `DB_NAME` | `bequest` | 库名 |

> `backup` 子命令（`bequest-server backup`）仅 SQLite 可用（VACUUM INTO）；MySQL/PG 请用 `mysqldump` / `pg_dump`。

## 环境变量

| 变量 | 必填 | 说明 |
|---|---|---|
| `JWT_SECRET` | **生产必填** | JWT 签名密钥（HS256）。未设回退 dev 密钥，可被伪造 token |
| `ENCRYPTION_KEY` | **生产必填** | 加密 SMTP 密码等敏感配置的 AES 密钥 |
| `SMTP_HOST/PORT/USER/PASS/FROM` | 否 | 系统邮件兜底（无 config.json 时生效） |
| `ADMIN_USERNAME/ADMIN_PASSWORD` | 否 | 启动时引导/提升首个管理员 |
| `PORT` | `8080` | 监听端口 |
| `WEB_DIR` | 自动探测 | Flutter Web 静态目录（`WEB_DIR` > `./web` > `app/build/web`） |
| `DATA_DIR` | `data` | 数据目录 |

## 邮件配置（三层，优先级从高到低）

1. **管理后台 → 系统配置**：编辑后写入运行目录 `config.json` 并热重载（推荐，含 SMTP/SMS/额度/阶梯）。
2. `SMTP_*` 环境变量：仅当 `config.json` 不存在时作为单服务器兜底。
3. 用户级 SMTP（App 设置 → 邮箱发件设置）：存数据库，提醒邮件优先走它，失败回退系统通道。

## 常用运维

```bash
# 启动
go run . 或 ./bequest-server

# 健康检查(查 DB 可达)
curl http://localhost:8080/healthz

# 备份(SQLite)
./bequest-server backup     # 生成 bequest-backup-<时间戳>.db

# 版本
curl http://localhost:8080/api/v1/version
```

## 部署

- Docker Compose（推荐）：见 [docker-compose.yml](docker-compose.yml)，先建 `.env`（`JWT_SECRET`/`ENCRYPTION_KEY` 必填）。生产远程拉镜像运行请使用**不含 `build:` 段**的 compose 或 `docker run`（见仓库根 README 部署章节）。
- 二进制交叉编译：`../scripts/build.sh`（5 平台）或 `../scripts/build.ps1`（Windows）。
- 详细部署说明（中/英）：[README-deploy.md](README-deploy.md)。
