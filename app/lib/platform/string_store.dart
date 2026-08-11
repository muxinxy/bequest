/// 平台无关的字符串存储抽象:
/// - VM/桌面:文件(见 string_store_io.dart);
/// - Web:localStorage(见 string_store_web.dart)。
///
/// 供 Logger(日志)与 LocalVault(加密快照)使用,值本身已是密文/日志,
/// 明文存 localStorage 即可(快照内容已 AES-GCM 加密)。
abstract class StringStore {
  /// 读取;不存在返回 null。
  Future<String?> read();

  /// 覆盖写入(父目录/键自动创建)。
  Future<void> write(String value);

  /// 删除;不存在时静默。
  Future<void> delete();
}
