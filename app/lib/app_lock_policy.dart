/// 应用锁判定纯函数,便于单元测试。
library;

/// 冷启动/进入后台时是否应锁定:锁已启用且存在可校验凭据
/// (云端 jwt 或本地模式主密钥,二者任一即可)。
///
/// 凭据缺失(如已退出登录)时不锁,避免在登录页被锁门卡住。
bool shouldLockOnColdStart({
  required bool lockEnabled,
  required bool hasCredential,
}) =>
    lockEnabled && hasCredential;
