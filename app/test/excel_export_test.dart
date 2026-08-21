import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/models/export_format.dart';
import 'package:bequest/pages/excel_export.dart';

void main() {
  test('buildExcelBytes:生成 xlsx,含表头与资产行', () {
    final bytes = buildExcelBytes([
      ExportItem(
        name: '支付宝',
        assetType: 'virtual',
        category: '账户',
        expiryDate: null,
        credentials: '账号: 138xxxx\n密码: secret',
        notes: '主账户',
        advanceDays: 7,
        inheritors: ['张三', '李四'],
      ),
    ]);
    expect(bytes, isNotEmpty);
    // xlsx 是 zip 容器,以 PK 开头。
    expect(bytes.sublist(0, 2), [0x50, 0x4B]);

    final excel = Excel.decodeBytes(bytes);
    // 只有一个 sheet(默认 Sheet1 已删除)。
    expect(excel.tables.keys.toList(), ['资产']);
    final sheet = excel.tables['资产'];
    expect(sheet, isNotNull);
    expect(sheet!.rows.length, 2); // 表头 + 1 行
    // 表头。
    final header = sheet.rows.first.map((c) => c?.value.toString()).toList();
    expect(
      header,
      containsAll(['名称', '类型', '分组', '到期日', '属性', '备注', '继承人']),
    );
    // 数据行。
    final row = sheet.rows[1].map((c) => c?.value.toString()).toList();
    expect(row.first, '支付宝');
    expect(row[1], '虚拟');
    expect(row[4], contains('账号'));
    expect(row.last, '张三、李四'); // 继承人
  });
}
