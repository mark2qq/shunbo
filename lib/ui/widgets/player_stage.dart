import 'package:flutter/material.dart';

import '../../core/player/media_kit_player_controller.dart';
import '../../core/player/mpv/libmpv_player_controller.dart';
import '../../core/player/player_bootstrap.dart';
import '../../core/player/player_controller.dart';
import '../../app/theme.dart';
import '../media_kit_surface.dart';
import '../player_surface.dart';

/// 按内核返回真实渲染面；返回 null 表示这个内核没有画面（Mock）。
///
/// 全工程只在这里做「内核类型 → 渲染组件」的映射，避免每个页面各写一遍
/// `is MediaKitPlayerController`，将来加内核也只需改一处。
///
/// [fit] 必须传下来：缩放三档是**用户可见的功能**（控制条上的「画面缩放」），
/// 只在页面里改状态、不传到渲染面等于按钮点了没反应——这正是接进参数前的
/// 实际状况（`PlayerStage.fit` 存在但从未被使用）。
Widget? buildVideoSurface(PlayerController player, {BoxFit fit = BoxFit.contain}) {
  if (player is MediaKitPlayerController) {
    return MediaKitSurface(controller: player.videoController, fit: fit);
  }
  if (needsRenderSurface(player) && player is LibMpvPlayerController) {
    return PlayerSurface(fit: fit);
  }
  return null;
}

/// 播放舞台：黑底容器 + 视频面 + 状态叠加层。
///
/// 直播与点播共用。叠加层刻意做得很薄：电视场景下画面本身是主角，
/// 常驻的大块信息卡只会挡住内容。
///
/// [fill] 决定舞台怎么取尺寸：
/// * `false`（点播默认）：固定 [aspectRatio]，在 Column 里自然算出 16:9 高度；
/// * `true`（直播）：**铺满父级给的有界区域**。
///
/// `fill` 存在的理由是一处真实的手机横屏缺陷：舞台外层是
/// `ColoredBox → GestureDetector`，这两层都把约束原样透传（**松散约束**），
/// 于是 `AspectRatio(16/9)` 在 2.16:1 的屏幕上会算出 `宽 = 高 × 16/9`
/// 并**左对齐**，右侧剩下的宽度被外层黑底填满 —— 用户看到的就是
/// 「右边一大块纯黑空白」，连控制条也只画到 16:9 边界为止。
/// 手机横屏要的是画面铺满全屏（比例交给渲染面的 `fit` 处理），而不是
/// 再套一层 16:9 盒子。
class PlayerStage extends StatelessWidget {
  const PlayerStage({
    super.key,
    required this.player,
    this.overlay,
    this.centerMessage,
    this.showSpinner = false,
    this.aspectRatio = 16 / 9,
    this.background = Colors.black,
    this.fit = BoxFit.contain,
    this.scrimAlpha = 0.45,
    this.fill = false,
    this.attachSurface = true,
  });

  final PlayerController player;

  /// 右下角等位置的常驻叠加（控制条、台标等）。
  final Widget? overlay;

  /// 居中的状态文案（缓冲中 / 无信号）。
  final String? centerMessage;

  final bool showSpinner;
  final double aspectRatio;
  final Color background;
  final BoxFit fit;

  /// 状态蒙层不透明度。
  ///
  /// 直播换台时内核里**还留着上一个台的末帧**（libmpv 直到新流首帧渲染才清屏），
  /// 蒙层一深就把它全遮住——用户看到「黑屏 + 转圈」，感觉比实际更卡。
  /// 所以 `tuning` 阶段用低透明度（0.18）：保留旧画面打底、文案可读；
  /// 只有终态失败（`failed`）才用深蒙层，那时画面已经没有保留价值。
  final double scrimAlpha;

  /// 铺满父级有界区域（直播横屏/全屏），而不是收缩成 16:9。
  ///
  /// 默认 false，保持点播页「Column 里自然得出 16:9 高度」的旧行为。
  final bool fill;

  /// 是否真的把内核渲染面挂到树上。
  ///
  /// **为什么必须有这个开关**（1.0.5 直播串台事故的根因）：
  /// 直播页与三个点播页放在同一个 `IndexedStack` 里保活，非当前页只是**不绘制**；
  /// 但视频面不是普通 Flutter 组件 ——
  ///  * Android 是 `PlatformView`（TextureView 混入合成），它的原生视图在
  ///    不绘制时仍可能留在视图层级里继续显示最后一帧；
  ///  * 桌面是 media_kit 的纹理，内核在停播后也保留末帧。
  /// 于是「从直播切到电视剧」时，直播画面就停在了点播页面上。
  /// 把渲染面从树上摘掉是唯一对两个平台都成立的隔离手段。
  final bool attachSurface;

  @override
  Widget build(BuildContext context) {
    final surface = attachSurface ? buildVideoSurface(player, fit: fit) : null;
    final Widget content = DecoratedBox(
      decoration: BoxDecoration(color: background),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!attachSurface)
            // 页面不在前台：挂一块纯黑，既不留上一路画面的残帧，
            // 也不会误报「演示内核无画面」。
            const ColoredBox(color: Colors.black)
          else if (surface != null)
            // 直接铺满：舞台已给出确定尺寸，再套一层 FittedBox 只会在窗口
            // 尺寸变化时多做一次无谓的缩放。
            surface
          else
            const _NoSurfaceHint(),
          if (centerMessage != null)
            ColoredBox(
              color: Colors.black.withValues(alpha: scrimAlpha),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showSpinner) ...[
                      const SizedBox(
                        width: 34,
                        height: 34,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.6,
                          color: AppTheme.accent,
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    Text(
                      centerMessage!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (overlay != null) Positioned.fill(child: overlay!),
        ],
      ),
    );

    if (!fill) {
      return AspectRatio(aspectRatio: aspectRatio, child: content);
    }
    // 只在**宽高都有界**时铺满：若父级给了无界高度（例如误放进可滚动
    // Column），`SizedBox.expand` 会抛布局异常——退回 16:9 是安全兜底，
    // 宁可留一条正常黑边也不能让整页崩掉。
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return AspectRatio(aspectRatio: aspectRatio, child: content);
        }
        return SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: content,
        );
      },
    );
  }
}

/// Mock 内核没有画面，必须讲明白，否则用户会以为是信号坏了。
class _NoSurfaceHint extends StatelessWidget {
  const _NoSurfaceHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.monitor_heart_outlined, color: AppTheme.textTertiary, size: 34),
          SizedBox(height: 10),
          Text(
            '当前环境使用演示内核（无画面）\n请在 Windows / Android 设备上运行',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.textTertiary, fontSize: 13, height: 1.5),
          ),
        ],
      ),
    );
  }
}
