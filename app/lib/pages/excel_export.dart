import 'package:excel/excel.dart';

import '../models/export_format.dart';

/// 把资产导出项生成为 xlsx 字节(会员权益)。
/// 列:名称 / 类型 / 分组 / 到期日 / 凭据 / 备注 / 提前提醒天数。
List<int> buildExcelBytes(List<ExportItem> items) {
  final excel = Excel.createExcel();
  // 先建资产表(此时有 Sheet1+资产 两个 sheet),再删默认 Sheet1——
  // excel 包的 delete 要求至少 2 个 sheet 才生效。
  final sheet = excel['资产'];
  if (excel.tables.containsKey('Sheet1')) {
    excel.delete('Sheet1');
  }
  // 表头。
  sheet.appendRow([
    TextCellValue('名称'),
    TextCellValue('类型'),
    TextCellValue('分组'),
    TextCellValue('到期日'),
    TextCellValue('属性'),
    TextCellValue('备注'),
    TextCellValue('提前提醒(天)'),
    TextCellValue('继承人'),
  ]);
  for (final item in items) {
    sheet.appendRow([
      TextCellValue(item.name),
      TextCellValue(_assetTypeLabel(item.assetType)),
      TextCellValue(item.category ?? ''),
      TextCellValue(item.expiryDate ?? ''),
      TextCellValue(item.credentials),
      TextCellValue(item.notes),
      IntCellValue(item.advanceDays ?? 0),
      TextCellValue(item.inheritors?.join('、') ?? ''),
    ]);
  }
  // 表头加粗。
  final header = sheet.row(0);
  for (final cell in header) {
    cell!.cellStyle = CellStyle(bold: true);
  }
  return excel.encode()!;
}

String _assetTypeLabel(String type) => type == 'virtual' ? '虚拟' : '实体';
