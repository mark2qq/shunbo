import 'dart:async';

import 'package:flutter/material.dart';

import '../core/cast/dlna/dlna_transport.dart';
import '../features/live/live_controller.dart';
import '../features/live/network_event.dart';
import '../features/vod/vod_catalog.dart';
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
  documentaries('纪录片', Icons.public_outlined, Icons.public_rounded);

  const AppSection(this.label, this.icon, this.activeIcon);

  final String label;
  final IconData icon;
  final IconData activeIcon;
}

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
    _applyDisplayMode();
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
    unawaited(DisplayMode(onAndroid: _formFactor.onAndroid)
        .apply(form: _formFactor.form, fullscreen: _fullscreen));

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
        if (_fullscreen) setState(() => _fullscreen = false);
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
              VodPage(
                section: VodSection.movies,
                services: widget.services,
                active: _section == AppSection.movies,
              ),
              VodPage(
                section: VodSection.series,
                services: widget.services,
                active: _section == AppSection.series,
              ),
              VodPage(
                section: VodSection.documentaries,
                services: widget.services,
                active: _section == AppSection.documentaries,
              ),
            ],
          );

          if (wide) {
            // 全屏：只留内容区，侧栏与频道栏全部隐藏，画面最大化。
            if (_fullscreen) {
              return Scaffold(body: content);
            }
            return Scaffold(
              body: Stack(
                children: [
                  Positioned.fill(child: content),
                  // 左侧导航栏：电视形态常驻（遥控器可达），
                  // 手机/桌面形态自动隐藏，鼠标移到左缘或悬停手柄时呼出。
                  if (tv)
                    Positioned(left: 0, top: 0, bottom: 0, child: _buildTvRail())
                  else
                    _buildSideBarOverlay(),
                ],
              ),
            );
          }

          // 全屏：窄屏同样只留内容区。
          // 旧实现只在宽屏分支判断 `_fullscreen`，手机上点「全屏」等于什么都没发生
          // （AppBar + 底部导航还在原位），用户只能认为按钮坏了。
          if (_fullscreen) return Scaffold(body: content);

          return Scaffold(
            appBar: AppBar(
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
            bottomNavigationBar: NavigationBar(
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
                    selectedIcon: Icon(s.activeIcon, size: 22, color: AppTheme.accent),
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
      color: AppTheme.surface,
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
      color: AppTheme.surface,
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
