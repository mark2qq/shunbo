import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 桌面端视频表面（media_kit 的 `Video`，底层是 libmpv 渲染到 Flutter 纹理）。
///
/// 与 Android 的 `PlayerSurface`（PlatformView + TextureView）并列：两条路各自走
/// 本平台唯一的真实渲染通道，UI 只按 [needsRenderSurface] 决定挂哪一个。
///
/// `controls: null` 是刻意的：播放控制条由本工程自己的 Flutter 面板提供，
/// 再叠一层 media_kit 内置控件会出现两套按钮抢同一片区域、且键盘焦点互相干扰。
class MediaKitSurface extends StatelessWidget {
  const MediaKitSurface({
    super.key,
    required this.controller,
    this.aspectRatio = 16 / 9,
    this.fit = BoxFit.contain,
  });

  final VideoController controller;
  final double aspectRatio;

  /// 画面缩放模式：`contain` 适应 / `cover` 铺满 / `fill` 拉伸。
  ///
  /// 必须透传给 `Video`：它内部按视频真实宽高做布局，这是桌面端唯一能
  /// 实现三档的地方（在 Dart 侧自己套 `FittedBox` 会与 `Video` 的内部布局
  /// 打架，实测表现为「切到铺满后画面位置偏掉」）。
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: aspectRatio,
      child: Container(
        color: Colors.black,
        child: Video(
          controller: controller,
          controls: null,
          fit: fit,
        ),
      ),
    );
  }
}
