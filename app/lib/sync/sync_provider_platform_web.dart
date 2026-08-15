import 'sync_provider.dart';

/// Web 端:仅支持 HTTP 系协议(WebDAV/S3)。FTP/SFTP 为 socket 协议,
/// 浏览器不支持,返回 null(UI 提示"仅桌面/移动端可用")。
SyncProvider? platformSyncProviderFromConfig(Map<String, dynamic> cfg) {
  final type = cfg['type']?.toString();
  if (type == 'webdav') {
    final url = cfg['url']?.toString();
    if (url == null || url.isEmpty) return null;
    return WebDavSyncProvider(
      url: url,
      user: cfg['user']?.toString() ?? '',
      password: cfg['password']?.toString() ?? '',
      basePath: cfg['base_path']?.toString() ?? '/bequest',
    );
  }
  if (type == 's3') {
    final endpoint = cfg['endpoint']?.toString();
    final bucket = cfg['bucket']?.toString();
    final accessKey = cfg['access_key']?.toString();
    final secretKey = cfg['secret_key']?.toString();
    if (endpoint == null ||
        endpoint.isEmpty ||
        bucket == null ||
        bucket.isEmpty ||
        accessKey == null ||
        accessKey.isEmpty ||
        secretKey == null ||
        secretKey.isEmpty) {
      return null;
    }
    return S3SyncProvider(
      endpoint: endpoint,
      bucket: bucket,
      region: cfg['region']?.toString() ?? 'us-east-1',
      accessKey: accessKey,
      secretKey: secretKey,
      prefix: cfg['prefix']?.toString() ?? 'bequest/',
    );
  }
  // ftp/sftp:web 不支持,返回 null。
  return null;
}
