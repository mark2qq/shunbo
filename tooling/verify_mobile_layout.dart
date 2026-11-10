// 移动端（手机）两处硬伤的门禁：
//   ① 频道切换「几乎无法操作」——布局把频道列表挤成 0 高度 + 呼出只依赖鼠标悬停；
//   ② 界面被强制横屏——播放态直接锁死 landscape，竖屏无法回退。
//
// 分三层：
//   A. 方向策略（`screen_policy.dart`，纯 Dart）：手机只有「进入全屏」才锁横屏；
//   B. 布局决策（`mobile_layout.dart`，纯 Dart）：视频高度必须有上界，
//      任何常见手机尺寸下频道列表都要留够可点的高度；
//   C. 源码护栏：UI 层确实按上面两层接线（触摸形态常驻手柄、控制条有频道入口、
//      窄屏全屏也会隐藏 AppBar/底栏）。
//
// 运行：dart run tooling/verify_mobile_layout.dart
import 'dart:io';

import 'package:shunbo/app/mobile_layout.dart';
import 'package:shunbo/app/screen_policy.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (!ok) {
    _fail++;
    print('FAIL: $name${detail == null ? '' : ' —— $detail'}');
    return;
  }
  _pass++;
  print('PASS: $name');
}

String _src(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

/// 常见手机的**逻辑像素**（Flutter 的 `MediaQuery.size`），竖 / 横各一次。
///
/// 用真实机型而不是随便取的整数：断点判断（900）与比例约束的边界
/// 只有落到真机上才算数。
const Map<String, (double, double)> _devices = <String, (double, double)>{
  'iPhone 14': (390, 844),
  'iPhone 14 Pro Max': (430, 932),
  'Pixel 7': (412, 915),
  '小屏 Android': (360, 640),
  '红米大屏': (393, 873),
};

// ── A. 方向策略 ───────────────────────────────────────────────

void testScreenPolicy() {
  print('\n== A. 屏幕方向策略 ==');

  // 核心回归：手机「正在播放」不再有任何机会被锁成横屏。
  // `resolveScreenPolicy` 的签名里根本没有 playing，这条断言锁住这个事实：
  // 只要有人日后把 playing 加回来，编译期就会在这里炸掉。
  final phonePlaying = resolveScreenPolicy(
    isTv: false,
    fullscreen: false,
    isDesktop: false,
  );
  check('手机播放中：横竖屏均可', phonePlaying == ScreenPolicy.free,
      phonePlaying.name);

  check('手机点全屏：才锁横屏',
      resolveScreenPolicy(isTv: false, fullscreen: true, isDesktop: false) ==
          ScreenPolicy.landscapeOnly);

  check('手机退出全屏：恢复可旋转',
      resolveScreenPolicy(isTv: false, fullscreen: false, isDesktop: false) ==
          ScreenPolicy.free);

  check('电视：始终仅横屏（竖屏电视不存在）',
      resolveScreenPolicy(isTv: true, fullscreen: false, isDesktop: false) ==
              ScreenPolicy.landscapeOnly &&
          resolveScreenPolicy(isTv: true, fullscreen: true, isDesktop: false) ==
              ScreenPolicy.landscapeOnly);

  check('桌面：不接管方向（全屏也不锁）',
      resolveScreenPolicy(isTv: false, fullscreen: true, isDesktop: true) ==
          ScreenPolicy.free);

  check('策略说明文案不混淆',
      describeScreenPolicy(ScreenPolicy.free) == '横竖屏均可' &&
          describeScreenPolicy(ScreenPolicy.landscapeOnly) == '仅横屏');

  // 下发层护栏：`DisplayMode` 只接受 form + fullscreen，不再有 playing。
  final display = _src('lib/app/display_mode.dart');
  check('下发层不再以「是否播放」决定方向', !display.contains('playing'));
  check('下发层调用纯策略函数', display.contains('resolveScreenPolicy('));
  check('下发层对非 Android 直接跳过（浏览器/桌面不会抛异常）',
      display.contains('if (!onAndroid) return;'));
  check('竖屏恢复时四个方向全部允许',
      display.contains('DeviceOrientation.portraitUp') &&
          display.contains('DeviceOrientation.portraitDown'));

  final shell = _src('lib/app/app_shell.dart');
  check('外壳按「形态 + 全屏」下发方向',
      shell.contains('.apply(form: _formFactor.form, fullscreen: _fullscreen)'));
  check('切换全屏后立即重算方向',
      RegExp(r'void _toggleFullscreen\(\) \{[\s\S]*?_applyDisplayMode\(\);')
          .hasMatch(shell));
  check('窄屏全屏也隐藏 AppBar 与底部导航',
      RegExp(r'if \(_fullscreen\) return Scaffold\(body: content\);').hasMatch(shell));
}

// ── B. 布局决策 ───────────────────────────────────────────────

void testLayout() {
  print('\n== B. 窄屏布局决策 ==');

  check('宽屏（≥900）走浮层频道栏',
      MobileLayout.kindOf(1024, 768) == LiveLayoutKind.wideOverlay &&
          MobileLayout.kindOf(1280, 720) == LiveLayoutKind.wideOverlay);
  check('断点边界：900 走宽屏、899 走窄屏',
      MobileLayout.kindOf(900, 400) == LiveLayoutKind.wideOverlay &&
          MobileLayout.kindOf(899, 400) == LiveLayoutKind.landscapeFill);
  check('竖屏走上下分栏',
      MobileLayout.kindOf(390, 844) == LiveLayoutKind.portraitStack);
  check('窄屏横屏走抽屉（不再上下塞）',
      MobileLayout.kindOf(844, 390) == LiveLayoutKind.landscapeFill &&
          MobileLayout.kindOf(640, 360) == LiveLayoutKind.landscapeFill);

  for (final e in _devices.entries) {
    final (w, h) = e.value;
    // 竖屏
    final kind = MobileLayout.kindOf(w, h);
    check('${e.key} 竖屏($w×$h) 走上下分栏', kind == LiveLayoutKind.portraitStack,
        kind.name);

    final videoH = MobileLayout.videoHeightFor(w, h);
    check('${e.key} 竖屏视频高度非负', videoH >= 0, '$videoH');
    check('${e.key} 竖屏视频不超高', videoH <= h, '$videoH > $h');
    check('${e.key} 竖屏视频不超过 16:9 比例',
        videoH <= w * 9 / 16 + 0.001, '$videoH');
    check('${e.key} 竖屏视频不超过半屏', videoH <= h * 0.5 + 0.001, '$videoH');

    // 核心：列表必须留有可点高度。
    // 旧实现这里等于 0——这正是「换不了台」的直接原因。
    final listH =
        h - videoH - MobileLayout.dividerHeight;
    check('${e.key} 竖屏频道列表高度 ≥ ${MobileLayout.minListHeight}',
        listH >= MobileLayout.minListHeight - 0.001, 'listH=$listH');

    // 横屏
    final lk = MobileLayout.kindOf(h, w);
    check('${e.key} 横屏($h×$w) 不走上下分栏',
        lk != LiveLayoutKind.portraitStack, lk.name);

    final drawer = MobileLayout.drawerWidthFor(w);
    check('${e.key} 抽屉宽度不超过屏宽', drawer <= w, '$drawer > $w');
    check('${e.key} 抽屉宽度不小到点不中',
        drawer >= 240 || w < 240, '$drawer');
  }

  // 复现旧缺陷：844×390 横屏时 16:9 需要 474 的高度，可用只有 390。
  check('横屏 16:9 需求超过可用高度（旧实现必然挤压列表）',
      844 * 9 / 16 > 390);
  check('新实现把视频高度钳到可用范围内',
      MobileLayout.videoHeightFor(844, 390) <=
          390 - MobileLayout.dividerHeight - MobileLayout.minListHeight + 0.001,
      '${MobileLayout.videoHeightFor(844, 390)}');

  check('退化尺寸不产生负数/NaN',
      MobileLayout.videoHeightFor(0, 0) == 0 &&
          MobileLayout.videoHeightFor(1, 1) >= 0 &&
          MobileLayout.videoHeightFor(320, 260) >= 0);
}

// ── C. 源码护栏 ───────────────────────────────────────────────

void testWiring() {
  print('\n== C. UI 接线 ==');

  final page = _src('lib/ui/live/live_page.dart');
  final overlay = _src('lib/ui/live/player_overlay.dart');
  final handle = _src('lib/ui/widgets/edge_reveal_handle.dart');
  final shell = _src('lib/app/app_shell.dart');

  check('直播页用统一布局决策', page.contains('MobileLayout.kindOf(w, h)'));
  check('竖屏视频高度受控', page.contains('MobileLayout.videoHeightFor(w, h)'));
  check('横屏抽屉宽度受控', page.contains('MobileLayout.drawerWidthFor(w)'));
  check('竖屏频道列表占据剩余空间',
      RegExp(r'Expanded\(child: _buildRailInner\(c, inline: true\)\)').hasMatch(page));
  check('竖屏内嵌列表不渲染"收起"按钮（内嵌时没有收起语义）',
      page.contains('visible: !inline &&'));

  check('触摸形态手柄常驻（不再只靠悬停）',
      page.contains('persistent: widget.touchInput') &&
          handle.contains('final bool persistent'));
  check('触摸形态点击不看策略',
      handle.contains('if (!widget.persistent && !_policy.tap()) return;'));
  check('触摸形态支持从边缘向内拖动展开',
      handle.contains('onHorizontalDragEnd:'));

  check('控制条有频道列表入口', overlay.contains('onChannelListPressed'));
  check('手机形态注入频道入口',
      page.contains('widget.tvMode ? null : () => unawaited(_showChannelPicker())'));
  check('频道弹层是模态底部面板', page.contains('showModalBottomSheet<LiveChannel>('));
  check('弹层自带 ScrollController（不与侧栏共用）',
      page.contains('class _ChannelPickerSheetState extends State<_ChannelPickerSheet>') &&
          page.contains('final ScrollController _scroll = ScrollController();'));

  check('画面支持上下滑换台', page.contains('onVerticalDragEnd: _onStageSwipe'));
  check('上下滑有速度阈值（避免误切）', page.contains('if (vy.abs() < 300) return;'));
  check('上下滑只在触摸形态挂载',
      page.contains('widget.touchInput && !widget.tvMode'));

  check('外壳把触摸形态传进直播页',
      shell.contains('touchInput: _formFactor.touchFirst'));
  check('形态控制器提供触摸判定',
      _src('lib/app/form_factor_controller.dart')
          .contains('bool get touchFirst => !isDesktop && !isTv'));
}

// ── D. 画面缩放三档（适应 / 铺满 / 拉伸）全链路接线 ──────────────
//
// 这条链路以前是断的：`PlayerStage.fit` 存在但从未被使用 —— 控制条上的
// 「画面缩放」按钮点了什么都不发生（三端皆然）。所以门禁要钉住每一跳。
void testVideoScaleModes() {
  print('\n== D. 画面缩放三档接线 ==');
  final stage = _src('lib/ui/widgets/player_stage.dart');
  final kitchen = _src('lib/ui/media_kit_surface.dart');
  final surface = _src('lib/ui/player_surface.dart');
  final kotlinScale =
      _src('android/app/src/main/kotlin/com/shunbo/shunbo/VideoScale.kt');
  final kotlinFactory =
      _src('android/app/src/main/kotlin/com/shunbo/shunbo/PlayerSurfaceFactory.kt');
  final kotlinMain =
      _src('android/app/src/main/kotlin/com/shunbo/shunbo/MainActivity.kt');
  final kotlinEngine =
      _src('android/app/src/main/kotlin/com/shunbo/shunbo/ExoPlayerEngine.kt');

  // ① 舞台必须把 fit 传到渲染面（此前断在这里）。
  check('舞台把 fit 传给渲染面工厂',
      stage.contains('buildVideoSurface(player, fit: fit)'));
  check('渲染面工厂接收 fit 参数',
      stage.contains('Widget? buildVideoSurface(PlayerController player, {BoxFit fit'));

  // ② 桌面端：media_kit 的 Video 自己按视频尺寸布局，fit 必须透传。
  check('桌面渲染面把 fit 透传给 Video',
      kitchen.contains('fit: fit') && kitchen.contains('final BoxFit fit'));

  // ③ Android：走原生变换矩阵，通道名两端必须逐字一致。
  check('安卓渲染面接收 fit', surface.contains('final BoxFit fit'));
  check('安卓三档映射到原生模式名',
      surface.contains("BoxFit.cover => 'cover'") &&
          surface.contains("BoxFit.fill => 'fill'") &&
          surface.contains("_ => 'contain'"));
  check('安卓通过 scale 通道下发模式',
      surface.contains("MethodChannel('shunbo/player_view/scale')") &&
          surface.contains("invokeMethod<void>('setScaleMode'"));
  check('创建参数带初始模式（重建不丢）',
      surface.contains("creationParams: <String, Object?>{'mode': _modeOf(widget.fit)}"));

  // ④ 原生实现：三档 + 按视频真实宽高算矩阵。
  check('原生缩放控制器存在三档',
      kotlinScale.contains('enum class VideoScaleMode') &&
          kotlinScale.contains('FIT') &&
          kotlinScale.contains('CROP') &&
          kotlinScale.contains('STRETCH'));
  check('原生模式名与 Dart 侧一致',
      kotlinScale.contains('"cover" -> CROP') &&
          kotlinScale.contains('"fill" -> STRETCH'));
  check('原生按 view/视频基准比例算相对缩放',
      kotlinScale.contains('minOf(baseX, baseY)') &&
          kotlinScale.contains('maxOf(baseX, baseY)'));
  check('原生在视图尺寸变化时重算矩阵',
      kotlinFactory.contains('addOnLayoutChangeListener') &&
          kotlinFactory.contains('scale.apply('));
  check('原生销毁时注销渲染面', kotlinFactory.contains('scale.detach(textureView)'));
  check('原生创建时消费初始模式',
      kotlinFactory.contains('args as? Map<*, *>') &&
          kotlinFactory.contains('VideoScaleMode.fromName(mode)'));
  check('播放内核上报视频宽高',
      kotlinEngine.contains('onVideoSizeChanged') &&
          kotlinEngine.contains('onVideoSize?.invoke'));

  // ⑤ 通道双向同名。
  check('原生注册缩放通道', kotlinMain.contains('SCALE_CHANNEL = "shunbo/player_view/scale"'));
}

// ── E. 手机横屏双栏：右侧黑空白改为常驻频道切换区 ──────────────
// 用户反馈「右边为黑空白背景，建议右边为频道切换功能」。
void testLandscapeDualPane() {
  print('\n== E. 手机横屏双栏布局 ==');
  final page = _src('lib/ui/live/live_page.dart');

  // 决策是纯函数，四种形态必须逐一钉住：桌面 / 电视 / 竖屏 / 小屏横屏
  // 都不能被误判进双栏，全屏也必须让位给「视频优先 + 右侧抽屉」。
  check('1080×500 触摸横屏走双栏', MobileLayout.useLandscapeDualPane(
      width: 1080, height: 500,
      touchInput: true, tvMode: false, fullscreen: false));
  check('桌面（非触摸）不走双栏', !MobileLayout.useLandscapeDualPane(
      width: 1080, height: 500,
      touchInput: false, tvMode: false, fullscreen: false));
  check('电视形态不走双栏', !MobileLayout.useLandscapeDualPane(
      width: 1080, height: 500,
      touchInput: true, tvMode: true, fullscreen: false));
  check('全屏不走双栏', !MobileLayout.useLandscapeDualPane(
      width: 1080, height: 500,
      touchInput: true, tvMode: false, fullscreen: true));
  check('竖屏不走双栏', !MobileLayout.useLandscapeDualPane(
      width: 390, height: 844,
      touchInput: true, tvMode: false, fullscreen: false));
  check('小屏横屏（<700）改抽屉，不硬塞双栏', !MobileLayout.useLandscapeDualPane(
      width: 640, height: 360,
      touchInput: true, tvMode: false, fullscreen: false));

  // 侧栏宽度＝「画面按高度算完 16:9 后剩下的宽度」，不是拍脑袋的 30%。
  for (final e in <(double, double)>[
    (1080, 500),
    (844, 390),
    (640, 360),
    (1280, 720),
  ]) {
    final (w, h) = e;
    final rail = MobileLayout.landscapeRailWidthFor(w, h);
    check('$w×$h 侧栏宽度在 208~320 内',
        rail >= MobileLayout.minLandscapeRailWidth - 0.001 &&
            rail <= MobileLayout.maxLandscapeRailWidth + 0.001,
        '$rail');
    check('$w×$h 画面不被侧栏挤到比高度还窄', w - rail >= h - 0.001,
        '${w - rail} < $h');
  }
  // 核心：1080×500 的 16:9 理想宽 888.9，剩余 191 全给侧栏（下限 208），
  // 于是画面 872 宽 ≤ 理想宽，右侧不会再冒出一整条纯黑。
  final rail1080 = MobileLayout.landscapeRailWidthFor(1080, 500);
  check('1080×500 画面宽度不超过 16:9 理想宽',
      1080 - rail1080 <= 500 * 16 / 9 + 0.001, '${1080 - rail1080}');
  check('1080×500 侧栏 + 理想画面覆盖整屏（无剩余黑边）',
      rail1080 + 500 * 16 / 9 >= 1080 - 0.001);
  check('退化尺寸不产生负数/NaN',
      MobileLayout.landscapeRailWidthFor(0, 0) >= 0 &&
          MobileLayout.landscapeRailWidthFor(1, 1) >= 0);

  // 源码接线
  check('直播页调用统一双栏决策', page.contains('MobileLayout.useLandscapeDualPane('));
  check('双栏左视频右列表并排（Row + Expanded + SizedBox）',
      page.contains('Widget _buildLandscapeDualPane(LiveController c, double width, double height)') &&
          page.contains('crossAxisAlignment: CrossAxisAlignment.stretch') &&
          page.contains('child: _buildVideoStage(c, kind: LiveLayoutKind.landscapeFill)'));
  check('双栏侧栏宽度由纯函数给出',
      page.contains('MobileLayout.landscapeRailWidthFor(width, height)'));
  check('双栏频道列表常驻且不透明（不留黑空白）',
      page.contains('_buildRailInner(c, inline: true, opaque: true)') &&
          page.contains('bool opaque = false') &&
          page.contains('opaque ? AppTheme.surface :'));
  check('双栏不改变电视端与竖屏分支',
      page.contains('if (widget.tvMode) {') &&
          RegExp(r'Expanded\(child: _buildRailInner\(c, inline: true\)\)').hasMatch(page));
}

// ── F. 右侧黑底的根因 / 全屏右侧频道入口 / 窄屏无溢出 ───────────
//
// 双栏只覆盖「非全屏」；用户截图是全屏横屏：舞台被 16:9 AspectRatio
// 缩到左边（右侧整条纯黑），且全屏分支不渲染任何频道栏。这一节把
// 「舞台铺满」「右侧入口常驻」「控制条右侧钉住」「窄栏文字不截断」
// 四件事一起钉住，避免只修一半。
void testFullscreenStageAndRightEntry() {
  print('\n== F. 全屏铺满 / 右侧频道入口 / 窄屏无溢出 ==');
  final stage = _src('lib/ui/widgets/player_stage.dart');
  final page = _src('lib/ui/live/live_page.dart');
  final overlay = _src('lib/ui/live/player_overlay.dart');
  final tab = _src('lib/ui/widgets/channel_rail_tab.dart');

  // ① 根因：舞台在松散约束下不再收缩成 16:9 左对齐。
  check('舞台提供 fill 开关，点播仍默认 16:9',
      stage.contains('final bool fill;') && stage.contains('this.fill = false'));
  check('fill 模式按父级有界尺寸铺满',
      stage.contains('constraints.hasBoundedWidth') &&
          stage.contains('constraints.hasBoundedHeight') &&
          stage.contains('width: constraints.maxWidth'));
  check('fill 模式在无界约束下安全回退 16:9',
      RegExp(r'if \(!constraints\.hasBoundedWidth \|\| !constraints\.hasBoundedHeight\) \{[\s\S]{0,120}AspectRatio\(')
          .hasMatch(stage));
  check('直播舞台开启铺满，外层不再套 Center/AspectRatio',
      page.contains('fill: true') &&
          page.contains('final Widget sized = stage;') &&
          !page.contains('Center(child: stage)'));
  check('全屏舞台用 Positioned.fill 给紧约束',
      page.contains('final stage = Positioned.fill(child: _buildVideoStage(c, kind: kind));'));

  // ② 全屏横屏右侧入口：常驻标签 + 抽屉 + 不透明侧栏 + 点遮罩收起。
  check('全屏分支改走专用舞台方法',
      page.contains('return _buildFullscreenStage(c, w, h, kind);') &&
          page.contains('Widget _buildFullscreenStage('));
  check('全屏右侧入口按纯函数判定（触摸/非电视/横屏/够宽）',
      page.contains('MobileLayout.useFullscreenChannelRail('));
  check('全屏右侧抽屉宽度受限（≤42% 屏宽）',
      page.contains('MobileLayout.channelRailWidthFor(width)'));
  final wide = MobileLayout.channelRailWidthFor(1080);
  final narrow = MobileLayout.channelRailWidthFor(640);
  check('1080 宽抽屉 ≤360', wide <= 360 + 0.001, '$wide');
  check('640 宽抽屉不超过 42% 屏宽', narrow <= 640 * 0.42 + 0.001, '$narrow');
  check('全屏右侧标签常驻且带台号',
      page.contains('ChannelRailTab(') && tab.contains('final int? number') &&
          tab.contains('Icons.playlist_play_rounded'));
  check('右侧标签支持点按与贴边内滑',
      tab.contains('onTap: onTap') && tab.contains('onHorizontalDragEnd:'));
  check('全屏侧栏不透明（否则又透出黑底）',
      page.contains('child: _buildRailInner(c, opaque: true)'));
  check('全屏抽屉点遮罩收起、不排队 6 秒自动收起',
      page.contains('void _openFullscreenRail()') &&
          page.contains('onTap: _closeRail') &&
          page.contains('_railCloseTimer?.cancel();'));
  check('全屏避开挖孔/手势区', page.contains('SafeArea('));
  check('全屏右侧入口条件：小屏横屏/竖屏/电视/桌面均不显示',
      !MobileLayout.useFullscreenChannelRail(
          width: 640, height: 360, touchInput: true, tvMode: false) &&
          !MobileLayout.useFullscreenChannelRail(
              width: 390, height: 844, touchInput: true, tvMode: false) &&
          !MobileLayout.useFullscreenChannelRail(
              width: 1080, height: 500, touchInput: true, tvMode: true) &&
          !MobileLayout.useFullscreenChannelRail(
              width: 1080, height: 500, touchInput: false, tvMode: false));
  check('全屏横屏 1080×500 显示右侧入口',
      MobileLayout.useFullscreenChannelRail(
          width: 1080, height: 500, touchInput: true, tvMode: false));
  check('控制条频道入口在全屏横屏改开右侧抽屉（两种入口同一目的地）',
      page.contains('MobileLayout.useFullscreenChannelRail(') &&
          page.contains('_openFullscreenRail();'));

  // ③ 控制条：频道按钮钉在最右、其余按钮可横滚、触控目标放大。
  check('直播页按触摸形态开启右侧钉住入口',
      page.contains('channelEntryOnRight: widget.touchInput && !widget.tvMode') &&
          page.contains('touchFirst: widget.touchInput && !widget.tvMode'));
  check('控制条提供右侧钉住开关与触摸标志',
      overlay.contains('final bool channelEntryOnRight') &&
          overlay.contains('final bool touchFirst') &&
          overlay.contains('this.channelEntryOnRight = false'));
  check('右侧入口不进横滚区、独立固定',
      overlay.contains('final Widget core;') &&
          overlay.contains('const SizedBox(width: 8),') &&
          overlay.contains('channelEntry,') &&
          overlay.contains('SizedBox(\n        width: double.infinity,'));
  check('右侧入口是实色文字按钮（一眼可辨）',
      overlay.contains('class _ChannelEntryButton') &&
          overlay.contains('color: AppTheme.accent') &&
          overlay.contains("'频道'"));
  check('触摸形态按钮点击区放大到 44',
      overlay.contains('minSize: widget.touchFirst ? 44 : 38') &&
          overlay.contains('BoxConstraints(minWidth: minSize, minHeight: minSize)'));
  check('窄屏按钮区可横滚，不触发 OVERFLOW',
      overlay.contains('SingleChildScrollView(\n                scrollDirection: Axis.horizontal'));

  // ④ 窄侧栏：频道号缩宽、次要标注隐藏，保住台名。
  check('窄栏用 LayoutBuilder 判定紧凑排版',
      page.contains('final compactRail = box.maxWidth < 260;') &&
          page.contains('compact: compactRail'));
  check('紧凑台项缩号宽并隐去次要标注',
      page.contains('width: compact ? 26 : 40') &&
          page.contains('if (!compact && channel.channelLabel'));
}

void main() {
  testScreenPolicy();
  testLayout();
  testWiring();
  testVideoScaleModes();
  testLandscapeDualPane();
  testFullscreenStageAndRightEntry();
  print('');
  if (_fail == 0) {
    print('回归通过：$_pass/$_pass 断言通过');
    exit(0);
  }
  print('回归失败：$_pass/${_pass + _fail} 断言通过');
  exit(1);
}
