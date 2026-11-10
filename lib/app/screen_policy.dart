/// 屏幕方向策略（纯 Dart，不 import Flutter，可被 `dart run` 直接回归）。
///
/// 为什么要把「策略」从「下发」里拆出来：
/// `SystemChrome.setPreferredOrientations` 是副作用，跑在 Widget 之外，
/// 一旦写成散落在 build 里的 if，就无法断言「手机在没有进入全屏时到底
/// 有没有被锁成横屏」。而**锁了不该锁的方向**恰恰是最难自查的一类缺陷：
/// 代码里看不出问题，用户拿到手只会说「界面转不过来」。
library;

/// 允许的屏幕方向集合。
enum ScreenPolicy {
  /// 竖屏与横屏都允许，由系统按传感器（或用户手动旋转）决定。
  free,

  /// 只允许横屏。
  landscapeOnly,
}

/// 决策依据：形态 + 是否处于「横屏全屏」+ 是否桌面端。
///
/// 规则（2026-11 调整，直接对应「界面不该被强制横屏」）：
/// 1. **电视**：只允许横屏——竖屏电视不存在，这条没有例外；
/// 2. **桌面**：不接管窗口方向，一律 [ScreenPolicy.free]（真正的桌面端
///    由 `DisplayMode` 直接跳过，这里给出 free 只是让纯函数自洽）；
/// 3. **手机/平板**：默认 [ScreenPolicy.free]。**不再因为「正在播放」就锁横屏**
///    —— 用手机竖着看直播、竖着刷频道是最常见的用法，锁死横屏等于
///    把整个界面转成用户不想要的方向，而且退出播放前没有任何补救入口；
/// 4. **手机点了全屏**：这时才锁横屏。这是「按要求进入横屏」的唯一显式入口，
///    用户随时可以退出全屏回到可旋转状态，竖屏回退因此始终存在。
ScreenPolicy resolveScreenPolicy({
  required bool isTv,
  required bool fullscreen,
  required bool isDesktop,
}) {
  if (isTv) return ScreenPolicy.landscapeOnly;
  if (isDesktop) return ScreenPolicy.free;
  if (fullscreen) return ScreenPolicy.landscapeOnly;
  return ScreenPolicy.free;
}

/// 诊断/日志用的一句话说明（设置页与 `print` 共用，避免两处文案漂移）。
String describeScreenPolicy(ScreenPolicy p) => switch (p) {
      ScreenPolicy.free => '横竖屏均可',
      ScreenPolicy.landscapeOnly => '仅横屏',
    };
