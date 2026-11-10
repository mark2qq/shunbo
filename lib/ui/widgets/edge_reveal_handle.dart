import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'edge_handle_policy.dart';

/// 侧栏位于屏幕的哪一侧。左右两侧只差一个方向与一个箭头，
/// 显隐逻辑、热区尺寸、动画时长全部共用，保证行为一致。
enum EdgeSide { left, right }

/// 边缘「伸缩控件」：侧栏收起时贴边的一条细长胶囊。
///
/// 与旧实现的三点区别：
/// - **默认隐藏**：[EdgeHandlePolicy.visible] 初值为 false，初始加载时
///   `AnimatedOpacity` 是 0，且 `IgnorePointer` 不响应点击；
/// - **按需显示**：鼠标进入 30px 透明热区才淡入，停留 400ms 自动展开
///   （保留原「悬停呼出」手感），或直接点击立即展开；
/// - **只在收起态渲染**：展开态不渲染热区，避免盖住侧栏最外侧 30px 的
///   导航项 / 分类 chip / 列表滚动条，原有交互完全不受影响。
///
/// 必须作为 `Stack` 的直接子节点使用（返回值是 `Positioned`）。
class EdgeRevealHandle extends StatefulWidget {
  const EdgeRevealHandle({
    super.key,
    required this.side,
    required this.onActivate,
    this.hoverDelay = const Duration(milliseconds: 400),
    this.persistent = false,
  });

  final EdgeSide side;

  /// 展开侧栏。由调用方决定是 `_openSide()` 还是 `_openRail()`。
  final VoidCallback onActivate;

  /// 悬停多久后自动展开；`Duration.zero` 表示只响应点击。
  final Duration hoverDelay;

  /// 触摸设备：手柄**常驻可见且始终可点**，不依赖鼠标悬停。
  ///
  /// 触摸屏不产生 hover 事件（`MouseRegion.onEnter` 永不触发），而旧实现把
  /// 「可见」完全绑在 hover 上，同时用 `IgnorePointer` 把不可见状态下的点击
  /// 一并吃掉 —— 结果是在手机上这个手柄既看不见也点不到，侧栏一旦自动收起
  /// 就再也唤不出来。为 true 时改为「常驻半透明、悬停/按下变实」。
  final bool persistent;

  /// 热区宽度：与原实现一致，不改动画面可用区域。
  static const double hitWidth = 30;

  /// 淡入淡出时长，两侧与「按需收起按钮」共用。
  static const Duration fadeDuration = Duration(milliseconds: 180);

  @override
  State<EdgeRevealHandle> createState() => _EdgeRevealHandleState();
}

class _EdgeRevealHandleState extends State<EdgeRevealHandle> {
  final EdgeHandlePolicy _policy = EdgeHandlePolicy();
  Timer? _hoverTimer;

  void _cancelHover() {
    _hoverTimer?.cancel();
    _hoverTimer = null;
  }

  void _onEnter() {
    final startTimer = _policy.enter();
    if (!mounted) return;
    setState(() {});
    if (startTimer) _scheduleHoverActivate();
  }

  void _scheduleHoverActivate() {
    _cancelHover();
    // 常驻模式只靠点击/拖动展开：触控笔或带触摸的笔记本悬停在边缘时
    // 自动弹开侧栏会打断正在看的内容。
    if (widget.persistent) return;
    if (widget.hoverDelay <= Duration.zero) return;
    _hoverTimer = Timer(widget.hoverDelay, () {
      if (!mounted) return;
      if (_policy.onHoverElapsed()) widget.onActivate();
    });
  }

  void _onExit() {
    _cancelHover();
    _policy.exit();
    if (mounted) setState(() {});
  }

  void _onTap() {
    // 常驻模式不看策略：手柄一直可见，点击就该展开。
    // 策略里那条「隐藏时点击不生效」是为了挡住透明热区里的误点，
    // 而常驻模式下热区本来就是可见的，不存在误点。
    if (!widget.persistent && !_policy.tap()) return;
    _cancelHover();
    widget.onActivate();
  }

  @override
  void dispose() {
    _cancelHover();
    _policy.reset();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.side == EdgeSide.left;
    // 常驻模式下「可见」与策略解耦：策略仍然只负责 hover 计时，
    // 视觉与命中由 persistent 直接决定。
    final visible = widget.persistent || _policy.visible;
    final opacity = widget.persistent ? (_policy.visible ? 1.0 : 0.62) : (_policy.visible ? 1.0 : 0.0);
    return Positioned(
      top: 0,
      bottom: 0,
      left: left ? 0 : null,
      right: left ? null : 0,
      width: EdgeRevealHandle.hitWidth,
      child: MouseRegion(
        onEnter: (_) => _onEnter(),
        onExit: (_) => _onExit(),
        child: GestureDetector(
          // 常驻模式整块热区都可点：手指按在边缘任意位置都算「我要打开侧栏」，
          // 不必精确命中那条 30px 宽、14px 可见的小胶囊。
          behavior: visible ? HitTestBehavior.opaque : HitTestBehavior.deferToChild,
          onTap: _onTap,
          // 从边缘向内容方向拖动也能展开（手机上的抽屉惯性）。
          // 只认「朝屏幕内侧」的方向，反向滑动不该触发。
          onHorizontalDragEnd: visible
              ? (d) {
                  final vx = d.velocity.pixelsPerSecond.dx;
                  final towardInside = left ? vx > 260 : vx < -260;
                  if (towardInside) _onTap();
                }
              : null,
          child: IgnorePointer(
            ignoring: !visible,
            child: AnimatedOpacity(
              opacity: opacity,
              duration: EdgeRevealHandle.fadeDuration,
              curve: Curves.easeOut,
              child: Container(
                // 保持原手柄的位置与尺寸：只在垂直中段出现，不压住
                // 顶部台标与底部控制条。
                margin: const EdgeInsets.symmetric(vertical: 80),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceHigh,
                  borderRadius: left
                      ? const BorderRadius.only(
                          topRight: Radius.circular(10),
                          bottomRight: Radius.circular(10),
                        )
                      : const BorderRadius.only(
                          topLeft: Radius.circular(10),
                          bottomLeft: Radius.circular(10),
                        ),
                ),
                child: Center(
                  child: Icon(
                    left
                        ? Icons.chevron_right_rounded
                        : Icons.chevron_left_rounded,
                    color: AppTheme.textSecondary,
                    size: 20,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 侧栏展开态的「收起」入口，**仅在鼠标停留在侧栏上时淡入**。
///
/// 右侧频道栏原本常驻一个收起 IconButton；左侧导航栏没有对应入口，
/// 两侧行为不一致。现在统一成同一个组件：默认隐藏、按需显示，
/// 且固定 40×40 占位，淡入淡出不会引起头部布局跳动。
class OnDemandCollapseButton extends StatelessWidget {
  const OnDemandCollapseButton({
    super.key,
    required this.side,
    required this.visible,
    required this.onPressed,
  });

  final EdgeSide side;
  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: EdgeRevealHandle.fadeDuration,
        curve: Curves.easeOut,
        child: SizedBox(
          width: 40,
          height: 40,
          child: IconButton(
            tooltip: side == EdgeSide.left ? '收起导航栏' : '收起频道栏',
            icon: Icon(
              side == EdgeSide.left
                  ? Icons.chevron_left_rounded
                  : Icons.chevron_right_rounded,
              size: 20,
            ),
            color: AppTheme.textSecondary,
            padding: EdgeInsets.zero,
            onPressed: onPressed,
          ),
        ),
      ),
    );
  }
}
