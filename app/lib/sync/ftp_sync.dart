import 'dart:convert';
import 'dart:io';

import 'package:ftpconnect/ftpconnect.dart';

import 'sync_provider.dart';

/// FTP 加密方式。
enum FtpSecurity {
  /// 禁用加密(明文,默认 21 端口)。
  plain,

  /// 显式 SSL/TLS(FTPES,21 端口 STARTTLS 升级)。
  explicitTls,

  /// 隐式 SSL/TLS(FTPS,990 端口直接 TLS)。
  implicitTls,
}

/// FTP 同步提供方。基于 ftpconnect(socket 协议,仅桌面/移动端,web 不支持)。
/// ftpconnect 的 upload/download 基于本地 File,备份数据是内存字符串,
/// 用临时文件中转。
class FtpSyncProvider implements SyncProvider {
  FtpSyncProvider({
    required this.host,
    required this.user,
    required this.password,
    this.port,
    this.basePath = '/bequest',
    this.security = FtpSecurity.plain,
    this.timeoutSeconds = 15,
  });

  final String host;
  final int? port;
  final String user;
  final String password;
  final String basePath;
  final FtpSecurity security;
  final int timeoutSeconds;

  @override
  String get name => 'FTP';

  /// 建立连接并登录。
  Future<FTPConnect> _connect() async {
    final ftp = FTPConnect(
      host,
      port: port,
      user: user,
      pass: password,
      timeout: timeoutSeconds,
      securityType: switch (security) {
        FtpSecurity.plain => SecurityType.ftp,
        FtpSecurity.explicitTls => SecurityType.ftpes,
        FtpSecurity.implicitTls => SecurityType.ftps,
      },
    );
    final ok = await ftp.connect();
    if (!ok) throw SyncException('FTP 连接失败($host:$port)');
    return ftp;
  }

  /// 进入 basePath;不存在则创建。
  Future<void> _ensureBasePath(FTPConnect ftp) async {
    final path = basePath.replaceAll(RegExp(r'^/+|/+$'), '');
    if (path.isEmpty) return;
    // 逐级 mkdir(已存在会返回 false,忽略)。
    for (final seg in path.split('/')) {
      if (seg.isEmpty) continue;
      await ftp.makeDirectory(seg);
      await ftp.sendCustomCommand('CWD $seg');
    }
  }

  @override
  Future<void> upload(String remotePath, String data) async {
    final ftp = await _connect();
    try {
      await _ensureBasePath(ftp);
      final tmp = File('${Directory.systemTemp.path}/bequest_upload_${DateTime.now().millisecondsSinceEpoch}');
      await tmp.writeAsString(data, encoding: utf8);
      try {
        final ok = await ftp.uploadFile(tmp, sRemoteName: remotePath);
        if (!ok) throw SyncException('FTP 上传失败: $remotePath');
      } finally {
        try { await tmp.delete(); } catch (_) {}
      }
    } finally {
      await ftp.disconnect();
    }
  }

  @override
  Future<String> download(String remotePath) async {
    final ftp = await _connect();
    try {
      await _ensureBasePath(ftp);
      final tmp = File('${Directory.systemTemp.path}/bequest_download_${DateTime.now().millisecondsSinceEpoch}');
      try {
        final ok = await ftp.downloadFile(remotePath, tmp);
        if (!ok) throw SyncException('FTP 下载失败: $remotePath');
        return await tmp.readAsString(encoding: utf8);
      } finally {
        try { await tmp.delete(); } catch (_) {}
      }
    } finally {
      await ftp.disconnect();
    }
  }

  @override
  Future<bool> testConnection() async {
    try {
      final ftp = await _connect();
      await ftp.disconnect();
      return true;
    } on SyncException {
      rethrow;
    } catch (e) {
      throw SyncException('FTP 连接失败: $e');
    }
  }

  @override
  Future<List<BackupFileInfo>> listFiles() async {
    final ftp = await _connect();
    try {
      await _ensureBasePath(ftp);
      final entries = await ftp.listDirectoryContent();
      final files = entries
          .where((e) => e.type == FTPEntryType.file)
          .map((e) => BackupFileInfo(
                name: e.name,
                size: e.size ?? 0,
                modified: e.modifyTime,
              ))
          .toList()
        ..sort((a, b) {
          final am = a.modified ?? DateTime(1970);
          final bm = b.modified ?? DateTime(1970);
          return bm.compareTo(am);
        });
      return files;
    } finally {
      await ftp.disconnect();
    }
  }

  @override
  Future<void> delete(String remotePath) async {
    final ftp = await _connect();
    try {
      await _ensureBasePath(ftp);
      await ftp.deleteFile(remotePath);
    } finally {
      await ftp.disconnect();
    }
  }
}
