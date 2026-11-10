import 'dart:async';

// Flutter 构建走官方 foundation；裸 `dart run` 的状态机回归走纯 Dart 替身，
// 否则 foundation.dart 会拉进 dart:ui，回归脚本连控制器都 import 不进来。
import 'live_notifier_stub.dart'
    if (dart.library.ui) 'package:flutter/foundation.dart'
    show ChangeNotifier, debugPrint, visibleForTesting;

import '../../core/player/kernel_error.dart';
import '../../core/player/player_controller.dart';
import 'async_gate.dart';
import 'carrier_detector.dart';
import 'channel_numbering.dart';
import 'channel_settings.dart';
import 'decode_gate.dart';
import 'live_auto_advance.dart';
import 'live_catalog.dart';
import 'live_channel.dart';
import 'live_health.dart';
import 'live_selection.dart';
import 'network_channel.dart';
import 'official_sources.dart';
import 'preferred_stream.dart';

/// 直播调台状态。
enum LiveTuning {
  /// 还没开始（首屏尚未调台）。
  idle,

  /// 正在连接 / 起播中。
  tuning,

  /// 已出画面。
  playing,

  /// 该频道所有线路都不可用（明确终态，绝不是「一直在加载」）。
  failed,
}

/// 电视直播的播放控制器：**调台 + 单台多线路自动容错 + 全失效自动切台**。
///
/// 为什么不复用 `PlaybackOrchestrator`：那套是给点播设计的，
/// 「集数偏移 / 广告插入 / 片尾判定 / 续播记录」对直播全是噪声——
/// 直播只需要「把这条流播出来，播不出来就换下一条，整个台都播不出来就换台」。
///
/// 容错策略（四层）：
/// 1. `load` 抛异常 → 立刻试下一条线路；
/// 2. 载入成功但 [startTimeout] 内位置始终不前进 → 判定这条线路起不来，换线路；
/// 3. 已经在播但位置连续 [stallTimeout] 不前进 → 判定卡死，换线路；
/// 4. **当前台全部线路都试过仍不能播 → 按频道表顺序自动切下一个台**，
///    继续走完整的正常起播流程。绝不留在原台反复加载/重复重试/卡加载态。
///
/// 稳定性（对应「线路切换、加载失败、自动切台时闪退」）：
/// * [AsyncSerialGate] 把所有会碰播放内核的流程排成一条队——epoch 只能丢弃
///   「过期结果」，挡不住「已经发出的 `player.load()`」。并发 open 是原生崩溃主因。
/// * 所有 Timer 回调 / `unawaited` 分支都有 try-catch，不产生未捕获异步异常。
/// * [_notify] 统一守卫，dispose 之后不再 `notifyListeners()`。
/// * 看门狗切线路期间用 [_failoverInFlight] 防重入，避免周期回调叠出多条换线流程。
class LiveController extends ChangeNotifier {
  final PlayerController player;
  final LiveCatalogService catalogService;

  /// 起播确认上限：超过这个时间既没画面、位置也没动，才认为线路挂了。
  ///
  /// 这个值给得比较宽（30 秒），因为**它只是兜底，不是主要判据**：
  /// 真正决定换线时机的是内核报出的终态错误（见 [PictureProbe.lastError]），
  /// 死线路通常 1~3 秒内就会报 `Failed to open` 被换掉，根本等不到这里。
  final Duration startTimeout;

  /// 播放中位置停滞多久判定卡死。
  final Duration stallTimeout;

  /// 线路健康度（探测耗时 / 起播耗时 / 失败次数）。
  final StreamHealthBoard health;

  /// 健康度变化时的落盘钩子（节流调用，可为 null）。
  final Future<void> Function(String json)? healthSink;

  /// 数字编号的落盘钩子（跨会话保持「同一个台永远同一个号」）。
  final ChannelNumberStore? numberStore;

  /// 每频道「上次顺畅播放」的线路缓存（跨会话直达最优线路，可为 null）。
  final PreferredStreamBoard? preferred;

  /// 偏好线路变化时的落盘钩子（节流调用，可为 null）。
  final Future<void> Function(String json)? preferredSink;

  /// 频道 → 数字编号。
  late final ChannelNumberBook numbers;

  /// 自动切台的间隔。留出一点时间让 UI 把「切到下一台」的提示显示出来，
  /// 也避免整网故障时几百个台被瞬间空转一遍。
  static const Duration advanceDelay = Duration(milliseconds: 800);

  /// 一整轮全灭后，多久重新扫描一次（低频，不会卡在加载态）。
  static const Duration fullRescanDelay = Duration(seconds: 30);

  /// 单个频道的**整台起播总预算**。
  ///
  /// 央视补强后单台线路可达 10 条，若逐条都等满耐心，最坏是 2 分钟黑屏；
  /// 而用户对「切台」的耐心只有几秒。所以按台封顶：预算内没出画面就停止
  /// 逐条试错，直接给出「本台线路都不通」的可操作结论（换台 / 稍后重试）。
  ///
  /// 15 秒的依据（2026-11-07 实测）：
  /// * 能播的慢源首帧分布 3.5 / 4.8 / 5.5 / 5.6 / 7.7 秒，单条 7 秒耐心够覆盖；
  /// * 死链的失败是**确定性**的（内核 1~3 秒报 Failed to open，或探测 3.5 秒超时），
  ///   不需要为它留 12 秒；
  /// * 15 秒刚好容得下「两条线路各等到 7 秒」，比 30 秒少一半黑屏等待，
  ///   也仍然覆盖「第一条慢源失败、第二条正常」的常见路径。
  ///
  /// **2026-11-07 21:30 复测后放宽到 20 秒**：晚间高峰下同一批「慢源」的首帧从
  /// 上午的 3.5~7.7 秒涨到 10~14 秒（河南卫视 14s / CCTV-17 14s / 山东教育 14s
  /// 才出画面，8s 窗口会全部误判为死链）。15 秒会把它们卡在边界上反复失败，
  /// 20 秒既容得下这批慢源，也比改动前的 30 秒少三分之一等待。
  /// 判定口径不变：预算内没出画面就停手、给可操作结论，不无限重试。
  static const Duration tuneBudget = Duration(seconds: 20);

  /// 官方源解析器（起播前把带时效令牌的中转地址换成官方 CDN 直连）。
  /// 测试可注入替身；默认构造一个真实解析器。
  final OfficialSourceResolver resolver;

  /// 解码门禁的判决记忆（已知花屏的地址在选源里排到最后）。
  final DecodeGateBoard decodeBoard;

  /// 按网络可达性筛候选（组播 / 运营商内网 CDN）。
  ///
  /// 默认构造一个「组播关闭、运营商未知」的策略，此时所有线路都是 public，
  /// 行为与本能力接入前**逐字节一致**——这是档位 C 用户的默认状态。
  final NetworkChannelPolicy channelPolicy;

  LiveController({
    required this.player,
    required this.catalogService,
    StreamHealthBoard? health,
    this.healthSink,
    this.numberStore,
    this.preferred,
    this.preferredSink,
    this.startTimeout = const Duration(seconds: 30),
    this.stallTimeout = const Duration(seconds: 18),
    OfficialSourceResolver? resolver,
    DecodeGateBoard? decodeBoard,
    DecodeFaultSource? decodeSource,
    NetworkChannelPolicy? channelPolicy,
  })  : health = health ?? StreamHealthBoard(),
        resolver = resolver ?? OfficialSourceResolver(),
        decodeBoard = decodeBoard ?? DecodeGateBoard(),
        channelPolicy = channelPolicy ?? NetworkChannelPolicy() {
    numbers = ChannelNumberBook(store: numberStore);
    // 播放内核没有日志转发能力时（Android 平台通道内核）自动静默退化：
    // 官方源的离线解码验证仍然生效，只是不做运行时的花屏换线。
    final source = decodeSource ??
        (player is DecodeFaultSource ? player as DecodeFaultSource : null);
    _decodeSub = source?.decodeFaults.listen(_onDecodeFault);
  }

  StreamSubscription<DecodeFaultEvent>? _decodeSub;

  /// 本轮调台**真的试过**的线路地址。
  ///
  /// 换线不能只靠 `_nextStreamIndex + 1`：解码门禁会把花屏线路挪到末尾，
  /// 选源排序因此会在一次调台中途改变，原来的下标加一可能直接跳过唯一
  /// 没试过的备用线路（实测「加扰 → 换线」时整台被误判为全灭）。
  /// 用地址集合记录实际尝试，排序怎么变都不会漏线或重复试线。
  final Set<String> _attemptedUrls = <String>{};

  /// 当前实际交给播放内核的地址。
  ///
  /// 官方源线路在 load 前会被解析器换成 CDN 直连地址，解码事件里带的是
  /// **换过之后的**地址；比对必须用它，不能用 `LiveStream.url`（那是稳定的
  /// 身份键，用于健康度 / 失效 / 偏好记忆）。
  String _loadedUrl = '';

  List<LiveChannel> _channels = const <LiveChannel>[];
  String _sourceLabel = '尚未装载';
  List<String> _warnings = const <String>[];

  LiveChannel? _current;
  LiveStream? _currentStream;
  LiveTuning _phase = LiveTuning.idle;
  String _message = '准备就绪';
  int _nextStreamIndex = 0;

  /// 每次调台自增；异步流程每步都比对，旧调台的结果一律丢弃。
  int _epoch = 0;

  /// 频道表装载代次：后台增强回来时若代次已变（用户重载 / 再次 bootstrap），
  /// 丢弃旧结果，避免把更旧的频道表覆盖回正在展示的新表。
  int _catalogGeneration = 0;

  /// dispose 之后禁止再通知监听者（ChangeNotifier 的经典崩溃点）。
  bool _disposed = false;

  /// 串行化所有「会碰播放内核」的流程，杜绝并发 open。
  final AsyncSerialGate _gate = AsyncSerialGate();

  /// 一轮自动切台的进度（纯策略，可独立回归）。
  final AutoAdvancePlanner _advance = AutoAdvancePlanner();

  Timer? _watchdog;
  double _lastWatchedPosition = -1;
  int _stallTicks = 0;
  bool _paused = false;

  /// 自动切台 / 全表重扫定时器（取代旧的「同一台静默重连」）。
  Timer? _advanceTimer;

  /// 看门狗触发的换线流程是否正在执行：周期回调每 2 秒来一次，
  /// 没有这个标记就会叠出多条同时换线的流程。
  bool _failoverInFlight = false;

  /// 手动换线时指定的「先试这条」（[tune] 消费后即清空）。
  String? _forceFirstUrl;

  /// 健康度落盘节流时间戳。
  DateTime _lastPersistAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 偏好线路落盘节流时间戳。
  DateTime _lastPreferredPersistAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 本次调台实际使用的起播耐心（多线路时比 [startTimeout] 短）。
  Duration _activeStartTimeout = const Duration(seconds: 30);

  List<LiveChannel> get channels => _channels;
  String get sourceLabel => _sourceLabel;
  List<String> get warnings => _warnings;
  LiveChannel? get current => _current;
  LiveStream? get currentStream => _currentStream;
  LiveTuning get phase => _phase;
  String get message => _message;
  bool get isPlaying => _phase == LiveTuning.playing;
  bool get isPaused => _paused;

  /// 诊断用：本轮已经自动跳了几个台。
  int get autoAdvanceHops => _advance.hops;

  /// 当前台按实际尝试顺序排好的线路（UI 用来显示「线路 2/4」）。
  List<LiveStream> get currentStreams =>
      _current == null ? const <LiveStream>[] : _rankedStreams(_current!);

  int get currentStreamIndex {
    final s = _currentStream;
    if (s == null) return -1;
    return currentStreams.indexWhere((e) => e.url == s.url);
  }

  int get currentStartupMs {
    final h = health.healthOf(_currentStream?.url ?? '');
    return h?.startupMs.round() ?? 0;
  }

  int get currentIndex =>
      _current == null ? -1 : _channels.indexWhere((c) => c.id == _current!.id);

  /// 按分类分组的频道表。
  ///
  /// 分类是**叠加**的：「苏州新闻综合」同时出现在「地方频道」与「新闻」两栏，
  /// 这正是「新闻 / 少儿 / 体育 覆盖央视、卫视、地方三类来源」的实现方式。
  Map<String, List<LiveChannel>> get grouped {
    final map = <String, List<LiveChannel>>{};
    for (final c in _channels) {
      final cats = c.categories.isEmpty ? <String>[c.group] : c.categories;
      for (final g in cats) {
        map.putIfAbsent(g, () => <LiveChannel>[]).add(c);
      }
    }
    return map;
  }

  /// 换掉整张频道表，并同步重建数字编号。
  ///
  /// 编号必须在**每次频道表变化**时重建：频道表变了（新增台 / 少了一个镜像）
  /// 编号表要跟着变，但老台已经分配到的号必须保持不变（靠落盘记忆）。
  void _setChannels(List<LiveChannel> channels) {
    _channels = LiveCatalogService.sortChannels(channels);
    numbers.rebuild(_channels);
    // 运行时顺序（自动切台 / 上下台 / 频道反查迭代 / currentIndex）必须与界面
    // 展示的「按编号升序」对齐：
    // [LiveCatalogService.sortChannels] 只按台名里的数字排序，而「山西卫视 /
    // CHC动作电影 / CGTN 西语」这类**没有内嵌数字的台名**都会落到 9999、退回
    // 输入顺序——于是运行时顺序与展示顺序脱节，自动切台 / 上下台会跳到界面上
    // 并不相邻的频道（实测 山西卫视→重庆卫视、CHC→CGTN Spanish）。
    // 此刻编号已经分配完毕，按「实际编号」重排一遍即可让两者一致。
    // 编号全局唯一，这是一条全序，且天然按号段（央视<卫视<地方）成块。
    _channels.sort(_compareByAssignedNumber);
  }

  /// 按已分配数字编号升序（见 [_setChannels] 说明）。
  int _compareByAssignedNumber(LiveChannel a, LiveChannel b) {
    final na = numbers.numberOf(a.id) ?? 999999;
    final nb = numbers.numberOf(b.id) ?? 999999;
    return na.compareTo(nb);
  }

  /// 频道的数字编号（遥控器输入用；未分配时返回 null）。
  int? numberOf(String channelId) => numbers.numberOf(channelId);

  /// 当前台的数字编号。
  int? get currentNumber {
    final id = _current?.id;
    return id == null ? null : numbers.numberOf(id);
  }

  /// 按数字编号切台（遥控器数字键）。
  ///
  /// 编号不存在时返回 false，UI 可以给一句「没有这个频道」。
  /// 走的是与点台完全相同的 [tune] 流程——数字键不是「另一条播放路径」。
  Future<bool> tuneByNumber(int number) async {
    if (_disposed) return false;
    final target = numbers.channelForNumber(_channels, number);
    if (target == null) return false;
    await tune(target);
    return true;
  }

  /// 仅供回归：直接装载频道表，跳过 [bootstrap] 的首启探测与自动选台。
  ///
  /// 「当前台全线路失败 → 自动切下一台」必须能脱离网络与首启策略被单独驱动，
  /// 否则测试里 bootstrap 的两次起播尝试会抢先改掉 epoch，把待验证的
  /// 定时器流程取消掉，结果测的是另一条路径。
  @visibleForTesting
  void loadChannelsForTest(
    Iterable<LiveChannel> channels, {
    String label = '测试清单',
  }) {
    _setChannels(LiveCatalogService.sortChannels(channels.toList()));
    _sourceLabel = label;
    _notify();
  }

  /// 统一通知出口：dispose 之后一律不碰 `notifyListeners()`。
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  void _cancelAdvanceTimer() {
    _advanceTimer?.cancel();
    _advanceTimer = null;
  }

  /// 装载频道表并开播。**任何异常都在内部消化**，不给 `initState` 的
  /// `unawaited(bootstrap())` 留下未捕获异步错误。
  Future<void> bootstrap({bool remote = true}) async {
    try {
      await _bootstrapLocked(remote: remote);
    } catch (e) {
      debugPrint('[live] bootstrap failed: $e');
      if (!_disposed && _phase == LiveTuning.idle) {
        _phase = LiveTuning.failed;
        _message = '频道表装载失败，请检查网络后重试';
        _notify();
      }
    }
  }

  Future<void> _bootstrapLocked({required bool remote}) async {
    // 运营商识别是「增强项」：后台跑，绝不占用首帧时间。
    // 失败 / 蜂窝 / 归属服务不可用时策略自动落到「仅公网」，用户体验不变。
    unawaited(_detectNetworkAsync());
    if (_channels.isEmpty && catalogService.builtIn.isNotEmpty) {
      _setChannels(LiveCatalogService.sortChannels(catalogService.builtIn));
      _sourceLabel = '内置清单（${_channels.length} 个频道）';
      _notify();
    }

    if (!remote) {
      if (_channels.isEmpty) return;
      if (_current != null && _phase == LiveTuning.playing) return;
      await _startPlayback();
      return;
    }

    // ── 第一阶段：只等主索引（小目录，亚秒~1s）就先出画面 ──────────────
    // 备用线路（streams.json 3.8 MB）与全网聚合表（多 MB）挪到第二阶段后台补齐，
    // 首帧不再等它们。这是「初始加载耗时过长」最关键的一刀。
    // 重新装载前清掉上一轮的证书失败结论：换了网络或系统升级后，
    // 旧结论会让本来能播的源被标成「证书太旧」。
    catalogService.resetTlsFailures();
    final base = await catalogService.loadBase(remote: true);
    _applyCatalog(base.channels, base.sourceLabel, base.warnings);
    debugPrint('[live] catalog(base) ${base.sourceLabel}'
        '${base.warnings.isEmpty ? '' : ' 降级=${base.warnings.join(' / ')}'}');
    if (_channels.isEmpty) return;
    // 已经在播就别打断：设置页「重新获取频道表」只更新列表，不动画面。
    if (_current != null && _phase == LiveTuning.playing) return;

    final generation = ++_catalogGeneration;
    await _startPlayback();
    if (_disposed || generation != _catalogGeneration) return;

    // ── 第二阶段：后台补齐备用源与全网聚合表，不阻塞首帧、不打断播放 ──
    unawaited(_enhanceAsync(generation, base));
  }

  /// 首屏起播：优先走「上次顺畅线路」捷径，否则小批探测选台。
  ///
  /// 探测批次从 8×4（最坏 32 条）压到 6×2（最坏 12 条）：基线来自 iptv-org 官方目录，
  /// 前几批基本都能命中，堆满 4 轮只会在极端全灭场景多等一两个 3s 周期。
  Future<void> _startPlayback() async {
    if (_channels.isEmpty) return;

    // 热启动捷径：上一会话记过「顺畅线路」、且 5 分钟内刚探通过的频道，
    // 直接切过去——跳过首屏「整批探测选台」的等待，几乎瞬时出画面。
    if (preferred != null) {
      for (final ch in _channels) {
        final url = preferred!.preferredFor(ch.id);
        if (url != null && !_dead.isDead(url) && health.isFreshOk(url)) {
          final epochBeforeWarm = _epoch;
          await tune(ch);
          if (_phase == LiveTuning.playing) return;
          // 这条偏好线路实际起播失败（已自动标记为失效）：不阻塞，继续探测选台。
          if (_epoch != epochBeforeWarm + 1) return;
          break;
        }
      }
      if (_phase == LiveTuning.playing) return;
    }

    var epochBefore = _epoch;
    // 最多试两个台：探测只能证明「HTTP 能连通」，不能证明码流可解码。
    // 再往后就交给自动切台链路，不需要在这里堆重试。
    for (var attempt = 0; attempt < 2; attempt++) {
      final probed = await _selectProbed(batch: 6, rounds: 2);
      if (epochBefore != _epoch) return;
      final pick = probed ?? _pickPlayable();
      if (pick == null) return;
      final epochBeforeTune = _epoch;
      await tune(pick);
      if (_phase == LiveTuning.playing) return;
      if (_epoch != epochBeforeTune + 1) return;
      epochBefore = _epoch;
      debugPrint('[live] 第 ${attempt + 1} 个台起播失败：${pick.name}');
    }
  }

  Future<void> _detectNetworkAsync() async {
    try {
      await channelPolicy.refresh(force: true);
      _notify();
    } catch (e) {
      debugPrint('[live] carrier detect failed, stay on public: $e');
    }
  }

  /// 应用一份频道表并通知 UI；[replaceCurrent] 为真时把当前台换成新表里的同 id 对象，
  /// 好让「线路 i/n」与手动换线用上增强后新增的备用线路（对象换了、id/播放在途都不变）。
  void _applyCatalog(
    List<LiveChannel> channels,
    String label,
    List<String> warnings,
  ) {
    _setChannels(channels);
    _sourceLabel = label;
    _warnings = warnings;
    final cur = _current;
    if (cur != null) {
      for (final c in _channels) {
        if (c.id == cur.id) {
          _current = c;
          break;
        }
      }
    }
    _notify();
  }

  /// 后台增强：拉城市台 / 全网发现源 / streams.json，合并后静默换表。
  Future<void> _enhanceAsync(int generation, LiveCatalogSnapshot base) async {
    try {
      // 起播后先让首个缓冲稳定，再开始后台补齐（多 MB 下载），
      // 避免与起播抢带宽造成「刚出画面就卡一下」。
      if (_phase == LiveTuning.playing) {
        await Future<void>.delayed(const Duration(milliseconds: 1200));
      }
      if (_disposed || generation != _catalogGeneration) return;
      final enhanced = await catalogService.enhanceSnapshot(base);
      if (_disposed || generation != _catalogGeneration) return;
      _applyCatalog(enhanced.channels, enhanced.sourceLabel, enhanced.warnings);
      debugPrint('[live] catalog(enhanced) ${enhanced.sourceLabel}');
    } catch (e) {
      // 增强失败不影响已经出画面的基线频道表。
      debugPrint('[live] enhance failed: $e');
    }
  }

  Future<LiveChannel?> _selectProbed({int batch = 8, int rounds = 4}) async {
    try {
      return await LiveSelection.pickProbed(
        channels: _channels,
        dead: _dead,
        health: health,
        policy: channelPolicy,
        batch: batch,
        rounds: rounds,
        probe: (stream) => catalogService.probe(
          stream.url,
          headers: stream.headers,
        ),
        log: debugPrint,
      );
    } catch (e) {
      debugPrint('[live] probe failed: $e');
      return null;
    }
  }

  LiveChannel? _pickPlayable() => LiveSelection.pickPlayable(
        _channels,
        _dead,
        health: health,
        policy: channelPolicy,
      );

  final DeadStreamRegistry _dead = DeadStreamRegistry();

  void _markDead(LiveStream stream) {
    _dead.mark(stream.url);
    // 通道级冷却只记「当前网络确实该试」的线路：异网 / 未配置的线路
    // 永远不会进候选，它们的失败不该被记进任何健康分或冷却表。
    channelPolicy.noteFailure(stream);
  }

  List<LiveStream> _rankedStreams(LiveChannel channel) {
    final ranked = LiveSelection.rankStreams(
      channel,
      _dead,
      health: health,
      decodeBad: decodeBoard.knownBadUrls(),
      policy: channelPolicy,
    );
    // 组播线路在**每次**选源时按当前 udpxy 主机/端口重写：用户改了端口
    // 不用重新导入地址表，也不用重启 App（方案 F2 / 验收 5）。
    return ranked.map(channelPolicy.rewriteIfNeeded).toList(growable: false);
  }

  /// 诊断页的通道三项结果（不触发网络请求）。
  ChannelDiagnostics get channelDiagnostics => channelPolicy.diagnostics();

  /// 网络切换 / 设置页「重新检测」。
  ///
  /// 识别失败不会抛错、不阻塞播放：最坏结果是继续走公网源。
  Future<CarrierDetection> refreshNetwork({NetworkState? state}) async {
    final result = await channelPolicy.refresh(state: state, force: true);
    _notify();
    return result;
  }

  /// 网络断开 / VPN / 未知传输：暂停非公网通道，**不发起任何归属探测**。
  ///
  /// 与 [refreshNetwork] 的区别是这里只做失效与通知；离线时发公网 IP
  /// 请求注定失败，VPN 出口还可能给出与家宽完全不同的归属，反而会把
  /// 只在运营商内网可达的地址放进候选。
  void suspendNetwork({String reason = kNetworkSuspendReason}) {
    channelPolicy.suspend(reason: reason);
    _notify();
  }

  /// 应用一组新的通道设置（组播开关 / 网关 / 手动覆盖）。
  void applyChannelSettings(ChannelSettings settings) {
    channelPolicy.updateSettings(settings);
    _notify();
  }

  /// 把用户导入的地址表并入频道表。
  ///
  /// 用线上同一套 `mergeChannels`：同名台只**并入线路**、不新建第二个台，
  /// 台名与分组沿用现有表（与内置实测清单的合并规则完全一致）。
  String importAddressTable(List<LiveChannel> imported, {String label = '地址表'}) {
    if (imported.isEmpty) return '地址表没有可用频道';
    _applyCatalog(
      LiveCatalogService.mergeChannels(builtIn: _channels, remote: imported),
      '$_sourceLabel + $label',
      _warnings,
    );
    final count = imported.fold<int>(0, (n, c) => n + c.streams.length);
    return '已并入 ${imported.length} 个频道 / $count 条线路';
  }

  /// 起播前把「解析器中转地址」换成当次有效的官方 CDN 直连地址。
  ///
  /// 官方 4K 地址普遍带 `txSecret` / `txTime` / 一次性路径，写死即过期；
  /// 而直接把中转地址丢给播放内核，实测 23 条里只有 13 条能建起解码链
  /// （还要 UA 完全对上）。所以先由 Dart 侧解析一次，失败再退回原地址，
  /// 让既有的换线链路兜底。
  /// 官方源解析结果缓存（换台/回切时省掉一次 302 往返）。
  ///
  /// 为什么需要：官方 CDN 地址带时效令牌，每次起播都要重新 302 换一次，
  /// 实测单次 150~300ms —— 用户在这段时间里是黑屏。而令牌的有效期是**小时级**
  /// （miguvideo 的 `txTime` 实测约 +1h），所以短窗口内重用上一次的解析结果
  /// 完全安全，能把这段时间直接抹掉。
  ///
  /// 为什么只缓存 120 秒：公开 CDN 会提前失效（换 token、限流、下架），
  /// 缓存太久会让「回切」撞上已经过期的地址——那比慢更糟（要等一次失败）。
  /// 任何一次起播失败都会**立刻作废**该条目的缓存（见 [_invalidateResolve]）。
  static const Duration _resolveCacheTtl = Duration(seconds: 120);

  /// 解析**失败**的负缓存有效期。
  ///
  /// 为什么需要：解析器是第三方中转，故障时会对每个请求都返回 404/超时。
  /// 如果没有负缓存，每次切到这些台都要白等一次 150~300ms 的请求，然后才
  /// 退回本来就写死的官方直连地址——纯损耗（实测 2026-11-07 22:00 该解析器
  /// 全线 404，三个 4K 台每次切换都被拖慢）。
  /// 60 秒足够短，故障恢复后会很快重新尝试，不会把好地址长期挡在门外。
  static const Duration _resolveFailTtl = Duration(seconds: 60);

  /// 线路 → 负缓存到期时刻（这段时间内不再请求解析器）。
  final Map<String, DateTime> _resolveFailUntil = <String, DateTime>{};

  final Map<String, ({String url, DateTime at})> _resolvedCache =
      <String, ({String url, DateTime at})>{};

  Future<String> _resolvePlayUrl(LiveStream stream) async {
    final resolverUrl = stream.resolverUrl;
    if (resolverUrl == null || resolverUrl.isEmpty) return stream.url;
    // 负缓存命中：解析器刚失败过，直接退回原地址，不再浪费一次往返。
    final failUntil = _resolveFailUntil[stream.url];
    if (failUntil != null && DateTime.now().isBefore(failUntil)) {
      debugPrint('[live] 解析器近期失败，跳过解析直接退回原地址：${stream.url}');
      return stream.url;
    }
    // 命中正缓存：直接返回上一次解析出的 CDN 直连地址。
    final cached = _resolvedCache[stream.url];
    if (cached != null &&
        DateTime.now().difference(cached.at) < _resolveCacheTtl) {
      debugPrint('[live] 官方源解析命中缓存（${DateTime.now().difference(cached.at).inSeconds}s 前）');
      return cached.url;
    }
    try {
      final r = await resolver.resolve(resolverUrl, headers: stream.headers);
      if (r.ok) {
        debugPrint('[live] 官方源解析成功（${r.hops} 跳，${r.host}）：${r.url}');
        _resolvedCache[stream.url] = (url: r.url, at: DateTime.now());
        _resolveFailUntil.remove(stream.url);
        return r.url;
      }
      debugPrint('[live] 官方源解析失败：${r.reason}，退回 ${stream.url}');
    } catch (e) {
      debugPrint('[live] 官方源解析异常：$e，退回 ${stream.url}');
    }
    _resolvedCache.remove(stream.url);
    _resolveFailUntil[stream.url] = DateTime.now().add(_resolveFailTtl);
    return stream.url;
  }

  /// 起播失败时作废该线路的解析缓存：下次必须重新换 token，不能复用坏地址。
  void _invalidateResolve(LiveStream stream) {
    if (stream.resolverUrl == null) return;
    final hadCache = _resolvedCache.remove(stream.url) != null;
    // 失败说明**地址本身不行**（而不是解析器不行），负缓存也要清掉，
    // 否则 60 秒内会一直跳过解析、反复拿同一条坏地址去撞。
    _resolveFailUntil.remove(stream.url);
    if (hadCache) {
      debugPrint('[live] 解析缓存已作废：${stream.url}');
    }
  }

  /// 播放内核报告「这条流解不开」——立刻换线。
  ///
  /// 这是解码门禁与选源链路的唯一接点。四个守卫缺一不可：
  ///  * 只在 playing 阶段处理（起播阶段由首帧轮询与终态错误裁决）；
  ///  * 事件地址必须等于**本轮实际 load 的地址**（官方源解析后会变），
  ///    否则上一条线路的迟到日志会把刚播好的新线路踢掉；
  ///  * 只有加扰类才换线，网络类交给既有链路；
  ///  * 换线本身经 `_failoverToNextStream` 串行化，防重入。
  void _onDecodeFault(DecodeFaultEvent event) {
    if (_disposed || _phase != LiveTuning.playing || !event.shouldSwitch) return;
    if (event.url.isEmpty || event.url != _loadedUrl) return;
    final channel = _current;
    final stream = _currentStream;
    if (channel == null || stream == null) return;
    debugPrint('[live] 解码门禁判定花屏（${event.count} 条）：'
        '${event.sample} @ ${stream.url}');
    decodeBoard.record(
      stream.url,
      DecodeVerdict.scrambledFault(
        errorCount: event.count,
        sample: event.sample,
      ),
    );
    // 身份键用 stream.url（解析器地址），不是解析后的 CDN 地址：
    // 这样健康度 / 失效 / 偏好记忆不会因为每次解析出不同 token 而分裂。
    _markDead(stream);
    _forgetPreferred(channel, stream.url);
    health.recordFail(stream.url);
    _persistHealth();
    _message = '当前线路画面异常，正在切换备用线路…';
    _notify();
    unawaited(_failoverToNextStream(_epoch));
  }

  /// 调台：按线路优先级依次尝试，第一条出画面即停。
  ///
  /// [manual] 为 true 表示用户主动操作（点台 / 刷新 / 换线路 / 上下台），
  /// 会重置自动切台的一轮进度；自动切台内部用 false，保证一轮扫完能停下。
  Future<void> tune(LiveChannel channel, {bool manual = true}) async {
    if (_disposed) return;
    if (manual) _advance.reset();
    // **立即**作废旧流程，再排队。旧流程在下一个 await 检查点就会退出，
    // 而原生调用由 [_gate] 保证不会与本次调台重叠。
    final attempt = ++_epoch;
    _stopWatchdog();
    _cancelAdvanceTimer();
    _failoverInFlight = false;
    try {
      await _gate.run(() => _tuneLocked(channel, attempt));
    } catch (e) {
      debugPrint('[live] tune failed: $e');
      if (!_disposed && attempt == _epoch) {
        _phase = LiveTuning.failed;
        _message = '「${channel.name}」起播异常，正在切换下一个频道…';
        _notify();
        await _safePause();
        _onChannelExhausted(channel, attempt);
      }
    }
  }

  Future<void> _tuneLocked(LiveChannel channel, int attempt) async {
    _paused = false;
    _current = channel;
    _currentStream = null;
    _loadedUrl = '';
    _attemptedUrls.clear();
    _phase = LiveTuning.tuning;
    _message = '正在连接「${channel.name}」…';
    _nextStreamIndex = 0;
    _notify();

    if (!channel.isPlayable) {
      _phase = LiveTuning.failed;
      _message = '「${channel.name}」没有配置任何线路';
      _notify();
      _onChannelExhausted(channel, attempt);
      return;
    }

    final streams = _rankedStreams(channel).toList();
    // 多条线路时单条耐心必须比整台预算短，否则第一条就能吃掉全部预算。
    // 10s：覆盖实测最慢的可播首帧（7.7s）并留 2s 余量，同时保证 15s 预算内
    // 至少还能再试一条。单线台没有「换下一条」可言，仍用完整的 startTimeout。
    _activeStartTimeout =
        streams.length > 1 ? const Duration(seconds: 10) : startTimeout;
    final forced = _forceFirstUrl;
    _forceFirstUrl = null;
    // 偏好线路（上次顺畅播放的那条）优先试：切回同一频道时直接选它，
    // 跳过探测与逐条试错，把「切台延迟」从黑屏几秒压到几乎无缝。
    // 仅当它还活着（本会话没被判失效）才前置——已经标记死的不该被钉死。
    final preferredUrl = preferred?.preferredFor(channel.id);
    // 偏好地址必须**仍是这个台现有的一条线路**才能用。
    //
    // 公开源换 token / 换路径 / 换镜像之后，记忆里那条 URL 已经从频道表里消失。
    // 旧实现只在 `indexWhere` 找到时才前置，找不到就静默跳过——记录会一直留着，
    // 每次切回来都白查一次、且永远不会被新结果覆盖（因为新线路成功时才写）。
    // 这里显式作废：记忆以「当前表里真的存在」为前提。
    var usablePreferred = preferredUrl;
    if (preferredUrl != null &&
        !streams.any((s) => s.url == preferredUrl)) {
      preferred?.forget(channel.id);
      _persistPreferred(force: true);
      debugPrint('[live] 偏好线路已不在线路表，作废：${channel.name}');
      usablePreferred = null;
    }
    var firstUrl = forced;
    if (firstUrl == null &&
        usablePreferred != null &&
        !_dead.isDead(usablePreferred)) {
      firstUrl = usablePreferred;
    }
    if (firstUrl != null) {
      final at = streams.indexWhere((s) => s.url == firstUrl);
      if (at > 0) streams.insert(0, streams.removeAt(at));
    }
    final failures = <String>[];
    // 是否至少有一条线路是「证书握手失败」。这类失败与网络不通的表现完全一样，
    // 但处置方式相反：重试没用、换源才行。所以要单独记下来，最后给不同的文案。
    var tlsFailed = false;
    // 本会话已经判死的线路直接跳过：它们 10 分钟内不会自己变好，
    // 逐条重试只会让用户盯着黑屏一条一条等（4 条 × 8 秒 = 半分钟）。
    // `rankStreams` 只是把它们排到最后，并不会跳过。
    //
    // 这里同样**只认地址级失效**，不认主机连坐：一个主机常承载十几个台
    // （实测 74.91.26.218 一家就承载 13 个央视台），按主机连坐过滤会让
    // 这些台在 `alive` 里一条都不剩，只剩 `streams.take(1)` 的一条演示性尝试，
    // 那就是用户看到的「央视全都不能播」。
    final alive = streams.where((s) => !_dead.isDeadUrl(s.url)).toList();
    // 整台都被判死时也不能「一个都不试」：网络可能刚恢复。只试第一条，
    // 一次就够验证是否恢复；失败则立刻给结论，不再把剩下几条重走一遍超时。
    final order = alive.isNotEmpty ? alive : streams.take(1).toList();
    // 整台起播总预算：线路多不等于该等更久。
    // 央视这类台补强后单台可达 6~8 条线路，逐条满额等待的最坏情况是几十秒黑屏——
    // 那比「直接说这条台暂时不通」更糟。总预算内没出画面就收工、给出可操作结论。
    final tuneStartedAt = DateTime.now();
    final tuneDeadline = tuneStartedAt.add(tuneBudget);
    for (final s in order) {
      if (attempt != _epoch || _disposed) return;
      if (!DateTime.now().isBefore(tuneDeadline)) {
        debugPrint('[live] 整台起播预算用尽（${tuneBudget.inSeconds}s），'
            '跳过剩余线路：${channel.name}');
        break;
      }
      _currentStream = s;
      _attemptedUrls.add(s.url);
      // 索引仍按**完整**列表算：`_failoverLocked` / `switchToNextStream`
      // / UI 的「线路 i/n」都用完整列表下标，这里换成过滤后的下标会整体错位。
      _nextStreamIndex = streams.indexWhere((e) => e.url == s.url);
      final total = streams.length;
      _message = total == 1
          ? '正在连接「${channel.name}」…'
          : '正在连接「${channel.name}」（线路 ${_nextStreamIndex + 1}/$total）…';
      _notify();

      final ok = await _tryStream(
        attempt,
        s,
        channel: channel,
        budgetDeadline: tuneDeadline,
        // 「上次真的出过画面」比任何探测都可信。这正是用户要的
        // 「切回同一频道直接播，不再重新检索」：连 1.2s 的短探测也省掉。
        // 万一它已经失效，后面还有首帧轮询与逐条换线兜底，代价可控。
        trustedByPreference: s.url == usablePreferred,
      );
      if (attempt != _epoch || _disposed) return;
      if (ok) return;
      if (catalogService.tlsFailed(s.url)) tlsFailed = true;
      failures.add('${s.label}：${catalogService.tlsFailed(s.url) ? '证书握手失败' : '无响应'}');
    }

    _phase = LiveTuning.failed;
    // 失败文案必须带「花了多久」：用户对黑屏的耐心是「感觉过了很久」，
    // 报出实际秒数才知道是线路真不通，而不是应用卡死。
    final spentSeconds = DateTime.now().difference(tuneStartedAt).inSeconds;
    _message = tlsFailed
        // 乐视专项：证书失败必须说清原因与对策，不能混进「暂无信号」里，
        // 否则用户会一直重试、重启路由器，永远找不到出路。
        ? '「${channel.name}」${KernelErrorClassifier.tlsUserHint}'
        : '「${channel.name}」暂无可用信号'
            // 「本次尝试」而不是「已尝试全部」：被判死的线路会被跳过，
            // 说成「已尝试 N 条」会让人以为所有线路都试过了。
            '${failures.isEmpty ? '' : '（${spentSeconds}s 内试了 ${failures.length} 条线路）'}';
    _notify();
    // 收掉内核：起播判定失败时内核可能仍在后台重试，最终真的放起来
    // （实测出现过「界面显示暂无信号、声音已经在放」）。这种孤儿播放必须停掉。
    await _safePause();
    _persistHealth(force: true);
    _onChannelExhausted(channel, attempt);
  }

  /// **当前台全部线路都试过仍不能播**：按频道表顺序自动切下一个台。
  ///
  /// 这里刻意不再有「同一台静默重连 N 次」——那正是用户反馈的
  /// 「停留在原频道反复加载、重复重试」。切换前先把状态落到明确的
  /// [LiveTuning.failed] 终态（不是一直 `tuning`），定时器到点后走
  /// 与用户点台完全相同的 [tune] 流程，画面、看门狗、健康度全部照常。
  void _onChannelExhausted(LiveChannel channel, int attempt) {
    if (_disposed || attempt != _epoch) return;
    _advance.recordFailure(channel.id);
    final total = _channels.length;

    int? next;
    if (total >= 2 && !_advance.sweepComplete(total)) {
      final from = currentIndex;
      next = _advance.nextIndex(
        from < 0 ? 0 : from,
        total,
        (i) =>
            _advance.hasAttempted(_channels[i].id) ||
            !LiveSelection.hasLiveStream(_channels[i], _dead,
                health: health, policy: channelPolicy),
      );
    }
    if (next == null) {
      _phase = LiveTuning.failed;
      _message = '全部 $total 个频道暂时无可用信号，'
          '${fullRescanDelay.inSeconds} 秒后重新扫描';
      _notify();
      _scheduleFullRescan(attempt);
      return;
    }
    final target = _channels[next];
    _phase = LiveTuning.failed;
    _message = '「${channel.name}」全部线路不可用 → 正在切换到「${target.name}」';
    _notify();
    _scheduleAdvance(attempt, target);
  }

  void _scheduleAdvance(int attempt, LiveChannel target) {
    _cancelAdvanceTimer();
    _advanceTimer = Timer(advanceDelay, () {
      if (_disposed || attempt != _epoch) return;
      unawaited(_autoAdvance(attempt, target));
    });
  }

  /// 一轮扫完仍全灭：低频重扫，不空转、不卡加载态。
  void _scheduleFullRescan(int attempt) {
    _cancelAdvanceTimer();
    _advanceTimer = Timer(fullRescanDelay, () {
      if (_disposed || attempt != _epoch) return;
      _advance.reset();
      // 给所有线路一次重新机会：30 秒足够 CDN 换 token / 镜像复活。
      _dead.clear();
      final from = currentIndex;
      if (_channels.isEmpty) return;
      final target = _channels.length == 1
          ? _channels.first
          : _channels[((from < 0 ? 0 : from) + 1) % _channels.length];
      unawaited(_autoAdvance(attempt, target));
    });
  }

  Future<void> _autoAdvance(int attempt, LiveChannel target) async {
    if (_disposed || attempt != _epoch) return;
    try {
      debugPrint('[live] auto advance ${_advance.hops} -> ${target.name}');
      await tune(target, manual: false);
    } catch (e) {
      debugPrint('[live] auto advance failed: $e');
    }
  }

  /// 起播成功 2.5 秒后再预热其余线路（不动播放器）。
  ///
  /// 为什么不立刻预热：首帧出来之后紧接着就是拉后续分片、解码、送显，
  /// 这时再并发 3 条 HTTP 探测（每条最长 3s）会抢带宽，用户观感是
  /// 「刚切过去头两秒发卡」。推迟 2.5 秒让首批分片落袋，再在后台补健康度。
  ///
  /// 延迟期间用户若切台（epoch 变化）或已经开始播别的内容，直接放弃：
  /// 预热只是优化项，绝不能在错误的时间点占用带宽。
  void _schedulePrewarm(int attempt) {
    unawaited(Future<void>.delayed(const Duration(milliseconds: 2500), () {
      if (_disposed || attempt != _epoch || _phase != LiveTuning.playing) {
        return;
      }
      _prewarm(attempt);
    }));
  }

  /// 播放稳定后，在后台把本台其余备用线路测一遍（不动播放器）。
  void _prewarm(int attempt) {
    final channel = _current;
    final playing = _currentStream;
    if (channel == null || playing == null) return;
    final candidates = _rankedStreams(channel)
        .where((s) => s.url != playing.url && !_dead.isDead(s.url))
        .take(3)
        .toList(growable: false);
    if (candidates.isEmpty) return;
    unawaited(_prewarmAsync(attempt, candidates));
  }

  Future<void> _prewarmAsync(int attempt, List<LiveStream> candidates) async {
    try {
      for (final s in candidates) {
        if (attempt != _epoch || _disposed || _phase != LiveTuning.playing) {
          return;
        }
        final sw = Stopwatch()..start();
        final ok = await catalogService.probe(
          s.url,
          timeout: const Duration(seconds: 3),
        );
        sw.stop();
        if (attempt != _epoch || _disposed) return;
        if (ok) {
          health.recordOk(s.url, sw.elapsed);
        } else {
          health.recordFail(s.url);
        }
      }
      _persistHealth(force: true);
    } catch (e) {
      debugPrint('[live] prewarm failed: $e');
    }
  }

  void _persistHealth({bool force = false}) {
    final sink = healthSink;
    if (sink == null) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastPersistAt) < const Duration(seconds: 5)) {
      return;
    }
    _lastPersistAt = now;
    try {
      unawaited(sink(health.encode()).catchError((Object _) {}));
    } catch (e) {
      debugPrint('[live] health persist failed: $e');
    }
  }

  /// 偏好线路落盘（节流，与主健康度共用思路）。
  void _persistPreferred({bool force = false}) {
    final board = preferred;
    final sink = preferredSink;
    if (board == null || sink == null || board.isEmpty) return;
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastPreferredPersistAt) < const Duration(seconds: 5)) {
      return;
    }
    _lastPreferredPersistAt = now;
    try {
      unawaited(sink(board.encode()).catchError((Object _) {}));
    } catch (e) {
      debugPrint('[live] preferred persist failed: $e');
    }
  }

  /// 手动换到下一线路。
  Future<void> switchToNextStream() async {
    final channel = _current;
    if (channel == null) return;
    final streams = currentStreams;
    if (streams.length < 2) return;
    final index = currentStreamIndex;
    LiveStream? next;
    for (var step = 1; step < streams.length; step++) {
      final candidate = streams[(index + step) % streams.length];
      if (!_dead.isDead(candidate.url)) {
        next = candidate;
        break;
      }
    }
    next ??= streams[((index < 0 ? 0 : index) + 1) % streams.length];
    final current = _currentStream;
    if (current != null) health.recordFail(current.url);
    _forceFirstUrl = next.url;
    await tune(channel);
  }

  /// 起播单条线路，成功返回 true。**整段不向外抛异常**。
  ///
  /// [channel] 由调用方显式传入而不是从 `_current` 里取：自动切台与看门狗
  /// 换线都会在 `await` 期间改动 `_current`，用字段读到的可能已经是下一个台，
  /// 于是「刚播成功的这条线路」被记到了别的频道名下。
  ///
  /// [trustedByPreference] 表示这条就是该频道上次真的出过画面的线路。
  Future<bool> _tryStream(
    int attempt,
    LiveStream stream, {
    required LiveChannel channel,
    bool trustedByPreference = false,
    DateTime? budgetDeadline,
  }) async {
    // 计时从「开始尝试这条线路」算起：resolve + 探测 + load + 首帧都属于用户
    // 实际等待。旧实现只在 load 之后起表，健康分因此看不到 3.5 秒探测和 6 秒
    // 解析，排序会把「探测慢、首帧慢」的线路当成「首帧快」。
    final attemptStartedAt = DateTime.now();
    try {
      // 整台预算已用尽时连探测都不做：探测本身也要 3.5 秒。
      if (budgetDeadline != null &&
          !DateTime.now().isBefore(budgetDeadline)) {
        return false;
      }
      // 官方源：先解析出当次有效的 CDN 直连地址。解析本身已经是一次带超时
      // 的真实网络请求，所以这类线路不再重复做下面的短探测（省 1~3.5 秒）。
      final resolveStartedAt = DateTime.now();
      final playUrl = await _resolvePlayUrl(stream);
      if (attempt != _epoch || _disposed) return false;
      final resolveMs = DateTime.now().difference(resolveStartedAt).inMilliseconds;
      // 探测只用来「把明显打不开的地址提前筛掉」；它不该成为换台延迟的主因。
      // 旧实现每次换台都先跑一次 4s 的 HTTP 探测再 load，用户点下去要等好几秒
      // 才见到画面。现在分三档：
      //  0) 上次真的出过画面（偏好线路）→ 直接信，连探测都不做；
      //  1) 5 分钟内实测可用（isFreshOk）→ 直接信，跳过探测；
      //  2) 有历史数据且不 flaky → 也直接信（省掉重复探测，切回常看台几乎零等待）；
      //  3) 未知线路 → 做一次**短探测**（1.2s）：既筛得掉「回 200 却不吐数据」的
      //     镜像，又不会像 4s 探测那样拖慢每一次换台。
      // 真正判死仍交给内核的终态错误（1~3s 内报 Failed to open）+ 起播轮询。
      final h = health.healthOf(stream.url);
      final trusted = stream.resolverUrl != null ||
          trustedByPreference ||
          health.isFreshOk(stream.url) ||
          (h != null && h.hasData && !h.isFlaky);
      // 探测没通过只说明「3.5 秒内没回包」，**不等于播不了**。
      // 实测 119 条央视/卫视线路：12 条首次探测失败、重试 2.0~4.7 秒成功。
      // 旧实现探测一失败就 markDead + return，等于用一把过短的尺子把
      // 「慢但能播」的源全部筛掉——用户看到的就是「这个台点不开」。
      // 现在探测只用来：① 能通过就记一笔健康度；② 没通过就把首帧耐心压短，
      // 真正的死活交给内核的终态错误（通常 1~3 秒）+ 首帧轮询裁决。
      //
      // **与 load 并行**：探测不再挡在起播前面。实测「未知线路」= 每次都先等
      // 3.5 秒才 load，这是切台慢最直接的一笔；并行后这 3.5 秒被 load 与解码
      // 建链吸收掉，探测只负责在失败时缩短耐心。
      var probeFailed = false;
      var probeMs = -1;
      if (trusted) {
        debugPrint('[live] trusted${trustedByPreference ? '(preferred)' : ''}'
            ', skip probe ${stream.url}');
      } else {
        final probeWatch = Stopwatch()..start();
        // 必须带线路声明的 Referer / UA：探测与播放用不同的请求头，
        // 等于用一把错的尺子把能播的源量成死链（见 `probe` 的注释）。
        //
        // 3.5 秒而不是 2 秒：实测能播的央视线路**首字节**分布是
        // 1.5 / 1.9 / 2.2 / 2.5 / 2.9 / 4.5 / 5.1 秒（境外中转 + 限速），
        // 2 秒的尺子会把其中一半量成「不通」。探测通过与否不影响是否起播
        // （只影响首帧耐心），所以这里宁可放宽，也不要把慢源记成死链。
        unawaited(catalogService
            .probe(
              stream.url,
              timeout: const Duration(milliseconds: 3500),
              headers: stream.headers,
            )
            .then((reachable) {
          probeWatch.stop();
          probeMs = probeWatch.elapsedMilliseconds;
          if (attempt != _epoch || _disposed) return;
          if (reachable) {
            health.recordOk(stream.url, probeWatch.elapsed);
          } else {
            probeFailed = true;
            debugPrint('[live] probe timed out (parallel), '
                'still try to play ${stream.url}');
          }
        }).catchError((Object e) {
          probeFailed = true;
          debugPrint('[live] probe crashed (parallel): $e');
        }));
      }

      // 原生调用前的最后一道闸门：epoch 变了就绝不碰播放内核。
      if (attempt != _epoch || _disposed) return false;
      final loadStartedAt = DateTime.now();
      final pictureEpochAtLoad = _pictureProbe?.pictureEpoch ?? 0;
      // 解码事件比对用的是**实际 load 的地址**（官方源解析后会变成 CDN 直连）。
      // 在 load 之前赋值，能让上一条线路的迟到日志立刻被判为过期。
      _loadedUrl = playUrl;
      try {
        await player.load(playUrl, 0, 0, headers: stream.headers);
        if (attempt != _epoch || _disposed) return false;
        await player.play();
      } catch (e) {
        debugPrint('[live] load failed ${stream.url} -> $e');
        _invalidateResolve(stream);
        _markDead(stream);
        _forgetPreferred(channel, stream.url);
        return false;
      }

      // 探测没通过的线路给更短的首帧耐心：它可能只是慢，也可能是
      // 「连上了却永远不吐流」的僵尸镜像。实测能播的慢源首帧上限 7.7 秒
      // （山东教育卫视），而探测已经花掉最多 3.5 秒，所以「探测失败后再给
      // 4 秒」≈ 总耐心 7.5 秒，既覆盖慢源，又不再让僵尸镜像白占 12 秒。
      // 主机已被连坐判可疑时更短（3 秒）：那种情况大概率整站真挂。
      final suspiciousHost = _dead.isDeadHost(stream.url);
      final probeFailBudget =
          suspiciousHost ? const Duration(seconds: 3) : const Duration(seconds: 4);
      var startBudget = _activeStartTimeout;
      // 整台总预算优先：剩下的时间不够一条线路的耐心时，用剩余时间——
      // 否则 6 条线路逐条满额等待会把单次切台拖到一分多钟。
      if (budgetDeadline != null) {
        final remaining = budgetDeadline.difference(DateTime.now());
        if (remaining <= Duration.zero) return false;
        if (remaining < startBudget) startBudget = remaining;
      }
      var deadline = DateTime.now().add(startBudget);
      // 探测失败只缩短一次，避免每轮循环都把 deadline 往后推。
      var probeShrunk = false;
      var firstFrameSettled = false;
      while (DateTime.now().isBefore(deadline)) {
        // 轮询粒度分两档：**头 2 秒用 90ms**，之后退到 250ms。
        //
        // 为什么要自适应：绝大多数换台在头 2 秒内就出画面（实测健康线路
        // 0.9~2.3s），300ms 的固定粒度等于平均多等 150ms——这段纯粹是
        // 「发现了没」的延迟，不是真的在等数据。而慢源阶段没必要 90ms 空转，
        // 退到 250ms 既省 CPU 又不影响体感（那时用户已经在等秒级）。
        if (!firstFrameSettled &&
            DateTime.now().difference(loadStartedAt) >
                const Duration(seconds: 2)) {
          firstFrameSettled = true;
        }
        await Future<void>.delayed(Duration(
            milliseconds: firstFrameSettled ? 250 : 90));
        if (attempt != _epoch || _disposed) return false;
        // 并行探测一旦失败，就把这条线路的耐心压短（只压一次）。
        // 探测与 load 是同时开始的，所以这里不会重新引入「先等探测」的延迟。
        if (probeFailed && !probeShrunk) {
          probeShrunk = true;
          final shrunk = DateTime.now().add(probeFailBudget);
          if (shrunk.isBefore(deadline)) {
            deadline = shrunk;
            debugPrint('[live] probe failed, shortening patience on '
                '${stream.url} to ${probeFailBudget.inSeconds}s');
          }
        }
        double pos;
        try {
          pos = await player.currentRawSeconds();
        } catch (_) {
          pos = 0;
        }
        final pictureReady =
            _isRendering && (_pictureProbe?.pictureEpoch ?? 0) > pictureEpochAtLoad;
        if (pos > 0.2 || pictureReady) {
          _phase = LiveTuning.playing;
          _message = '正在播放 · ${stream.label}';
          final elapsed = DateTime.now().difference(attemptStartedAt);
          final loadMs = DateTime.now().difference(loadStartedAt).inMilliseconds;
          // 一行结构化日志把「时间去哪了」拆开：解析 / 探测（并行，可能仍在跑）
          // / load 建链 / 总首帧。切台慢的归因直接看这一行，不用猜。
          debugPrint('[live] playing ${stream.url} pos=$pos'
              '${pictureReady ? ' picture=yes' : ''}'
              ' in ${elapsed.inMilliseconds}ms '
              '(resolve=${resolveMs}ms '
              'probe=${probeMs < 0 ? 'running' : '${probeMs}ms'} '
              'load=${loadMs}ms)');
          health.recordStartup(stream.url, elapsed);
          // 这条线路真的出画面了 → 撤掉它的失效记录，并解除主机连坐。
          // 不这么做的话，一次抖动留下的连坐会在 10 分钟里继续压住同一主机上
          // 其它本来已经恢复的台（央视 13 个台共用一台主机时尤其致命）。
          _dead.noteSuccess(stream.url);
          channelPolicy.noteSuccess(stream);
          // 记下「这个频道刚才顺畅播放的就是这条线路」：下次切回来直接选它，
          // 跨会话保留（落盘），是「按频道记忆流畅线路」的核心落点。
          if (channel.id.isNotEmpty) {
            preferred?.record(channel.id, stream.url);
            // 成功写盘必须立即落地：用户常常「看两秒就退出」，
            // 5 秒节流会把这条最有价值的记录直接丢掉。
            _persistPreferred(force: true);
          }
          // 播成功了就清掉本轮失败轨迹：之后的卡顿从一张干净的表重新开始。
          _advance.reset();
          _cancelAdvanceTimer();
          _persistHealth();
          _startWatchdog(attempt);
          _schedulePrewarm(attempt);
          _notify();
          return true;
        }
        final err = _pictureProbe?.lastError;
        if (err != null && KernelErrorClassifier.isFatal(err)) {
          debugPrint('[live] fatal kernel error on ${stream.url}: $err');
          health.recordFail(stream.url);
          _invalidateResolve(stream);
          _markDead(stream);
          _forgetPreferred(channel, stream.url);
          _persistHealth();
          return false;
        }
      }
      debugPrint('[live] start timeout on ${stream.url}'
          ', picture=${_isRendering ? 'yes' : 'no'}');
      health.recordFail(stream.url);
      _invalidateResolve(stream);
      _markDead(stream);
      _forgetPreferred(channel, stream.url);
      _persistHealth();
      return false;
    } catch (e) {
      // 任何意外（内核抛异常、探测抛异常、健康度写盘抛异常）都只当作
      // 「这条线路不行」，绝不让它冒泡成未捕获异步异常把 App 带崩。
      debugPrint('[live] stream attempt crashed, skipping: $e');
      _invalidateResolve(stream);
      _markDead(stream);
      _forgetPreferred(channel, stream.url);
      return false;
    }
  }

  /// 偏好线路起播失败 → 立即把记忆作废。
  ///
  /// 只 `markDead` 不够：失效表 10 分钟就过期，之后每次切回这个台又会先试
  /// 这条已经证明播不了的线。记忆必须以「真的出过画面」为准，失败就不是了。
  ///
  /// 只在「确实试过这条线路」时才调用（调用点都在失败分支里），
  /// 用户中途切台（epoch 变化）不走这里——那不是线路的问题。
  void _forgetPreferred(LiveChannel channel, String url) {
    final board = preferred;
    if (board == null) return;
    if (board.preferredFor(channel.id) != url) return;
    board.forget(channel.id);
    _persistPreferred(force: true);
    debugPrint('[live] 偏好线路起播失败，已作废：${channel.name}');
  }

  PictureProbe? get _pictureProbe =>
      player is PictureProbe ? player as PictureProbe : null;

  bool get _isRendering => _pictureProbe?.hasPicture ?? false;

  /// 播放中看门狗：位置连续 [stallTimeout] 不前进就换线路。
  void _startWatchdog(int attempt) {
    _stopWatchdog();
    _lastWatchedPosition = -1;
    _stallTicks = 0;
    _watchdog = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (_disposed || attempt != _epoch) {
        timer.cancel();
        return;
      }
      // 周期回调必须包住整个异步体：Timer 的 async 回调抛异常是
      // 未捕获异步错误，在桌面端就是一闪而退。
      unawaited(_watchdogTick(attempt, timer));
    });
  }

  Future<void> _watchdogTick(int attempt, Timer timer) async {
    try {
      if (_paused || _phase != LiveTuning.playing || _failoverInFlight) {
        _lastWatchedPosition = -1;
        _stallTicks = 0;
        return;
      }
      double pos;
      try {
        pos = await player.currentRawSeconds();
      } catch (_) {
        pos = -1;
      }
      final timelineNotStarted = pos <= 0.5;
      final alive =
          (pos > _lastWatchedPosition + 0.5) || (timelineNotStarted && _isRendering);
      if (alive) {
        _lastWatchedPosition = pos;
        _stallTicks = 0;
        return;
      }
      _stallTicks += 2;
      if (_stallTicks >= stallTimeout.inSeconds) {
        _stallTicks = 0;
        _lastWatchedPosition = -1;
        await _failoverToNextStream(attempt);
      }
    } catch (e) {
      debugPrint('[live] watchdog tick failed: $e');
    }
  }

  /// 当前线路卡死：试下一条；都试过就走全线路失败的自动切台链路。
  Future<void> _failoverToNextStream(int attempt) async {
    if (_disposed || attempt != _epoch || _failoverInFlight) return;
    _failoverInFlight = true;
    _stopWatchdog();
    try {
      await _gate.run(() => _failoverLocked(attempt));
    } catch (e) {
      debugPrint('[live] failover failed: $e');
    } finally {
      _failoverInFlight = false;
    }
  }

  Future<void> _failoverLocked(int attempt) async {
    final channel = _current;
    if (channel == null || attempt != _epoch || _disposed) return;
    final streams = _rankedStreams(channel);
    // 从「当前下标的下一项」开始绕一圈，而不是只往后走：
    // 解码门禁 / 健康度 / 失效登记都会在播放中改变排序，唯一没试过的
    // 备用线路可能已经被挪到前面。按地址集合跳过已试线路，既不会漏线，
    // 也不会把失败线路再等一遍超时。
    final start = (_nextStreamIndex + 1).clamp(0, streams.length);
    final order = <int>[
      for (var i = start; i < streams.length; i++) i,
      for (var i = 0; i < start; i++) i,
    ];
    for (final i in order) {
      if (attempt != _epoch || _disposed) return;
      final candidate = streams[i];
      // 地址级失效 + 本轮已试过：两者都不该重试。主机连坐是推测，
      // 只影响排序不影响资格，否则一个镜像承载十几个台时会整批无候选。
      if (_dead.isDeadUrl(candidate.url) ||
          _attemptedUrls.contains(candidate.url)) {
        continue;
      }
      _phase = LiveTuning.tuning;
      _message = '信号中断，正在切换备用线路…';
      _notify();
      _attemptedUrls.add(candidate.url);
      _currentStream = candidate;
      _nextStreamIndex = i;
      final ok = await _tryStream(attempt, candidate, channel: channel);
      if (attempt != _epoch || _disposed) return;
      if (ok) return;
    }
    _phase = LiveTuning.failed;
    _message = '「${channel.name}」本轮可用线路均已失败，正在切换下一个频道…';
    _notify();
    await _safePause();
    _persistHealth(force: true);
    _onChannelExhausted(channel, attempt);
  }

  /// 手动重试当前台（用户看到失败提示后点「刷新」）。
  Future<void> retry() async {
    final c = _current;
    if (c == null) return;
    await tune(c);
  }

  Future<void> nextChannel() async {
    final i = currentIndex;
    if (i < 0 || _channels.isEmpty) return;
    await tune(_channels[(i + 1) % _channels.length]);
  }

  Future<void> previousChannel() async {
    final i = currentIndex;
    if (i < 0 || _channels.isEmpty) return;
    await tune(_channels[(i - 1 + _channels.length) % _channels.length]);
  }

  Future<void> togglePause() async {
    if (_phase != LiveTuning.playing) return;
    _paused = !_paused;
    final wantPause = _paused;
    _notify();
    try {
      await _gate.run(() async {
        try {
          if (wantPause) {
            await player.pause();
          } else {
            await player.play();
          }
        } catch (_) {
          _paused = false;
          _notify();
        }
      });
    } catch (_) {
      _paused = false;
      _notify();
    }
  }

  Future<void> seekBy(Duration delta) async {
    if (_phase != LiveTuning.playing) return;
    try {
      final pos = await player.currentRawSeconds();
      await player.seek(((pos + delta.inSeconds).clamp(0, 1 << 30)).toDouble());
    } catch (_) {
      // 位置读不到时不打断播放。
    }
  }

  Future<void> _safePause() async {
    try {
      await player.pause();
    } catch (_) {
      // 停不下来也不影响把失败状态报给 UI / 继续自动切台。
    }
  }

  /// 离开直播页时调用：停掉画面与看门狗，但保留当前台，回来时可直接续上。
  Future<void> stop() async {
    _epoch++;
    _stopWatchdog();
    _cancelAdvanceTimer();
    _failoverInFlight = false;
    _phase = LiveTuning.idle;
    _message = '已停止';
    _paused = false;
    _notify();
    try {
      await _gate.run(_safePause);
    } catch (_) {
      // 停不下来不影响离开页面。
    }
  }

  /// 回到直播页时调用：接着播当前台（没有就调第一个）。
  Future<void> resume() async {
    if (_phase == LiveTuning.playing && !_paused) return;
    final c = _current ?? (_channels.isEmpty ? null : _channels.first);
    if (c == null) return;
    await tune(c);
  }

  void _stopWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _loadedUrl = '';
    unawaited(_decodeSub?.cancel());
    _stopWatchdog();
    _cancelAdvanceTimer();
    _gate.close();
    // 退出前把健康度写一次：下次启动就能直接选「已知最快」的源。
    _persistHealth(force: true);
    // 退出前把偏好线路写一次：下次启动切回常用台能直接命中最优线路。
    _persistPreferred(force: true);
    super.dispose();
  }
}
