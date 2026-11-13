import 'dart:async';

import 'package:flutter/widgets.dart';

/// 给一块**可交互浮层**套上「无操作 N 秒就自己收起来」的行为。
///
/// 为什么单独抽一个外壳，而不是在页面里再加一个 `Timer` 字段：
/// 浮层是条件渲染的（`if (_showEpisodes) …`），它的生命周期就是「打开 → 关闭」。
/// 计时器跟着浮层走，打开即起、关闭即 `dispose` 取消，天然没有「页面还在、
/// 计时器却指向一个已经不存在的浮层」这种悬挂状态；也不会因为漏了某个
/// 关闭路径（点条目的、点 X 的、按 Esc 的、换集的）而留下一个还在跑的 timer。
///
/// **什么算「有响应」**：指针移动 / 点击 / 滚轮 / 滚动 / 焦点落进来 / 按键。
/// 只认指针移动是不够的 —— 电视端没有指针，遥控器是方向键在条目间移焦点；
/// 而「滚轮翻列表」在 Flutter 里既不触发 `onHover` 也不改焦点，只发
/// `ScrollNotification`，所以四类信号都要接。
///
/// 按键用 [Focus.onKeyEvent] 接：键事件从当前焦点节点沿树上冒泡，这个
/// [Focus] 是浮层的祖先，比页面级的全局按键处理**更早**收到事件；
/// 返回 [KeyEventResult.ignored] 让它继续往上冒泡，不改变任何既有键位行为。
class PanelIdleHider extends StatefulWidget {
  const PanelIdleHider({
    super.key,
    required this.idle,
    required this.onIdle,
    required this.child,
  });

  /// 多久没有任何响应就收起来。
  final Duration idle;

  /// 到点回调。**只调用一次**：回调后计时器不再重启，等父级把浮层从树上摘掉。
  final VoidCallback onIdle;

  final Widget child;

  @override
  State<PanelIdleHider> createState() => _PanelIdleHiderState();
}

class _PanelIdleHiderState extends State<PanelIdleHider> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // 打开就开始计：用户点开浮层后**什么都不做**是最常见的「无响应」场景。
    _restart();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  void _restart() {
    _timer?.cancel();
    _timer = Timer(widget.idle, () {
      if (!mounted) return;
      _timer = null;
      widget.onIdle();
    });
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: (_) => _restart(),
      child: Listener(
        onPointerDown: (_) => _restart(),
        onPointerMove: (_) => _restart(),
        onPointerSignal: (_) => _restart(),
        child: NotificationListener<ScrollNotification>(
          onNotification: (_) {
            _restart();
            // 不吞通知：浮层里的 ListView 还要正常滚动。
            return false;
          },
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: (_, __) {
              _restart();
              return KeyEventResult.ignored;
            },
            onFocusChange: (hasFocus) {
              if (hasFocus) _restart();
            },
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
