import 'package:flutter/services.dart';

import 'form_factor.dart';
import 'screen_policy.dart';

/// 屏幕方向与系统栏策略（R4）。
///
/// 规则**集中在一处**：由 [resolveScreenPolicy] 纯函数决定，这里只负责下发。
///
/// * 电视形态：锁横屏 + 隐藏系统栏（全屏沉浸），始终如此；
/// * 手机形态：默认**不锁方向**，横竖屏都跟随系统；只有用户主动进入
///   「全屏」时才锁横屏，退出即恢复可旋转；
/// * 桌面端：不干预（窗口由用户自己调）。
///
/// 2026-11 修正：旧实现「手机 + 正在播放 → 锁横屏」，等于一开播就把整个
/// 界面钉死在横屏，竖屏被系统拒绝，用户没有任何入口转回来（全屏按钮在
/// 手机上本来就是个无效果的开关）。现在「播放」不再是锁方向的理由。
///
/// 只在「形态 / 是否全屏」发生变化时调用，不要在 build 里调：
/// `SystemChrome` 每次调用都会跨通道发一次消息，逐帧调用会让列表滚动抖动。
class DisplayMode {
  const DisplayMode({required this.onAndroid});

  final bool onAndroid;

  /// 记录上一次应用的策略，避免重复下发同一条 SystemChrome 消息。
  static String? _applied;

  Future<void> apply({
    required DeviceForm form,
    required bool fullscreen,
  }) async {
    // 桌面端：框架不接管窗口尺寸与装饰，也不该被锁方向。
    // 顺带兜住「不支持方向控制」的平台（如浏览器）：不调用就不会抛
    // MissingPluginException。
    if (!onAndroid) return;

    final policy = resolveScreenPolicy(
      isTv: form == DeviceForm.tv,
      fullscreen: fullscreen,
      isDesktop: false,
    );

    final key = '${form.name}|${policy.name}';
    if (key == _applied) return;
    _applied = key;

    switch (policy) {
      case ScreenPolicy.landscapeOnly:
        await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        // immersiveSticky 而非 immersive：允许用户从边缘短暂划出系统栏
        // 再自动收起，避免「想退退不出」。
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      case ScreenPolicy.free:
        // 四个方向都允许：手机竖着看、横着看、平板倒着拿都合规。
        await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  /// 退出应用前恢复默认，避免「退出播放器后整个桌面被锁成横屏」。
  static Future<void> restore() async {
    _applied = null;
    await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
}
