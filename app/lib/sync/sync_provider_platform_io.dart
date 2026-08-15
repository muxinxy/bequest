import 'ftp_sync.dart';
import 'sftp_sync.dart';
import 'sync_provider.dart';

/// 桌面/移动端:WebDAV/S3/FTP/SFTP 全部支持。
SyncProvider? platformSyncProviderFromConfig(Map<String, dynamic> cfg) {  final type = cfg['type']?.toString();
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
  if (type == 'ftp') {
    final host = cfg['ftp_host']?.toString();
    if (host == null || host.isEmpty) return null;
    final securityName = cfg['ftp_security']?.toString();
    return FtpSyncProvider(
      host: host,
      port: int.tryParse(cfg['ftp_port']?.toString() ?? ''),
      user: cfg['ftp_user']?.toString() ?? '',
      password: cfg['ftp_password']?.toString() ?? '',
      basePath: cfg['ftp_base_path']?.toString() ?? '/bequest',
      security: securityName == 'explicitTls'
          ? FtpSecurity.explicitTls
          : securityName == 'implicitTls'
              ? FtpSecurity.implicitTls
              : FtpSecurity.plain,
    );
  }
  if (type == 'sftp') {
    final host = cfg['sftp_host']?.toString();
    if (host == null || host.isEmpty) return null;
    return SftpSyncProvider(
      host: host,
      port: int.tryParse(cfg['sftp_port']?.toString() ?? '') ?? 22,
      user: cfg['sftp_user']?.toString() ?? '',
      password: cfg['sftp_password']?.toString() ?? '',
      basePath: cfg['sftp_base_path']?.toString() ?? '/bequest',
    );
  }
  return null;
}
