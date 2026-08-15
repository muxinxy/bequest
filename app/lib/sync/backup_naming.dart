import '../storage/secure_store.dart';
import 'device_name_io.dart'
    if (dart.library.js_interop) 'device_name_web.dart';

/// 备份文件名生成:bequest_<用户名>_<设备名>_<时间戳>.json。
/// 纯函数便于测试;用户名/设备名做安全清洗——保留 Unicode 字母/数字/_-,
/// 空白与符号替换为下划线(中文账户名保留,如"张三")。
String buildBackupFileName({
  required String username,
  required String deviceName,
  required String timestamp,
}) {
  final user = _cleanForMatch(username);
  final device = _cleanForMatch(deviceName);
  final parts = [
    'bequest',
    if (user.isNotEmpty) user,
    if (device.isNotEmpty) device,
    timestamp,
  ];
  return '${parts.join('_')}.json';
}

/// 设备名:io 端取设备型号(Android 手机型号/桌面 hostname),web 回退 'web'。
Future<String> deviceName() async => platformDeviceName();

/// 当前账户名:云端用 [cloudUsername](已由调用方从 /me 获取);
/// 本地模式用当前激活账户的名称(如"张三");都取不到回退 'local'。
Future<String> currentAccountName({
  String? cloudUsername,
  SecureStore? store,
}) async {
  if (cloudUsername != null && cloudUsername.isNotEmpty) return cloudUsername;
  final s = store ?? SecureStore();
  try {
    final activeId = await s.readActiveLocalProfileId();
    if (activeId != null && activeId.isNotEmpty) {
      final profiles = await s.readLocalProfiles();
      for (final p in profiles) {
        if (p['id'] == activeId) {
          final name = p['name']?.toString().trim();
          if (name != null && name.isNotEmpty) return name;
        }
      }
    }
  } catch (_) {
    // 读取失败回退 local。
  }
  return 'local';
}

/// 该文件名是否属于当前账户:仅匹配 `bequest_<清洗后账户名>_` 前缀的备份。
/// 恢复列表/轮转删除只操作本账户的文件,不碰其他账户(或多端)的备份。
bool isBackupForAccount(String fileName, String accountName) {
  final prefix = 'bequest_${_cleanForMatch(accountName)}_';
  return fileName.startsWith(prefix);
}

String _cleanForMatch(String s) => s
    .replaceAll(RegExp(r'[\s!@#\$%^&*()+=,.;:"' r"'"
        r'<>?/\\|[\]{}`~]'), '_')
    .replaceAll(RegExp(r'_+'), '_')
    .replaceAll(RegExp(r'^_|_$'), '');
