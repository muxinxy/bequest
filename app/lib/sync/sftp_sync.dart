import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import 'sync_provider.dart';

/// SFTP 同步提供方。基于 dartssh2(socket 协议,仅桌面/移动端,web 不支持)。
class SftpSyncProvider implements SyncProvider {
  SftpSyncProvider({
    required this.host,
    required this.user,
    required this.password,
    this.port = 22,
    this.basePath = '/bequest',
    this.timeoutSeconds = 15,
  });

  final String host;
  final int port;
  final String user;
  final String password;
  final String basePath;
  final int timeoutSeconds;

  @override
  String get name => 'SFTP';

  /// 建立 SSH 连接 + 认证 + 打开 SFTP 会话。
  Future<(SSHClient, SftpClient)> _connect() async {
    final socket = await SSHSocket.connect(host, port).timeout(
      Duration(seconds: timeoutSeconds),
    );
    final authenticated = Completer<void>();
    final ssh = SSHClient(
      socket,
      username: user,
      onPasswordRequest: () => password,
      onAuthenticated: () {
        if (!authenticated.isCompleted) authenticated.complete();
      },
    );
    try {
      await authenticated.future.timeout(Duration(seconds: timeoutSeconds));
    } catch (_) {
      ssh.close();
      throw SyncException('SFTP 认证失败或超时');
    }
    final sftp = await ssh.sftp();
    return (ssh, sftp);
  }

  String _fullPath(String remotePath) {
    final base = basePath.replaceAll(RegExp(r'^/+|/+$'), '');
    return base.isEmpty ? '/$remotePath' : '/$base/$remotePath';
  }

  /// 确保 basePath 目录存在(逐级 mkdir,已存在忽略)。
  Future<void> _ensureBasePath(SftpClient sftp) async {
    final path = basePath.replaceAll(RegExp(r'^/+|/+$'), '');
    if (path.isEmpty) return;
    var current = '';
    for (final seg in path.split('/')) {
      if (seg.isEmpty) continue;
      current = '$current/$seg';
      try {
        await sftp.mkdir(current);
      } catch (_) {
        // 已存在则忽略。
      }
    }
  }

  @override
  Future<void> upload(String remotePath, String data) async {
    final (ssh, sftp) = await _connect();
    try {
      await _ensureBasePath(sftp);
      final file = await sftp.open(
        _fullPath(remotePath),
        mode: SftpFileOpenMode.write | SftpFileOpenMode.create | SftpFileOpenMode.truncate,
      );
      try {
        final bytes = utf8.encode(data);
        await file.writeBytes(bytes).timeout(Duration(seconds: timeoutSeconds));
        await file.close();
      } catch (_) {
        try { await file.close(); } catch (_) {}
        rethrow;
      }
    } finally {
      ssh.close();
    }
  }

  @override
  Future<String> download(String remotePath) async {
    final (ssh, sftp) = await _connect();
    try {
      await _ensureBasePath(sftp);
      final file = await sftp.open(_fullPath(remotePath));
      try {
        final bytes = await file.readBytes().timeout(
              Duration(seconds: timeoutSeconds),
            );
        await file.close();
        return utf8.decode(bytes);
      } catch (_) {
        try { await file.close(); } catch (_) {}
        rethrow;
      }
    } finally {
      ssh.close();
    }
  }

  @override
  Future<bool> testConnection() async {
    try {
      final (ssh, _) = await _connect();
      ssh.close();
      return true;
    } on SyncException {
      rethrow;
    } catch (e) {
      throw SyncException('SFTP 连接失败: $e');
    }
  }

  @override
  Future<List<BackupFileInfo>> listFiles() async {
    final (ssh, sftp) = await _connect();
    try {
      await _ensureBasePath(sftp);
      final path = basePath.replaceAll(RegExp(r'^/+|/+$'), '');
      final dir = path.isEmpty ? '/' : '/$path';
      final entries = await sftp.listdir(dir);
      final files = entries
          .where((e) => !e.longname.startsWith('d')) // 目录排除
          .map((e) => BackupFileInfo(
                name: e.filename,
                size: e.attr.size ?? 0,
                modified: e.attr.modifyTime == null
                    ? null
                    : DateTime.fromMillisecondsSinceEpoch(
                        e.attr.modifyTime! * 1000,
                      ),
              ))
          .toList()
        ..sort((a, b) {
          final am = a.modified ?? DateTime(1970);
          final bm = b.modified ?? DateTime(1970);
          return bm.compareTo(am);
        });
      return files;
    } finally {
      ssh.close();
    }
  }

  @override
  Future<void> delete(String remotePath) async {
    final (ssh, sftp) = await _connect();
    try {
      await _ensureBasePath(sftp);
      await sftp.remove(_fullPath(remotePath));
    } finally {
      ssh.close();
    }
  }
}
