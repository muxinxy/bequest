import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../models/trigger_ladder.dart';

/// 加载触发阶梯;失败(本地模式/离线/网络)返回空列表,不报错。
Future<List<TriggerLadder>> loadTriggerLadders(ApiClient api, String jwt) async {
  try {
    final list = await api.listTriggerLadders(jwt);
    return list.map(TriggerLadder.fromJson).toList();
  } catch (_) {
    return const [];
  }
}

/// 触发阶梯下拉:全局(默认) + 自定义阶梯。
/// [value] 为 null 表示全局阶梯。
class LadderDropdown extends StatelessWidget {
  const LadderDropdown({
    super.key,
    required this.ladders,
    required this.value,
    required this.onChanged,
    this.label = '触发阶梯',
  });

  final List<TriggerLadder> ladders;
  final int? value;
  final ValueChanged<int?> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: value == null ? 'global' : '$value',
      decoration: InputDecoration(labelText: label),
      items: [
        const DropdownMenuItem<String>(
          value: 'global',
          child: Text('全局(默认)'),
        ),
        for (final l in ladders.where((l) => !l.isGlobal))
          DropdownMenuItem<String>(
            value: '${l.id}',
            child: Text('${l.name}(${l.daysLabel})', overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (v) => onChanged(v == 'global' ? null : int.tryParse(v ?? '')),
    );
  }
}

/// 选择触发阶梯对话框;返回 (是否确认, 阶梯 id)(null = 全局)。
Future<(bool, int?)> pickLadderDialog(
  BuildContext context, {
  required List<TriggerLadder> ladders,
  int? initial,
}) async {
  var selected = initial;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('修改触发阶梯'),
        content: LadderDropdown(
          ladders: ladders,
          value: selected,
          onChanged: (v) => setDialogState(() => selected = v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
  return (ok == true, selected);
}