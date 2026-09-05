# 托孤 (bequest) 客户端

Flutter 编写的数字资产保险箱客户端：同一套代码编译 **Android + Web**。端到端加密、应用锁、本地模式、自托管同步（WebDAV/S3）、继承交接与中英文界面。

> English: [README.en.md](README.en.md) · 服务端见 [../server/README.md](../server/README.md)

## 技术要点

- **端到端加密**：主密码 Argon2id 派生 AES-256 主密钥；资产敏感字段加密后上传，服务端不见明文。
- **密钥派生**：Android/桌面走 pointycastle（纯 Dart）；Web 走自托管 WASM（`web/assets/hash-wasm.js`，~0.3s）。
- **本地模式**：不登录也可用（多本地账户、加密本地库）。
- **自托管同步**：WebDAV/S3 加密备份，凭据仅存本机。
- **平台存储抽象**：`lib/platform/` 下 io/web 双实现（string_store / file_share）。
- **中英文**：`lib/l10n/app_l10n.dart` 字典 + 设置页语言切换。

## 环境要求

- Flutter 3.44+（stable），Dart 3.12+
- Android：JDK 17、Android SDK（release 需要签名 keystore）
- 国内镜像（可选）：`PUB_HOSTED_URL=https://pub.flutter-io.cn`、`FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`

## 运行与联调

```bash
cd app
flutter pub get

# 连接本地后端(模拟器用 10.0.2.2 访问宿主机)
flutter run                      # 默认 Android 模拟器;进入登录页后服务器地址填 http://10.0.2.2:8080

# 直接指定后端地址调试(Android 真机填局域网 IP)
# 登录页/设置 → 服务器地址 可改;release 包已含网络权限与明文 HTTP 支持
```

Web 版通常由服务端同源托管（无需单独跑）：

```bash
flutter build web                # 产物在 build/web
cd ../server && go run .         # 浏览器打开 http://localhost:8080
```

## 测试与检查

```bash
flutter analyze                  # 静态检查(web 专属条件导入在 VM 视角有少量已知误报)
flutter test                     # 单元/组件测试(test/ 下 33 个文件)
flutter build web                # Web 产物
flutter build apk --debug        # Android debug
flutter build apk --release      # Android release(需签名配置,见仓库根 README 发布章节)
```

## 目录结构

```
lib/
├── main.dart             # 入口:主题/语言/路由/应用锁(LockGate)
├── api/                  # HTTP 客户端、API 配置(服务器地址)
├── crypto/               # 主密码派生、加解密、恢复密钥
├── l10n/                 # 中英文翻译字典
├── models/               # 数据模型
├── pages/                # 页面(登录/主页/资产/继承/设置/同步…)
├── platform/             # 平台抽象(io/web 条件导入)
├── repository/           # 云/本地资产仓储(RepositoryFactory)
├── storage/              # secure storage(Keystore/localStorage)、LocalVault
├── sync/                 # WebDAV/S3 自托管同步、自动备份调度
├── utils/ widgets/       # 工具与通用组件
test/                     # 单元与组件测试
```

## 功能速览

资产 CRUD/分组/回收站/搜索 · 到期提醒 · 继承(资产级/分组级/全局开关/领取状态) · 导入导出(JSON/加密 .beq/Excel) · 应用锁(PIN/图案/生物识别) · 多本地账户 · WebDAV/S3 加密备份 · 会员权益 · 中英文界面
