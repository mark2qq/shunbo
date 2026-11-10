import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 原生视频表面（`shunbo/player_view` PlatformView）。
///
/// **仅 Android**：桌面端不用这个，走 `ui/media_kit_surface.dart`（libmpv → 纹理）。
/// 这里保留平台判断是为了防御：如果有人在桌面误挂本组件，返回空而不是抛
/// `MissingPluginException`（AndroidView 在非 Android 平台没有实现）。
///
/// 16:9 只是兜底比例：真实产品应按视频宽高比自适应。ExoPlayer 的 `videoFormat`
/// 目前没有通过通道暴露，桌面端则由 media_kit 的 `Video` 自己按视频尺寸布局。
///
/// 缩放三档（适应 / 铺满 / 拉伸）走**原生变换矩阵**而不是 Flutter 的 `BoxFit`：
/// `TextureView` 的内容由原生合成，Flutter 对它的裁剪/缩放无从下手——
/// 在 Dart 侧套 `FittedBox` 只会缩放「已经拉伸好的画面」，既变形又浪费性能。
/// 所以这里只把模式名转发给原生（`setScaleMode`），由
/// `VideoScaleController` 按视频真实宽高重算矩阵。
class PlayerSurface extends StatefulWidget {
  const PlayerSurface({
    super.key,
    this.viewType = 'shunbo/player_view',
    this.aspectRatio = 16 / 9,
    this.fit = BoxFit.contain,
  });

  final String viewType;
  final double aspectRatio;

  /// 画面缩放模式：`contain` 适应 / `cover` 铺满 / `fill` 拉伸。
  final BoxFit fit;

  @override
  State<PlayerSurface> createState() => _PlayerSurfaceState();
}

class _PlayerSurfaceState extends State<PlayerSurface> {
  /// 与 `MainActivity.SCALE_CHANNEL` 必须逐字一致。
  static const MethodChannel _scaleChannel =
      MethodChannel('shunbo/player_view/scale');

  /// `BoxFit` → 原生模式名。取值必须与 Kotlin 侧
  /// `VideoScaleMode.fromName` 一致，写错会静默退回「适应」。
  static String _modeOf(BoxFit fit) => switch (fit) {
        BoxFit.cover => 'cover',
        BoxFit.fill => 'fill',
        _ => 'contain',
      };

  /// 是否 Android 内核。
  ///
  /// 用 `defaultTargetPlatform` 而不是 `Theme.of(context).platform`：后者是
  /// 继承组件查询，在 `initState` 里调用不合规（要等 `didChangeDependencies`），
  /// 而这里必须在首帧前就把模式下发下去。两者在真实设备上取值一致。
  static bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    _pushMode();
  }

  @override
  void didUpdateWidget(PlayerSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fit != widget.fit) _pushMode();
  }

  /// 把当前模式发给原生。
  ///
  /// 失败一律吞掉：这条通道只影响「画面怎么缩放」，桌面端没有注册该通道、
  /// 老版本 APK 也可能没有——让它抛出去会把一次无关紧要的视觉设置
  /// 变成整页异常。
  void _pushMode() {
    if (!_isAndroid) return;
    unawaited(_scaleChannel
        .invokeMethod<void>('setScaleMode', <String, Object?>{
      'mode': _modeOf(widget.fit),
    })
        .catchError((Object e) {
      debugPrint('[surface] 缩放模式下发失败（保持原生默认）：$e');
    }));
  }

  @override
  Widget build(BuildContext context) {
    if (!_isAndroid) {
      return const SizedBox.shrink();
    }
    return AspectRatio(
      aspectRatio: widget.aspectRatio,
      child: Container(
        color: Colors.black,
        child: AndroidView(
          viewType: widget.viewType,
          // 创建时就带上模式：PlatformView 首次创建时通道可能还没通，
          // 单靠 didUpdateWidget 会漏掉「首次进入就是铺满模式」的情况。
          creationParams: <String, Object?>{'mode': _modeOf(widget.fit)},
          creationParamsCodec: const StandardMessageCodec(),
          // 视频区域不参与 Flutter 手势竞争：点击/拖动手势由上层 Flutter 组件处理，
          // 否则 TextureView 会吞掉手势，导致控制条点不出来。
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        ),
      ),
    );
  }
}
