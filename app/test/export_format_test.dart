import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/models/export_format.dart';

void main() {
  group('buildExportJson', () {
    test('只包含非空可选字段', () {
      final json = buildExportJson(
        [
          const ExportItem(
            name: '银行账户A',
            assetType: 'virtual',
            credentials: '账号/密码',
            notes: '',
          ),
          const ExportItem(
            name: '房产',
            assetType: 'physical',
            category: '房产',
            expiryDate: '2030-01-01',
            credentials: '',
            notes: '备注',
            advanceDays: 7,
          ),
        ],
        DateTime(2026, 8, 9),
      );
      expect(json['app'], 'bequest');
      expect(json['version'], 1);
      expect(json['exported_at'], '2026-08-09T00:00:00.000');
      final assets = json['assets'] as List;
      final first = assets[0] as Map<String, dynamic>;
      expect(first['name'], '银行账户A');
      expect(first.containsKey('category'), isFalse);
      expect(first.containsKey('expiry_date'), isFalse);
      expect(first.containsKey('advance_days'), isFalse);
      expect(first['credentials'], '账号/密码');
      expect(first['notes'], '');
      final second = assets[1] as Map<String, dynamic>;
      expect(second['category'], '房产');
      expect(second['expiry_date'], '2030-01-01');
      expect(second['advance_days'], 7);
    });
  });

  group('parseExportFile', () {
    test('合法文件返回条目列表', () {
      final items = parseExportFile(
        '{"app":"bequest","version":1,'
        '"exported_at":"2026-08-09T00:00:00.000",'
        '"assets":[{"name":"A","asset_type":"physical",'
        '"credentials":"","notes":""}]}',
      );
      expect(items, isNotNull);
      expect(items!.length, 1);
      expect(items[0]['name'], 'A');
    });

    test('app 不符返回 null', () {
      expect(parseExportFile('{"app":"other","assets":[]}'), isNull);
    });

    test('assets 非列表返回 null', () {
      expect(parseExportFile('{"app":"bequest","assets":"x"}'), isNull);
    });

    test('非法 JSON 返回 null', () {
      expect(parseExportFile('not json'), isNull);
    });
  });

  test('构建→解析往返一致', () {
    final json = buildExportJson(
      [
        const ExportItem(
          name: 'A',
          assetType: 'physical',
          credentials: 'c',
          notes: 'n',
          advanceDays: 0,
        ),
      ],
      DateTime(2026, 1, 2),
    );
    final items = parseExportFile(jsonEncode(json));
    expect(items![0]['name'], 'A');
    expect(items[0]['credentials'], 'c');
    expect(items[0]['advance_days'], 0);
  });
}
