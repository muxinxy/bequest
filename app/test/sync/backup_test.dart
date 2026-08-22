import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:bequest/api/api_client.dart';
import 'package:bequest/sync/backup.dart';
import 'package:bequest/sync/local_vault.dart';

/// 用 MockClient 伪造后端,验证备份构建/解析/加密/恢复逻辑。
void main() {
  final key = base64.encode(List<int>.filled(32, 7));
  final wrongKey = base64.encode(List<int>.filled(32, 8));

  late List<Map<String, dynamic>> serverCategories;
  late List<Map<String, dynamic>> createdAssets;

  ApiClient fakeApi() {
    return ApiClient(
      client: MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' && path == '/api/v1/assets') {
          return http.Response(
            jsonEncode([
              {'id': '1', 'name': '房产A', 'asset_type': 'physical'},
              {'id': '2', 'name': '证券B', 'asset_type': 'virtual'},
            ]),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' && path == '/api/v1/assets/1') {
          return http.Response(
            jsonEncode({
              'id': '1',
              'name': '房产A',
              'asset_type': 'physical',
              'encrypted_data': 'blob-1',
              'expiry_date': '2030-01-01',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' && path == '/api/v1/assets/2') {
          return http.Response(
            jsonEncode({
              'id': '2',
              'name': '证券B',
              'asset_type': 'virtual',
              'encrypted_data': 'blob-2',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' && path == '/api/v1/categories') {
          return http.Response(jsonEncode(serverCategories), 200,
              headers: {'content-type': 'application/json'});
        }
        if (request.method == 'POST' && path == '/api/v1/categories') {
          final name = (jsonDecode(request.body) as Map)['name'].toString();
          final created = {'id': '99', 'name': name};
          serverCategories.add(created);
          return http.Response(jsonEncode(created), 201,
              headers: {'content-type': 'application/json'});
        }
        if (request.method == 'GET' && path == '/api/v1/reminder-templates') {
          return http.Response(
            jsonEncode([
              {'id': '5', 'name': '默认模板'},
            ]),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' && path == '/api/v1/inheritors') {
          return http.Response(
            jsonEncode([
              {'id': '7', 'name': '张三', 'email': 'z@example.com'},
            ]),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' && path == '/api/v1/logs') {
          return http.Response(
            jsonEncode([
              {'kind': 'audit', 'action': '新增资产「房产A」', 'created_at': '2026-08-01 10:00:00'},
            ]),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'POST' && path == '/api/v1/assets') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (body['name'] == '坏资产') {
            return http.Response('{"message":"服务器拒绝"}', 500);
          }
          createdAssets.add(body);
          return http.Response(jsonEncode({'id': '100', ...body}), 201,
              headers: {'content-type': 'application/json'});
        }
        return http.Response('{"message":"not found"}', 404);
      }),
    );
  }

  setUp(() {
    serverCategories = [
      {'id': '10', 'name': '股票'},
    ];
    createdAssets = [];
  });

  test('buildBackupJson 产出含全部数据键的备份 JSON', () async {
    final tempDir = Directory.systemTemp.createTempSync('bequest_backup_main');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final vault = LocalVault(directory: tempDir.path);
    final json = await buildBackupJson('jwt', fakeApi(), key, vault: vault);
    final backup = jsonDecode(json) as Map<String, dynamic>;
    expect(backup['app'], 'bequest');
    expect(backup['type'], 'backup');
    expect(backup['version'], 1);
    expect(backup['exported_at'], isNotEmpty);
    final assets = backup['assets'] as List;
    expect(assets, hasLength(2));
    expect((assets[0] as Map)['encrypted_data'], 'blob-1');
    expect((assets[1] as Map)['encrypted_data'], 'blob-2');
    expect(backup['categories'], hasLength(1));
    expect(backup['reminder_templates'], hasLength(1));
    expect(backup['inheritors'], hasLength(1));
    expect(backup['logs'], hasLength(1));
    expect((backup['logs'] as List).first['action'], contains('新增资产'));
    // 服务器拉取后本地快照已写入,可用主密钥读回。
    expect(await vault.loadVault(key), json);
  });

  test('buildBackupJson jwt=null 时读本地快照,不请求服务器', () async {
    final tempDir = Directory.systemTemp.createTempSync('bequest_backup_offline');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final vault = LocalVault(directory: tempDir.path);
    const cached =
        '{"app":"bequest","type":"backup","version":1,"assets":[],'
        '"categories":[],"reminder_templates":[],"inheritors":[]}';
    await vault.saveVault(cached, key);

    // 任何服务器请求都会抛错;成功返回即证明全程未走网络。
    final api = ApiClient(
      client: MockClient((_) async => throw StateError('不应请求服务器')),
    );
    final json = await buildBackupJson(null, api, key, vault: vault);
    expect(json, cached);
  });

  test('buildBackupJson jwt=null 且无本地快照 → StateError', () async {
    final tempDir = Directory.systemTemp.createTempSync('bequest_backup_empty');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final vault = LocalVault(directory: tempDir.path);
    expect(
      () => buildBackupJson(null, fakeApi(), key, vault: vault),
      throwsA(isA<StateError>()),
    );
  });

  test('restoreToLocal 写入的本地快照可被 loadVault 读回', () async {
    final tempDir = Directory.systemTemp.createTempSync('bequest_backup_restore');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final vault = LocalVault(directory: tempDir.path);
    const backup =
        '{"app":"bequest","type":"backup","version":1,"assets":[],'
        '"categories":[],"reminder_templates":[],"inheritors":[]}';
    await restoreToLocal(backup, key, vault: vault);
    expect(await vault.loadVault(key), backup);
  });

  test('parseBackupJson 校验通过与拒绝非法输入', () {
    final valid = jsonEncode({
      'app': 'bequest',
      'type': 'backup',
      'version': 1,
      'assets': <Map<String, dynamic>>[],
    });
    expect(parseBackupJson(valid), isNotNull);
    expect(parseBackupJson('not json'), isNull);
    expect(parseBackupJson('[]'), isNull);
    expect(
      parseBackupJson(jsonEncode({
        'app': 'bequest',
        'type': 'export',
        'version': 1,
        'assets': <Map<String, dynamic>>[],
      })),
      isNull,
    );
    expect(
      parseBackupJson(jsonEncode({
        'app': 'bequest',
        'type': 'backup',
        'version': 2,
        'assets': <Map<String, dynamic>>[],
      })),
      isNull,
    );
  });

  test('buildSyncPayload/extractBackupJson 主密钥往返;错误密钥返回 null', () async {
    final payload = await buildSyncPayload('{"a":1}', key);
    expect(payload['blob'], isNotEmpty);
    final payloadJson = jsonEncode(payload);
    expect(await extractBackupJson(payloadJson, key), '{"a":1}');
    expect(await extractBackupJson(payloadJson, wrongKey), isNull);
    expect(await extractBackupJson('garbage', key), isNull);
    expect(await extractBackupJson('{"blob":""}', key), isNull);
  });

  test('restoreAssets 解析分类(复用/新建/预设按名创建)并统计成功失败', () async {
    final backup = jsonEncode({
      'app': 'bequest',
      'type': 'backup',
      'version': 1,
      'assets': [
        {
          'id': '1',
          'name': '房产A',
          'asset_type': 'physical',
          'category_id': '10',
          'encrypted_data': 'blob-1',
        },
        {
          'id': '2',
          'name': '证券B',
          'asset_type': 'virtual',
          'category_id': '20',
          'encrypted_data': 'blob-2',
        },
        {
          'id': '3',
          'name': '收藏C',
          'asset_type': 'physical',
          'category_id': '30',
          'encrypted_data': 'blob-3',
        },
        {
          'id': '4',
          'name': '坏资产',
          'asset_type': 'physical',
          'category_id': null,
          'encrypted_data': 'blob-4',
        },
      ],
      'categories': [
        {'id': '10', 'name': '股票'},
        {'id': '20', 'name': '新分类'},
        {'id': '30', 'name': '房产'},
      ],
    });

    final result = await restoreAssets(backup, 'jwt', fakeApi());
    expect(result.ok, 3);
    expect(result.fail, 1);

    // 新分类被创建并复用其 id。
    expect(serverCategories.map((c) => c['name']), contains('新分类'));
    final byName = <String, Map<String, dynamic>>{
      for (final a in createdAssets) a['name'].toString(): a,
    };
    expect(byName['房产A']!['category_id'], 10); // 已存在分类:复用(服务端 int64)
    expect(byName['证券B']!['category_id'], 99); // 新分类:创建后复用
    expect(byName['收藏C']!['category_id'], 99); // 预设名服务端无此分类:按名创建后复用
    expect(byName['房产A']!['encrypted_data'], 'blob-1'); // 密文原样
  });
}
