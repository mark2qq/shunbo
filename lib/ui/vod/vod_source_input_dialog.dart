/// 片源接口输入页（1.0.5 第十六次修；第二十六次修改「当前接口」口径）。
///
/// 触发条件由 [VodIndexGatePhase.needAddress] 统一给出，共三种：
/// 初次使用未设定接口、索引目录缺失/无有效片源、索引记录的接口与当前设定不一致。
/// 页面把具体理由原样显示，不自己再判一遍 —— 判据只在状态机里有一份。
///
/// ## 第二十六次修：不再展示随包默认地址那一行
///
/// 用户红标：「改成当前接口，如果没有就是空，初次加载也是空，要有简短免责说明」。
/// 原来这里固定显示随包目录记录的那条默认地址，用途是提示「填同一个地址
/// 可直接加载已有片源」。但初次使用的用户根本没有「当前接口」，先看到一条
/// 与自己无关的地址只会误以为它已经生效。现在：
///
///  * 「当前接口」读**用户自己设定过的地址**（`selectedUrl`），没设过就是空，
///    整块不渲染；
///  * 输入框也只预填这条地址，没设过就是空；
///  * 底部固定放一句简短的免责与版权说明，交代客户端只聚合索引、不承载内容。
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../data/onboarding/vod_source_address.dart' show kVodDefaultSourceUrl;

/// 一次提交的结果。null 表示用户取消（VodPage 会保留「设定接口」入口）。
class VodSourceInputResult {
  const VodSourceInputResult({
    required this.url,
    required this.allowInsecureHttp,
  });

  final String url;
  final bool allowInsecureHttp;
}

/// 校验由调用方注入（纯函数，门禁可裸跑）：返回 null 表示可提交，否则是理由。
typedef VodSourceInputValidator = String? Function(
    String url, bool allowInsecureHttp);

Future<VodSourceInputResult?> showVodSourceInputDialog({
  required BuildContext context,
  required String reason,
  required String currentSourceUrl,
  required String initialUrl,
  required VodSourceInputValidator validate,
  bool initialAllowInsecureHttp = false,
}) {
  return showDialog<VodSourceInputResult>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _VodSourceInputDialog(
      reason: reason,
      currentSourceUrl: currentSourceUrl,
      initialUrl: initialUrl,
      initialAllowInsecureHttp: initialAllowInsecureHttp,
      validate: validate,
    ),
  );
}

class _VodSourceInputDialog extends StatefulWidget {
  const _VodSourceInputDialog({
    required this.reason,
    required this.currentSourceUrl,
    required this.initialUrl,
    required this.initialAllowInsecureHttp,
    required this.validate,
  });

  final String reason;

  /// 用户**设定过**的接口地址；没设过是空串（初次使用）。
  final String currentSourceUrl;

  final String initialUrl;
  final bool initialAllowInsecureHttp;
  final VodSourceInputValidator validate;

  @override
  State<_VodSourceInputDialog> createState() => _VodSourceInputDialogState();
}

class _VodSourceInputDialogState extends State<_VodSourceInputDialog> {
  late final TextEditingController _controller;
  late bool _insecure;
  String? _error;

  /// 用户是否已经点过「确定」。没点过时输入框为空**不报错** ——
  /// 初次使用打开就顶一行红字，比空输入框更让人困惑。
  bool _attempted = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialUrl);
    // 默认源是明文 http：初次使用不自动放行的话，用户填了唯一能用的地址
    // 也会被校验挡住，形成「点得动的必然失败」的死循环（本项目踩过一次）。
    _insecure = widget.initialAllowInsecureHttp ||
        widget.initialUrl.trim().toLowerCase().startsWith('http://');
    _validate();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _validate() {
    final text = _controller.text.trim();
    if (text.isEmpty && !_attempted) {
      _error = null;
      return;
    }
    _error = widget.validate(_controller.text, _insecure);
  }

  void _submit() {
    _attempted = true;
    _validate();
    if (_error != null) {
      setState(() {});
      return;
    }
    Navigator.of(context).pop(VodSourceInputResult(
      url: _controller.text.trim(),
      allowInsecureHttp: _insecure,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.currentSourceUrl.trim();
    return AlertDialog(
      backgroundColor: AppTheme.surface,
      title: const Text('设定片源接口',
          style: TextStyle(fontSize: 18, color: AppTheme.textPrimary)),
      content: SizedBox(
        width: 520,
        // 不用 SingleChildScrollView / SelectableText：两者可聚焦，
        // 电视端会吞掉 OK 键（诊断页踩过同一坑）。内容高度固定，无需滚动。
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.reason,
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textSecondary)),
              const SizedBox(height: 12),
              // 第二十六次修：这里改成**用户当前设定的接口**。没设过就整块
              // 不出现（初次使用即是空），不再拿随包默认地址顶替。
              if (current.isNotEmpty) ...[
                const Text('当前接口：',
                    style: TextStyle(
                        fontSize: 11, color: AppTheme.textTertiary)),
                const SizedBox(height: 4),
                Text(current,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textSecondary)),
                const SizedBox(height: 10),
              ],
              TextField(
                controller: _controller,
                autofocus: true,
                maxLines: 2,
                style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                decoration: const InputDecoration(
                  labelText: '片源接口地址',
                  hintText: 'http(s)://.../config.json',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(_validate),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () {
                      _controller.text = kVodDefaultSourceUrl;
                      _insecure = true;
                      setState(_validate);
                    },
                    icon: const Icon(Icons.bolt, size: 15),
                    label: const Text('填入默认源地址',
                        style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
              SwitchListTile(
                value: _insecure,
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('允许明文 http',
                    style: TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
                subtitle: const Text('默认源为 http，关闭时该地址会被传输策略拒绝',
                    style: TextStyle(
                        fontSize: 10, color: AppTheme.textTertiary)),
                onChanged: (v) => setState(() {
                  _insecure = v;
                  _validate();
                }),
              ),
              // 简短免责与版权说明（用户红标要求）。
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Text(
                  '仅聚合第三方公开接口的索引信息，不提供、不存储、不传播任何影音内容；'
                  '片源与版权归各来源站点所有，请自行确认来源合法。',
                  style: TextStyle(
                      fontSize: 10,
                      height: 1.4,
                      color: AppTheme.textTertiary),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(_error!,
                      style: const TextStyle(fontSize: 11, color: Colors.redAccent)),
                ),
            ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('稍后再说', style: TextStyle(fontSize: 12)),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('确定并加载片源', style: TextStyle(fontSize: 12)),
        ),
      ],
    );
  }
}
