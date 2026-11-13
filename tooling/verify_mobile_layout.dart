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

/// 判断 [a] 是否**每一次**出现都在 [b] 之前，用于锁住「先解绑后释放」这类
/// 顺序敏感的销毁逻辑（顺序反了就是 native 崩溃，且编译器不会报错）。
///
/// 语义是「配对」而不是「全体比较」：源码里通常有两处销毁路径
/// （`onSurfaceTextureDestroyed` 与 `dispose`），各自成对，整体序列是
/// `a b a b`。所以这里按出现顺序扫描，要求每个 `b` 都能就近配到一个尚未
/// 配对的 `a` —— 只要出现一个「前面没有 a 的 b」就判失败。
///
/// 返回 1 = 全部合规；0 = [a] 完全没出现；-1 = 存在 `b` 早于 `a` 的位置。
int _orderOf(String source, String a, String b) {
  final marks = <(int, bool)>[]; // (位置, 是否为 a)
  for (var i = source.indexOf(a); i >= 0; i = source.indexOf(a, i + a.length)) {
    marks.add((i, true));
  }
  for (var i = source.indexOf(b); i >= 0; i = source.indexOf(b, i + b.length)) {
    marks.add((i, false));
  }
  if (!marks.any((m) => m.$2)) return 0;
  marks.sort((x, y) => x.$1.compareTo(y.$1));
  var pending = 0;
  for (final m in marks) {
    if (m.$2) {
      pending++;
    } else {
      if (pending == 0) return -1;
      pending--;
    }
  }
  return 1;
}

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
  // 桌面端不能像旧实现那样**先**被 `if (!onAndroid) return;` 拦掉：那样
  // Windows 上点全屏只让内容区变大一点，任务栏照样压着画面（用户报的
  // 「不是真全屏」）。顺序是关键——桌面分支必须在 Android 守卫之前。
  final desktopIdx = display.indexOf('if (isDesktop) {');
  final androidIdx = display.indexOf('if (!onAndroid) return;');
  check('桌面端分支存在且排在 Android 守卫之前（否则全屏仍被丢弃）',
      desktopIdx >= 0 && androidIdx > desktopIdx);
  check('桌面端把全屏真正下发到窗口层',
      RegExp(r'if \(isDesktop\) \{[\s\S]{0,400}?_window\.setFullscreen\(fullscreen\);')
          .hasMatch(display));
  check('桌面端与 Android 两路互斥（不会互相覆盖去重键）',
      display.contains("final key = 'desktop|") &&
          display.contains("final key = '\${form.name}|\${policy.name}'"));
  check('浏览器等无方向能力平台仍安全跳过', androidIdx >= 0);
  check('竖屏恢复时四个方向全部允许',
      display.contains('DeviceOrientation.portraitUp') &&
          display.contains('DeviceOrientation.portraitDown'));

  final shell = _src('lib/app/app_shell.dart');
  check('外壳按「形态 + 全屏」下发方向',
      shell.contains('.apply(form: _formFactor.form, fullscreen: _fullscreen)'));
  check('切换全屏后立即重算方向',
      RegExp(r'void _toggleFullscreen\(\) \{[\s\S]*?_applyDisplayMode\(\);')
          .hasMatch(shell));
  // 全屏切换**不许改变 Widget 树形**：同一位置父类型从 Stack 变成 IndexedStack
  // 会让 Flutter 无法复用 Element，整棵子树 unmount → 页面 State 重建 →
  // 点播页退回上一级（1.0.5 用户报的「点全屏就回退」就是这个）。
  //
  // 断言必须按**行首**匹配：文档注释里引用了这句旧写法做反面示例，
  // 用 `contains` 会把自己写的注释当成代码命中（假阴性）。
  check('全屏不再另起一棵树（旧写法已从代码中删除）',
      !RegExp(r'^\s*if \(_fullscreen\) return Scaffold\(body: content\);',
              multiLine: true)
          .hasMatch(shell));
  check('宽屏全屏只条件渲染侧栏，content 恒为 Stack 第 0 个孩子',
      RegExp(r'Positioned\.fill\(child: content\),\s*\n\s*//')
              .hasMatch(shell) &&
          shell.contains('if (!_fullscreen)'));
  check('窄屏全屏只把 appBar / bottomNavigationBar 传 null（槽位不变）',
      RegExp(r'appBar: _fullscreen\s*\n?\s*\? null').hasMatch(shell) &&
          RegExp(r'bottomNavigationBar: _fullscreen\s*\n?\s*\? null')
              .hasMatch(shell));
  check('返回键退全屏后同步收回系统栏/窗口装饰',
      RegExp(r'if \(!_fullscreen\) return;\s*\n(?:\s*//.*\n)*\s*setState\(\(\) => _fullscreen = false\);\s*\n\s*_applyDisplayMode\(\);')
          .hasMatch(shell));
  // 直播页本身不处理键盘，全屏出口必须由外壳兜住（遥控器/纯键盘用户）。
  check('外壳挂全局键盘兜底，直播页全屏可用 Esc/F 退出',
      shell.contains('HardwareKeyboard.instance.addHandler(_onGlobalKey)') &&
          shell.contains('HardwareKeyboard.instance.removeHandler(_onGlobalKey)') &&
          shell.contains('_section != AppSection.live'));
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

  // ⑥ Surface 释放时序：播放中点返回会闪退，根因是「先 release 后解绑」。
  //
  // Surface 三方共持（PlayerSurface / MpvMethodHandler.surface / ExoPlayerEngine），
  // 旧代码 dispose 里先 `surface.release()`、再 `host.detachSurface()`，而
  // `detachSurface()` 又刻意不清播放器的 surface —— 于是 ExoPlayer 渲染线程
  // 继续往已释放的 buffer 提交帧，native 崩溃闪退。
  // 这四条钉住「解绑一定在 release 之前」与「布局监听一定被注销」。
  final kotlinHandler =
      _src('android/app/src/main/kotlin/com/shunbo/shunbo/MpvMethodHandler.kt');
  check('解绑渲染面时必须让播放器脱离 Surface（否则 use-after-release）',
      kotlinHandler.contains('engine?.setSurface(null)'));
  check('原生销毁顺序：先解绑播放器，后释放 Surface',
      _orderOf(kotlinFactory, 'host.detachSurface()', 'surface?.release()') == 1);
  check('布局监听存成字段以便注销',
      kotlinFactory.contains('private val layoutListener') &&
          kotlinFactory.contains('removeOnLayoutChangeListener(layoutListener)'));
  check('缩放对已脱离窗口的视图不再 setTransform',
      kotlinScale.contains('if (!view.isAttachedToWindow) return'));
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

// ── E. 左栏底色与右栏一致（1.0.5 用户红标）──────────────────────

/// 左栏的底色走过三步：实心 `surface`（截图实测 `#121821`）→ 全透明（文字压不住
/// 亮画面，用户回退意见）→ **与右栏同值 `AppTheme.panelScrim`（78%）**。
///
/// 断言分两半，缺一半就会放过另一类回退：
///   · 值：左栏与右栏取自**同一个出口**，谁都不许各写一份 alpha；
///   · 布局：宽度、导航项、品牌区、设置入口一个字没动。
///
/// 只锁「透明/半透明」的话，有人把宽度改了照样绿；只锁宽度的话，底色又会悄悄退回去。
void testRailBackground() {
  print('\n== E. 左栏底色与右栏统一 ==');
  final shell = _src('lib/app/app_shell.dart');
  final theme = _src('lib/app/theme.dart');
  final live = _src('lib/ui/live/live_page.dart');

  // ① 唯一出口：透明度的数字只允许出现在 theme.dart 一处。
  check('透明度只在 AppTheme.panelScrim 定义一次',
      RegExp(r'static Color get panelScrim =>\s*surface\.withValues\(alpha: 0\.78\);')
          .hasMatch(theme));
  check('左栏引用该出口',
      RegExp(r'final Color _railBackground = AppTheme\.panelScrim;')
          .hasMatch(shell));
  check('右栏（频道栏浮层态）也引用该出口',
      live.contains('opaque ? AppTheme.surface : AppTheme.panelScrim'));
  // 反面：除了 theme.dart，别处不许再出现写死的 0.78。
  check('别处不再写死 alpha 0.78',
      !RegExp(r'withValues\(alpha: 0\.78\)')
          .hasMatch(shell + live.replaceAll('AppTheme.panelScrim', '')));

  check('电视轨（140 宽）用该常量', shell.contains("width: 140,\n      color: _railBackground,"));
  check('浮层侧栏（184 宽）用该常量',
      shell.contains("width: 184,\n      color: _railBackground,"));
  // 反面：rail 的 Container 上不允许再出现实心底色（`_NavItem` 选中态的高亮
  // 是「内容」，不在这一条的范围里，故只查紧跟 width 的那一行）。
  check('两处 rail 都不再画实心底色',
      !RegExp(r'width: 1(40|84),\n\s*color: AppTheme\.surface,').hasMatch(shell));
  // 回归：全透明是**已经否掉**的方案（文字在亮画面上看不清），不许再退回去。
  check('左栏不再是全透明',
      !shell.contains('_railBackground = Colors.transparent'));

  // 布局与内容不变：宽度、导航项顺序、品牌区、设置项都还在。
  check('宽度未变（140 / 184）',
      shell.contains('width: 140,') && shell.contains('width: 184,'));
  check('导航项仍来自 AppSection，顺序未改',
      shell.contains('for (final s in AppSection.values)') &&
          _src('lib/app/app_shell.dart').contains("live('电视直播'"));
  check('品牌区与设置入口仍在',
      shell.contains('_BrandMark()') &&
          shell.contains("'顺播'") &&
          shell.contains("'设置'"));
}

void main() {
  testScreenPolicy();
  testLayout();
  testWiring();
  testVideoScaleModes();
  testLandscapeDualPane();
  testFullscreenStageAndRightEntry();
  testRailBackground();
  print('');
  if (_fail == 0) {
    print('回归通过：$_pass/$_pass 断言通过');
    exit(0);
  }
  print('回归失败：$_pass/${_pass + _fail} 断言通过');
  exit(1);
}
