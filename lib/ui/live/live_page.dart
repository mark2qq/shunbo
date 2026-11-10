import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../app/live_cast.dart';
import '../../app/mobile_layout.dart';
import '../../app/theme.dart';
import '../../core/cast/cast_fallback.dart';
import '../../core/player/player_controller.dart';
import '../../data/live_region_store.dart';
import '../../features/live/live_channel.dart';
import '../../features/live/live_controller.dart';
import '../../features/live/live_geo_ip.dart';
import '../../features/live/live_region.dart';
import '../../features/live/network_channel.dart';
import '../widgets/channel_number_input.dart';
import '../widgets/channel_rail_tab.dart';
import '../widgets/edge_reveal_handle.dart';
import '../widgets/player_stage.dart';
import 'player_overlay.dart';

/// 电视直播页：**画面常驻 + 频道栏侧挂**。
///
/// 交互骨架（与 `docs/tv-ui-patterns.md` 一致）：
/// - 进页面就自动调台（由 `LiveController.bootstrap()` 完成），不要求用户先选台；
/// - 换台只换流不换页，画面区域不重建（重建会闪一次黑）；
/// - 频道按分组过滤，当前台始终高亮，换台后列表自动滚到可视区。
///
/// 2026-11 改版：
/// - 底部控制条改为**半透明玻璃悬浮层**（`player_overlay.dart`），默认精简、
///   悬停/钉住展开，不再占用画面下方的固定高度；
/// - 右侧频道栏改为**可自动隐藏、边缘呼出**的浮层（见 [_buildRailOverlay]），
///   并修复长列表滚动时菜单项被截断的问题；
/// - 左右两侧的伸缩控件统一为**默认隐藏、按需淡入**（[EdgeRevealHandle] /
///   [OnDemandCollapseButton]），初始加载不显示，行为左右一致；
/// - 接入画面缩放（fit）与全屏（应用内影院模式）；
/// - 分类栏改成**固定顺序 + 左右滑动/箭头/滚轮翻页**，少儿、其它等分类
///   常驻可达；地方频道按 IP 定位城市过滤，并可切换其它城市。
class LivePage extends StatefulWidget {
  const LivePage({
    super.key,
    required this.controller,
    required this.player,
    required this.active,
    required this.ipLocator,
    required this.regionStore,
    this.fullscreen = false,
    this.onToggleFullscreen = _noop,
    this.tvMode = false,
    this.touchInput = false,
    this.cast,
  });

  final LiveController controller;
  final PlayerController player;

  /// 当前栏目是否可见。切到别的栏目时停播，切回来续上。
  final bool active;

  /// 是否处于全屏（影院）模式：为 true 时隐藏右侧频道栏，并通知外壳隐藏侧栏。
  final bool fullscreen;

  /// 切换全屏。由外壳注入，实际状态由外壳持有（侧栏隐藏需要跨组件）。
  final VoidCallback onToggleFullscreen;

  /// 公网 IP → 当前城市（地方频道默认定位）。
  final IpCityLocator ipLocator;

  /// 用户选择的城市偏好落盘。
  final LiveRegionStore regionStore;

  /// 电视形态（R1 判定结果）。为 true 时频道栏常驻、遥控器可直达，
  /// 不再使用「鼠标移到右缘呼出」这套只对鼠标成立的交互（R3）。
  final bool tvMode;

  /// 触摸优先（手机形态）。
  ///
  /// 触摸屏上没有「鼠标悬停」这回事，所以任何**只靠悬停**才能呼出的面板
  /// 在这类设备上等于永久关闭。为 true 时：
  /// * 边缘手柄常驻可见（点击/拖动即可展开，不必先等悬停）；
  /// * 频道抽屉带遮罩、点空白处收起；
  /// * 画面区域支持上滑/下滑直切上/下一台。
  final bool touchInput;

  /// 直播投屏协调器（R12c）。为 null 表示不提供投屏入口 ——
  /// 电视形态就是 null：本机已经是输出端，让用户「投屏到电视」没有意义（R12e）。
  final LiveCastCoordinator? cast;

  static void _noop() {}

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  final ScrollController _listScroll = ScrollController();

  /// 分类栏的横向滚动控制器：选中项要自动滚进可视区。
  final ScrollController _groupScroll = ScrollController();
  final Map<String, GlobalKey> _tileKeys = <String, GlobalKey>{};
  final Map<String, GlobalKey> _chipKeys = <String, GlobalKey>{};

  /// null = 「全部」分组。
  String? _groupFilter;

  /// 用户手动选的城市；null 表示还没选过，按「上次选择 → IP 定位 → 全部」推。
  String? _city;

  /// 启动阶段读回的上次选择。
  String? _savedCity;

  /// IP 定位结果（失败为 null）。
  String? _locatedCity;

  bool _regionReady = false;

  /// 画面缩放模式（适应 / 铺满 / 拉伸）。
  BoxFit _fit = BoxFit.contain;

  /// 右侧频道栏是否展开（自动隐藏 + 边缘呼出）。
  ///
  /// 默认**收起**：手机/桌面启动直接进视频满屏画面，频道栏在需要时由
  /// 右缘手柄、控制条「频道」按钮或横滑唤出——这是主流手机播放器
  /// （视频优先）与电视 IPTV（列表侧挂）之外的标准做法。旧实现默认展开
  /// 且面板接近不透明（alpha 0.96），手机横屏启动时右边就是一大块
  /// 「黑背景」，用户第一眼以为播放器坏了。
  bool _railOpen = false;

  /// 鼠标是否正停留在频道栏上（停留期间不自动收起）。
  bool _railHovering = false;

  /// 收起频道的计时器（鼠标离开后 / 启动若干秒后延迟，避免抖动）。
  Timer? _railCloseTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    widget.cast?.addListener(_onCastChanged);
    // 首屏：频道表还没装载过就装载（bootstrap 内部会自动调第一个台）。
    if (widget.controller.channels.isEmpty) {
      unawaited(widget.controller.bootstrap());
    }
    // 启动后默认先展示频道栏（保持原有首屏布局），6 秒无操作后自动隐藏；
    // 收起后边缘伸缩控件默认不显示，鼠标移到右缘才淡入，悬停停留或点击呼出。
    //
    // 电视形态**不排这个定时器**，也不允许收起：遥控器没有「把鼠标移到右缘」
    // 这个动作，一旦收起就再也没有入口，频道列表等于永久不可达（R3）。
    if (!widget.tvMode) _scheduleRailHide(const Duration(seconds: 6));
    unawaited(_initRegion());
  }

  /// 城市初值：读回用户选择 + 并发做一次 IP 定位。
  ///
  /// 这两步都在后台跑，不进首屏关键路径——定位接口挂了/慢了，
  /// 最坏结果是「全部城市」，画面照常出，绝不弹错误框。
  Future<void> _initRegion() async {
    String? saved;
    String? located;
    try {
      saved = await widget.regionStore.load();
    } catch (_) {
      saved = null;
    }
    try {
      located = await widget.ipLocator.locate();
    } catch (_) {
      located = null;
    }
    if (!mounted) return;
    setState(() {
      _savedCity = saved;
      _locatedCity = located;
      _regionReady = true;
    });
  }

  @override
  void didUpdateWidget(covariant LivePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cast != widget.cast) {
      oldWidget.cast?.removeListener(_onCastChanged);
      widget.cast?.addListener(_onCastChanged);
    }
    if (widget.active && !oldWidget.active) {
      unawaited(widget.controller.resume());
    } else if (!widget.active && oldWidget.active) {
      unawaited(widget.controller.stop());
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    widget.cast?.removeListener(_onCastChanged);
    _listScroll.dispose();
    _groupScroll.dispose();
    _railCloseTimer?.cancel();
    super.dispose();
  }

  void _onCastChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    _maybeRetargetCast();
    // 换台后把当前台滚进可视区：遥控器连按上下台时，列表不跟随会让人失去位置感。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _tileKeys[widget.controller.current?.id];
      final ctx = key?.currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.35,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// 换台/换线路后，把新的上游地址推给投屏设备（R12c）。
  ///
  /// 只在「真的出图了」才推：`tuning` 阶段反复 notify，此时推的是正在试的
  /// 中间线路，电视会被反复 `SetAVTransportURI` 并每次都从头缓冲。
  /// 去重与「后发先至」由 [LiveCastCoordinator.retarget] 负责，这里不做判断。
  void _maybeRetargetCast() {
    final cast = widget.cast;
    if (cast == null || !cast.isCasting) return;
    final stream = widget.controller.currentStream;
    if (stream == null) return;
    unawaited(cast.retarget(
      url: stream.url,
      headers: stream.headers,
      sourceId: widget.controller.current?.id ?? '',
      playing: widget.controller.isPlaying,
    ));
  }

  /// 点控制条上的投屏按钮：未投屏 → 选设备；已投屏 → 状态与管理。
  Future<void> _onCastPressed() async {
    final cast = widget.cast;
    if (cast == null) return;
    if (cast.isCasting) {
      await _showCastingMenu(cast);
      return;
    }
    final stream = widget.controller.currentStream;
    if (stream == null) {
      _hint('当前频道还没有可播放的线路，无法投屏。');
      return;
    }
    final picked = await showModalBottomSheet<CastDevice>(
      context: context,
      backgroundColor: AppTheme.surface,
      isScrollControlled: true,
      builder: (_) => _CastDeviceSheet(cast: cast),
    );
    if (picked == null || !mounted) return;
    final ok = await cast.start(
      device: picked,
      url: stream.url,
      headers: stream.headers,
      sourceId: widget.controller.current?.id ?? '',
    );
    if (!mounted) return;
    final message = cast.status.message;
    if (message.isNotEmpty) _hint(message);
    if (ok && cast.status.modeName == '串流') {
      // 串流靠本机转发：用户一退出页面电视就断。这不是可以"以后再说"的提示。
      _hint('该频道需要本机中转（防盗链），请保持本页面运行。');
    }
  }

  Future<void> _showCastingMenu(LiveCastCoordinator cast) async {
    final status = cast.status;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('正在投屏到「${status.deviceName ?? '电视'}」'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('方式：${status.modeName ?? '直推'}'),
            const SizedBox(height: 6),
            Text(
              status.message.isEmpty ? '本机与电视同时播放，换台会自动同步到电视。' : status.message,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('继续观看'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await cast.stop();
              if (!mounted) return;
              _hint('已结束投屏，返回本机播放。');
            },
            child: const Text('结束投屏'),
          ),
        ],
      ),
    );
  }

  /// 这个台是否**只有**组播线路（没有公网 / 内网兜底）。
  bool _onlyMulticast(LiveChannel channel) =>
      channel.hasMulticast &&
      channel.streams
          .every((s) => s.channelType == LiveChannelType.multicast);

  /// 仅组播台在无专网时点击：保留条目、置灰，并给出「需要 专网网络」提示，
  /// 不启动一次注定失败的调台（方案 F8 / 验收 7）。
  Future<void> _tuneOrHint(LiveController c, LiveChannel channel) async {
    if (_onlyMulticast(channel) &&
        c.channelPolicy.multicastState != ChannelUsable.usable) {
      _hint('「${channel.name}」需要 电视专网网络（组播转单播），当前不可用');
      return;
    }
    await c.tune(channel);
  }

  void _hint(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 手机形态的「频道」弹层（主流播放器的选集/换台交互）。
  ///
  /// 为什么除了侧栏还要它：
  /// * 竖屏全屏、横屏抽屉收起时，侧栏根本不在画面上；
  /// * 手机宽度下侧栏最多 360 宽，长列表一屏只露 6~7 个台，找台很难；
  /// * 弹层从底部升起，单手可及，且支持分类筛选——这是用户对手机播放器的预期。
  Future<void> _showChannelPicker() async {
    final c = widget.controller;
    // 全屏横屏：频道入口统一走**右侧抽屉**，与右缘常驻标签同一个目的地。
    // 竖屏 / 非全屏仍用底部弹层（单手可及，且不会盖住上方画面）。
    // 两处入口不能开出两种列表，否则用户会以为有两个频道表。
    final size = MediaQuery.sizeOf(context);
    if (widget.fullscreen &&
        MobileLayout.useFullscreenChannelRail(
          width: size.width,
          height: size.height,
          touchInput: widget.touchInput,
          tvMode: widget.tvMode,
        )) {
      if (c.channels.isEmpty) {
        _hint('频道表还没准备好，请稍候再试。');
        return;
      }
      _openFullscreenRail();
      return;
    }
    if (c.channels.isEmpty) {
      _hint('频道表还没准备好，请稍候再试。');
      return;
    }
    // 打开弹层时把侧栏收起：两个列表同时在屏上会互相遮挡，
    // 而且用户此刻要操作的是弹层，不是背后的抽屉。
    if (_railOpen && widget.touchInput) _closeRail();
    final picked = await showModalBottomSheet<LiveChannel>(
      context: context,
      backgroundColor: AppTheme.surface,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ChannelPickerSheet(
        channels: c.channels,
        currentId: c.current?.id,
        numberOf: c.numberOf,
        initialGroup: _groupFilter,
      ),
    );
    if (picked == null || !mounted) return;
    unawaited(c.tune(picked));
  }

  void _openRail() {
    _railCloseTimer?.cancel();
    if (!_railOpen) setState(() => _railOpen = true);
    // 与左侧导航栏同样的时序：唤出后即使鼠标没跟进栏内，也会自动收起。
    if (!widget.tvMode) _scheduleRailHide(const Duration(seconds: 6));
  }

  void _closeRail() {
    _railCloseTimer?.cancel();
    // 电视形态不允许收起频道栏（收起后遥控器无法再唤起）。
    if (widget.tvMode) return;
    if (_railOpen) setState(() => _railOpen = false);
  }

  /// 安排频道栏收起：默认 6 秒（启动后）、离开后 1.2 秒（避免抖动）。
  /// 只要鼠标正停在栏上，就绝不收起。
  void _scheduleRailHide(Duration d) {
    _railCloseTimer?.cancel();
    // 电视形态：不排队收起。
    if (widget.tvMode) return;
    _railCloseTimer = Timer(d, () {
      if (!mounted) return;
      if (_railOpen && !_railHovering) setState(() => _railOpen = false);
    });
  }

  // ── 分类切换（左右滑动 / 箭头 / 点击 / 滚轮） ───────────────

  int get _groupIndex => LiveRegion.indexOfGroup(_groupFilter);

  /// 切到某个分类，并让选中的 chip 自动滚进可视区。
  ///
  /// 自动滚动是「少儿、其它等靠后的分类能访问到」的关键：面板只有 344px 宽，
  /// 11 个 chip 一定放不下；没有它，用户即使能横滚也不知道后面还有多少类。
  void _selectGroup(int index) {
    final next = LiveRegion.groupAt(index);
    setState(() {
      _groupFilter = next == LiveRegion.allGroup ? null : next;
    });
    _scrollGroupIntoView(index);
    // 换分类后列表回到顶部：否则从「全部」滚到底再切分类，
    // 新列表会停在一个看似随机位置。
    if (_listScroll.hasClients) {
      _listScroll.jumpTo(_listScroll.position.minScrollExtent);
    }
  }

  void _scrollGroupIntoView(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _chipKeys[LiveRegion.groupAt(index)]?.currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// 频道区左右滑动切分类（主流播放器的 Tab 手势）。
  ///
  /// 用速度阈值而不是位移：竖向列表的轻微斜向拖动不该被当成翻页。
  /// 向左滑 = 下一个分类，向右滑 = 上一个分类。
  void _onHorizontalDragEnd(DragEndDetails details) {
    final vx = details.velocity.pixelsPerSecond.dx;
    if (vx.abs() < 220) return;
    _selectGroup(LiveRegion.moveGroup(_groupIndex, vx < 0 ? 1 : -1));
  }

  /// 分类栏上的鼠标滚轮：Windows 滚轮是纵向 delta，横向 ListView 默认
  /// 完全不响应，所以「少儿 / 其它」在桌面端实际上滚不到。
  /// 把纵向滚动量换算成分类栏的横向偏移即可顺滑浏览全部分类。
  void _onGroupPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_groupScroll.hasClients) return;
    final dy = event.scrollDelta.dy;
    if (dy.abs() < 1) return;
    final max = _groupScroll.position.maxScrollExtent;
    final target = (_groupScroll.offset + dy).clamp(0.0, max);
    _groupScroll.animateTo(
      target,
      duration: const Duration(milliseconds: 130),
      curve: Curves.easeOut,
    );
  }

  // ── 地方频道按城市 ────────────────────────────────────────

  List<LiveChannel> _localChannels(LiveController c) => c.channels
      .where((ch) => ch.group == LiveRegion.localGroup)
      .toList(growable: false);

  /// 频道列表按**数字编号升序**排列。
  ///
  /// 编号由 [LiveController.numbers]（[ChannelNumberBook]）分配
  /// （CCTV-1=1、卫视 101 起、地方 201 起…），升序后列表顺序与「按号切台」保持一致：
  /// 用户看列表时数字从小到大，按遥控器数字键跳的也是同样顺序。
  /// 没有分配到编号的台排到最后（理论上极少，例如演示台）。
  List<LiveChannel> _sortByNumber(
    LiveController c,
    List<LiveChannel> channels,
  ) {
    final withNumber = <LiveChannel>[];
    final without = <LiveChannel>[];
    for (final ch in channels) {
      if (c.numberOf(ch.id) != null) {
        withNumber.add(ch);
      } else {
        without.add(ch);
      }
    }
    withNumber.sort((a, b) {
      final na = c.numberOf(a.id)!;
      final nb = c.numberOf(b.id)!;
      return na.compareTo(nb);
    });
    return <LiveChannel>[...withNumber, ...without];
  }

  /// 当前应展示的城市 / 省。频道表是异步装载的，所以每次 build 都按**当下**的
  /// 地方频道重算一次：用户选择 > IP 定位 > 本地默认（苏州）> 全部城市。
  /// 没传 [CityDirectory.defaultLocalCity] 之前，新用户开机看到的是全国
  /// 896 个地方台；现在默认只看本地台，其它地区通过下面的选择器加载。
  String _effectiveCity(List<LiveChannel> local) => _city ??
      CityDirectory.defaultCity(
        local,
        saved: _savedCity,
        located: _locatedCity,
        preferredLocal: CityDirectory.defaultLocalCity,
      );

  void _selectCity(String city) {
    setState(() => _city = city);
    unawaited(widget.regionStore.save(city));
    // 换城市后频道集合整个变了，列表回到顶部才有「重新看一遍」的感觉。
    if (_listScroll.hasClients) {
      _listScroll.jumpTo(_listScroll.position.minScrollExtent);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final kind = MobileLayout.kindOf(w, h);

        // 全屏（影院）模式：画面铺满全屏，但**手机横屏仍保留右侧频道入口**。
        //
        // 这里以前只 `return _buildVideoStage(...)`：左侧导航、右侧频道栏、
        // 右缘手柄全都不渲染，换台只剩控制条里一个图标。再叠加舞台被
        // 16:9 `AspectRatio` 缩到左边（右侧整条纯黑），就是用户截图里
        // 「右边一大块黑空白、想换台还找不到入口」的完整成因。
        if (widget.fullscreen) {
          return _buildFullscreenStage(c, w, h, kind);
        }

        // 手机/平板横屏（触摸形态、非电视）：**左画面 + 右频道常驻双栏**。
        //
        // 这些设备横屏比例普遍 2:1 以上（本机 2800x1280 ≈ 2.19:1），
        // 16:9 画面按 contain 居中后两侧会空出黑边；把「16:9 之外的那部分
        // 宽度」明确划给频道列表，既不挤画面，也不留死黑 —— 这是主流
        // 直播 App 在横屏/平板上的通行双栏布局（各有独立背景、互不遮挡）。
        //
        // 只作用于触摸形态：桌面端保留「画面铺满 + 可呼出浮层」的旧交互，
        // 电视端保留遥控器可达的常驻侧栏（tvMode 分支在 _buildRailOverlay 里）。
        if (MobileLayout.useLandscapeDualPane(
          width: w,
          height: h,
          touchInput: widget.touchInput,
          tvMode: widget.tvMode,
          fullscreen: false,
        )) {
          return _buildLandscapeDualPane(c, w, h);
        }

        if (kind == LiveLayoutKind.wideOverlay) {
          return Stack(
            children: [
              Positioned.fill(child: _buildVideoStage(c, kind: kind)),
              _buildRailOverlay(c, width: 344),
            ],
          );
        }

        if (kind == LiveLayoutKind.portraitStack) {
          // 竖屏：画面在上、频道列表在下。
          //
          // 视频高度必须**有上界**（`MobileLayout.videoHeightFor`）。旧实现直接
          // 让 `AspectRatio(16:9)` 按宽度撑高，手机横屏时视频高 480~510 而可用
          // 高度只有 360~430，于是列表被挤成 0 高度：看得见标题、一条也点不到。
          final videoH = MobileLayout.videoHeightFor(w, h);
          return Column(
            children: [
              SizedBox(
                width: double.infinity,
                height: videoH,
                child: _buildVideoStage(c, kind: kind),
              ),
              const Divider(height: MobileLayout.dividerHeight),
              // `inline: true`：竖屏时列表是页面的一部分，不存在"收起/展开"，
              // 因此不渲染右上角的收起按钮——它在这里点了不会有任何反应。
              Expanded(child: _buildRailInner(c, inline: true)),
            ],
          );
        }

        // 窄屏横屏：画面铺满，频道列表改为抽屉（右缘手柄 / 控制条按钮 / 横滑）。
        // 横屏没有纵向余量再塞一个列表，硬塞的结果就是「列表高度为 0」。
        return Stack(
          children: [
            Positioned.fill(child: _buildVideoStage(c, kind: kind)),
            _buildRailOverlay(c, width: MobileLayout.drawerWidthFor(w)),
          ],
        );
      },
    );
  }

  /// 手机横屏双栏：左视频 + 右频道列表常驻。
  ///
  /// 与「浮层」的本质区别：两栏**并排各占一份真实宽度**，频道列表不再
  /// 叠在视频上、也不会自动收起——右侧黑空白从此变成可点的频道切换区。
  Widget _buildLandscapeDualPane(LiveController c, double width, double height) {
    // 侧栏宽度＝「按高度算完 16:9 画面后剩下的宽度」，夹在 208~320。
    // 用固定 30% 会反过来把画面压出上下黑边；按剩余宽度算才两不欠。
    final railWidth = MobileLayout.landscapeRailWidthFor(width, height);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 视频区按剩余宽度铺满；内部 Video/TextureView 会按真实比例适配
        // （缩放三档已接通），舞台自身不再缩成 16:9 留右侧黑边。
        Expanded(
          child: _buildVideoStage(c, kind: LiveLayoutKind.landscapeFill),
        ),
        // 竖线分隔：明确「这是两个区域」，而不是画面没铺满留下的黑边。
        const VerticalDivider(width: 1, thickness: 1),
        SizedBox(
          width: railWidth,
          child: _buildRailInner(c, inline: true, opaque: true),
        ),
      ],
    );
  }

  /// 全屏舞台：画面铺满 + 手机横屏右侧常驻频道入口 / 抽屉。
  ///
  /// 舞台用 `Positioned.fill` 给**紧约束**，`PlayerStage(fill: true)` 会
  /// 直接铺满整个屏幕，不再被 16:9 收缩成「左边画面 + 右边纯黑」。
  /// 频道入口是叠在画面右侧的一个薄标签，不抢占画面宽度；展开时才变成
  /// 右侧抽屉，点遮罩或收起按钮即回到纯画面 —— 与主流手机播放器一致。
  Widget _buildFullscreenStage(
    LiveController c,
    double width,
    double height,
    LiveLayoutKind kind,
  ) {
    final stage = Positioned.fill(child: _buildVideoStage(c, kind: kind));
    final withRail = MobileLayout.useFullscreenChannelRail(
      width: width,
      height: height,
      touchInput: widget.touchInput,
      tvMode: widget.tvMode,
    );
    return Stack(
      children: [
        stage,
        if (withRail)
          SafeArea(
            left: false,
            child: _buildFullscreenChannelRail(
              c,
              MobileLayout.channelRailWidthFor(width),
            ),
          ),
      ],
    );
  }

  Widget _buildFullscreenChannelRail(LiveController c, double width) {
    return Stack(
      children: [
        // 展开态：半透明遮罩，点画面任意处收起（手机上最自然的退出方式）。
        if (_railOpen)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeRail,
              child: const ColoredBox(color: Color(0x66000000)),
            ),
          ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
          top: 0,
          bottom: 0,
          right: _railOpen ? 0 : -width,
          width: width,
          // 不透明：全屏底下就是黑色画面，半透明会透出黑底，
          // 又变成用户抱怨的「右边一块黑」。
          child: _buildRailInner(c, opaque: true),
        ),
        if (!_railOpen)
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 52,
            child: Center(
              child: ChannelRailTab(
                number: c.currentNumber,
                name: c.current?.name,
                onTap: _openFullscreenRail,
              ),
            ),
          ),
      ],
    );
  }

  /// 全屏右侧抽屉**不排队自动收起**。
  ///
  /// 通用浮层为了「视频优先」会在 6 秒后自动收起，但那是鼠标场景的
  /// 兜底；手机上用户正在几百个台里翻找，6 秒消失只会让人以为列表坏了。
  /// 收起改由遮罩点按、栏内收起按钮或返回键显式触发。
  void _openFullscreenRail() {
    _railCloseTimer?.cancel();
    if (!_railOpen) setState(() => _railOpen = true);
  }

  // ── 画面 + 悬浮控制层 ──────────────────────────────────

  Widget _buildVideoStage(LiveController c, {required LiveLayoutKind kind}) {
    final centre = switch (c.phase) {
      LiveTuning.idle => '正在准备信号…',
      LiveTuning.tuning => c.message,
      LiveTuning.failed => c.message,
      LiveTuning.playing => null,
    };
    // 换台阶段用**浅蒙层**：内核里还留着上一个台的末帧，深蒙层会把它全遮成
    // 「黑屏 + 转圈」——那是切台观感卡顿的最大来源（实际首帧只要 0.2~1s）。
    // 浅蒙层让旧画面透出来打底，只有终态失败才上深蒙层。
    final scrim = c.phase == LiveTuning.failed ? 0.45 : 0.18;
    final stage = PlayerStage(
      player: widget.player,
      fit: _fit,
      // 直播舞台一律铺满父级有界区域。旧的固定 16:9 在宽屏/手机横屏的
      // 松散约束下会左对齐收缩，右侧由外层黑底填满 —— 就是那块黑空白。
      // 视频比例交给渲染面的 fit（适应/铺满/拉伸）处理，不再由舞台决定。
      fill: true,
      centerMessage: centre,
      showSpinner: c.phase == LiveTuning.tuning || c.phase == LiveTuning.idle,
      background: Colors.black,
      scrimAlpha: scrim,
      // 数字输入层放在**播放器舞台内部**：Windows 上视频是引擎合成层，
      // 挂在舞台外面（AppShell 层）的浮层会被视频盖住；放进舞台后
      // 与控制条同一层级，实测可见。
      overlay: ChannelNumberInput(
        controller: widget.controller,
        child: PlayerControlsOverlay(
          controller: c,
          player: widget.player,
          fit: _fit,
          onFitChanged: (fit) => setState(() => _fit = fit),
          fullscreen: widget.fullscreen,
          onToggleFullscreen: widget.onToggleFullscreen,
          castStatus: widget.cast?.status,
          onCastPressed: widget.cast == null ? null : () => unawaited(_onCastPressed()),
          // 手机上必须有「点开频道列表」的入口：横屏抽屉收起后，光靠边缘手柄
          // 不够显眼；竖屏全屏时列表更是被画面完全盖住。
          onChannelListPressed:
              widget.tvMode ? null : () => unawaited(_showChannelPicker()),
          // 触摸形态把这枚入口**钉在控制条最右**：左侧按钮多、窄屏要横滚，
          // 放在最左或中间等于默认看不见；右侧恰好也是横握时拇指的位置。
          channelEntryOnRight: widget.touchInput && !widget.tvMode,
          touchFirst: widget.touchInput && !widget.tvMode,
          // 桌面 / Web 有鼠标：底部控制区改为自动隐藏 + 底部触发带悬停唤出。
          // 电视（遥控器）与手机（手指）都不产生 hover，必须保持控制条常驻，
          // 否则自动隐藏后用户再也唤不出来。
          autoHide: !widget.tvMode && !widget.touchInput,
        ),
      ),
    );

    // 舞台自己按 `fill: true` 铺满父级有界区域，外层不再套 `AspectRatio` /
    // `Center` 做二次缩放：那样只会在宽屏上重新引入「16:9 左对齐 + 右侧黑边」。
    // 竖屏的画面高度由 `MobileLayout.videoHeightFor` 控制，频道列表照常在下。
    final Widget sized = stage;

    // 上滑 = 下一台，下滑 = 上一台：直播类 App 在手机上的通用手势，
    // 也是「一遍遍点列表」之外最快的换台方式。只在触摸形态上挂，
    // 电视/桌面仍走列表与遥控器，避免误吞鼠标拖拽。
    final Widget body = widget.touchInput && !widget.tvMode
        ? GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragEnd: _onStageSwipe,
            child: sized,
          )
        : sized;

    return ColoredBox(color: Colors.black, child: body);
  }

  /// 画面区纵向滑动换台（仅触摸形态）。
  ///
  /// 用速度阈值而不是位移：控制条钉住后用户可能在画面上小幅拖动，
  /// 那不该被当成换台。300px/s 与分类横滑的 220 同量级，手感一致。
  void _onStageSwipe(DragEndDetails details) {
    final vy = details.velocity.pixelsPerSecond.dy;
    if (vy.abs() < 300) return;
    final c = widget.controller;
    if (c.channels.length < 2) return;
    unawaited(vy < 0 ? c.nextChannel() : c.previousChannel());
  }

  // ── 右侧频道栏（自动隐藏 + 边缘呼出） ──────────────────

  Widget _buildRailOverlay(LiveController c, {required double width}) {
    // 电视形态：频道栏常驻在右侧，不包 MouseRegion、不留呼出手柄。
    // 遥控器的可达性来自「常驻 + 可聚焦」，任何依赖悬停的浮层在电视上都不可用。
    if (widget.tvMode) {
      return Positioned(
        top: 0,
        bottom: 0,
        right: 0,
        width: width,
        child: _buildRailInner(c),
      );
    }
    return Stack(
      children: [
        // 触摸形态的抽屉语义：展开时加一层遮罩，点空白即收起。
        // 只在触摸形态加——桌面端加了会挡住画面控制条，用户想暂停还得先点一下
        // 遮罩，反而多一步。
        if (_railOpen && widget.touchInput)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeRail,
              child: const ColoredBox(color: Color(0x66000000)),
            ),
          ),
        // 展开态：从右缘滑入的浮层。
        AnimatedPositioned(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
          top: 0,
          bottom: 0,
          right: _railOpen ? 0 : -width,
          width: width,
          child: MouseRegion(
            onEnter: (_) {
              setState(() => _railHovering = true);
              _railCloseTimer?.cancel();
            },
            onExit: (_) {
              setState(() => _railHovering = false);
              _scheduleRailHide(const Duration(milliseconds: 1200));
            },
            child: _buildRailInner(c),
          ),
        ),
        // 收起态：右缘呼出手柄。
        //
        // 触摸形态下必须**常驻可见**：这个手柄此前的唯一呼出方式是
        // `MouseRegion.onEnter`，而触摸屏不产生 hover 事件，30px 热区里
        // 又因为 `IgnorePointer` 连点击都落不下去——6 秒自动收起之后，
        // 频道栏就在这台设备上永久消失了（用户表现为「无法切换频道」）。
        if (!_railOpen)
          EdgeRevealHandle(
            side: EdgeSide.right,
            onActivate: _openRail,
            persistent: widget.touchInput,
          ),
      ],
    );
  }

  /// [opaque] 用于「常驻双栏」：此时侧栏是页面的一块真实区域，不是浮层，
  /// 必须用不透明背景，否则透出后面的黑底又会被当成「右边黑空白」。
  Widget _buildRailInner(
    LiveController c, {
    bool inline = false,
    bool opaque = false,
  }) {
    final filter = _groupFilter;
    final local = _localChannels(c);
    // 分类是**叠加**的：「苏州新闻综合」既在「地方频道」也在「新闻」，
    // 所以过滤用 inCategory 而不是 `group ==`。
    final base = filter == null
        ? c.channels
        : c.channels.where((ch) => ch.inCategory(filter)).toList(growable: false);
    // 只有「地方频道」这一栏按城市过滤；其它分类保持原样的完整列表。
    final sorted = _sortByNumber(
      c,
      filter == LiveRegion.localGroup
          ? CityDirectory.filter(base, _effectiveCity(local))
          : base,
    );
    // 4K / 超高清频道归集到每个列表最前面，作为**显示层**规则：
    // 不参与台号排序、不影响按号切台与线路优先级，只做一次稳定分区。
    // 规则与兼容分支共用 ChannelQuality，手机和电视不会出现两套 4K 名单。
    final visible = ChannelQuality.fourKFirst(
      sorted,
      (ch) => ChannelQuality.is4K(ch.name),
    );

    return Container(
      decoration: BoxDecoration(
        // 浮层态半透明（0.78）：能透出背后还在播的画面，不再像一块死黑面板
        // 盖死视频；常驻双栏态则完全不透明，让右侧成为一块有内容的实区。
        color: opaque ? AppTheme.surface : AppTheme.surface.withValues(alpha: 0.78),
        border: const Border(
          left: BorderSide(color: AppTheme.divider, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
            child: Row(
              children: [
                const Text(
                  '频道',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${visible.length}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textTertiary),
                ),
                const Spacer(),
                // 与左侧导航栏一致的收起入口：默认隐藏，鼠标停在栏上才淡入。
                // 电视形态不提供收起（收起后遥控器无法唤起），这也保证了
                // 「焦点不会因为栏被隐藏而丢失」（R3）。
                OnDemandCollapseButton(
                  side: EdgeSide.right,
                  // 触摸形态没有悬停：收起按钮必须常驻，否则用户只能靠"等 6 秒自动收起"
                  // 或点遮罩，而这个按钮就在眼前却看不见。
                  visible: !inline &&
                      (_railHovering || widget.touchInput) &&
                      !widget.tvMode,
                  onPressed: _closeRail,
                ),
              ],
            ),
          ),
          _buildGroupBar(),
          if (filter == LiveRegion.localGroup) _buildCitySelector(local),
          const SizedBox(height: 6),
          // 频道列表：竖向滚动，长列表完整可达；外层再接一个水平拖拽手势，
          // 左右滑一下就切到相邻分类（主流播放器的分类切换方式）。
          // 用 `Expanded` 让其吃掉剩余高度并自行滚动，这是修掉
          // 「菜单项显示不全」的关键——之前列表被压在没有滚动空间的盒子里。
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                // 双栏右侧只有 208~260 宽：40px 的频道号会把台名挤成三个字。
                // 窄栏时缩号宽、去掉次要标注，让台名尽可能完整显示。
                final compactRail = box.maxWidth < 260;
                return GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragEnd: _onHorizontalDragEnd,
                  child: visible.isEmpty
                      ? _buildEmptyHint(filter, local)
                      : Scrollbar(
                          thumbVisibility: true,
                          child: ListView.builder(
                            controller: _listScroll,
                            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                            itemCount: visible.length,
                            itemBuilder: (context, i) {
                              final ch = visible[i];
                              final key =
                                  _tileKeys.putIfAbsent(ch.id, GlobalKey.new);
                              return _ChannelTile(
                                key: key,
                                channel: ch,
                                number: c.numberOf(ch.id),
                                compact: compactRail,
                                selected: c.current?.id == ch.id,
                                tuning: c.current?.id == ch.id &&
                                    c.phase == LiveTuning.tuning,
                                // 电视形态：焦点默认落在**当前播放的频道**上。
                                // 「焦点可记忆」的最低要求——进频道栏时不用再从第一个
                                // 往下按几十次找回正在看的台（R3）。
                                autofocus: widget.tvMode && c.current?.id == ch.id,
                                // F8：仅组播台在无专网时置灰但不隐藏，点击给可执行提示。
                                disabled: _onlyMulticast(ch) &&
                                    c.channelPolicy.multicastState !=
                                        ChannelUsable.usable,
                                onTap: () => unawaited(_tuneOrHint(c, ch)),
                              );
                            },
                          ),
                        ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 分类条：两端箭头 + 可横滚的常驻分类 + 鼠标滚轮翻页。
  ///
  /// 分类用 [LiveRegion.groups] 的固定顺序而不是「从当前频道表里推导」：
  /// 后者会让暂时没数据的分类整个消失，少儿 / 其它 这类靠后的分类
  /// 就再也找不到入口了。常驻 + 空态提示才是主流播放器的做法。
  Widget _buildGroupBar() {
    final index = _groupIndex;
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          _GroupArrow(
            icon: Icons.chevron_left_rounded,
            tooltip: '上一个分类',
            enabled: index > 0,
            onTap: () => _selectGroup(LiveRegion.moveGroup(index, -1)),
          ),
          Expanded(
            child: Listener(
              onPointerSignal: _onGroupPointerSignal,
              child: ListView(
                controller: _groupScroll,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                children: [
                  for (var i = 0; i < LiveRegion.groups.length; i++)
                    _GroupChip(
                      key: _chipKeys.putIfAbsent(
                          LiveRegion.groupAt(i), GlobalKey.new),
                      label: LiveRegion.groupAt(i),
                      selected: i == index,
                      onTap: () => _selectGroup(i),
                    ),
                ],
              ),
            ),
          ),
          _GroupArrow(
            icon: Icons.chevron_right_rounded,
            tooltip: '下一个分类',
            enabled: index < LiveRegion.groups.length - 1,
            onTap: () => _selectGroup(LiveRegion.moveGroup(index, 1)),
          ),
        ],
      ),
    );
  }

  /// 地方频道的省 / 市选择器：默认本地，可切到任意已收录省或城市。
  /// 选省 = 加载本省全部地方台（含省级台），选市 = 只加载本市台。
  Widget _buildCitySelector(List<LiveChannel> local) {
    final options = CityDirectory.citiesOf(local);
    final provinceOptions = CityDirectory.provincesOf(local);
    final current = _effectiveCity(local);
    final located = _locatedCity;
    final locatedMissing = _regionReady &&
        located != null &&
        _city == null &&
        _savedCity == null &&
        !options.any((o) => o.name == located) &&
        current != located;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 12, 4),
      child: Row(
        children: [
          const Icon(Icons.place_outlined,
              size: 14, color: AppTheme.textTertiary),
          const SizedBox(width: 4),
          PopupMenuButton<String>(
            tooltip: '切换城市',
            padding: EdgeInsets.zero,
            onSelected: _selectCity,
            itemBuilder: (context) => <PopupMenuEntry<String>>[
              _cityEntry(CityDirectory.allCities, '全部城市（${local.length} 台）', current),
              _cityEntry(CityDirectory.otherCities, '其它城市', current),
              if (provinceOptions.isNotEmpty) const PopupMenuDivider(),
              // 「按省」项：value 带 `省:` 前缀，与同名市（北京 / 上海）区分。
              for (final p in provinceOptions)
                _cityEntry(CityDirectory.provincePrefix + p.name,
                    '${p.name}全省（${p.count} 台）', current),
              if (options.isNotEmpty) const PopupMenuDivider(),
              for (final o in options)
                _cityEntry(o.name, '${o.name}（${o.count} 台）', current),
              // 定位到的城市若暂时没有收录频道，也放进菜单：用户仍能选中它，
              // 看到明确的空态，而不是疑惑「为什么没有我所在的城市」。
              if (located != null && !options.any((o) => o.name == located))
                _cityEntry(located, '$located（暂无收录）', current),
            ],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  CityDirectory.selectionLabel(current),
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textSecondary),
                ),
                const Icon(Icons.arrow_drop_down_rounded,
                    size: 16, color: AppTheme.textTertiary),
              ],
            ),
          ),
          const Spacer(),
          if (locatedMissing)
            Flexible(
              child: Text(
                '定位 $located · 暂无收录，已显示 '
                '${CityDirectory.selectionLabel(current)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: AppTheme.textTertiary),
              ),
            ),
        ],
      ),
    );
  }

  PopupMenuItem<String> _cityEntry(String value, String label, String current) {
    final selected = current == value;
    return PopupMenuItem<String>(
      value: value,
      height: 34,
      child: Row(
        children: [
          Icon(
            selected
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_off_rounded,
            size: 15,
            color: selected ? AppTheme.accent : AppTheme.textTertiary,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: selected ? AppTheme.textPrimary : AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyHint(String? filter, List<LiveChannel> local) {
    if (filter == LiveRegion.localGroup) {
      final city = _effectiveCity(local);
      if (city != CityDirectory.allCities) {
        return Center(
          child: Text(
            '$city 暂无收录频道，可点上方切换地区',
            style: const TextStyle(color: AppTheme.textTertiary, fontSize: 12),
          ),
        );
      }
    }
    return const Center(
      child: Text(
        '该分组暂无频道',
        style: TextStyle(color: AppTheme.textTertiary, fontSize: 13),
      ),
    );
  }
}

// ── 小部件 ────────────────────────────────────────────────

/// 分类条两端的翻页箭头：到头自动置灰。
///
/// 为什么必须有：桌面端鼠标滚轮默认不驱动横向 ListView，光靠「可横滚」
/// 等于让「少儿 / 其它」这些靠后的分类事实上不可达。箭头 + 滚轮 +
/// 左右滑动三条路都给到，遥控器/触屏/鼠标才都走得通。
class _GroupArrow extends StatelessWidget {
  const _GroupArrow({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 26,
      child: IconButton(
        tooltip: tooltip,
        onPressed: enabled ? onTap : null,
        icon: Icon(icon, size: 18),
        color: enabled
            ? AppTheme.textSecondary
            : AppTheme.textTertiary.withValues(alpha: 0.3),
        iconSize: 18,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 26, minHeight: 30),
        splashRadius: 14,
      ),
    );
  }
}

class _GroupChip extends StatelessWidget {
  const _GroupChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        // 分类同样要能被遥控器方向键选中并看清焦点（R3）。
        focusColor: AppTheme.accentDim,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? AppTheme.accentDim : AppTheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? AppTheme.accent : AppTheme.divider,
              width: selected ? 1 : 0.8,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: selected ? Colors.white : AppTheme.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    super.key,
    required this.channel,
    required this.number,
    required this.selected,
    required this.tuning,
    required this.onTap,
    this.disabled = false,
    this.autofocus = false,
    this.compact = false,
  });

  final LiveChannel channel;

  /// 数字编号（遥控器输入用；null = 还没分配）。
  final int? number;

  final bool selected;
  final bool tuning;

  /// 仅组播台在当前网络不可用：置灰但不隐藏（F8）。
  final bool disabled;
  final VoidCallback onTap;

  /// 电视形态下让「当前播放的台」拿到初始焦点（R3 焦点可记忆）。
  final bool autofocus;

  /// 窄栏（双栏右侧 ≤ 260）：缩频道号宽度、隐去次要标注，优先保住台名。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? AppTheme.surfaceHigh : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          // 电视上的焦点环必须够醒目：默认高亮在 3 米观看距离下几乎不可见，
          // 用户会以为「遥控器没反应」。
          focusColor: AppTheme.accentDim,
          autofocus: autofocus,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                // 数字编号放在**最左侧**：电视上的操作习惯是「按号跳台」，
                // 用户必须能在列表里一眼看到自己该按哪个数字，所以固定靠左。
                if (number != null)
                  SizedBox(
                    width: compact ? 26 : 40,
                    child: Text(
                      '$number',
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: compact ? 13 : 15,
                        fontWeight: FontWeight.w700,
                        color: selected
                            ? AppTheme.accent
                            : AppTheme.textSecondary,
                      ),
                    ),
                  ),
                SizedBox(width: compact ? 5 : 8),
                Expanded(
                  child: Text(
                    channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: disabled
                          ? AppTheme.textTertiary
                          : (selected
                              ? AppTheme.textPrimary
                              : AppTheme.textSecondary),
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                // 通道标注：纯公网台不显示任何文字（档位 C 界面保持干净），
                // 只有用户真的导入了专网/内网线路时才出现一个小标签。
                if (!compact && channel.channelLabel != '公网')
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text(
                      channel.channelLabel,
                      style: const TextStyle(
                          fontSize: 9, color: AppTheme.textTertiary),
                    ),
                  ),
                if (tuning)
                  const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 1.8),
                  )
                else if (selected)
                  const Icon(Icons.graphic_eq_rounded, size: 15, color: AppTheme.accent)
                else if (!channel.isPlayable)
                  const Icon(Icons.block_rounded, size: 14, color: AppTheme.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 投屏设备选择面板（R12c）。
///
/// 刻意不用 `FutureBuilder` 包 `discover()`：Future 在每次 build 都会重建，
/// 一次 5 秒的 SSDP 发现会被触发十几遍。这里在 initState 里只发一次，
/// 失败时给「重新搜索」按钮，用户能自己重来，而不是盯着转圈等超时。
class _CastDeviceSheet extends StatefulWidget {
  const _CastDeviceSheet({required this.cast});

  final LiveCastCoordinator cast;

  @override
  State<_CastDeviceSheet> createState() => _CastDeviceSheetState();
}

class _CastDeviceSheetState extends State<_CastDeviceSheet> {
  List<CastDevice>? _devices;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await widget.cast.discover();
    if (!mounted) return;
    setState(() {
      _devices = list;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cast_rounded, size: 20, color: AppTheme.accent),
                const SizedBox(width: 8),
                const Text('投屏到电视',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const Spacer(),
                if (_loading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    tooltip: '重新搜索',
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    onPressed: _load,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _loading
                  ? '正在搜索局域网内的投屏设备…'
                  : devices == null || devices.isEmpty
                      ? '未发现设备。请确认电视已开机、与本机在同一 Wi-Fi，'
                          '并在电视上打开「投屏 / DLNA / 多屏互动」。'
                      : '发现 ${devices.length} 台设备，点击开始投屏',
              style: const TextStyle(fontSize: 12, color: AppTheme.textTertiary),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: devices == null
                  ? const SizedBox.shrink()
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: devices.length,
                      itemBuilder: (_, i) {
                        final d = devices[i];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.tv_rounded),
                          title: Text(d.name),
                          subtitle: Text(d.protocol.toUpperCase(),
                              style: const TextStyle(fontSize: 11)),
                          onTap: () => Navigator.of(context).pop(d),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
            const Text(
              '直播投屏期间本机继续播放：换台要能立刻反映到电视，'
              '而本机的画面检测正是判断「这条线路还能不能用」的依据。',
              style: TextStyle(fontSize: 11, color: AppTheme.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

/// 手机形态的频道弹层（R3 触摸可达性的兜底入口）。
///
/// 与右侧侧栏刻意分开实现，不共用 `_LivePageState._listScroll`：
/// `ScrollController` 同一时刻只能挂一个 `ScrollView`，弹层与侧栏可能同时
/// 存在于树上（弹层的 modal 路由不会卸载背后页面），共用会直接抛
/// "ScrollController attached to multiple scroll views"。
class _ChannelPickerSheet extends StatefulWidget {
  const _ChannelPickerSheet({
    required this.channels,
    required this.currentId,
    required this.numberOf,
    required this.initialGroup,
  });

  final List<LiveChannel> channels;
  final String? currentId;
  final int? Function(String channelId) numberOf;

  /// 进入弹层时沿用侧栏当前的分类筛选，避免「刚在侧栏选了卫视，
  /// 打开弹层又回到全部」这种前后不一致。
  final String? initialGroup;

  @override
  State<_ChannelPickerSheet> createState() => _ChannelPickerSheetState();
}

class _ChannelPickerSheetState extends State<_ChannelPickerSheet> {
  final ScrollController _scroll = ScrollController();
  String? _group;

  @override
  void initState() {
    super.initState();
    _group = widget.initialGroup;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 按频道号升序；没有编号的排最后。
  ///
  /// 不做 `sort` 一把梭：Dart 的 `List.sort` 不稳定，同编号（或都无编号）时
  /// 顺序会随机变化，列表看起来会"自己跳"。
  List<LiveChannel> _ordered() {
    final group = _group;
    final base = group == null
        ? widget.channels
        : widget.channels.where((c) => c.inCategory(group)).toList(growable: false);
    final withNumber = <LiveChannel>[];
    final without = <LiveChannel>[];
    for (final ch in base) {
      if (widget.numberOf(ch.id) != null) {
        withNumber.add(ch);
      } else {
        without.add(ch);
      }
    }
    withNumber.sort(
        (a, b) => widget.numberOf(a.id)!.compareTo(widget.numberOf(b.id)!));
    return <LiveChannel>[...withNumber, ...without];
  }

  @override
  Widget build(BuildContext context) {
    // 72% 屏高：留出顶部画面与手势条，同时在 6 英寸屏上能一次看到 8~9 个台。
    final height = MediaQuery.sizeOf(context).height * 0.72;
    final list = _ordered();
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Row(
              children: [
                const Text(
                  '频道',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${list.length}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textTertiary),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                _GroupChip(
                  label: LiveRegion.allGroup,
                  selected: _group == null,
                  onTap: () => setState(() => _group = null),
                ),
                for (final g in LiveRegion.groups)
                  if (g != LiveRegion.allGroup)
                    _GroupChip(
                      label: g,
                      selected: _group == g,
                      onTap: () => setState(() => _group = g),
                    ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: list.isEmpty
                ? const Center(
                    child: Text(
                      '该分类下没有频道',
                      style: TextStyle(fontSize: 13, color: AppTheme.textTertiary),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final ch = list[i];
                      final selected = ch.id == widget.currentId;
                      final num = widget.numberOf(ch.id);
                      return ListTile(
                        dense: true,
                        onTap: () => Navigator.of(context).pop(ch),
                        leading: SizedBox(
                          width: 40,
                          child: Text(
                            num == null ? '—' : '$num',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: selected ? AppTheme.accent : AppTheme.textTertiary,
                            ),
                          ),
                        ),
                        title: Text(
                          ch.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                            color: selected ? AppTheme.accent : AppTheme.textPrimary,
                          ),
                        ),
                        subtitle: ch.group.isEmpty
                            ? null
                            : Text(
                                ch.group,
                                style: const TextStyle(
                                    fontSize: 11, color: AppTheme.textTertiary),
                              ),
                        trailing: selected
                            ? const Icon(Icons.graphic_eq_rounded,
                                size: 18, color: AppTheme.accent)
                            : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
