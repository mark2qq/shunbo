import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../features/vod/vod_playback_controls.dart';

/// 控制栏上可以展开的内联面板。
///
/// 刻意**不用下拉菜单 / PopupMenu**：这条控制栏同时要给遥控器用，弹出层在
/// 电视上有两个硬伤 —— 焦点会跑出播放页（遥控器方向键开始满屏乱跳），
/// 以及「按一次 OK 打开、再按一次 OK 才关」的两段式操作。改成贴在控制条上方
/// 的内联面板后，选项本身就是一行可聚焦的横向列表，方向键左右选、OK 确认，
/// 与遥控器的操作模型一致；鼠标端也更省一次点击（不用先关菜单）。
enum PlayerBarPanel { none, quality, rate, volume, more }

/// 清晰度选项。
///
/// [label] 是主文案（`自动` / `1080P`），[detail] 是次要说明（`实测 1920×1080`）。
/// 采集源普遍只提供单档，所以选项列表常常只有「自动」一项 ——
/// 这时控件仍然显示**实测分辨率**，并如实说明为什么不能切（见 [qualityNote]）。
class PlayerQualityOption {
  const PlayerQualityOption({
    required this.id,
    required this.label,
    this.detail = '',
  });

  final String id;
  final String label;
  final String detail;
}

/// 底部控制栏。
///
/// 视觉与交互参考主流播放器（爱奇艺 / YouTube / VLC）的共同约定：
///
/// * **一条进度轨**在最上方，三段着色：已播（主题蓝）、已缓冲（白 34%）、未缓冲（白 18%）；
/// * 悬停时轨道从 4px 长到 6px、滑杆出现，并浮出时间气泡；拖动时气泡跟着走；
/// * 下方一行：左侧播放控制，右侧设置类控件（时间 → 清晰度 → 倍速 → 音量 → 选集 → 全屏）；
/// * 所有控件统一 38×38 命中区、9 圆角、白 12% 悬停底、主题蓝 24% 激活底。
///
/// 三档密度（[full] / [medium] / [compact]）按可用宽度切换，见 [_densityFor]。
class PlayerControlBar extends StatefulWidget {
  const PlayerControlBar({
    super.key,
    required this.playing,
    required this.position,
    required this.duration,
    required this.buffered,
    required this.volume,
    required this.rate,
    required this.qualityId,
    required this.qualityLabel,
    required this.qualities,
    this.qualityNote = '',
    required this.hasPrevious,
    required this.hasNext,
    required this.canPickEpisodes,
    required this.episodesOpen,
    required this.fullscreen,
    this.visible = true,
    this.showHints = true,
    this.onPanelChanged,
    required this.onTogglePlay,
    required this.onSkip,
    required this.onScrub,
    required this.onSeek,
    required this.onPrevious,
    required this.onNext,
    required this.onVolume,
    required this.onMute,
    required this.onRate,
    required this.onQuality,
    required this.onEpisodes,
    required this.onFullscreen,
  });

  final bool playing;
  final double position;
  final double duration;
  final double buffered;
  final double volume;
  final double rate;

  /// 当前清晰度档的 id（用于面板里勾选，`auto` 表示跟随源）。
  final String qualityId;

  /// 当前清晰度徽标文案（实测分辨率，未出画时为「自动」）。
  final String qualityLabel;
  final List<PlayerQualityOption> qualities;

  /// 清晰度面板底部的如实说明（例如「采集源只提供单档清晰度」）。
  final String qualityNote;

  final bool hasPrevious;
  final bool hasNext;
  final bool canPickEpisodes;
  final bool episodesOpen;
  final bool fullscreen;

  /// 控制条是否可见。整条淡出时必须顺手收起内联面板 ——
  /// 否则再呼出时面板是「开着」的，用户以为自己没关过。
  final bool visible;

  /// 是否显示底部键盘提示行（宽屏显示，窄屏不占高度）。
  final bool showHints;

  /// 面板展开状态变化（父级据此暂停「4 秒自动收起」）。
  final ValueChanged<bool>? onPanelChanged;

  final VoidCallback onTogglePlay;

  /// 快进 / 快退，参数为秒（正数前进、负数后退）。
  final ValueChanged<double> onSkip;

  /// 拖动过程中回调目标比例（0–1），用于让页面实时更新时间文案并钉住控制条。
  final ValueChanged<double> onScrub;

  /// 松手 / 点击时确认 seek 的比例（0–1）。
  final ValueChanged<double> onSeek;

  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final ValueChanged<double> onVolume;
  final VoidCallback onMute;
  final ValueChanged<double> onRate;
  final ValueChanged<String> onQuality;
  final VoidCallback onEpisodes;
  final VoidCallback onFullscreen;

  @override
  State<PlayerControlBar> createState() => _PlayerControlBarState();
}

/// 控制栏密度。宽度三档，不是「宽/窄」两档 —— 两档在 700–1000dp 这段
/// （平板横屏、电视小窗）会把右侧控件挤成两行，反而不如少放两个按钮。
enum _Density { full, medium, compact }

/// 音量图标随档位切换（静音 / 小 / 正常）。抽成顶层函数：
/// 宽屏的内联音量组与窄屏的图标按钮共用，避免两处判断不一致。
IconData _volumeIcon(double volume) {
  if (volume <= 0.5) return Icons.volume_off_rounded;
  if (volume < 45) return Icons.volume_down_rounded;
  return Icons.volume_up_rounded;
}

class _PlayerControlBarState extends State<PlayerControlBar> {
  PlayerBarPanel _panel = PlayerBarPanel.none;

  /// 拖动进度条时的临时位置。
  ///
  /// 拖动的实时反馈（时间文案跟着走）留在控制栏**内部**做：
  /// 让页面 setState 去更新它，等于每帧重建整个点播页（含几千条卡片网格），
  /// 拖一下进度条就掉帧。这里只重建控制栏自己。
  double? _scrubPreview;

  @override
  void didUpdateWidget(covariant PlayerControlBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 选集抽屉被外部关掉时，面板一起收；否则会出现「面板开着但按钮不高亮」。
    if (widget.episodesOpen && !oldWidget.episodesOpen) {
      _setPanel(PlayerBarPanel.none);
    }
    // 整条淡出时把面板收掉（这里直接改字段：didUpdateWidget 之后本组件必然重建，
    // 在 didUpdateWidget 里 setState 是多余的，也会把父级构建期搅乱）。
    if (!widget.visible && oldWidget.visible && _panel != PlayerBarPanel.none) {
      _panel = PlayerBarPanel.none;
      widget.onPanelChanged?.call(false);
    }
  }

  void _setPanel(PlayerBarPanel next) {
    if (_panel == next) return;
    setState(() => _panel = next);
    widget.onPanelChanged?.call(next != PlayerBarPanel.none);
  }

  void _togglePanel(PlayerBarPanel kind) {
    _setPanel(_panel == kind ? PlayerBarPanel.none : kind);
  }

  static _Density _densityFor(double width) {
    // 三档阈值是按「最坏内容宽度」倒推的，不是拍脑袋：
    // full 的左右两组固定宽度合计约 640dp（含 h:mm:ss 时间文案），留 260dp 余量 → 900；
    // medium 去掉上下集后约 505dp → 560；再窄就走 compact（约 304dp，360dp 竖屏放得下）。
    if (width >= 900) return _Density.full;
    if (width >= 560) return _Density.medium;
    return _Density.compact;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final density = _densityFor(constraints.maxWidth);
        final pad = density == _Density.compact ? 10.0 : 18.0;
        return Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: <Color>[Color(0xE6000000), Color(0x00000000)],
            ),
          ),
          padding: EdgeInsets.only(top: 26, bottom: density == _Density.compact ? 4 : 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 面板贴在控制条上方，右对齐（清晰度/倍速/音量全在右侧，
              // 面板从中开的那个按钮上方长出来，视线不用横跳）。
              AnimatedSize(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                alignment: Alignment.bottomRight,
                child: _panel == PlayerBarPanel.none
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: EdgeInsets.fromLTRB(pad, 0, pad, 8),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: _buildPanel(
                              (constraints.maxWidth - pad * 2)
                                  .clamp(200.0, double.infinity)),
                        ),
                      ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: pad),
                child: _TrackBar(
                  value: vodProgress(widget.position, widget.duration),
                  secondary: vodBufferedProgress(
                      widget.buffered, widget.position, widget.duration),
                  enabled: widget.duration > 0,
                  formatter: (r) => vodClock(r * widget.duration),
                  onScrub: (f) {
                    setState(() => _scrubPreview = widget.duration * f);
                    widget.onScrub(f);
                  },
                  onSeek: (f) {
                    setState(() => _scrubPreview = null);
                    widget.onSeek(f);
                  },
                ),
              ),
              SizedBox(height: density == _Density.compact ? 2 : 6),
              _buildRow(density, pad),
              if (widget.showHints && density != _Density.compact)
                Padding(
                  padding: EdgeInsets.fromLTRB(pad, 6, pad, 0),
                  child: Text(
                    '空格/OK 播放暂停 · ←→ 快退快进 10 秒 · ↑↓ 音量 · '
                    'F 全屏 · Esc 退出播放',
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.2,
                      color: Colors.white.withValues(alpha: 0.38),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // ── 控制行 ──────────────────────────────────────────────

  Widget _buildRow(_Density density, double pad) {
    final compact = density == _Density.compact;
    final big = compact ? 36.0 : 42.0;
    final normal = compact ? 34.0 : 38.0;
    final time = _TimeLabel(
      position: _scrubPreview ?? widget.position,
      duration: widget.duration,
      fontSize: compact ? 11 : 12,
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 0, pad, compact ? 2 : 4),
      child: Row(
        children: [
          _BarButton(
            icon: widget.playing
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
            tooltip: widget.playing ? '暂停（空格）' : '播放（空格）',
            size: big,
            iconSize: compact ? 24 : 27,
            onTap: widget.onTogglePlay,
          ),
          _BarButton(
            icon: Icons.replay_10_rounded,
            tooltip: '快退 10 秒（←）',
            size: normal,
            onTap: () => widget.onSkip(-kVodSeekStepSeconds),
          ),
          _BarButton(
            icon: Icons.forward_10_rounded,
            tooltip: '快进 10 秒（→）',
            size: normal,
            onTap: () => widget.onSkip(kVodSeekStepSeconds),
          ),
          if (density == _Density.full) ...[
            const SizedBox(width: 6),
            _BarButton(
              icon: Icons.skip_previous_rounded,
              tooltip: '上一集',
              size: normal,
              enabled: widget.hasPrevious,
              onTap: widget.onPrevious,
            ),
            _BarButton(
              icon: Icons.skip_next_rounded,
              tooltip: '下一集',
              size: normal,
              enabled: widget.hasNext,
              onTap: widget.onNext,
            ),
          ],
          const Spacer(),
          if (!compact) ...[
            time,
            const SizedBox(width: 10),
          ],
          if (compact) ...[
            // 窄屏只留「时间 + 更多 + 全屏」：360dp 竖屏上放不下清晰度/倍速/音量
            // 三个独立入口，硬塞会横向溢出。清晰度 / 倍速 / 音量全部收进 [_MorePanel]。
            time,
            const SizedBox(width: 2),
            _BarButton(
              icon: Icons.tune_rounded,
              tooltip: '清晰度 / 倍速 / 音量',
              size: normal,
              active: _panel == PlayerBarPanel.more,
              onTap: () => _togglePanel(PlayerBarPanel.more),
            ),
            _BarButton(
              icon: widget.fullscreen
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded,
              tooltip: widget.fullscreen ? '退出全屏' : '全屏',
              size: normal,
              active: widget.fullscreen,
              onTap: widget.onFullscreen,
            ),
          ] else ...[
            _PillButton(
              label: widget.qualityLabel,
              tooltip: '清晰度',
              active: _panel == PlayerBarPanel.quality,
              onTap: () => _togglePanel(PlayerBarPanel.quality),
            ),
            const SizedBox(width: 6),
            _PillButton(
              label: vodRateLabel(widget.rate),
              tooltip: '播放倍速',
              active: _panel == PlayerBarPanel.rate,
              onTap: () => _togglePanel(PlayerBarPanel.rate),
            ),
            const SizedBox(width: 6),
            if (density == _Density.full)
              _VolumeGroup(
                volume: widget.volume,
                onVolume: widget.onVolume,
                onMute: widget.onMute,
              )
            else
              _BarButton(
                icon: _volumeIcon(widget.volume),
                tooltip: '音量 ${vodVolumeLabel(widget.volume)}',
                size: normal,
                active: _panel == PlayerBarPanel.volume,
                onTap: () => _togglePanel(PlayerBarPanel.volume),
              ),
            if (widget.canPickEpisodes)
              _BarButton(
                icon: Icons.playlist_play_rounded,
                tooltip: '选集（M）',
                size: normal,
                active: widget.episodesOpen,
                onTap: widget.onEpisodes,
              ),
            _BarButton(
              icon: widget.fullscreen
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded,
              tooltip: widget.fullscreen ? '退出全屏（F）' : '全屏（F）',
              size: normal,
              active: widget.fullscreen,
              onTap: widget.onFullscreen,
            ),
          ],
        ],
      ),
    );
  }

  // ── 内联面板 ────────────────────────────────────────────

  /// 内联面板。宽度固定 380 —— 比这窄时（手机竖屏）直接铺满可用宽度，
  /// 绝不让它溢出：溢出在 Flutter 里是黄黑条，在电视上会直接吃掉半个画面。
  Widget _buildPanel(double available) {
    final width = available > 420 ? 380.0 : available;
    final children = <Widget>[];

    void section(String title, Widget body, {bool gap = true}) {
      children.add(Padding(
        padding: EdgeInsets.only(top: children.isEmpty ? 0 : (gap ? 12 : 4)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 46,
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppTheme.textTertiary,
                  height: 1.3,
                ),
              ),
            ),
            Expanded(
              child: Align(alignment: Alignment.centerLeft, child: body),
            ),
          ],
        ),
      ));
    }

    if (_panel == PlayerBarPanel.quality || _panel == PlayerBarPanel.more) {
      section(
        '清晰度',
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final q in widget.qualities)
              _PanelChip(
                label: q.label,
                trailing: q.detail,
                selected: q.id == widget.qualityId,
                onTap: () {
                  widget.onQuality(q.id);
                  if (_panel == PlayerBarPanel.more) return;
                  _setPanel(PlayerBarPanel.none);
                },
              ),
          ],
        ),
      );
      if (widget.qualityNote.isNotEmpty) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            widget.qualityNote,
            style: const TextStyle(
              fontSize: 10,
              height: 1.4,
              color: AppTheme.textTertiary,
            ),
          ),
        ));
      }
    }

    if (_panel == PlayerBarPanel.rate || _panel == PlayerBarPanel.more) {
      section(
        '倍速',
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final r in kVodRateOptions)
              _PanelChip(
                label: vodRateLabel(r),
                selected: (r - widget.rate).abs() < 0.001,
                onTap: () {
                  widget.onRate(r);
                  if (_panel == PlayerBarPanel.more) return;
                  _setPanel(PlayerBarPanel.none);
                },
              ),
          ],
        ),
      );
    }

    if (_panel == PlayerBarPanel.volume || _panel == PlayerBarPanel.more) {
      section(
        '音量',
        Row(
          children: [
            _PanelChip(
              label: widget.volume <= 0.5 ? '取消静音' : '静音',
              selected: widget.volume <= 0.5,
              onTap: widget.onMute,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _TrackBar(
                value: (widget.volume / 100).clamp(0.0, 1.0),
                secondary: 0,
                thickness: 3,
                hitHeight: 20,
                formatter: (r) => vodVolumeLabel(r * 100),
                onScrub: (r) => widget.onVolume(r * 100),
                onSeek: (r) => widget.onVolume(r * 100),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 40,
              child: Text(
                vodVolumeLabel(widget.volume),
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.white70,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: width,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceHigh.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        boxShadow: const [
          BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, 6)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

// ── 进度轨 ─────────────────────────────────────────────────

/// 自绘进度轨（点播与音量共用一套视觉语言）。
///
/// 为什么不用 Material `Slider`：
/// 1. 它画不出「已缓冲但未播」的中间段（本页最需要的那段信息）；
/// 2. 它的拇指有 48×48 的内置命中区与 padding，会把视觉长度吃掉一截，
///    进度条与上方画面边缘对不齐；
/// 3. 悬浮预览气泡要贴着指针走，Slider 没有这个挂点。
class _TrackBar extends StatefulWidget {
  const _TrackBar({
    required this.value,
    required this.secondary,
    required this.formatter,
    required this.onScrub,
    required this.onSeek,
    this.enabled = true,
    this.thickness = 4,
    this.hitHeight = 22,
  });

  final double value;
  final double secondary;
  final String Function(double fraction) formatter;
  final ValueChanged<double> onScrub;
  final ValueChanged<double> onSeek;
  final bool enabled;
  final double thickness;
  final double hitHeight;

  @override
  State<_TrackBar> createState() => _TrackBarState();
}

class _TrackBarState extends State<_TrackBar> {
  double? _hoverDx;
  double? _dragFraction;

  double _fractionAt(double dx, double width) {
    if (width <= 0) return 0;
    final r = dx / width;
    if (!r.isFinite) return 0;
    return r.clamp(0.0, 1.0);
  }

  void _commit(double fraction) {
    widget.onSeek(fraction);
    setState(() => _dragFraction = null);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final shown = _dragFraction ?? widget.value;
        final active = _hoverDx != null || _dragFraction != null;
        // 优先级必须写清楚：拖动中显示拖到哪，否则显示悬停指针位置。
        // （`a ?? b == null ? c : d` 在 Dart 里会被解析成 `(a ?? b) == null`，
        //  不是想要的语义，所以这里显式拆开写。）
        final double? previewFraction = _dragFraction != null
            ? _dragFraction
            : (_hoverDx == null ? null : _fractionAt(_hoverDx!, width));

        return MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onHover: widget.enabled
              ? (e) => setState(() => _hoverDx = e.localPosition.dx)
              : null,
          onExit: (_) => setState(() => _hoverDx = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 用 onTapUp 而不是 onTapDown：按下即 seek 的话，紧接着的拖动会在
            // 起手位置多打一次 seek（弱源上是两次连续 seek，画面会黑一下）。
            // onTapUp 只在「没有变成拖动」时才触发。
            onTapUp: widget.enabled
                ? (d) => _commit(_fractionAt(d.localPosition.dx, width))
                : null,
            onHorizontalDragStart: widget.enabled
                ? (d) {
                    final f = _fractionAt(d.localPosition.dx, width);
                    setState(() => _dragFraction = f);
                    widget.onScrub(f);
                  }
                : null,
            onHorizontalDragUpdate: widget.enabled
                ? (d) {
                    final f = _fractionAt(d.localPosition.dx, width);
                    setState(() => _dragFraction = f);
                    widget.onScrub(f);
                  }
                : null,
            onHorizontalDragEnd: widget.enabled
                ? (_) {
                    final f = _dragFraction;
                    if (f != null) _commit(f);
                  }
                : null,
            child: SizedBox(
              height: widget.hitHeight,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _TrackPainter(
                        value: shown.clamp(0.0, 1.0),
                        secondary: widget.secondary.clamp(0.0, 1.0),
                        thickness: widget.thickness,
                        active: active && widget.enabled,
                      ),
                    ),
                  ),
                  if (previewFraction != null && widget.enabled)
                    _bubble(previewFraction, width),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 悬停 / 拖动时贴着指针的时间气泡。
  ///
  /// 左右两端各做一次夹取：气泡宽度固定 64，指针在最左/最右时若不做夹取，
  /// 气泡会有一半跑到控制栏外面被裁掉，露出半截文字。
  Widget _bubble(double fraction, double width) {
    const bubbleWidth = 64.0;
    final left = (fraction * width - bubbleWidth / 2)
        .clamp(0.0, (width - bubbleWidth).clamp(0.0, double.infinity));
    return Positioned(
      left: left,
      top: -26,
      child: IgnorePointer(
        child: Container(
          width: bubbleWidth,
          padding: const EdgeInsets.symmetric(vertical: 3),
          decoration: BoxDecoration(
            color: AppTheme.surfaceHigh.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          child: Text(
            widget.formatter(fraction),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 11,
              height: 1.2,
              fontWeight: FontWeight.w600,
              color: Colors.white,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackPainter extends CustomPainter {
  const _TrackPainter({
    required this.value,
    required this.secondary,
    required this.thickness,
    required this.active,
  });

  final double value;
  final double secondary;
  final double thickness;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final h = active ? thickness + 2 : thickness;
    final cy = size.height / 2;
    final radius = Radius.circular(h / 2);
    Rect bar(double to) => Rect.fromLTWH(0, cy - h / 2, size.width * to, h);

    canvas.drawRRect(
      RRect.fromRectAndRadius(bar(1), radius),
      Paint()..color = Colors.white.withValues(alpha: 0.18),
    );
    if (secondary > 0.002) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(bar(secondary), radius),
        Paint()..color = Colors.white.withValues(alpha: 0.34),
      );
    }
    if (value > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(bar(value), radius),
        Paint()..color = AppTheme.accent,
      );
    }
    if (active) {
      const r = 6.5;
      // 夹一次：value 为 0 或 1 时滑杆会有一半画到轨道外面。
      final x = (size.width * value).clamp(r, (size.width - r).clamp(r, size.width));
      canvas.drawCircle(Offset(x, cy), r, Paint()..color = Colors.white);
      canvas.drawCircle(
        Offset(x, cy),
        r,
        Paint()
          ..color = AppTheme.accent.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TrackPainter old) =>
      old.value != value ||
      old.secondary != secondary ||
      old.thickness != thickness ||
      old.active != active;
}

// ── 按钮 ───────────────────────────────────────────────────

/// 图标按钮：悬停白 12%、激活主题蓝 24%、禁用白 26% 图标。
///
/// **刻意不用 `IconButton` / `InkWell`**：它们的水波纹画在最近的 Material 上，
/// 而这条控制栏浮在播放画面之上、Material 在画面**下面** —— 波纹会被视频盖住，
/// 悬停时什么都不亮（1.0.4 的按钮就有这个问题，只是没人注意）。
/// 自己画 `AnimatedContainer` 才能保证反馈出现在画面之上。
///
/// 也刻意**不参与焦点遍历**：播放页的 [Focus] 已经把方向键映射成快进/音量，
/// 控制钮一旦可聚焦，遥控器方向键就会开始满屏跳焦点，把「←→ 快退快进」顶掉。
class _BarButton extends StatefulWidget {
  const _BarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 38,
    this.iconSize = 21,
    this.enabled = true,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;
  final double iconSize;
  final bool enabled;
  final bool active;

  @override
  State<_BarButton> createState() => _BarButtonState();
}

class _BarButtonState extends State<_BarButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final Color background = !enabled
        ? Colors.transparent
        : widget.active
            ? AppTheme.accent.withValues(alpha: 0.24)
            : _hover
                ? Colors.white.withValues(alpha: 0.12)
                : Colors.transparent;
    final Color iconColor = !enabled
        ? Colors.white.withValues(alpha: 0.26)
        : widget.active
            ? Colors.white
            : _hover
                ? Colors.white
                : Colors.white.withValues(alpha: 0.88);

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? widget.onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(widget.icon, size: widget.iconSize, color: iconColor),
          ),
        ),
      ),
    );
  }
}

/// 文字胶囊（清晰度 / 倍速）。与图标按钮同一套状态色，只是内容换成短文案。
class _PillButton extends StatefulWidget {
  const _PillButton({
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  @override
  State<_PillButton> createState() => _PillButtonState();
}

class _PillButtonState extends State<_PillButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final background = widget.active
        ? AppTheme.accent.withValues(alpha: 0.24)
        : _hover
            ? Colors.white.withValues(alpha: 0.12)
            : Colors.white.withValues(alpha: 0.06);
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 9),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: widget.active
                    ? AppTheme.accent.withValues(alpha: 0.6)
                    : Colors.transparent,
              ),
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.1,
                fontWeight: FontWeight.w600,
                color: widget.active || _hover
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.82),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 音量：图标（点击静音）+ 悬停展开的横向滑块（宽屏常驻）。
///
/// 展开而不是常驻：音量不是每次播放都要调的东西，常驻一条 96px 的滑块会在
/// 右侧挤掉清晰度/倍速的位置。但**触屏端没有 hover**，所以窄屏不用这个组件，
/// 而是把音量放进内联面板（见 [_buildPanel] 的 volume 段）。
class _VolumeGroup extends StatefulWidget {
  const _VolumeGroup({
    required this.volume,
    required this.onVolume,
    required this.onMute,
  });

  final double volume;
  final ValueChanged<double> onVolume;
  final VoidCallback onMute;

  @override
  State<_VolumeGroup> createState() => _VolumeGroupState();
}

class _VolumeGroupState extends State<_VolumeGroup> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _open = true),
      onExit: (_) => setState(() => _open = false),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _BarButton(
            icon: _volumeIcon(widget.volume),
            tooltip: widget.volume <= 0.5
                ? '取消静音（↑↓ 调音量）'
                : '静音 · 当前 ${vodVolumeLabel(widget.volume)}',
            onTap: widget.onMute,
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: _open ? 88 : 0,
              child: ClipRect(
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: _TrackBar(
                    value: (widget.volume / 100).clamp(0.0, 1.0),
                    secondary: 0,
                    thickness: 3,
                    hitHeight: 20,
                    formatter: (r) => vodVolumeLabel(r * 100),
                    onScrub: (r) => widget.onVolume(r * 100),
                    onSeek: (r) => widget.onVolume(r * 100),
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

/// 面板里的选项胶囊。
class _PanelChip extends StatefulWidget {
  const _PanelChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.trailing = '',
  });

  final String label;
  final String trailing;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_PanelChip> createState() => _PanelChipState();
}

class _PanelChipState extends State<_PanelChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.selected
        ? AppTheme.accent
        : _hover
            ? Colors.white.withValues(alpha: 0.16)
            : Colors.white.withValues(alpha: 0.07);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.1,
                  fontWeight:
                      widget.selected ? FontWeight.w700 : FontWeight.w500,
                  color: widget.selected
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.86),
                ),
              ),
              if (widget.trailing.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(
                  widget.trailing,
                  style: TextStyle(
                    fontSize: 10,
                    height: 1.1,
                    color: widget.selected
                        ? Colors.white.withValues(alpha: 0.82)
                        : AppTheme.textTertiary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// `01:23 / 45:00`。当前时间比总时长亮一档，是最常见的层级处理。
class _TimeLabel extends StatelessWidget {
  const _TimeLabel({
    required this.position,
    required this.duration,
    this.fontSize = 12,
  });

  final double position;
  final double duration;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(
      fontSize: fontSize,
      height: 1.2,
      color: Colors.white,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(vodClock(position), style: base),
        Text(
          ' / ',
          style: base.copyWith(color: Colors.white.withValues(alpha: 0.38)),
        ),
        Text(
          duration > 0 ? vodClock(duration) : '--:--',
          style: base.copyWith(color: Colors.white.withValues(alpha: 0.62)),
        ),
      ],
    );
  }
}
