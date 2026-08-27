import 'package:flutter/material.dart';

import '../api/api_client.dart';

/// 单文本框 + 保存对话框:校验/保存中/失败均保留输入,保存成功才 pop 返回输入值。
/// 用于分组新增/改名、备注编辑、本地账户改名等"输入后保存"场景。
/// [onSave] 抛异常视为保存失败(弹窗保留,显示错误);ApiException 409 显示 [conflictMessage]。
class TextSaveDialog extends StatefulWidget {
  const TextSaveDialog({
    super.key,
    required this.title,
    required this.onSave,
    this.initialValue = '',
    this.labelText = '名称',
    this.hintText,
    this.maxLength = 20,
    this.maxLines = 1,
    this.conflictMessage,
    this.failMessage = '保存失败,请检查网络后重试',
    this.allowEmpty = false,
  });

  final String title;
  final String labelText;
  final String? hintText;
  final int? maxLength;
  final int maxLines;
  final String initialValue;

  /// 保存动作:抛异常视为失败,弹窗保留输入。
  final Future<void> Function(String value) onSave;

  /// statusCode 409 时显示的文案(如"分组已存在")。
  final String? conflictMessage;
  final String failMessage;

  /// 允许保存空值(如清空备注)。
  final bool allowEmpty;

  @override
  State<TextSaveDialog> createState() => _TextSaveDialogState();
}

class _TextSaveDialogState extends State<TextSaveDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = _controller.text.trim();
    if (value.isEmpty && !widget.allowEmpty) {
      setState(() => _error = '请输入${widget.labelText}');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(value);
      if (!mounted) return;
      Navigator.of(context).pop(value);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.statusCode == 409 && widget.conflictMessage != null
            ? widget.conflictMessage!
            : e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = widget.failMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            maxLength: widget.maxLength,
            maxLines: widget.maxLines,
            decoration: InputDecoration(
              labelText: widget.labelText,
              hintText: widget.hintText,
              border: const OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: errorColor, fontSize: 13)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中...' : '保存'),
        ),
      ],
    );
  }
}
