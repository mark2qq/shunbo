import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/cast/dlna/dlna_transport.dart';
import '../features/live/live_controller.dart';
import '../features/live/network_event.dart';
import '../features/vod/vod_catalog.dart';
import '../platform/window_channel.dart';
import '../ui/live/live_page.dart';
import '../ui/settings/settings_page.dart';
import '../ui/vod/vod_page.dart';
import '../ui/widgets/edge_reveal_handle.dart';
import 'cast_support.dart';
import 'display_mode.dart';
import 'form_factor_controller.dart';
import 'live_cast.dart';
import 'services.dart';
import 'theme.dart';

/// 顶部/侧边栏目。
///
/// 顺序即侧栏顺序，也决定 App 启动后落在哪一栏——**电视直播必须是第一个**，
/// 因为产品定义是「打开就是直播画面」，不该让用户先做选择。
enum AppSection {
  live('电视直播', Icons.live_tv_outlined, Icons.live_tv_rounded),
  movies('电影', Icons.movie_outlined, Icons.movie_rounded),
  series('电视剧', Icons.video_library_outlined, Icons.video_library_rounded),
  documentaries('纪录片', Icons.public_outlined, Icons.public_rounded),

  /// 短视频 / 微短剧。追加在末尾：枚举序号即 `IndexedStack` 下标，
  /// 插在中间会让 1.0.4 就有的四个栏目全部错位。
  shortVideos('短视频', Icons.smart_display_outlined,
      Icons.smart_display_rounded),

  /// 动漫 / 番剧 / 动画。1.0.5 第十二次修新增，同样**只能追加在末尾**。
  /// 图标用 `animation`（胶片+播放三角），与「动画」语义一致，
  /// 也与短视频的 `smart_display`（竖屏手机）区分得开。
  anime('动漫', Icons.animation_outlined, Icons.animation_rounded);

  const AppSection(this.label, this.icon, this.activeIcon);

  final String label;
  final IconData icon;
  final IconData activeIcon;
}

/// 左侧导航栏的底色：与右侧频道栏浮层态**同一个值**（`AppTheme.panelScrim`，78%）。
///
/// 演变过程值得留一笔：1.0.5 之前左栏是整块实心 `AppTheme.surface`（用户红标截图里
/// 实测 `#121821`，与右栏透出的画面不一致）；改成全透明后导航文字直接压在亮画面上
/// 看不清，最终收敛到「和右栏一样」—— 78% 的 `surface`，既透出画面又压得住字。
///
/// 电视轨（140 宽）与浮层侧栏（184 宽）都用它；值本身只在 `AppTheme` 里定义一次。
///
/// 是 `final` 不是 `const`：`panelScrim` 由 `surface.withValues(alpha:)` 算出来，
/// 写死成 `Color(0xC7121821)` 虽然能 const，但改主题底色时会悄悄失同步。
final Color _railBackground = AppTheme.panelScrim;

/// 应用外壳：侧栏（宽屏）/ 底栏（窄屏）+ 栏目内容区。
///
/// 用 [IndexedStack] 而不是按需构建：直播页一旦被重建就会重新调台，
/// 用户「去电影页看一眼再回来」会白等一次起播。保活是这类播放器的最低要求。
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.services, this.advancedBuilder});

  final ShunboServices services;

  /// 高级工具页（原开发调试面板）的构造器，由 `main()` 注入。
  final WidgetBuilder? advancedBuilder;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  AppSection _section = AppSection.live;

  /// 全屏（影院）模式：为 true 时隐藏左侧导航栏，直播页也会据此隐藏频道栏。
  ///
  /// 状态放在外壳而不是直播页：侧栏由外壳持有，全屏按钮在直播页的控制条上——
  /// 跨组件协作必须有个共同的上层状态。直播页只负责「显示哪条源」「缩放」这类
  /// 自身范围内的事。
  ///
  /// 电视形态初始为 true：R4 要求电视全屏沉浸，遥控器不该先看到一条导航栏。
  late bool _fullscreen = widget.services.formFactor.isTv;

  /// 上一次下发的「是否在播」，用于避免逐帧重复申请/撤销前台服务保活。
  bool? _lastKeepAlive;

  /// Android 精确网络事件订阅；桌面端是空流，订阅开销为零。
  StreamSubscription<NetworkSnapshot>? _networkSub;
  bool _networkSeeded = false;

  FormFactorController get _formFactor => widget.services.formFactor;

  /// 直播投屏协调器（R12c）。懒创建：电视形态永远不建，省掉一个 DLNA 传输
  /// 与一份 UDP socket；手机上第一次点投屏才真正初始化。
  LiveCastCoordinator? _liveCastInstance;

  LiveCastCoordinator get _liveCast =>
      _liveCastInstance ??= LiveCastCoordinator(
        transport: DlnaCastTransport(),
        diagnostics: widget.services.diagnostics,
        relayFactory: startCastRelay,
        readMode: _castModes.read,
        writeMode: _castModes.write,
        probeUrlStatus: probeCastUrlStatus,
      );

  late final CastModeMemory _castModes = CastModeMemory();

  /// 传给直播页的投屏能力：电视形态为 null（R12e，本机就是输出端）。
  LiveCastCoordinator? get _liveCastForUi =>
      _formFactor.castEntryVisible ? _liveCast : null;

  void _select(AppSection s) {
    if (s == _section) return;
    setState(() => _section = s);
  }

  void _toggleFullscreen() {
    setState(() => _fullscreen = !_fullscreen);
    // 全屏是「按要求进入横屏」的显式入口（手机形态锁横屏），
    // 退出全屏立即恢复可旋转——竖屏回退必须是一步操作，不能藏进设置页。
    _applyDisplayMode();
  }

  @override
  void initState() {
    super.initState();
    // 启动时先展示侧栏（保持原有首屏布局），6 秒无操作后自动隐藏；
    // 收起后边缘伸缩控件默认不显示，鼠标移到左缘才淡入，悬停停留或点击呼出。
    //
    // 电视形态**不排这个定时器**：遥控器没有「鼠标移到边缘」这个动作，
    // 自动收起的侧栏在电视上等于永久消失（R3 禁止只能触摸的操作）。
    if (!_formFactor.isTv) _scheduleSideHide(const Duration(seconds: 6));

    _formFactor.addListener(_onFormFactorChanged);
    widget.services.live.addListener(_onPlaybackChanged);
    WidgetsBinding.instance.addObserver(this);
    _networkSub = widget.services.networkWatch.changes.listen(_onNetworkSnapshot);

    // 全屏必须有键盘出口。直播页此前完全不处理键盘事件（点播页有，
    // 直播页没有），于是进了全屏只能靠鼠标去点控制条上的按钮——
    // 遥控器/纯键盘用户等于被困在满屏画面里。
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
    // Windows：Alt+Enter 由 runner 拦下来（DefWindowProc 会把它当系统菜单），
    // 再回传到 Dart 统一翻转状态，避免「窗口切了但 Dart 还认为没切」。
    if (_formFactor.isDesktop) {
      const WindowChannel().onToggleFullscreen(_toggleFullscreen);
    }

    _applyDisplayMode();
  }

  /// 全局键盘兜底：只处理「全屏退出」，且只在直播页生效。
  ///
  /// 为什么不统一接管 Esc / F：点播页自己有一套按键语义（Esc 先退选集、
  /// 再退播放器、播放中才退全屏；F 切换影院模式），抢过来会把那一层逻辑
  /// 打乱。这里只补它没覆盖的那一半——直播页全屏后的唯一出口。
  bool _onGlobalKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (!_fullscreen) return false;
    if (_section != AppSection.live) return false;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.escape && key != LogicalKeyboardKey.keyF) {
      return false;
    }
    _toggleFullscreen();
    return true;
  }

  /// ConnectivityManager 报来的默认网络变化（已语义去重）。
  ///
  /// 第一条是订阅时的初始快照：若受限（离线/VPN/未知传输）必须立刻暂停，
  /// 否则**不重复触发**归属探测——`LiveController.bootstrap` 启动阶段已经
  /// 用同一个精确状态源做过一次识别。
  void _onNetworkSnapshot(NetworkSnapshot snapshot) {
    final first = !_networkSeeded;
    _networkSeeded = true;
    if (snapshot.shouldSuspend) {
      widget.services.live.suspendNetwork();
      return;
    }
    if (first) return;
    unawaited(widget.services.live.refreshNetwork(state: snapshot.state));
  }

  /// 回到前台时重判一次出口运营商。
  ///
  /// 用户在系统设置里换 Wi-Fi / 切流量再回来，是最常见的「网络已变」场景。
  /// Android 上取 ConnectivityManager 的精确快照：受限网络直接暂停且不发请求，
  /// 桌面端拿不到快照时沿用原来的 `refreshNetwork()` 兜底。
  /// 识别在后台跑、失败按公网兜底，不弹框也不打断正在播的画面。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshNetworkOnResume());
    }
  }

  Future<void> _refreshNetworkOnResume() async {
    final snap = await widget.services.networkWatch.currentSnapshot();
    if (snap == null) {
      await widget.services.live.refreshNetwork();
      return;
    }
    if (snap.shouldSuspend) {
      widget.services.live.suspendNetwork();
      return;
    }
    await widget.services.live.refreshNetwork(state: snap.state);
  }

  @override
  void dispose() {
    unawaited(_networkSub?.cancel());
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    WidgetsBinding.instance.removeObserver(this);
    _formFactor.removeListener(_onFormFactorChanged);
    widget.services.live.removeListener(_onPlaybackChanged);
    // 投屏中继与设备连接必须随外壳一起收掉：留一个后台转发器比留一个
    // 播放器更糟 —— 用户看不到任何迹象，流量却一直跑。
    _liveCastInstance?.dispose();
    super.dispose();
  }

  /// 形态在运行中被改变（设置页强制/取消强制）：重新决定全屏与导航形态。
  void _onFormFactorChanged() {
    if (!mounted) return;
    setState(() {
      _fullscreen = _formFactor.isTv;
      _sideOpen = !_formFactor.isTv;
    });
    if (_formFactor.isTv) {
      _sideHideTimer?.cancel();
    }
    _applyDisplayMode();
  }

  /// 播放状态变化 → 应用屏幕方向与系统栏（R4）、并维护前台服务保活（R11c）。
  ///
  /// 只在「是否在播」翻转时下发，避免每次状态通知都跨通道发一条 SystemChrome。
  void _onPlaybackChanged() {
    _applyDisplayMode();
  }

  void _applyDisplayMode() {
    // 方向只看「形态 + 是否全屏」：播放与否不再决定方向（2026-11 修正）。
    // 去重由 `DisplayMode` 自己按策略键做，这里不必再算一遍。
    //
    // `isDesktop` 必须显式传：桌面端的「全屏」不是方向问题，而是窗口问题
    // （去边框 + 覆盖显示器 + 隐藏任务栏），只有 runner 改得了。
    unawaited(DisplayMode(
      onAndroid: _formFactor.onAndroid,
      isDesktop: _formFactor.isDesktop,
    ).apply(form: _formFactor.form, fullscreen: _fullscreen));

    // R11c：播放期间启用前台服务，降低被酷开/小米等系统强杀的概率；
    // 停播即撤，避免常驻通知变成骚扰。失败静默（拿不到不该打断播放）。
    final playing = widget.services.live.phase == LiveTuning.playing;
    if (_lastKeepAlive == playing) return;
    _lastKeepAlive = playing;
    if (_formFactor.onAndroid) {
      unawaited(widget.services.systemChannel.setKeepAlive(playing));
    }
  }

  /// 左侧导航栏是否展开（自动隐藏 + 左缘呼出）。
  bool _sideOpen = true;

  /// 鼠标是否正停留在侧栏上。
  bool _sideHovering = false;

  Timer? _sideHideTimer;

  void _openSide() {
    _sideHideTimer?.cancel();
    if (!_sideOpen) setState(() => _sideOpen = true);
    // 展开后重新安排一次自动隐藏：用键盘/触摸唤出、鼠标没跟进栏内时，
    // 不能让侧栏永远停在画面上。右侧频道栏用同样的时序（左右一致）。
    _scheduleSideHide(const Duration(seconds: 6));
  }

  void _closeSide() {
    _sideHideTimer?.cancel();
    if (_sideOpen) setState(() => _sideOpen = false);
  }

  void _scheduleSideHide(Duration d) {
    _sideHideTimer?.cancel();
    _sideHideTimer = Timer(d, () {
      if (!mounted) return;
      if (_sideOpen && !_sideHovering) setState(() => _sideOpen = false);
    });
  }

  /// 左侧导航栏浮层：展开时从左缘滑入并压在内容之上。
  ///
  /// 收起态**默认不显示任何伸缩控件**：30px 边缘热区是透明的，
  /// 只有鼠标进入才淡入呼出手柄（[EdgeRevealHandle] 与右侧频道栏共用），
  /// 悬停停留 400ms 或点击才真正展开。展开态不渲染热区，避免遮挡导航项。
  Widget _buildSideBarOverlay() {
    return Stack(
      children: [
        AnimatedPositioned(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
          top: 0,
          bottom: 0,
          left: _sideOpen ? 0 : -188,
          width: 188,
          child: MouseRegion(
            onEnter: (_) {
              setState(() => _sideHovering = true);
              _sideHideTimer?.cancel();
            },
            onExit: (_) {
              setState(() => _sideHovering = false);
              _scheduleSideHide(const Duration(milliseconds: 1200));
            },
            child: _SideBar(
              selected: _section,
              onSelect: _select,
              services: widget.services,
              advancedBuilder: widget.advancedBuilder,
              collapseVisible: _sideHovering,
              onCollapse: _closeSide,
            ),
          ),
        ),
        if (!_sideOpen)
          EdgeRevealHandle(side: EdgeSide.left, onActivate: _openSide),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tv = _formFactor.isTv;
    return PopScope(
      // R3「返回键按层级逐级退出」：全屏时先退出全屏，而不是直接退到桌面。
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (!_fullscreen) return;
        // 退全屏 = 状态 + 系统层一起收回来。
        // 只 setState 不动 `_applyDisplayMode()` 的话，Android 会停在
        // immersiveSticky 且继续锁横屏（退出全屏后竖屏仍被拒绝），
        // Windows 会停在没有标题栏、没有任务栏的无边框窗口里——
        // 用户点 Esc 之后反而更找不到出口。方向与窗口装饰必须同一次收掉。
        setState(() => _fullscreen = false);
        _applyDisplayMode();
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 布局宽度只在**手机形态内部**区分「横屏平板 / 竖屏手机」；
          // 形态本身已经由 R1 判定完毕，不再用宽度反推是不是电视。
          final wide = tv || constraints.maxWidth >= 1000;
          final content = IndexedStack(
            index: _section.index,
            children: [
              LivePage(
                controller: widget.services.live,
                player: widget.services.player,
                active: _section == AppSection.live,
                fullscreen: _fullscreen,
                onToggleFullscreen: _toggleFullscreen,
                ipLocator: widget.services.ipLocator,
                regionStore: widget.services.liveRegion,
                // R3：电视形态下频道栏常驻、遥控器可达，不走「鼠标移边缘呼出」。
                tvMode: tv,
                // 触摸优先：手机形态不许把「鼠标悬停」当成呼出频道栏的唯一入口。
                touchInput: _formFactor.touchFirst,
                // R12c 直播投屏入口：电视形态为 null（本机就是输出端，R12e）。
                cast: _liveCastForUi,
              ),
              // 全屏状态由外壳统一持有：点播的「全屏」与直播是同一个开关，
              // 隐藏侧栏 / 频道栏的结构改动只有外壳做得到。
              VodPage(
                section: VodSection.movies,
                services: widget.services,
                active: _section == AppSection.movies,
                fullscreen: _fullscreen,
                onToggleFullscreen: _toggleFullscreen,
              ),
              VodPage(
                section: VodSection.series,
                services: widget.services,
                active: _section == AppSection.series,
                fullscreen: _fullscreen,
                onToggleFullscreen: _toggleFullscreen,
              ),
              VodPage(
                section: VodSection.documentaries,
                services: widget.services,
                active: _section == AppSection.documentaries,
                fullscreen: _fullscreen,
                onToggleFullscreen: _toggleFullscreen,
              ),
              VodPage(
                section: VodSection.shortVideo,
                services: widget.services,
                active: _section == AppSection.shortVideos,
                fullscreen: _fullscreen,
                onToggleFullscreen: _toggleFullscreen,
              ),
              // 1.0.5 第十二次修：第 6 个栏目。`AppSection.anime` 与
              // `VodSection.anime` 都追加在各自枚举末尾，因此这里的下标
              // 6 与 `_section.index` 天然对齐，前五项一个都不动。
              VodPage(
                section: VodSection.anime,
                services: widget.services,
                active: _section == AppSection.anime,
                fullscreen: _fullscreen,
                onToggleFullscreen: _toggleFullscreen,
              ),
            ],
          );

          if (wide) {
            // 全屏只隐藏侧栏 / 频道栏，**不改变 `content` 的父链与槽位**。
            //
            // 旧实现全屏时 `return Scaffold(body: content)`、非全屏时
            // `Scaffold(body: Stack(children: [Positioned.fill(child: content), …]))`：
            // 同一位置上父类型从 `Stack` 变成 `IndexedStack`，Flutter 无法复用
            // Element，整棵子树被 unmount → 所有页面 State 重建 → 点播页的
            // 「当前视图 / 正在看的条目」全部回到初始值。用户看到的现象就是
            // 「一点全屏，页面退回了上一级」。
            //
            // 现在两种状态共用同一个 Stack 骨架，只把侧栏条件渲染掉：
            // `content` 永远是 Stack 的第 0 个孩子、永远被 Positioned.fill 包着，
            // Element 得以复用，State 与滚动位置原样保留。
            return Scaffold(
              body: Stack(
                children: [
                  Positioned.fill(child: content),
                  // 左侧导航栏：电视形态常驻（遥控器可达），
                  // 手机/桌面形态自动隐藏，鼠标移到左缘或悬停手柄时呼出。
                  // 全屏时整条不渲染（不是透明化），画面才真正最大化。
                  if (!_fullscreen)
                    if (tv)
                      Positioned(left: 0, top: 0, bottom: 0, child: _buildTvRail())
                    else
                      _buildSideBarOverlay(),
                ],
              ),
            );
          }

          // 窄屏同样走**稳定骨架**：Scaffold 的三个槽位（appBar / body /
          // bottomNavigationBar）保持不变，全屏只是把两侧的槽位传 null。
          // 旧实现用 `if (_fullscreen) return Scaffold(body: content);` 另起一棵树，
          // 手机点全屏同样会丢 State（并且和宽屏分支是同一个 bug 的两个出口）。
          return Scaffold(
            appBar: _fullscreen
                ? null
                : AppBar(
                    title: Text(_section.label),
                    actions: [
                      IconButton(
                        tooltip: '设置',
                        icon: const Icon(Icons.settings_outlined),
                        onPressed: () => _openSettings(context),
                      ),
                    ],
                  ),
            // 窄屏分支同样要接数字输入层：窗口被拖窄 / 在手机上跑时，
            // 遥控器（外接键盘）仍然应该能按号跳台。
            body: content,
            bottomNavigationBar: _fullscreen
                ? null
                : NavigationBar(
                    backgroundColor: AppTheme.surface,
                    indicatorColor: AppTheme.accentDim,
                    selectedIndex: _section.index,
                    height: 62,
                    labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                    onDestinationSelected: (i) => _select(AppSection.values[i]),
                    destinations: [
                      for (final s in AppSection.values)
                        NavigationDestination(
                          icon: Icon(s.icon, size: 22),
                          selectedIcon:
                              Icon(s.activeIcon, size: 22, color: AppTheme.accent),
                          label: s.label,
                        ),
                    ],
                  ),
          );
        },
      ),
    );
  }

  /// 电视形态的左侧导航：**常驻**、可聚焦、图标 + 文字（遥控器上纯图标不好认）。
  ///
  /// 与手机/桌面形态的浮层侧栏是同一份导航数据，只是不再依赖鼠标悬停——
  /// 交互差异集中在布局层，业务与导航项定义一处维护。
  Widget _buildTvRail() {
    return Container(
      width: 140,
      color: _railBackground,
      child: FocusTraversalGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 20, 16, 14),
              child: Row(
                children: [
                  _BrandMark(),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '顺播',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            for (final s in AppSection.values)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: _TvNavItem(
                  section: s,
                  selected: s == _section,
                  autofocus: s == _section,
                  onTap: () => _select(s),
                ),
              ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 14),
              child: _TvNavItem(
                icon: Icons.settings_outlined,
                label: '设置',
                selected: false,
                autofocus: false,
                onTap: () => _openSettings(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(
          services: widget.services,
          advancedBuilder: widget.advancedBuilder,
        ),
      ),
    );
  }
}

class _TvNavItem extends StatelessWidget {
  const _TvNavItem({
    this.section,
    this.icon,
    this.label,
    required this.selected,
    required this.autofocus,
    required this.onTap,
  });

  /// 栏目项（与 `_NavItem` 共用同一份 [AppSection] 定义）。
  final AppSection? section;

  /// 非栏目项（设置）用显式图标与文案。
  final IconData? icon;
  final String? label;

  final bool selected;
  final bool autofocus;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sec = section;
    final effectiveIcon = sec == null
        ? (icon ?? Icons.circle_outlined)
        : (selected ? sec.activeIcon : sec.icon);
    final text = sec?.label ?? label ?? '';
    return Material(
      color: selected ? AppTheme.surfaceHigh : Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        // R3：焦点必须「始终可见」。遥控器没有鼠标悬停，默认的极淡高亮在
        // 电视 3 米观看距离下几乎看不见，这里给足对比度。
        focusColor: AppTheme.accentDim,
        autofocus: autofocus,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border(
              left: BorderSide(
                color: selected ? AppTheme.accent : Colors.transparent,
                width: 2.5,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(
                effectiveIcon,
                size: 19,
                color: selected ? AppTheme.accent : AppTheme.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? AppTheme.textPrimary : AppTheme.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SideBar extends StatelessWidget {
  const _SideBar({
    required this.selected,
    required this.onSelect,
    required this.services,
    required this.collapseVisible,
    required this.onCollapse,
    this.advancedBuilder,
  });

  final AppSection selected;
  final ValueChanged<AppSection> onSelect;
  final ShunboServices services;
  final WidgetBuilder? advancedBuilder;

  /// 与右侧频道栏一致的「按需收起」入口：仅鼠标停留在栏上时淡入。
  final bool collapseVisible;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 184,
      color: _railBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
            child: Row(
              children: [
                _BrandMark(),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '顺播',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      Text(
                        'shunbo',
                        style: TextStyle(fontSize: 10, color: AppTheme.textTertiary),
                      ),
                    ],
                  ),
                ),
                OnDemandCollapseButton(
                  side: EdgeSide.left,
                  visible: collapseVisible,
                  onPressed: onCollapse,
                ),
              ],
            ),
          ),
          for (final s in AppSection.values)
            _NavItem(
              section: s,
              selected: s == selected,
              onTap: () => onSelect(s),
            ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              child: InkWell(
                borderRadius: BorderRadius.circular(9),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SettingsPage(
                      services: services,
                      advancedBuilder: advancedBuilder,
                    ),
                  ),
                ),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: Row(
                    children: [
                      Icon(Icons.settings_outlined, size: 19),
                      SizedBox(width: 12),
                      Text(
                        '设置',
                        style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: AppTheme.accent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 20),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final AppSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: selected ? AppTheme.surfaceHigh : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border(
                left: BorderSide(
                  color: selected ? AppTheme.accent : Colors.transparent,
                  width: 2.5,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected ? section.activeIcon : section.icon,
                  size: 19,
                  color: selected ? AppTheme.accent : AppTheme.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    section.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected ? AppTheme.textPrimary : AppTheme.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
