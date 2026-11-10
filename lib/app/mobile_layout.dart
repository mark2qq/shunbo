/// 窄屏（手机 / 平板 / 窄窗口）布局决策（纯 Dart，可被 `dart run` 直接回归）。
///
/// 这一层存在的唯一理由：**频道列表不能没有高度**。
///
/// 旧实现把窄屏硬写成 `Column[视频(16:9), 分隔线, Expanded(频道列表)]`。
/// 手机横屏时可用高度只有 360~430，而 `AspectRatio(16/9)` 按宽度算出来的
/// 视频高度是 480~510——视频先把整列撑满并溢出，`Expanded` 拿到的剩余空间
/// 变成 0，频道列表高度为 0：**列表在屏幕上"存在"但一条也点不到**，
/// 用户看到的就是「点了频道没反应，根本换不了台」。
///
/// 所以布局必须先按「可用方向」分类，再给视频一个**有上界**的高度。
library;

/// 三种窄/宽屏布局形态。
enum LiveLayoutKind {
  /// 宽屏（≥ [MobileLayout.wideBreakpoint]）：画面铺满 + 右侧频道栏浮层。
  wideOverlay,

  /// 竖屏（高 ≥ 宽）：视频在上（高度受限），频道列表占据剩余空间。
  portraitStack,

  /// 窄屏横屏（宽 > 高 且 宽 < 断点）：画面铺满，频道列表改为可呼出的抽屉。
  ///
  /// 横屏没有纵向余量再塞一个列表——硬塞的结果就是上面说的「列表高度为 0」。
  /// 抽屉是主流手机播放器的做法：需要时滑出，不需要时不挡画面。
  landscapeFill,
}

abstract final class MobileLayout {
  /// 宽度断点：≥ 此值按「宽屏 + 浮层频道栏」处理。
  ///
  /// 900 而不是 600/720：手机横屏的逻辑宽度普遍在 740~900 之间，
  /// 用 720 之类的断点会让一部分手机走进浮层分支（依赖悬停），
  /// 而另一部分走进上下分栏分支——同一台设备换个方向就换一套布局，
  /// 交互不一致比布局不完美更糟。
  static const double wideBreakpoint = 900;

  /// 频道列表至少保留的高度。
  ///
  /// 132 = 分类条(36) + 标题行(约 44) + 至少一条半的频道项(约 50)：
  /// 低于这个数，列表就只剩"看得见标题、点不到内容"，比直接隐藏更糟。
  static const double minListHeight = 132;

  /// 分隔线高度。
  static const double dividerHeight = 1;

  static LiveLayoutKind kindOf(double width, double height) {
    if (width >= wideBreakpoint) return LiveLayoutKind.wideOverlay;
    return height >= width ? LiveLayoutKind.portraitStack : LiveLayoutKind.landscapeFill;
  }

  /// 竖屏下视频区应占的高度：16:9 理想值，但不超过半屏、并给列表留足空间。
  ///
  /// 三道约束缺一不可：
  /// * `width * 9 / 16` —— 视频本身的比例，别无故留黑边；
  /// * `height * 0.5` —— 竖屏手机上半屏给画面，下半屏给内容，符合直觉；
  /// * `height - divider - minListHeight` —— 硬保底，保证列表可用。
  static double videoHeightFor(double width, double height) {
    if (width <= 0 || height <= 0) return 0;
    final ideal = width * 9 / 16;
    final half = height * 0.5;
    final reserve = height - dividerHeight - minListHeight;
    var v = ideal < half ? ideal : half;
    if (v > reserve) v = reserve;
    return v < 0 ? 0 : v;
  }

  /// 抽屉宽度：不超过屏宽的一半，也不超过 360，且不小于 240（再窄点不中）。
  static double drawerWidthFor(double width) {
    final half = width * 0.52;
    final capped = half > 360 ? 360.0 : half;
    return capped < 240 ? (width < 240 ? width : 240.0) : capped;
  }

  // ── 手机横屏「右侧留给频道」的宽度 ──────────────────────────
  //
  // 旧做法取「屏宽 30%（220~320）」是拍脑袋：在 1080×500 的手机上直接
  // 拿走 320，画面剩 760×500（1.52:1），16:9 内容上下又被压出两条黑边。
  //
  // 正确做法是**先把 16:9 画面按高度算出来，再把剩下的宽度交给频道栏**：
  // 1080×500 → 画面理想宽 889、剩余 191；给侧栏 208 之后画面 872×500
  // （1.74:1），几乎正好 16:9，两侧都不留黑边。这块宽度本来就是以前
  // 「右侧纯黑空白」，现在变成了可点的频道列表。

  /// 侧栏最小宽度：分类 chip + 台名 + 频道号在这个宽度内还能点得准。
  static const double minLandscapeRailWidth = 208;

  /// 侧栏最大宽度：再宽就变成「列表抢画面」，不是播放器该有的比例。
  static const double maxLandscapeRailWidth = 320;

  /// 小于这个宽度不常驻双栏，改用可呼出的抽屉（小屏横屏/分屏窗口）。
  static const double minDualPaneWidth = 700;

  /// 全屏时右侧呼出抽屉的宽度：不超过屏宽 42%，避免小屏横屏一开就盖住大半画面。
  static double channelRailWidthFor(double width) {
    if (width <= 0) return minLandscapeRailWidth;
    final drawer = drawerWidthFor(width);
    final cap = width * 0.42;
    return drawer > cap ? cap : drawer;
  }

  /// 常驻右侧频道栏应占的宽度：优先吃下「16:9 之外的剩余宽度」。
  static double landscapeRailWidthFor(double width, double height) {
    if (width <= 0 || height <= 0) return minLandscapeRailWidth;
    final leftover = width - height * 16 / 9;
    final rail = leftover.clamp(minLandscapeRailWidth, maxLandscapeRailWidth);
    // 硬保底：画面不能比高度还窄（否则 16:9 内容只剩中间一条）。
    final maxRail = width - height;
    if (maxRail <= 0) return minLandscapeRailWidth;
    return rail > maxRail ? maxRail : rail;
  }

  /// 是否走「左画面 + 右常驻频道栏」双栏。
  ///
  /// 四个条件缺一不可：触摸形态（桌面保留浮层）、非电视（电视有遥控器侧栏）、
  /// 非全屏（全屏要视频优先，频道改右侧抽屉）、横屏且够宽（竖屏是上下分栏）。
  static bool useLandscapeDualPane({
    required double width,
    required double height,
    required bool touchInput,
    required bool tvMode,
    required bool fullscreen,
  }) {
    return touchInput &&
        !tvMode &&
        !fullscreen &&
        width >= minDualPaneWidth &&
        kindOf(width, height) != LiveLayoutKind.portraitStack;
  }

  /// 全屏横屏是否提供「右侧频道入口 + 抽屉」。
  ///
  /// 全屏时左侧导航栏已隐藏、频道列表也不在页面上，只剩右缘手柄对新手
  /// 几乎等于没有；给一个常驻、带台号的频道标签，点击/内滑都能展开列表。
  static bool useFullscreenChannelRail({
    required double width,
    required double height,
    required bool touchInput,
    required bool tvMode,
  }) {
    return touchInput &&
        !tvMode &&
        width >= minDualPaneWidth &&
        kindOf(width, height) != LiveLayoutKind.portraitStack;
  }
}
