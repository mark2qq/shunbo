import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/services.dart';
import '../../app/theme.dart';
import '../../core/scheduler/playback_orchestrator.dart';
import '../../core/scheduler/playback_queue.dart';
import '../../core/source/source_adapter.dart';
import '../../data/resume_record.dart';
import '../../features/live/channel_numbering.dart';
import '../../features/vod/vod_catalog.dart';
import '../widgets/player_stage.dart';

/// 点播栏目页（电影 / 电视剧 / 纪录片共用一套实现）。
///
/// 三态视图：浏览 → 详情 → 播放，全部在**同一页内切换**而不是 push 路由。
/// 理由：电视端每次 push 都会多一层返回栈，遥控器连按返回很容易一路退回桌面；
/// 页内切换则让「返回」始终只有一层，行为可预测。
class VodPage extends StatefulWidget {
  const VodPage({
    super.key,
    required this.section,
    required this.services,
    required this.active,
  });

  final VodSection section;
  final ShunboServices services;
  final bool active;

  @override
  State<VodPage> createState() => _VodPageState();
}

enum _VodView { browse, detail, playing }

class _VodPageState extends State<VodPage> {
  _VodView _view = _VodView.browse;
  VodItem? _item;
  ResumeRecord? _resume;
  PlaybackSession? _session;
  bool _paused = false;
  bool _busy = false;

  double _position = 0;
  double _duration = 0;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    if (widget.active) _bindQueue();
  }

  @override
  void didUpdateWidget(covariant VodPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _bindQueue();
    } else if (!widget.active && oldWidget.active) {
      _unbindQueue();
      // 切走栏目就停掉：不停会出现「看着电影页，声音还在放」，
      // 而且进度上报会继续写别的媒体的记录。
      if (_view == _VodView.playing) {
        unawaited(_pauseForLeave());
      }
    }
  }

  @override
  void dispose() {
    _unbindQueue();
    _ticker?.cancel();
    super.dispose();
  }

  /// 自动连播推进后要换到新会话：只有当前栏目才有权接管这个回调。
  ///
  /// `queue.onAdvanced` 是单个字段，三个栏目页会抢它。这里存下自己注册的那个闭包，
  /// 解绑时用 `identical` 确认「现在挂的还是我」再清空——
  /// 否则会出现「从剧集切到电影时，电影的绑定被剧集的解绑顺手清掉」，
  /// 表现为切栏目后自动连播失效。
  void Function(QueueAdvance)? _boundCallback;

  void _bindQueue() {
    void callback(QueueAdvance result) {
      if (!mounted) return;
      setState(() {
        _session = result.session;
        _paused = false;
        _view = _VodView.playing;
      });
      _startTicker();
    }

    _boundCallback = callback;
    widget.services.queue.onAdvanced = callback;
  }

  void _unbindQueue() {
    if (identical(widget.services.queue.onAdvanced, _boundCallback)) {
      widget.services.queue.onAdvanced = null;
    }
    _boundCallback = null;
  }

  Future<void> _pauseForLeave() async {
    _ticker?.cancel();
    try {
      await widget.services.player.pause();
    } catch (_) {
      // 离开页面时暂停失败不影响切栏目。
    }
    _paused = true;
  }

  // ── 播放 ────────────────────────────────────────────────

  Future<void> _play(VodItem item, VodEpisode episode, {double seconds = 0}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final s = await widget.services.orchestrator.startPlayback(
        sourceId: VodCatalog.sourceId,
        mediaId: item.id,
        mediaTitle: item.title,
        canonicalEpisode: episode.number,
        canonicalSeconds: seconds,
      );
      // 剧集表交给播放列表层：看完一集才能自动进下一集。
      widget.services.queue.setEpisodes(
        item.episodes.map((e) => EpisodeInfo(episode: e.number, title: e.title)),
      );
      widget.services.queue.attach(s);
      if (!mounted) return;
      setState(() {
        _session = s;
        _paused = false;
        _busy = false;
        _view = _VodView.playing;
      });
      _startTicker();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('播放失败：$e')),
      );
    }
  }

  /// 续播入口：有记录就从记录点继续；已看完的直接进下一集。
  Future<void> _resumeOrPlay(VodItem item) async {
    final rec = _resume;
    if (rec == null) {
      await _play(item, item.episodes.first);
      return;
    }
    if (rec.finished) {
      final next = item.episodes.firstWhere(
        (e) => e.number > rec.canonicalEpisode,
        orElse: () => item.episodes.first,
      );
      await _play(item, next);
      return;
    }
    final ep = item.episodes.firstWhere(
      (e) => e.number == rec.canonicalEpisode,
      orElse: () => item.episodes.first,
    );
    await _play(item, ep, seconds: rec.canonicalSeconds);
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (t) async {
      final p = widget.services.player;
      try {
        final pos = await p.currentRawSeconds();
        final dur = await p.duration();
        if (!mounted) return;
        setState(() {
          _position = pos;
          _duration = dur;
        });
      } catch (_) {
        // 读数失败就跳过这一拍，不打断播放。
      }
    });
  }

  Future<void> _togglePause() async {
    final p = widget.services.player;
    try {
      if (_paused) {
        await p.play();
      } else {
        await p.pause();
      }
      if (mounted) setState(() => _paused = !_paused);
    } catch (_) {
      // 暂停/继续失败不改变 UI 状态，避免「按了没反应但按钮变了」。
    }
  }

  Future<void> _openDetail(VodItem item) async {
    final rec = await widget.services.orchestrator.resumeFor(item.id);
    if (!mounted) return;
    setState(() {
      _item = item;
      _resume = rec;
      _view = _VodView.detail;
    });
  }

  void _back() {
    if (_view == _VodView.playing) {
      _ticker?.cancel();
      widget.services.queue.detach();
      setState(() {
        _view = _VodView.detail;
        _session = null;
      });
      return;
    }
    if (_view == _VodView.detail) {
      setState(() {
        _view = _VodView.browse;
        _item = null;
      });
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return switch (_view) {
      _VodView.browse => _buildBrowse(),
      _VodView.detail => _buildDetail(),
      _VodView.playing => _buildPlaying(),
    };
  }

  // ── 浏览 ────────────────────────────────────────────────

  Widget _buildBrowse() {
    final items = VodCatalog.inSection(widget.section);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1100
            ? 5
            : constraints.maxWidth >= 820
                ? 4
                : constraints.maxWidth >= 560
                    ? 3
                    : 2;
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _header(items.length)),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisExtent: 186,
                  crossAxisSpacing: 14,
                  mainAxisSpacing: 14,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _VodCard(
                    item: items[i],
                    onTap: () => unawaited(_openDetail(items[i])),
                  ),
                  childCount: items.length,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _header(int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            widget.section.label,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(width: 10),
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              '$count 部 · 公开授权示例片库',
              style: const TextStyle(fontSize: 12, color: AppTheme.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  // ── 详情 ────────────────────────────────────────────────

  Widget _buildDetail() {
    final item = _item!;
    final rec = _resume;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextButton.icon(
            onPressed: _back,
            icon: const Icon(Icons.arrow_back_rounded, size: 18),
            label: Text('返回${widget.section.label}'),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppTheme.radius),
                child: SizedBox(
                  width: 220,
                  height: 124,
                  child: _PosterBlock(item: item, large: true),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.subtitle,
                      style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      item.description,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.6,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      item.license,
                      style: const TextStyle(fontSize: 11, color: AppTheme.textTertiary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : () => unawaited(_resumeOrPlay(item)),
                icon: Icon(
                  rec == null ? Icons.play_arrow_rounded : Icons.history_rounded,
                  size: 20,
                ),
                label: Text(
                  rec == null
                      ? '从头播放'
                      : (rec.finished
                          ? '播放下一集'
                          : '继续观看 · 第 ${rec.canonicalEpisode} 集 '
                              '${_mmss(rec.canonicalSeconds)}'),
                ),
              ),
              if (item.isSeries) ...[
                const SizedBox(width: 10),
                Text(
                  '共 ${item.episodeCount} 集',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textTertiary),
                ),
              ],
            ],
          ),
          if (item.isSeries) ...[
            const SizedBox(height: 20),
            const Text(
              '选集',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final e in item.episodes)
                  _EpisodeChip(
                    label: e.title,
                    current: rec?.canonicalEpisode == e.number,
                    onTap: () => unawaited(_play(item, e)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ── 播放 ────────────────────────────────────────────────

  Widget _buildPlaying() {
    final s = _session;
    final item = _item;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlayerStage(
          player: widget.services.player,
          centerMessage: s == null ? '正在载入…' : null,
          showSpinner: s == null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item?.title ?? s?.mediaTitle ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      s == null
                          ? ''
                          : '第 ${s.contentEpisode} 集 · 内容坐标 '
                              '${_mmss(s.contentSeconds)}',
                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: _paused ? '继续' : '暂停',
                onPressed: () => unawaited(_togglePause()),
                icon: Icon(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
              ),
              IconButton(
                tooltip: '返回详情',
                onPressed: _back,
                icon: const Icon(Icons.list_rounded),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          child: Row(
            children: [
              Text(_mmss(_position),
                  style: const TextStyle(fontSize: 11, color: AppTheme.textTertiary)),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: _duration > 0 ? (_position / _duration).clamp(0.0, 1.0) : 0,
                    minHeight: 4,
                    backgroundColor: AppTheme.surfaceHigh,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(_duration > 0 ? _mmss(_duration) : '--:--',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textTertiary)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            _autoNextLabel(),
            style: const TextStyle(fontSize: 11, color: AppTheme.textTertiary),
          ),
        ),
      ],
    );
  }

  String _autoNextLabel() {
    final q = widget.services.queue;
    if (q.episodes.isEmpty) return '单集内容，没有下一集';
    return q.autoNext
        ? '连播已开启 · 本集结束后自动进入第 ${q.episodes.length} 集内的下一集'
        : '连播已关闭 · 本集结束后停在片尾';
  }
}

// ── 小部件 ────────────────────────────────────────────────

String _mmss(double seconds) {
  final total = seconds.isFinite && seconds > 0 ? seconds.round() : 0;
  final m = (total ~/ 60).toString().padLeft(2, '0');
  final s = (total % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// 没有海报图时用色块 + 首字构建卡片主视觉。
///
/// 刻意不引网络海报：首屏加载网络图会白闪，且这些公开素材并没有官方海报，
/// 硬凑一张只会显得像假海报。色块方案在深色底上辨识度足够。
class _PosterBlock extends StatelessWidget {
  const _PosterBlock({required this.item, this.large = false});

  final VodItem item;
  final bool large;

  static const List<Color> _palette = <Color>[
    Color(0xFF23405C),
    Color(0xFF3B2E52),
    Color(0xFF4E2F35),
    Color(0xFF2A4640),
    Color(0xFF3D3A24),
    Color(0xFF2E3A56),
    Color(0xFF44304A),
    Color(0xFF253F3A),
  ];

  @override
  Widget build(BuildContext context) {
    final color = _palette[item.accentSeed % _palette.length];
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(large ? AppTheme.radius : 8),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            right: -12,
            bottom: -18,
            child: Text(
              item.title.characters.first,
              style: TextStyle(
                fontSize: large ? 92 : 64,
                fontWeight: FontWeight.w600,
                color: Colors.white.withValues(alpha: 0.10),
              ),
            ),
          ),
          if (item.isSeries)
            Positioned(
              left: 8,
              top: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.38),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  '${item.episodeCount} 集',
                  style: const TextStyle(fontSize: 10, color: Colors.white),
                ),
              ),
            ),
          if (!large)
            const Center(
              child: Icon(Icons.play_circle_outline_rounded,
                  size: 30, color: Colors.white70),
            ),
        ],
      ),
    );
  }
}

class _VodCard extends StatefulWidget {
  const _VodCard({required this.item, required this.onTap});

  final VodItem item;
  final VoidCallback onTap;

  @override
  State<_VodCard> createState() => _VodCardState();
}

class _VodCardState extends State<_VodCard> {
  bool _hover = false;

  /// 节目编号（`1001` 起）；没有登记的条目为 null。
  int? get programNumber => kProgramNumbers[widget.item.id];

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: _hover ? AppTheme.surfaceHigh : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: _hover ? AppTheme.accent.withValues(alpha: 0.5) : Colors.transparent,
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _PosterBlock(item: widget.item)),
              const SizedBox(height: 8),
              Row(
                children: [
                  // 节目编号：与直播频道共用一套「唯一、稳定的数字编号」，
                  // 电视上可以直接用遥控器输入编号定位。
                  if (programNumber != null) ...[
                    Text(
                      '$programNumber',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.accent,
                      ),
                    ),
                    const SizedBox(width: 5),
                  ],
                  Expanded(
                    child: Text(
                      widget.item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                widget.item.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: AppTheme.textTertiary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EpisodeChip extends StatelessWidget {
  const _EpisodeChip({
    required this.label,
    required this.current,
    required this.onTap,
  });

  final String label;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: current ? AppTheme.accentDim : AppTheme.surface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: current ? AppTheme.accent : AppTheme.divider,
              width: current ? 1 : 0.8,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: current ? Colors.white : AppTheme.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
