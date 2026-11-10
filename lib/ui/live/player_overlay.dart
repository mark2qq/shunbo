import 'dart:async';
import 'dart:ui';

import 'package:flutter/gestures.dart' show PointerHoverEvent;
import 'package:flutter/material.dart';

import '../../app/live_cast.dart';
import '../../app/theme.dart';
import '../../core/player/player_controller.dart';
import '../../features/live/live_channel.dart';
import '../../features/live/live_controller.dart';
import '../widgets/auto_hide_controls_policy.dart';

/// 当前线路的通道后缀（只在线路选择入口的提示文案里出现）。
String channelHintOf(LiveStream? stream) {
  if (stream == null || stream.channelType == LiveChannelType.public) return '';
  return '（当前：${LiveChannel.typeLabel(stream.channelType)}）';
}

/// 直播播放器悬浮控制层（半透明玻璃质感）。
///
/// 设计目标（对齐主流播放器：VLC / PotPlayer / 各视频网站）：
/// 1. **默认精简**：只在底部留一条矮控制条，露出「快退 / 上一台 / 播放暂停 /
///    下一台 / 快进 / 音量 / 缩放 / 全屏」这些核心按钮，不占画面；
/// 2. **悬停展开**：鼠标移入播放区 → 顶部浮出「频道名 + 状态 + 源信息」，
///    底部控制条加高、在**同一行**补齐「换线路 / 刷新 / 音量滑块 / 来源说明」
///    （按用户标注，源操作不再独占上面一行，控制条因此更矮）；
/// 3. **移出收起**：鼠标离开 1.5 秒后自动回落到精简态；
/// 4. **触屏 / 遥控器兜底**：点一下画面切换「钉住」，暂停 / 无信号时强制展开，
///    否则这类没有鼠标悬停的设备永远看不到控制条。
/// 5. **桌面自动隐藏**（[autoHide]）：默认整条控制区移出屏幕，鼠标移入页面
///    底部触发带并短暂停留才滑入；离开触发带或长时间无操作再滑出。
///    显隐状态机在 [AutoHideControlsPolicy]，含防快速划过、防重复唤出、
///    显示期间控制项可操作、隐藏时不拦截画面等边界处理。
///
/// 整条控制条用 `BackdropFilter` 做毛玻璃 + 底部黑色渐变，参考主流播放器的
/// 半透明叠层而不是实色色块。
class PlayerControlsOverlay extends StatefulWidget {
  const PlayerControlsOverlay({
    super.key,
    required this.controller,
    required this.player,
    required this.fit,
    required this.onFitChanged,
    required this.fullscreen,
    required this.onToggleFullscreen,
    this.castStatus,
    this.onCastPressed,
    this.onChannelListPressed,
    this.channelEntryOnRight = false,
    this.touchFirst = false,
    this.autoHide = false,
  });

  final LiveController controller;
  final PlayerController player;
  final BoxFit fit;

  /// 缩放模式变化（适应 / 铺满 / 拉伸）。
  final ValueChanged<BoxFit> onFitChanged;

  final bool fullscreen;

  /// 全屏（应用内影院模式）开关。
  final VoidCallback onToggleFullscreen;

  /// 直播投屏状态（R12c）。为 null 表示当前形态不提供投屏入口
  /// （电视形态本机就是输出端，见 R12e），按钮整颗不渲染。
  final LiveCastStatus? castStatus;

  /// 点投屏按钮：由 `LivePage` 弹设备选择 / 结束投屏菜单。
  final VoidCallback? onCastPressed;

  /// 点「频道」按钮：由 `LivePage` 弹底部频道列表。
  ///
  /// 手机形态必须给这个入口：竖屏全屏或横屏抽屉收起时，侧栏不在画面上，
  /// 只留一个贴边手柄对新手几乎等于没有。为 null 表示不提供（电视形态
  /// 侧栏常驻，不需要第二个入口）。
  final VoidCallback? onChannelListPressed;

  /// 触摸形态：把「频道」入口**钉在控制条最右**，且不被横向滚动带出屏幕。
  ///
  /// 桌面/TV 仍按旧布局放在最左（那儿不与遥控器方向键的焦点顺序冲突）。
  /// 手机上按钮本来就有十来个，窄屏必须横滚；把最常用的换台入口放在
  /// 滚动区里，等于让它默认不可见 —— 这是旧实现在窄屏上最难用的一点。
  final bool channelEntryOnRight;

  /// 触摸形态：按钮点击区放大到 44×44（Material 的最小可点尺寸）。
  final bool touchFirst;

  /// 桌面 / Web：底部控制区自动隐藏 + 底部悬停唤出。
  ///
  /// 电视与纯触摸形态**必须保持 false**：遥控器与手指不产生 hover 事件，
  /// 一旦自动隐藏就再也唤不出来。此时仍走原来的「精简条常驻 + 点画面钉住」。
  final bool autoHide;

  @override
  State<PlayerControlsOverlay> createState() => _PlayerControlsOverlayState();
}

class _PlayerControlsOverlayState extends State<PlayerControlsOverlay> {
  /// 自动隐藏的时间分辨率：50ms 一帧，足够平滑且不会造成 rebuild 风暴
  /// （只有 [AutoHideControlsPolicy.advance] 返回 true 才 setState）。
  static const int _autoHideTickMs = 50;

  /// 页面底部触发带高度。控制条本身（展开 82 / 精简 54）落在带内，
  /// 因此「从触发带移到控制条上」不会被判成离开。
  static const double _autoHideTriggerHeight = 96;

  /// 滑入 / 滑出 + 淡入 / 淡出共用时长，保证视觉同步。
  static const Duration _autoHideAnim = Duration(milliseconds: 220);

  bool _hovering = false;

  /// 触屏 / 遥控器：点画面钉住控制条，再点收起。
  bool _pinned = false;

  /// 鼠标离开后的收起计时（避免抖动）。仅非自动隐藏形态使用。
  Timer? _collapseTimer;

  /// 自动隐藏状态机（纯 Dart）；null 表示该形态不启用自动隐藏。
  AutoHideControlsPolicy? _autoHidePolicy;
  Timer? _autoHideTicker;

  /// 播放区高度，由 LayoutBuilder 缓存；无限高时置 0，策略自动不动。
  double _stageHeight = 0;

  double _volume = 100;
  bool _muted = false;
  double _lastVolumeBeforeMute = 100;

  @override
  void initState() {
    super.initState();
    _volume = widget.player.volume;
    widget.player.volumeChanges.listen((v) {
      if (!mounted) return;
      // 用户正在拖滑块时，内核回灌的值先不覆盖本地显示，避免抖动。
      if (!_draggingVolume) setState(() => _volume = v);
    });
    if (widget.autoHide) _startAutoHide();
  }

  @override
  void didUpdateWidget(covariant PlayerControlsOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.autoHide != oldWidget.autoHide) {
      _stopAutoHide();
      if (widget.autoHide) _startAutoHide();
      setState(() {});
    } else if (widget.autoHide && widget.fullscreen != oldWidget.fullscreen) {
      // 全屏切换会改变舞台高度，之前缓存的鼠标位置已失效：
      // 清掉悬停态，避免用旧坐标误判触发带。
      _autoHidePolicy?.pointerLeave();
      setState(() {});
    }
  }

  @override
  void dispose() {
    _collapseTimer?.cancel();
    _stopAutoHide();
    super.dispose();
  }

  void _startAutoHide() {
    _autoHideTicker?.cancel();
    final policy = AutoHideControlsPolicy(
      triggerHeight: _autoHideTriggerHeight,
    );
    _autoHidePolicy = policy;
    _autoHideTicker = Timer.periodic(
      const Duration(milliseconds: _autoHideTickMs),
      (_) {
        if (!mounted || !policy.needsTicking) return;
        if (policy.advance(_autoHideTickMs)) setState(() {});
      },
    );
  }

  void _stopAutoHide() {
    _autoHideTicker?.cancel();
    _autoHideTicker = null;
    _autoHidePolicy?.reset();
    _autoHidePolicy = null;
  }

  /// 点击 / 拖动任意控制项：视为一次操作，推迟自动隐藏。
  void _noteInteraction() => _autoHidePolicy?.interaction();

  /// 正在拖音量滑块（期间不覆盖本地值）。
  bool _draggingVolume = false;

  bool get _needsControls =>
      widget.controller.phase != LiveTuning.playing ||
      widget.controller.isPaused;

  /// 整层控制区是否可见。非自动隐藏形态恒 true（保持旧行为）；
  /// 暂停 / 无信号 / 钉住三种兜底会强制显示，不会被自动隐藏吃掉。
  bool get _chromeVisible => !widget.autoHide ||
      (_autoHidePolicy?.visible ?? false) ||
      _pinned ||
      _needsControls;

  /// 是否展开完整控制：
  /// - 自动隐藏形态：唤出即完整展开，隐藏时整层收起（不再有常驻精简条）；
  /// - 其余形态：悬停 / 钉住 / 需要常驻任一满足。
  bool get _expanded => widget.autoHide
      ? _chromeVisible
      : (_hovering || _pinned || _needsControls);

  void _scheduleCollapse() {
    _collapseTimer?.cancel();
    _collapseTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      // 仅当鼠标确实离开、且此刻不需要常驻时才收起。
      if (!_hovering && !_pinned && !_needsControls) {
        setState(() {});
      }
    });
  }

  void _onEnter(PointerEvent _) {
    // 自动隐藏形态由底部触发带状态机接管，整幅画面 hover 不再算「展开」。
    if (widget.autoHide) return;
    _collapseTimer?.cancel();
    if (!_hovering) setState(() => _hovering = true);
  }

  void _onExit(PointerEvent _) {
    if (widget.autoHide) {
      _autoHidePolicy?.pointerLeave();
      return;
    }
    setState(() => _hovering = false);
    _scheduleCollapse();
  }

  /// 鼠标在播放区内移动：把局部坐标交给状态机判断是否进入底部触发带。
  void _onHover(PointerHoverEvent e) {
    _autoHidePolicy?.pointerMove(
      x: e.localPosition.dx,
      y: e.localPosition.dy,
      height: _stageHeight,
    );
  }

  /// 鼠标进入控制条本身：暂停空闲计时，保证显示期间按钮始终可点。
  void _onControlsEnter(PointerEvent _) =>
      _autoHidePolicy?.enterControls();

  void _onControlsExit(PointerEvent _) =>
      _autoHidePolicy?.exitControls();

  void _togglePin() => setState(() => _pinned = !_pinned);

  void _toggleMute() {
    setState(() {
      if (_muted || _volume <= 0) {
        _muted = false;
        _volume = _lastVolumeBeforeMute <= 0 ? 80 : _lastVolumeBeforeMute;
        unawaited(widget.player.setVolume(_volume));
      } else {
        _lastVolumeBeforeMute = _volume;
        _muted = true;
        _volume = 0;
        unawaited(widget.player.setVolume(0));
      }
    });
  }

  void _onVolumeChanged(double v) {
    _draggingVolume = true;
    setState(() {
      _volume = v;
      _muted = v <= 0;
    });
  }

  void _commitVolume(double v) {
    _draggingVolume = false;
    unawaited(widget.player.setVolume(v));
  }

  void _cycleFit() {
    const order = [BoxFit.contain, BoxFit.cover, BoxFit.fill];
    final idx = order.indexOf(widget.fit);
    final next = order[(idx + 1) % order.length];
    widget.onFitChanged(next);
  }

  static String _fitLabel(BoxFit fit) => switch (fit) {
        BoxFit.cover => '铺满',
        BoxFit.fill => '拉伸',
        _ => '适应',
      };

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final expanded = _expanded;
    final chromeVisible = _chromeVisible;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 播放区高度只用于判断鼠标是否落在底部触发带。父级无界时置 0，
        // 策略收到非法高度会停止判定，UI 仍照常渲染（安全回退）。
        _stageHeight =
            constraints.maxHeight.isFinite ? constraints.maxHeight : 0;
        return MouseRegion(
          onEnter: _onEnter,
          onExit: _onExit,
          onHover: _onHover,
          child: Stack(
            fit: StackFit.expand,
            // 显式裁切：控制条 bottom 为负时会整个滑出画面，
            // 不会在画面边缘留下残影，也不会拦住视频内容。
            clipBehavior: Clip.hardEdge,
            children: [
              // 中央透明区：点一下钉住 / 收起控制条（触屏、遥控器）。
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _togglePin,
                  child: const SizedBox.expand(),
                ),
              ),

              // 顶部信息条（展开时浮现）：频道名 + 状态 + 源信息。
              AnimatedPositioned(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                left: 0,
                right: 0,
                top: (expanded && chromeVisible) ? 0 : -72,
                height: 72,
                child: IgnorePointer(
                  ignoring: !(expanded && chromeVisible),
                  child: _buildTopBar(c),
                ),
              ),

              // 常驻频道号标签（播放界面左上角）：自动隐藏形态下随控制层
              // 一起淡出，隐藏态只留干净画面。
              _buildChannelTag(c, expanded, chromeVisible),

              // 底部控制区：自动隐藏形态默认整条滑出屏幕底部。
              //
              // 高度从改版前的 112 降到 82：把「换线路 / 刷新」从上面那一行
              // 并进核心行后，不再需要第二行按钮；顶部信息条才是展开态的
              // 主要视觉反馈。
              AnimatedPositioned(
                duration: _autoHideAnim,
                curve: Curves.easeOutCubic,
                left: 0,
                right: 0,
                // 不是简单透明：滑到画面外 + IgnorePointer 双保险，
                // 隐藏时既不遮挡主要内容也不吞掉画面上的点击。
                bottom: chromeVisible ? 0 : -82,
                height: expanded ? 82 : 54,
                child: IgnorePointer(
                  ignoring: !chromeVisible,
                  child: AnimatedOpacity(
                    duration: _autoHideAnim,
                    curve: Curves.easeOut,
                    opacity: chromeVisible ? 1 : 0,
                    child: MouseRegion(
                      onEnter: _onControlsEnter,
                      onExit: _onControlsExit,
                      child: LayoutBuilder(
                        builder: (context, constraints) =>
                            _buildBottomBar(c, expanded, constraints.maxWidth),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTopBar(LiveController c) {
    final ch = c.current;
    final num = c.currentNumber;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.62),
            Colors.black.withValues(alpha: 0.0),
          ],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 频道数字编号放在**最左**：电视上「按号跳台」需要先看到自己按的是哪个号，
          // 用户的明确诉求也是在播放界面显示当前频道号。没有编号时退回台标文字。
          if (num != null)
            _NumberBox(number: num)
          else
            _Badge(text: ch?.badge ?? '—', active: c.isPlaying),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              ch?.name ?? '未选台',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 播放界面左上角的常驻频道号标签。
  ///
  /// 平时（未展开控制条）显示，让观众随时知道当前是哪个频道；
  /// 展开顶部信息条时隐藏，由信息条里更大的编号接替，避免同一信息出现两遍。
  /// 仅当确有当前频道、且不在首屏「尚未调台」的 idle 态时才显示。
  Widget _buildChannelTag(
      LiveController c, bool expanded, bool chromeVisible) {
    final ch = c.current;
    final num = c.currentNumber;
    final visible = chromeVisible &&
        !expanded &&
        ch != null &&
        c.phase != LiveTuning.idle;
    final Widget content = ch == null
        ? const SizedBox.shrink()
        : Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (num != null)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    margin: const EdgeInsets.only(right: 9),
                    decoration: BoxDecoration(
                      color: AppTheme.accent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '$num',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                Text(
                  ch.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          );
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      left: 16,
      top: visible ? 14 : -56,
      child: IgnorePointer(
        ignoring: true,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 220),
          opacity: visible ? 1 : 0,
          child: content,
        ),
      ),
    );
  }

  Widget _buildBottomBar(LiveController c, bool expanded, double width) {
    final canTune = c.channels.length > 1;
    final compact = width < 560;
    // 半透明玻璃质感：先模糊背后的画面，再叠一层底部加深的黑色渐变 + 轻微暗化。
    // 这是主流播放器（VLC / 视频网站）控制条的共同做法，比实色色块更通透。
    final Widget bar = ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                Colors.black.withValues(alpha: 0.74),
                Colors.black.withValues(alpha: 0.08),
              ],
            ),
          ),
        ),
      ),
    );

    // 按红框标注：「换线路」「刷新」从上面那一行挪到**下面这一行**（核心行）。
    // 精简态仍不显示它们——上一轮定义的默认态只保留播放控制 / 音量 /
    // 缩放 / 全屏；展开态才补上，并用一条细分隔线把「源操作」与
    // 「播放控制」区分开，避免十来个图标挤成一坨认不出来。
    final sourceOps = <Widget>[
      ctrl(
        icon: Icons.swap_horiz_rounded,
        // F9：线路切换入口显示当前线路所属通道。公网源不追加文字，
        // 免得档位 C 的用户看见一堆与己无关的「组播」字样。
        tooltip: c.currentStreams.length > 1
            ? '换一条线路${channelHintOf(c.currentStream)}'
            : '该台只有一条线路${channelHintOf(c.currentStream)}',
        onPressed: c.currentStreams.length > 1
            ? () => unawaited(c.switchToNextStream())
            : null,
      ),
      ctrl(
        icon: Icons.refresh_rounded,
        tooltip: c.phase == LiveTuning.failed || c.phase == LiveTuning.idle
            ? '重新连接'
            : '重新连接当前台',
        onPressed: () => unawaited(c.retry()),
      ),
      Container(
        width: 1,
        height: 18,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: Colors.white.withValues(alpha: 0.18),
      ),
    ];

    // 频道入口：桌面/TV 仍在最左（遥控器焦点顺序），手机则做成一枚
    // **钉在控制条最右**的实色按钮，绝不进可横滚的那一段。
    final Widget? channelEntry = widget.onChannelListPressed == null
        ? null
        : (widget.channelEntryOnRight
            ? _ChannelEntryButton(onPressed: () {
                _noteInteraction();
                widget.onChannelListPressed!();
              })
            : ctrl(
                icon: Icons.playlist_play_rounded,
                tooltip: '频道列表',
                onPressed: widget.onChannelListPressed,
              ));

    final row = Row(
      children: [
        if (expanded) ...sourceOps,
        if (!widget.channelEntryOnRight && channelEntry != null) channelEntry,
        ctrl(
          icon: Icons.replay_10_rounded,
          tooltip: '快退 10 秒',
          onPressed: c.phase == LiveTuning.playing
              ? () => unawaited(c.seekBy(const Duration(seconds: -10)))
              : null,
        ),
        ctrl(
          icon: Icons.skip_previous_rounded,
          tooltip: '上一台',
          onPressed: canTune ? () => unawaited(c.previousChannel()) : null,
        ),
        ctrl(
          icon: c.isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          tooltip: c.isPaused ? '继续' : '暂停',
          onPressed: c.phase == LiveTuning.playing
              ? () => unawaited(c.togglePause())
              : null,
        ),
        ctrl(
          icon: Icons.skip_next_rounded,
          tooltip: '下一台',
          onPressed: canTune ? () => unawaited(c.nextChannel()) : null,
        ),
        ctrl(
          icon: Icons.forward_10_rounded,
          tooltip: '快进 10 秒',
          onPressed: c.phase == LiveTuning.playing
              ? () => unawaited(c.seekBy(const Duration(seconds: 10)))
              : null,
        ),
        const SizedBox(width: 6),
        _buildVolumeButton(c, compact ? 56 : 84),
        ctrl(
          icon: Icons.aspect_ratio_rounded,
          tooltip: '画面缩放：${_fitLabel(widget.fit)}',
          onPressed: _cycleFit,
        ),
        if (widget.castStatus != null)
          ctrl(
            icon: widget.castStatus!.casting
                ? Icons.cast_connected_rounded
                : Icons.cast_rounded,
            tooltip: widget.castStatus!.casting
                ? '已投屏到「${widget.castStatus!.deviceName ?? '电视'}」'
                    '（${widget.castStatus!.modeName ?? '直推'}）· 点击管理'
                : '投屏到电视',
            onPressed: widget.castStatus!.busy ? null : widget.onCastPressed,
            // 投屏中染成主题色：这是「输出目标已不在本机」的状态，
            // 和普通按钮用同一种白色就没人注意到画面为什么"延迟"。
            color: widget.castStatus!.casting ? AppTheme.accent : null,
          ),
        ctrl(
          icon: widget.fullscreen
              ? Icons.fullscreen_exit_rounded
              : Icons.fullscreen_rounded,
          tooltip: widget.fullscreen ? '退出全屏' : '全屏',
          onPressed: widget.onToggleFullscreen,
        ),
        // 来源说明（`公开索引 + 内置（383 个频道…）`）按用户要求不再显示：
        // 它是调试信息，对电视观众没有意义，还把控制条右半边占满。
      ],
    );

    // 触摸形态用「可横滚按钮区 + 固定右侧入口」两段式：
    // 任意窄屏都不会出现 OVERFLOW，而换台入口永远在拇指够得到的位置。
    // 桌面/TV 沿用旧的「整行横滚 / 直接铺开」，焦点顺序与手感不变。
    final Widget core;
    if (widget.channelEntryOnRight) {
      core = SizedBox(
        width: double.infinity,
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: row,
              ),
            ),
            if (channelEntry != null) ...[
              const SizedBox(width: 8),
              channelEntry,
            ],
          ],
        ),
      );
    } else {
      core = compact
          ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: row)
          : row;
    }

    return Stack(
      children: [
        Positioned.fill(child: bar),
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: core,
            ),
          ),
        ),
      ],
    );
  }

  /// 统一按形态决定按钮点击区（触摸 44×44 / 鼠标 38×38）。
  Widget ctrl({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    Color? color,
  }) =>
      _Ctrl(
        icon: icon,
        tooltip: tooltip,
        // 所有按钮点击都记一次「操作」：自动隐藏形态下这会重置空闲计时，
        // 用户连续点快进 / 换台时控制条不会中途消失。
        onPressed: onPressed == null
            ? null
            : () {
                _noteInteraction();
                onPressed();
              },
        color: color,
        minSize: widget.touchFirst ? 44 : 38,
      );

  Widget _buildVolumeButton(LiveController c, double sliderWidth) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ctrl(
          icon: _muted || _volume <= 0
              ? Icons.volume_off_rounded
              : (_volume < 50 ? Icons.volume_down_rounded : Icons.volume_up_rounded),
          tooltip: _muted ? '取消静音' : '静音',
          onPressed: _toggleMute,
        ),
        // 音量滑块：仅在展开时显示，避免精简态过长。
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: _expanded ? sliderWidth : 0,
          child: _expanded
                ? SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 7),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 12),
                      activeTrackColor: AppTheme.accent,
                      inactiveTrackColor: Colors.white.withValues(alpha: 0.28),
                      thumbColor: Colors.white,
                    ),
                    child: SizedBox(
                      height: 34,
                      child: Slider(
                        value: _volume,
                        min: 0,
                        max: 100,
                        onChanged: (v) {
                          _noteInteraction();
                          _onVolumeChanged(v);
                        },
                        onChangeEnd: (v) {
                          _noteInteraction();
                          _commitVolume(v);
                        },
                      ),
                    ),
                  )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

}

/// 控制条按钮：等宽、半透明底、悬停高亮，贴合主流播放器。
class _Ctrl extends StatelessWidget {
  const _Ctrl({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
    this.minSize = 38,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// 覆盖默认白色（用于「投屏中」这类需要持续提示的状态）。
  final Color? color;

  /// 最小点击区：桌面 38（控制条矮），触摸形态 44（Material 建议值）。
  final double minSize;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      color: enabled ? (color ?? Colors.white) : Colors.white.withValues(alpha: 0.35),
      splashRadius: 18,
      // 显式约束尺寸：IconButton 默认 48×48 的点击区会让整条控制条被撑高，
      // 展开态内容因此溢出 14px（曾出现黄色 BOTTOM OVERFLOWED 提示）。
      constraints: BoxConstraints(minWidth: minSize, minHeight: minSize),
      padding: const EdgeInsets.all(6),
    );
  }
}

/// 触摸形态下钉在控制条最右的「频道」入口。
///
/// 用主题色实底 + 文字而不是一枚小图标：手机横握时右侧是拇指区，
/// 用户要在不展开控制条的情况下一眼找到换台，只有一枚小图标不够。
/// 高度 42 与控制条精简态（54 - 底部 10 内边距）正好贴合，不会溢出。
class _ChannelEntryButton extends StatelessWidget {
  const _ChannelEntryButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '频道列表',
      child: Material(
        color: AppTheme.accent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(9),
          child: Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            alignment: Alignment.center,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.playlist_play_rounded, size: 18, color: Colors.white),
                SizedBox(width: 5),
                Text(
                  '频道',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
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

class _NumberBox extends StatelessWidget {
  const _NumberBox({required this.number});

  final int number;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppTheme.accent,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          '$number',
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: Colors.white,
          ),
        ),
      );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, this.active = false});

  final String text;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 50,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active ? AppTheme.accent : Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
          color: active ? AppTheme.accent : Colors.white.withValues(alpha: 0.22),
          width: active ? 1 : 0.8,
        ),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: active ? Colors.white : const Color(0xFFC7D0DC),
        ),
      ),
    );
  }
}
