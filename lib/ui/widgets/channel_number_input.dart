import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../features/live/channel_numbering.dart';
import '../../features/live/live_controller.dart';

/// **遥控器数字输入切台**。
///
/// 电视上的操作习惯是「按频道号直接跳过去」，而不是在长长的频道列表里翻。
/// 这个组件把 Android TV 遥控器上的数字键变成「输入频道号」：
///
/// * 逐位累积（主流机顶盒的行为）：按 `1` 立刻切到 CCTV-1，按 `0` 继续等，
///   1.5 秒内没有继续按就把已输入的数字当成完整编号提交；
/// * 按「确认 / OK」立即提交，不用等超时；
/// * 按「返回 / ESC」取消本次输入；
/// * 界面上给一块 **编号 + 台名** 的浮层（参考主流直播软件的频道号显示），
///   让用户看清自己输到了哪一步、跳到了哪个台。
///
/// 用 [HardwareKeyboard] 而不是 `Focus` + `onKeyEvent`：
/// 前者是**全局**钩子，不要求任何控件先拿到焦点。
/// 遥控器操作时焦点往往停在「播放画面」上（画面本身不可聚焦），
/// 用焦点方案会经常收不到按键。
class ChannelNumberInput extends StatefulWidget {
  const ChannelNumberInput({
    super.key,
    required this.controller,
    required this.child,
    this.enabled = true,
  });

  final LiveController controller;

  /// 是否接收数字键。默认开启；把它挂在直播页之外时关掉，
  /// 免得在设置页输入数字也触发切台。
  final bool enabled;

  final Widget child;

  @override
  State<ChannelNumberInput> createState() => _ChannelNumberInputState();
}

class _ChannelNumberInputState extends State<ChannelNumberInput> {
  final NumberInputBuffer _buffer = NumberInputBuffer();

  Timer? _commitTimer;

  /// 浮层上显示的编号文本。
  String _osdNumber = '';

  /// 浮层上显示的台名。
  String _osdName = '';

  /// 浮层是否可见。
  bool _osdVisible = false;

  /// 浮层提示语（空 = 不显示提示）。
  String _osdHint = '';

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _commitTimer?.cancel();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (!widget.enabled || !mounted) return false;
    // 文本输入框有焦点时一律放行。
    //
    // 这是个**全局** HardwareKeyboard 钩子，抢在焦点树之前拿到按键；
    // 检索框里输「2020」这类年份时必须原样进输入框，不能被当成频道号
    // 累积、更不能提交成一次切台。直播页目前没有输入框，但设置页、
    // 检索框、将来的任何 TextField 都靠这一条兜住。
    if (_editingText) return false;
    // 只处理按下事件：长按的重复事件（KeyRepeatEvent）会把 1 打成 11。
    if (event is! KeyDownEvent) return false;
    final key = event.logicalKey;

    final digit = _digitOf(key);
    if (digit != null) {
      if (!_buffer.addDigit(digit)) return false;
      debugPrint('[number] 收到数字键 $digit，当前缓冲 ${_buffer.buffer}');
      _commitTimer?.cancel();
      _commitTimer = Timer(_buffer.timeout, _commit);
      setState(() {
        _osdNumber = _buffer.buffer;
        _osdName = _nameOf(_buffer.buffer);
        _osdHint = '';
        _osdVisible = true;
      });
      return true;
    }

    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.gameButtonA) {
      if (_buffer.isEmpty) return false;
      _commit();
      return true;
    }

    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.backspace) {
      if (_buffer.isEmpty) return false;
      _cancel();
      return true;
    }
    return false;
  }

  /// 当前焦点是否落在文本输入控件上。
  ///
  /// [EditableText] 内部的 `Focus` 节点就是 `primaryFocus`，往上找一层即可
  /// 确认是输入框；`TextField` / `TextFormField` 最终都渲染成它。
  bool get _editingText {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    if (ctx.widget is EditableText) return true;
    return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// 数字键 → 数字值（同时认主键区与小键盘）。
  int? _digitOf(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.digit0) return 0;
    if (key == LogicalKeyboardKey.digit1) return 1;
    if (key == LogicalKeyboardKey.digit2) return 2;
    if (key == LogicalKeyboardKey.digit3) return 3;
    if (key == LogicalKeyboardKey.digit4) return 4;
    if (key == LogicalKeyboardKey.digit5) return 5;
    if (key == LogicalKeyboardKey.digit6) return 6;
    if (key == LogicalKeyboardKey.digit7) return 7;
    if (key == LogicalKeyboardKey.digit8) return 8;
    if (key == LogicalKeyboardKey.digit9) return 9;
    if (key == LogicalKeyboardKey.numpad0) return 0;
    if (key == LogicalKeyboardKey.numpad1) return 1;
    if (key == LogicalKeyboardKey.numpad2) return 2;
    if (key == LogicalKeyboardKey.numpad3) return 3;
    if (key == LogicalKeyboardKey.numpad4) return 4;
    if (key == LogicalKeyboardKey.numpad5) return 5;
    if (key == LogicalKeyboardKey.numpad6) return 6;
    if (key == LogicalKeyboardKey.numpad7) return 7;
    if (key == LogicalKeyboardKey.numpad8) return 8;
    if (key == LogicalKeyboardKey.numpad9) return 9;
    return null;
  }

  /// 输入过程中显示的台名（编号已存在则显示台名，否则提示「继续输入」）。
  String _nameOf(String buffer) {
    final n = int.tryParse(buffer);
    if (n == null) return '';
    final ch = widget.controller.numbers.channelForNumber(
      widget.controller.channels,
      n,
    );
    return ch?.name ?? '';
  }

  void _commit() {
    _commitTimer?.cancel();
    final buffer = _buffer.take();
    final n = int.tryParse(buffer);
    if (n == null || buffer.isEmpty) {
      _hide();
      return;
    }
    final ch = widget.controller.numbers.channelForNumber(
      widget.controller.channels,
      n,
    );
    if (ch == null) {
      setState(() {
        _osdNumber = buffer;
        _osdName = '';
        _osdHint = '没有这个频道号';
        _osdVisible = true;
      });
      _scheduleHide();
      return;
    }
    setState(() {
      _osdNumber = buffer;
      _osdName = ch.name;
      _osdHint = '';
      _osdVisible = true;
    });
    _scheduleHide();
    debugPrint('[number] 提交编号 $buffer → ${ch.name}');
    unawaited(widget.controller.tuneByNumber(n));
  }

  void _cancel() {
    _commitTimer?.cancel();
    _buffer.clear();
    setState(() {
      _osdNumber = '';
      _osdName = '';
      _osdHint = '已取消';
      _osdVisible = true;
    });
    _scheduleHide();
  }

  /// OSD 停留时长：电视上用户要来得及看清「编号 + 台名」，
  /// 主流机顶盒的频道号提示一般停留 3 秒左右。
  static const Duration osdDuration = Duration(milliseconds: 3000);

  void _scheduleHide() {
    _commitTimer?.cancel();
    _commitTimer = Timer(osdDuration, _hide);
  }

  void _hide() {
    if (!mounted) return;
    setState(() {
      _osdVisible = false;
      _osdNumber = '';
      _osdName = '';
      _osdHint = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_osdVisible) {
      debugPrint('[number] 渲染 OSD：$_osdNumber / $_osdName');
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_osdVisible)
          Align(
            alignment: Alignment.topCenter,
            child: _NumberOsd(
              number: _osdNumber,
              name: _osdName,
              hint: _osdHint,
            ),
          ),
      ],
    );
  }
}

/// 「编号 + 台名」浮层。
///
/// 版式参考主流直播软件：左边一个大号编号，右边台名，
/// 一眼就能确认「我现在输的是 1 / 105 / 218」。
class _NumberOsd extends StatelessWidget {
  const _NumberOsd({
    required this.number,
    required this.name,
    required this.hint,
  });

  final String number;
  final String name;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        margin: const EdgeInsets.only(top: 40),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF2E7CF6), width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              number,
              style: const TextStyle(
                fontSize: 30,
                height: 1.1,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 18),
            if (name.isNotEmpty)
              Text(
                name,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            if (hint.isNotEmpty) ...[
              const SizedBox(width: 12),
              Text(
                hint,
                style: const TextStyle(fontSize: 13, color: Color(0xFFC7D0DC)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
