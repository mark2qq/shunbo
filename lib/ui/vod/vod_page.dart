import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/services.dart';
import '../../app/theme.dart';
import '../../core/player/player_controller.dart';
import '../../core/scheduler/playback_orchestrator.dart';
import '../../core/scheduler/playback_queue.dart';
import '../../core/source/source_adapter.dart';
import '../../data/onboarding/third_party_vod_service.dart';
import '../../data/onboarding/vod_index_directory_store.dart';
import '../../data/onboarding/vod_source_address.dart';
import '../../data/resume_record.dart';
import '../../features/live/channel_numbering.dart';
import '../../features/vod/third_party_vod.dart';
import '../../features/vod/vod_boot_index.dart';
import '../../features/vod/vod_builtin_index.dart';
import '../../features/vod/vod_builtin_service.dart';
import '../../features/vod/vod_catalog.dart';
import '../../features/vod/vod_facets.dart';
import '../../features/vod/vod_facet_directory.dart';
import '../../features/vod/vod_index_gate.dart';
import '../../features/vod/vod_poster_service.dart';
import '../../features/vod/vod_playback_controls.dart';
import '../../features/vod/vod_search.dart';
import '../widgets/edge_reveal_handle.dart';
import '../widgets/player_stage.dart';
import 'player_control_bar.dart';
import 'panel_idle_hider.dart';
import 'vod_source_input_dialog.dart';

/// 点播栏目页（电影 / 电视剧 / 纪录片共用一套实现）。
///
/// 三态视图：浏览 → 详情 → 播放，全部在**同一页内切换**而不是 push 路由。
/// 理由：电视端每次 push 都会多一层返回栈，遥控器连按返回很容易一路退回桌面；
/// 页内切换则让「返回」始终只有一层，行为可预测。代价是必须自己接 [PopScope]
/// （见 [build]），否则系统返回键会把整个 App 退掉。
class VodPage extends StatefulWidget {
  const VodPage({
    super.key,
    required this.section,
    required this.services,
    required this.active,
    this.fullscreen = false,
    this.onToggleFullscreen = _noop,
  });

  final VodSection section;
  final ShunboServices services;
  final bool active;

  /// 是否处于全屏（由 `AppShell` 统一管理，与直播页共用同一个状态）。
  ///
  /// 放进外壳而不是页内：全屏要隐藏左侧导航与底部导航，那是外壳的结构，
  /// 页面自己做不到；两页各存一份 `_fullscreen` 还会出现「直播退出了全屏、
  /// 点播还以为在全屏」的不一致。
  final bool fullscreen;

  final VoidCallback onToggleFullscreen;

  @override
  State<VodPage> createState() => _VodPageState();
}

void _noop() {}

/// 点播页的页内视图。**只有两态**：列表 / 播放。
///
/// 1.0.5 第二十二次修（用户红标）：中间那层详情页整个去掉 —— 选中片源
/// 直接进播放页，影片介绍搬到播放页右栏。原来的三态在电视遥控器上要多按
/// 一次确认、还多一个「返回落在哪」的分支，用户明确要求跳过。
enum _VodView { browse, playing }

class _VodPageState extends State<VodPage> {
  _VodView _view = _VodView.browse;
  VodItem? _item;
  ResumeRecord? _resume;
  PlaybackSession? _session;
  bool _paused = false;
  bool _busy = false;

  /// 1.0.5 十九次修：内置索引命中点开后**先乐观进页**，回源在后台做。
  ///
  /// 第二十二次修把「乐观进详情页」改成「乐观进播放页」：卡片一点就切到
  /// 播放视图并显示遮罩，回源回来的那一刻直接起播，中途不再有详情页。
  /// 原来的同步 `await` 让用户对着不动的列表干等 2 秒，这段等待体验仍然要治。
  bool _resolving = false;
  String? _resolveError;

  /// 播放页右栏「影片详情」是否展开（第二十二次修）。
  ///
  /// 默认展开：详情页没了，进来先让人看见标题和简介；[kVodDetailIdleTimeout]
  /// 到点自动收缩成右侧窄条，交互再展开。
  bool _detailExpanded = true;
  Timer? _detailTimer;

  /// 回源代次：离开详情页 / 重试 / 换片都自增，回包后对不上就丢弃，
  /// 避免「点 A 又点 B，A 的晚到回包把 B 的剧集覆盖掉」。
  int _resolveSeq = 0;

  // 1.0.5 / G3：片库本地检索。默认空串 ⇒ 过滤前后列表逐项相同，
  // 不改变 1.0.4 的浏览结果，只是多了输入框。
  final TextEditingController _search = TextEditingController();
  String _query = '';

  /// 进度读数（1 秒一拍）。放在 ValueNotifier 里而不是 setState：
  /// 原来每秒 `setState` 会把整个栏目页（含网格）重建一次，
  /// 240 部片子时就是肉眼可见的掉帧，切换栏目也跟着变慢。
  final ValueNotifier<double> _position = ValueNotifier<double>(0);
  final ValueNotifier<double> _duration = ValueNotifier<double>(0);

  /// 已缓冲秒数（进度条中间那段）。内核不支持 [BufferProbe] 时恒为 0，
  /// 控制栏据此整段不画 —— 不画一个假位置比画一个猜的位置好。
  final ValueNotifier<double> _buffered = ValueNotifier<double>(0);

  /// 内核实测解码分辨率（`1080P` 这类）。未出画时为空串，徽标显示「自动」。
  final ValueNotifier<String> _resolution = ValueNotifier<String>('');

  /// 控制栏的四个读数合成一个 listenable：套四层 ValueListenableBuilder 没必要，
  /// 分开监听还会出现「位置更新了、缓冲还停在上一拍」的撕裂。
  late final Listenable _readout = Listenable.merge(
      <Listenable>[_position, _duration, _buffered, _resolution, _volumeN]);

  /// 当前倍速。内核不支持变速时恒为 1.0，面板里选别的档位不会假装生效。
  double _rate = 1.0;

  /// 当前清晰度档 id。采集源只提供一档，所以目前恒为 `auto`。
  String _qualityId = 'auto';

  /// 内联面板是否展开 / 是否正在拖进度条 —— 两者都要**钉住控制条**，
  /// 否则 4 秒一到控制条带着面板一起淡出，拖到一半消失。
  bool _panelOpen = false;
  bool _scrubbing = false;

  Timer? _ticker;

  /// 控制条显隐（遥控器/鼠标 4 秒无操作自动收起）。
  bool _controlsVisible = true;
  Timer? _hideTimer;

  /// 1.0.5 第八次修：**等首帧**的遮罩。
  ///
  /// 原来的 loading 只看 `_session == null`，而 `_session` 在 `startPlayback`
  /// 返回时就有值了 —— 那只是「load 命令发出去了」，mpv 真正拉到首个分片、
  /// 解出第一帧还要几秒（弱源 3–10 秒）。这段窗口里 `attachSurface` 画的是
  /// 纯黑，用户看到的就是「点了播放，黑屏，不知道它到底在动没有」。
  /// 现在改成盯 `player.hasPicture`，出画才撤遮罩。
  bool _awaitingPicture = false;

  /// 等首帧的兜底拍数（每秒一拍）。源端彻底不给画面时也要把遮罩撤掉，
  /// 否则会一直转圈，比黑屏更让人以为卡死。
  int _awaitingTicks = 0;
  static const int _awaitingMaxTicks = 15;

  /// 选集浮层。
  bool _showEpisodes = false;

  /// 音量。放 ValueNotifier 而不是普通字段：拖音量滑块时每帧都会变，
  /// 用 setState 会把整个点播页（含几千条卡片网格）重建一遍。
  final ValueNotifier<double> _volumeN = ValueNotifier<double>(100);

  // 1.0.5：默认加载源。进入栏目时按需自动拉一次（三个栏目页共用同一个
  // 单飞的分页会话，只有第一次真正发请求）。
  bool _autoRequested = false;
  String? _autoError;

  // ── 1.0.5 第 1 项：内置索引检索 ─────────────────────────────
  //
  // `_filteredFor` 是**同步**的（每次 build 都要算，不能 await），而读内置
  // 索引分片是异步的（解 gzip + 逐行扫描）。所以分两步：
  //  1. 输入变化 → debounce 180 ms → 异步检索，结果写进 [_indexHits]；
  //  2. `_filteredFor` 只做**同步合并**，把 [_indexHits] 拼到本地命中后面。
  // 这样滚动/每秒进度刷新都不会触发解压，只有真的改了关键词才查一次。
  List<VodItem> _indexHits = const <VodItem>[];

  /// [_indexHits] 对应的关键词。与当前输入不一致时说明结果还没回来，
  /// 不能把它当成「这次查询的答案」拼进去。
  String _indexHitsQuery = '\u0000';

  /// 该关键词在**整份栏目目录**里命中了多少条（卡片只铺前 N 张）。
  ///
  /// 用户要求「检索要按当前栏目全目录检索」——这个数就是证据：
  /// 搜「2020」时它可能是一万多，而不是当前已加载的 120 条里的几条。
  int _indexHitsTotal = 0;

  // ── 第十八次修：筛选条件也走整份目录 ─────────────────────────
  //
  // 条件是从整份目录统计出来的（「类型 · 剧情片」在电影栏目有 6.8 万条），
  // 应用条件却只对已加载的 120 条生效 —— 点下去剩几条，等于条件在说谎。
  // 这里把「当前筛选项」当查询条件扫一遍整个分片，结果放 [_facetHits]。
  List<VodItem> _facetHits = const <VodItem>[];

  /// [_facetHits] 对应的筛选条件快照（`类型|地区|时间`）。
  String _facetHitsKey = '\u0000';

  /// 该筛选条件在整份目录里命中多少条。
  int _facetHitsTotal = 0;

  int _facetScanSeq = 0;
  bool _facetScanScheduled = false;

  /// 检索序号：连续输入时只认最后一次的结果，避免「打快了先回来的覆盖后回来的」。
  int _indexSeq = 0;
  Timer? _indexTimer;

  /// 单次检索最多铺多少张卡（命中总数不受此限，会单独报出来）。
  ///
  /// 取 400 而不是全部：分片里十万条同名系列（`斗罗大陆` 能命中几十条）
  /// 全铺出来既翻不动也没意义，用户要的是「这部片在不在」+ 能点开。
  static const int _indexHitLimit = 400;

  /// 检索结果缓存：`(revision, query) → 列表`。
  ///
  /// 原来每次 build 都对全量条目跑一次 `filterVodItems`；分页接入后条目会到
  /// 几千条，而每秒一次的进度刷新、每次焦点变化都会触发 build，
  /// 于是「切栏目慢」里有一半是这里白算出来的。
  int _filterRevision = -1;
  String _filterQuery = '\u0000';
  VodFilter _filterOn = VodFilter.empty;
  List<VodItem> _filtered = const <VodItem>[];

  /// 顶部筛选条件（类型 / 地区 / 时间 / 排序）。与检索关键词是**两套独立条件**，
  /// 叠加生效：先按 facet 过滤，再走关键词。这样「筛了剧情片再搜片名」才符合直觉。
  VodFilter _filter = VodFilter.empty;

  /// 筛选区是否展开。第十七次修默认 **true**：目录级条件要「完整覆盖」，
  /// 首屏就把目录里全部可筛项列出来；用户仍可手动收起成紧凑视图。
  bool _filtersExpanded = true;

  /// 目录身份变化时清掉的旧选中条件的提示（显示到下一次目录变化）。
  String _facetResetNotice = '';

  /// 已处理过的目录结论版本，避免同一次加载反复清选中值。
  int _facetAppliedRevision = -1;

  /// 只让一个 build 调度一次条件加载，防止每帧都排 microtask。
  bool _facetSyncScheduled = false;

  /// 本栏目**整份目录**的条数 —— 「全部」tab 后面那个统计数。
  ///
  /// 口径必须是目录而不是当前列表：内置索引取该栏目分片的 `records`，
  /// 生成目录取 `vod-index.json` 里该栏目的条目数。两者都是「目录里一共
  /// 有多少部」，与已加载的 120 条、与筛选后的命中数都不是一回事。
  int _sectionTotal = 0;

  /// 手动刷新进行中（按钮转圈 + 禁止重复点击）。
  bool _refreshing = false;

  /// 手动刷新的结果提示（成功 / 失败都写在这里，下一次刷新前清空）。
  String _refreshNotice = '';

  // ── 1.0.5 第十六次修：播放列表 = 最终采用的索引，来源唯一 ────────
  //
  // 进入点播先由 services.vodIndexGate 判定「哪一份索引有效且与当前接口匹配」，
  // ready 之后才把那一份的片源按栏目灌进 [_indexPool]。列表**只**读这份池子，
  // 不再从 VodLibrary.inSection 取 —— 后者是另一条链路的外部目录缓存，
  // 混进来就等于同时用了两个来源（需求明确禁止）。
  List<VodItem> _indexPool = const <VodItem>[];

  /// 当前池子来自哪一份索引（诊断与一致性校验用；非 ready 时为 null）。
  VodIndexOrigin? _poolOrigin;
  String _poolSourceUrl = '';

  /// 池子对应的目录时间戳。与 `_poolOrigin` / `_poolSourceUrl` 一起构成
  /// 「这个池子是不是当前这份目录的」—— 切走再切回栏目时用它避免重灌。
  String _poolStamp = '';

  /// 续载页序号。builtin 走等距采样的「每段第 N 张」，generated 走顺序分页。
  int _indexPage = 0;
  bool _indexLoading = false;
  bool _indexExhausted = false;

  /// 生成索引的文档缓存：滚动续载不重复读盘。
  VodIndexDocument? _generatedDoc;

  /// 默认接口的**本地增补**目录缓存（第二十三次修）。
  ///
  /// 「立即获取最新片源 / 每 24 小时自动更新」对默认接口不会改随包索引，
  /// 新片源单独存一份（`loadSupplementFor`）。浏览、检索、条件统计三处都要
  /// 用到它，所以一次解码后缓存住；目录切换时随 [_resetIndexPool] 清掉。
  VodIndexDocument? _supplementDoc;

  /// 增补目录的**一次性读取**。存 Future 而不是 bool 标记：条件统计与条数
  /// 统计会在同一帧里各调一次，用 bool 标记的话第二次会拿到「还没读完」
  /// 的空结果并永久缓存成空。
  Future<List<VodItem>>? _supplementFuture;

  /// 在途加载序号。状态切换（例如用户换了接口）要让旧结果作废，
  /// 否则旧索引的片源会晚一步覆盖新列表 —— 「来源唯一」就破了。
  int _poolSeq = 0;

  /// 一次 needAddress 周期只自动弹一次输入页；用户取消后页面上仍有入口。
  bool _addressPromptShown = false;
  bool _addressPromptDismissed = false;

  static const int _indexPageSize = 120;

  @override
  void initState() {
    super.initState();
    // 1.0.5：第三方点播源接入 / 移除时栏目列表要立即刷新。
    widget.services.vodLibrary.addListener(_onLibraryChanged);
    widget.services.vodSession.addListener(_onLibraryChanged);
    // 1.0.5 第 2 项：启动校验的六个状态要驱动页面文案（「正在校验…」→
    // 「已加载内置索引 N 条」→…），因此必须监听而不是只在 build 里读一次。
    widget.services.vodBoot.addListener(_onLibraryChanged);
    // 第十六次修：进入点播的索引校验状态要驱动「弹输入页 / 灌列表 / 显示进度」。
    widget.services.vodIndexGate.addListener(_onIndexGateChanged);
    // 第十七次修：目录级筛选条件是异步加载的，结论回来要刷新筛选区。
    widget.services.vodFacetDirectory.addListener(_onFacetDirectoryChanged);
    _volumeN.value = widget.services.player.volume;
    // 内核可能保留着上一次的倍速（连播、切集不会重置），进页先对齐真实值，
    // 否则面板里高亮 1.0x、实际在 1.5x 播。
    final Object p = widget.services.player;
    if (p is PlaybackRateControl) _rate = p.rate;
    if (widget.active) {
      _bindQueue();
      unawaited(_ensureDefaultSource());
      unawaited(_enterIndexGate());
      unawaited(_syncFacetDirectory());
    }
  }

  /// 进入（或重新进入）本栏目：先校验，再由状态通知决定灌列表还是弹输入页。
  ///
  /// 每次激活都重跑一遍是刻意的：用户可能在设置页换过接口，或另一个栏目页
  /// 刚生成了新的索引目录文件。校验只读本地清单（几十毫秒），能换来保证
  /// 「播放列表内容始终与最终采用的索引一致」。
  Future<void> _enterIndexGate() async {
    await widget.services.vodIndexGate.check();
  }

  void _onIndexGateChanged() {
    if (!mounted) return;
    // 六个栏目页共享同一个 gate 实例。状态通知是广播的，若每页都去解自己
    // 那一片，一次进入点播就会把 6 个分片（约 13 MB 文本 + 6×120 个对象）
    // 全压进内存 —— 真机 API18 / armv7a 正是为此才做的按栏目懒加载。
    // 非激活页等 didUpdateWidget 里自己重新校验时再加载。
    if (!widget.active) return;
    // 目录身份可能刚变（换了接口 / 重新生成了目录文件），条件要跟着重取。
    unawaited(_syncFacetDirectory());
    final gate = widget.services.vodIndexGate;
    final state = gate.state;
    if (state.ready) {
      // 同一份目录 + 同一个来源 + 已经灌过首屏 ⇒ 不重灌。
      // 切走再切回栏目时池子与海报都还在，重灌会让 120 张卡整体重建。
      if (!_poolMatchesCurrentSource()) {
        unawaited(_loadIndexPage(restart: true));
      }
      // 「全部」后面的统计数属于目录元数据，跟着目录身份一起换。
      unawaited(_reloadSectionTotal());
    } else {
      _resetIndexPool();
      _sectionTotal = 0;
    }
    if (state.phase == VodIndexGatePhase.needAddress && widget.active) {
      _maybePromptAddress();
    }
    setState(() {});
  }

  // ── 1.0.5 第十七次修：目录级筛选条件 + 可见卡片海报 ──────────────

  /// 当前采用的索引目录的**身份**。
  ///
  /// 六个栏目页都从 `VodIndexGateController` / `BuiltinIndexService` 这两个
  /// 共享实例取值，因此算出来的字符串完全一致 —— 否则共享的
  /// [VodPosterService] 会被六个页面轮流 `switchScope`，互相清缓存。
  /// `directoryStamp` 区分「同地址、同条数、但目录被重新生成过」。
  String _directoryScope() {
    final gate = widget.services.vodIndexGate;
    final m = widget.services.vodBuiltin.manifest;
    return <String>[
      gate.activeOrigin?.name ?? 'none',
      gate.lastUrl,
      gate.directoryStamp,
      '${gate.state.total}',
      '${m?.total ?? 0}',
    ].join('|');
  }

  /// 池子是否已经对应当前最终采用的那份索引（来源 + 接口地址 + 目录时间戳）。
  ///
  /// 三条都对得上才复用。切走再切回栏目时，六个页面都在 `IndexedStack` 里
  /// 保活、会重新跑一遍校验；如果这里不看结论就 `restart`，120 张卡会被
  /// 整体重建 —— 海报要重新贴一遍，用户看到的就是「切回来又闪一下色块」。
  bool _poolMatchesCurrentSource() {
    final gate = widget.services.vodIndexGate;
    return _poolStamp.isNotEmpty &&
        gate.ready &&
        _poolOrigin == gate.activeOrigin &&
        _poolSourceUrl == gate.lastUrl &&
        _poolStamp == gate.directoryStamp;
  }

  /// 条件目录结论变化时刷新本页，并清掉「新目录里已经不存在」的选中值。
  ///
  /// 不清的话会出现「旧目录选了 `伦理片`，换接口后条件里没这个词了，
  /// 但筛选仍然生效、列表一直空」—— 就是需求里的「过期 / 不一致」。
  void _onFacetDirectoryChanged() {
    if (!mounted) return;
    final catalog = widget.services.vodFacetDirectory
        .catalogFor(_directoryScope(), widget.section);
    if (catalog != null &&
        catalog.usable &&
        catalog.revision != _facetAppliedRevision) {
      _facetAppliedRevision = catalog.revision;
      final f = catalog.facets;
      var cleared = false;
      if (_filter.type.isNotEmpty && !f.types.contains(_filter.type)) {
        _filter = _filter.copyWith(type: '');
        cleared = true;
      }
      if (_filter.area.isNotEmpty && !f.areas.contains(_filter.area)) {
        _filter = _filter.copyWith(area: '');
        cleared = true;
      }
      if (_filter.time.isNotEmpty && !f.times.contains(_filter.time)) {
        _filter = _filter.copyWith(time: '');
        cleared = true;
      }
      _facetResetNotice = cleared ? '目录已更新，原筛选条件中不存在的项已自动清除' : '';
    }
    setState(() {});
  }

  /// 触发一次条件目录加载。**异步、绝不阻塞 build**：期间列表与关键词检索
  /// 照常渲染，筛选区只显示 loading / empty / error 文案。
  Future<void> _syncFacetDirectory({bool force = false}) async {
    if (!mounted || !widget.active) return;
    final scope = _directoryScope();
    // 海报缓存跟着目录身份走；同一身份时 switchScope 直接返回，不会清缓存。
    widget.services.vodPosters.switchScope(scope);
    final dir = widget.services.vodFacetDirectory;
    final existing = dir.catalogFor(scope, widget.section);
    if (!force && existing != null && existing.phase != VodFacetPhase.idle) {
      return;
    }
    await dir.ensureLoaded(
      scope: scope,
      section: widget.section,
      force: force,
      loader: _loadDirectoryFacets,
    );
  }

  /// 生成目录模式下读「当前接口地址自己的」那份索引目录。
  ///
  /// 第二十一次修：索引按地址独立存放后，不能再读固定的 `vod-index.json`
  /// —— 那会是上一任接口留下的旧文件。地址取闸门最后一次校验用的
  /// `lastUrl`，与 `readGenerated` / `rebuild` 完全同源；默认地址对应的
  /// 随包索引不会走到这里（origin 是 builtin）。
  Future<VodIndexDocument?> _generatedIndexDoc() async {
    final cached = _generatedDoc;
    if (cached != null) return cached;
    final url = widget.services.vodIndexGate.lastUrl;
    final doc = await widget.services.vodIndexStore.loadFor(url);
    return _generatedDoc = doc;
  }

  /// 默认接口的本地增补条目（本栏目）。非默认来源 / 没有增补时返回空。
  ///
  /// 只给 builtin 分支用：生成目录本身已是全量（追加就写在那份文件里）。
  Future<List<VodItem>> _supplementItems() =>
      _supplementFuture ??= _readSupplementItems();

  Future<List<VodItem>> _readSupplementItems() async {
    final url = widget.services.vodIndexGate.lastUrl;
    if (url.isEmpty) return const <VodItem>[];
    _supplementDoc = await widget.services.vodIndexStore.loadSupplementFor(url);
    final doc = _supplementDoc;
    if (doc == null) return const <VodItem>[];
    return doc.inSection(widget.section);
  }

  /// 把增补条目并到一批浏览结果**前面**（它们就是各站最新一页）。
  ///
  /// 按片名去重：随包索引的 id 是 `builtin:…`，增补条目是网络 id，两套 id
  /// 撞不上，同一部新片会在首屏出现两张卡。只跟**这一批**比对，代价是
  /// 一屏条数量级，不会随目录增长。
  List<VodItem> _withSupplement(List<VodItem> batch, List<VodItem> extra) {
    if (extra.isEmpty) return batch;
    final seen = <String>{for (final it in batch) it.title.trim()};
    return <VodItem>[
      for (final it in extra)
        if (it.title.trim().isNotEmpty && seen.add(it.title.trim())) it,
      ...batch,
    ];
  }

  /// 从**整份目录**统计该栏目的全部可筛项，而不是已加载的那 120 条。
  ///
  /// 返回 null = 目录读取 / 解析失败（error）；返回空 [VodFacets] =
  /// 目录存在但没有可筛字段（empty）。两者 UI 上分开呈现。
  Future<VodFacets?> _loadDirectoryFacets() async {
    final gate = widget.services.vodIndexGate;
    if (!gate.ready || gate.activeOrigin == null) {
      // 尚未设定接口 / 校验未通过：这是「目录为空」而不是「加载异常」。
      return VodFacets.empty;
    }
    if (gate.activeOrigin == VodIndexOrigin.generated) {
      final doc = await _generatedIndexDoc();
      if (doc == null) return null;
      return facetOptionsFromItems(doc.inSection(widget.section));
    }
    final m = await widget.services.vodBuiltin.ensureManifest();
    if (m == null || m.isEmpty) return null;
    final body = await widget.services.vodBuiltin.body(widget.section.name);
    if (body == null || body.isEmpty) return null;
    final shardFacets = facetOptionsFromShard(body, m, widget.section.name);
    // 第二十三次修：默认接口的最新片源不在随包分片里，条件统计要把
    // 本地增补那几条也算上，否则「刚追加的片子筛不到」。
    final extra = await _supplementItems();
    if (extra.isEmpty) return shardFacets;
    return mergeVodFacets(shardFacets, facetOptionsFromItems(extra));
  }

  /// 取「本栏目整份目录有多少条」——「全部」tab 的统计口径。
  /// 只读目录元数据，不解压、不建对象：内置索引是 manifest 里分片的
  /// `records`，生成目录是文档里该栏目的条目数。目录没就绪时返回 0，
  /// UI 就不显示这个数（宁可不显示，也不拿已加载的 120 条冒充全量）。
  Future<int> _directorySectionTotal() async {
    final gate = widget.services.vodIndexGate;
    if (!gate.ready || gate.activeOrigin == null) return 0;
    if (gate.activeOrigin == VodIndexOrigin.generated) {
      final doc = await _generatedIndexDoc();
      return doc?.inSection(widget.section).length ?? 0;
    }
    final m = widget.services.vodBuiltin.manifest ??
        await widget.services.vodBuiltin.ensureManifest();
    final records = m?.shardFor(widget.section.name)?.records ?? 0;
    // 本地增补的条目也算进「本栏目共 N 条」（它们就在列表最前面）。
    final extra = await _supplementItems();
    return records + extra.length;
  }

  /// 重新取一次目录条数并刷新 UI（目录身份变化 / 手动刷新时调用）。
  Future<void> _reloadSectionTotal() async {
    final total = await _directorySectionTotal();
    if (!mounted || total == _sectionTotal) return;
    setState(() => _sectionTotal = total);
  }

  /// 手动重读：重新从索引目录统计检索条件，并把列表按当前来源重排一遍。
  ///
  /// 第二十次修起只由 [_facetStatus] 的非就绪态「重试」触发（常驻刷新按钮
  /// 按红标去除）。条件虽然会自动跟随目录身份变化，但目录**内容**变了而
  /// 身份没变时，仍需要一个可控的「现在就重新读」入口。全程不阻塞列表：
  /// 期间旧列表继续显示，只禁用按钮。
  Future<void> _manualRefresh() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _refreshNotice = '';
    });
    var failed = '';
    try {
      // 1) 条件：force 绕过缓存重新统计（error / empty 也一起救回来）。
      await _syncFacetDirectory(force: true);
      // 2) 统计数：同一份目录的条数，跟着重算。
      await _reloadSectionTotal();
      // 3) 列表：按当前唯一生效的来源重排首屏（旧池子在 restart 里清掉）。
      await _loadIndexPage(restart: true);
      // 3b) 目录级筛选结果也要作废重扫：目录内容可能换了，旧命中不能留着。
      _facetScanSeq++;
      _facetHitsKey = '\u0000';
      // 4) 海报：目录可能换了内容，缓存键跟着 scope 走，重新按可见条目取图。
      widget.services.vodPosters.switchScope(_directoryScope());
    } catch (e) {
      failed = '$e';
    }
    if (!mounted) return;
    setState(() {
      _refreshing = false;
      // 用户红标（第十八次修）：刷新成功**不播报**。「已按索引目录重新载入
      // 检索条件与列表」这种话对用户没有信息量，刷新后列表与条件自己会变。
      // 只有失败才留一行，因为失败时列表没变，不说明会像「点了没反应」。
      _refreshNotice = failed.isEmpty ? '' : '重试失败：$failed（列表保持原样，可再试）';
    });
  }

  /// 状态离开 ready 时把列表清空 —— 不允许旧索引的片源留在屏幕上。
  /// 同时让在途加载结果作废（[_poolSeq] 自增）。
  void _resetIndexPool() {
    _poolSeq++;
    // 来源变了，上一份索引的检索结果也不能留：否则用户没改关键词时
    // `_mergeIndexHits` 会把旧来源的命中拼进新列表。
    _indexHits = const <VodItem>[];
    _indexHitsQuery = '\u0000';
    _indexHitsTotal = 0;
    _indexSeq++;
    _indexPool = const <VodItem>[];
    _indexPage = 0;
    _indexLoading = false;
    _indexExhausted = false;
    _poolOrigin = null;
    _poolSourceUrl = '';
    _poolStamp = '';
    _generatedDoc = null;
    _supplementDoc = null;
    _supplementFuture = null;
  }

  /// 按当前唯一生效的索引来源，把一批片源灌进播放列表。
  ///
  /// builtin：走 [BuiltinIndexService.browse] 等距采样（只解本栏目分片，
  ///   命中才建对象，60 万条不会变成 60 万个 VodItem）；
  /// generated：从数据目录的索引目录文件按栏目顺序分页，条目自带播放地址，
  ///   批量 [VodLibrary.adoptMany] 挂进播放链路后点开即播。
  Future<void> _loadIndexPage({bool restart = false}) async {
    final gate = widget.services.vodIndexGate;
    final state = gate.state;
    if (!state.ready || state.origin == null) {
      _resetIndexPool();
      return;
    }
    // restart 是「来源/状态变了」的强制重来：即便上一批还在途也要重排，
    // 旧任务会因为 [_poolSeq] 变化被丢弃。只有普通续载才需要防并发。
    if (!restart && _indexLoading) return;
    if (restart) {
      _resetIndexPool();
      _addressPromptShown = false;
    }
    if (_indexExhausted) return;
    final seq = ++_poolSeq;
    final origin = state.origin!;
    _indexLoading = true;
    try {
      List<VodItem> batch;
      if (origin == VodIndexOrigin.builtin) {
        final hits = await widget.services.vodBuiltin.browse(
          widget.section.name,
          page: _indexPage,
          limit: _indexPageSize,
        );
        batch = widget.services.vodBuiltin.toItems(hits);
        if (_indexPage == 0) {
          // 默认接口的本地增补排在整份目录**最前面**：它们是各站最新一页，
          // 用户点「立即获取最新片源」之后最该看到的就是这批。
          final extra = await _supplementItems();
          if (extra.isNotEmpty) {
            // 增补条目自带剧集地址，但不在本进程的 VodLibrary 里，
            // 不挂进去就点不开（与生成目录同一套处理）。
            widget.services.vodLibrary.adoptMany(extra);
            batch = _withSupplement(batch, extra);
          }
        }
      } else {
        final doc = await _generatedIndexDoc();
        if (doc == null) {
          _indexExhausted = true;
          return;
        }
        final all = doc.inSection(widget.section);
        final start = _indexPage * _indexPageSize;
        if (start >= all.length) {
          _indexExhausted = true;
          return;
        }
        var end = start + _indexPageSize;
        if (end > all.length) end = all.length;
        batch = all.sublist(start, end);
        // 冷启动时这些条目不在 VodLibrary 的 _external 里，适配器也没注册：
        // 批量挂进去，startPlayback 才能按 sourceId + mediaId 找到播放地址。
        widget.services.vodLibrary.adoptMany(batch);
      }
      if (!mounted || seq != _poolSeq) return;
      if (batch.isEmpty) {
        _indexExhausted = true;
        // 目录里这个栏目真的没有内容：也要记下「已经对齐过这份目录」，
        // 否则每次 gate 广播都会再解压一次分片。
        _poolOrigin = origin;
        _poolSourceUrl = gate.lastUrl;
        _poolStamp = gate.directoryStamp;
        setState(() {});
        return;
      }
      _indexPool =
          List<VodItem>.unmodifiable(<VodItem>[..._indexPool, ...batch]);
      _poolOrigin = origin;
      // 池子记录的就是「最终采用的索引对应的接口地址」，与 gate.lastUrl
      // 比对即可判出「来源已变但列表还没重建」的窗口（见 _buildBrowse）。
      _poolSourceUrl = gate.lastUrl;
      _poolStamp = gate.directoryStamp;
      _indexPage++;
      setState(() {});
    } catch (_) {
      // 分片读不到 / 目录文件损坏：列表保持已有内容，不弹错打断浏览。
      if (mounted && seq == _poolSeq) _indexExhausted = true;
    } finally {
      _indexLoading = false;
    }
  }

  /// 校验不通过 ⇒ 进入片源接口输入流程。初次使用（未设定接口）必弹。
  Future<void> _maybePromptAddress({bool force = false}) async {
    if (_indexLoading) return;
    if (_addressPromptShown && !force) return;
    if (_addressPromptDismissed && !force) return;
    _addressPromptShown = true;
    final gate = widget.services.vodIndexGate;
    // 第二十六次修（用户红标）：输入框只预填**当前设定**的地址，
    // 没设过就留空 —— 初次使用不该由一个用户看不见的默认地址替他把
    // 输入框填好。
    final initial = gate.lastUrl.trim();
    final saved = await widget.services.vodSourceStore.load();
    if (!mounted) {
      _addressPromptShown = false;
      return;
    }
    final result = await showVodSourceInputDialog(
      context: context,
      reason: gate.state.reason,
      // 「当前接口」= 用户设定过的那条；没设过就是空。传 `selectedUrl`
      // 而不是 `effectiveUrl`：后者在未设定时会回落到随包默认地址，
      // 那正是用户要求不要再显示的东西。
      currentSourceUrl: saved.selectedUrl.trim(),
      initialUrl: initial,
      initialAllowInsecureHttp: saved.allowInsecureHttp,
      validate: (url, insecure) {
        if (url.trim().isEmpty) return '请填写片源接口地址';
        final check =
            validateVodSourceAddress(url, allowInsecureHttp: insecure);
        return check.ok ? null : check.reason;
      },
    );
    _addressPromptShown = false;
    if (!mounted) return;
    if (result == null) {
      // 用户取消：不再自动重复弹窗，但页面保留「设定片源接口」按钮。
      _addressPromptDismissed = true;
      setState(() {});
      return;
    }
    _addressPromptDismissed = false;
    final verdict = await gate.submit(result.url,
        allowInsecureHttp: result.allowInsecureHttp);
    if (!mounted) return;
    if (!verdict.ready) {
      // 第二十六次修：提交后仍未通过就**不再自动弹回输入页**。
      // 否则「提交 → 未通过 → needAddress → 再弹」会无限循环，
      // 用户看到的就是对话框反复闪、退不出去（红标「不能死循环」）。
      // 现在只留一句失败提示，用户要重试必须自己点「重试 / 改地址」。
      _addressPromptDismissed = true;
      _toast(verdict.note);
      setState(() {});
    }
  }

  void _onLibraryChanged() {
    if (!mounted) return;
    // 启动校验完成时补一次检索：用户在 boot 结束前就打了字，那一次
    // `svc.ready` 还是 false、直接返回了空结果，之后不会自动重试 ——
    // 表现就是「刚打开 App 搜什么都搜不到，退出去再进来就有了」。
    // 这里在收到状态通知时把当前关键词重跑一遍（结果相同则内部会命中缓存）。
    final boot = widget.services.vodBoot;
    if (boot.hasLocalIndex && _indexHits.isEmpty) {
      final q = _query.trim();
      if (q.isNotEmpty && q != _indexHitsQuery) {
        _indexTimer?.cancel();
        unawaited(_runIndexSearch(q, ++_indexSeq));
      }
    }
    // 启动校验 / 片库版本变化后补一次条件同步；内部按目录身份去重。
    unawaited(_syncFacetDirectory());
    setState(() {});
  }

  /// 输入变化 → debounce → 异步查内置索引分片。
  ///
  /// 180 ms 是「连打字的间隔」与「单字响应」的折中：分片解压后 6 MB 文本扫
  /// 一遍在真机上约 60–120 ms，每敲一个字都扫会让输入框明显粘手。
  void _scheduleIndexSearch(String raw) {
    _indexTimer?.cancel();
    final q = raw.trim();
    if (q.isEmpty) {
      if (_indexHits.isNotEmpty ||
          _indexHitsQuery.isNotEmpty ||
          _indexHitsTotal != 0) {
        setState(() {
          _indexHits = const <VodItem>[];
          _indexHitsQuery = '';
          _indexHitsTotal = 0;
        });
      }
      return;
    }
    final seq = ++_indexSeq;
    _indexTimer = Timer(const Duration(milliseconds: 180), () {
      unawaited(_runIndexSearch(q, seq));
    });
  }

  /// 扫描整份目录取「当前筛选条件」的全部命中（异步，绝不阻塞 build）。
  Future<void> _runFacetScan(String key, int seq) async {
    final gate = widget.services.vodIndexGate;
    if (!gate.ready || gate.activeOrigin == null) return;
    final f = _filter;
    if (gate.activeOrigin == VodIndexOrigin.generated) {
      final doc = await _generatedIndexDoc();
      if (!mounted || seq != _facetScanSeq) return;
      final section = doc?.inSection(widget.section) ?? const <VodItem>[];
      final all = applyVodFilter(section, f);
      setState(() {
        _facetHits = all.take(_indexHitLimit).toList();
        _facetHitsKey = key;
        _facetHitsTotal = all.length;
      });
      return;
    }
    final svc = widget.services.vodBuiltin;
    if (!svc.ready) return;
    BuiltinIndexSearchResult result;
    try {
      result = await svc.filterSection(
        widget.section.name,
        type: f.type,
        area: f.area,
        time: f.time,
        limit: _indexHitLimit,
      );
    } catch (_) {
      return;
    }
    if (!mounted || seq != _facetScanSeq) return;
    // 本地增补同样参与筛选（否则筛选一开，刚追的片子就消失了）。
    final extra = await _supplementItems();
    final extraHits =
        extra.isEmpty ? const <VodItem>[] : applyVodFilter(extra, f);
    if (!mounted || seq != _facetScanSeq) return;
    setState(() {
      _facetHits = _withSupplement(svc.toItems(result.hits), extraHits)
          .take(_indexHitLimit)
          .toList();
      _facetHitsKey = key;
      _facetHitsTotal = result.total + extraHits.length;
    });
  }

  /// 当前筛选条件对应的快照键（也是 [_facetHits] 的有效性判据）。
  String _facetKey() => '${_filter.type}|${_filter.area}|${_filter.time}';

  Future<void> _runIndexSearch(String q, int seq) async {
    // 第十六次修：采用「生成索引目录」时，关键词检索必须查**同一份目录**。
    // 落到内置索引分片就变成「列表来自 A、搜索结果来自 B」，来源唯一被破，
    // 而且两家的 vod_id 根本不通用，点开必然回源失败。
    if (widget.services.vodIndexGate.activeOrigin == VodIndexOrigin.generated) {
      final doc = await _generatedIndexDoc();
      if (!mounted || seq != _indexSeq) return;
      final section = doc?.inSection(widget.section) ?? const <VodItem>[];
      final all = filterVodItems(section, q);
      setState(() {
        _indexHits = all.take(_indexHitLimit).toList();
        _indexHitsQuery = q;
        // 生成目录整份就在内存里，命中总数 = 过滤结果长度。
        _indexHitsTotal = all.length;
      });
      return;
    }
    final svc = widget.services.vodBuiltin;
    // 内置索引没就绪（缺失 / 还在校验）时什么都不查 —— 直接返回空，
    // 页面表现就是「只有本地记录能搜到」，不会卡在转圈。
    if (!svc.ready) return;
    BuiltinIndexSearchResult result;
    try {
      result = await svc.searchDetailed(widget.section.name, q,
          limit: _indexHitLimit);
    } catch (_) {
      return;
    }
    if (!mounted || seq != _indexSeq) return; // 有更新的输入了，丢弃这次结果
    // 本地增补也要能搜到（它们不在随包分片里）。
    final extra = await _supplementItems();
    final extraHits =
        extra.isEmpty ? const <VodItem>[] : filterVodItems(extra, q);
    if (!mounted || seq != _indexSeq) return;
    setState(() {
      _indexHits = _withSupplement(svc.toItems(result.hits), extraHits)
          .take(_indexHitLimit)
          .toList();
      _indexHitsQuery = q;
      _indexHitsTotal = result.total + extraHits.length;
    });
  }

  /// 默认加载源 / 本地记录同步（1.0.5 第十一次修）。
  ///
  /// **首屏不再等网络，也不再需要点「加载更多」**：`main()` 启动时已经把
  /// `vod-library.json` 整份读回 [VodLibrary]，栏目里就是完整本地目录。
  /// 这里只负责在后台把接口剩余分页一次跑完、逐批落盘，用户看到的是
  /// 「打开就有完整列表，后台自己悄悄补新的」。
  ///
  /// 两条路径：
  ///  * 默认源 + 开关开：[_revalidateInBackground] 全量同步（不阻塞、不清空）；
  ///  * 非默认源 / 开关关：沿用 [VodAutoSource] 的单飞自动导入，同样不阻塞首屏。
  Future<void> _ensureDefaultSource() async {
    if (_autoRequested) return;
    _autoRequested = true;
    final settings = await widget.services.vodSourceStore.load();
    if (!mounted) return;
    final isDefault =
        settings.effectiveUrl == widget.services.vodAutoSource.defaultUrl;

    // ── 先等启动校验出结论，再决定要不要联网 ────────────────────────
    //
    // 踩过的坑（1.0.5 第十五次修）：`vodBoot.boot()` 是在**首帧之后**的
    // postFrame 回调里才触发的，而这个函数在 initState 阶段就跑起来了。
    // 直接读 `hasLocalIndex` 会读到 false（phase 还是 idle / checking），
    // 于是「内置索引已就绪」的情况下照样把 147 万条的全量同步拉起来 ——
    // 界面同时显示「已加载内置索引 60.5 万条」和「目录同步中」，
    // 用户自然要问「为什么还在同步」。
    //
    // `settled` 在 boot 尚未开始时立刻返回（不会挂住），boot 已在跑则等到
    // 出结论为止（本地读 manifest + 6 个分片头，几十毫秒）。
    final boot = widget.services.vodBoot;
    await boot.settled;
    if (!mounted) return;

    // ── 第十六次修：后台全量同步彻底让位给索引目录 ──────────────────
    // 播放列表现在由 vodIndexGate 判定的**唯一一份索引**提供，旧链路（11 次修）
    // 的 1 万条上限永远追不上接口 147 万条，且每批重写 16 MB JSON。
    // ready ⇒ 直接用索引，不同步；needAddress/building/failed ⇒ 由输入流程
    // 接管，更不能由旧链路在背后偷偷联网。只有 gate 异常停在 checking 时
    // 才保留下面这段作为兜底，保证旧代码仍然可达。
    await widget.services.vodIndexGate.settled;
    if (!mounted) return;
    final gate = widget.services.vodIndexGate;
    if (gate.ready ||
        gate.phase == VodIndexGatePhase.needAddress ||
        gate.phase == VodIndexGatePhase.building ||
        gate.phase == VodIndexGatePhase.failed) {
      return;
    }

    if (settings.enabled && isDefault) {
      // 内置索引够用 ⇒ 后台全量同步**不启动**。
      //
      // 这不是「省一次请求」，是那条同步在结构上永远追不上接口：
      // 单次同步有 `kVodCacheMaxItems`（1 万条）硬上限，而接口统计 147 万条
      // ⇒ 覆盖率 0.68%，跑满 240 批 / 5 分钟也只能拿到上限那一万条，
      // 且每批都重写 16 MB 的 vod-library.json。转圈永远不会停。
      if (boot.hasLocalIndex) return;
      unawaited(_revalidateInBackground(settings.effectiveUrl,
          settings.allowInsecureHttp, settings.allowExternalCode));
      return;
    }
    final task = widget.services.vodAutoSource.ensureLoaded(
      enabled: settings.enabled,
      selectedUrl: settings.effectiveUrl,
      allowInsecureHttp: settings.allowInsecureHttp,
      allowExternalCode: settings.allowExternalCode,
      alreadyHasItems: widget.services.vodLibrary.externalCount > 0,
    );
    if (task == null) return;
    unawaited(_trackImport(task));
  }

  /// 自动导入只更新错误提示，不再把整页钉在 loading 上。
  Future<void> _trackImport(Future<VodImportReport?> task) async {
    final report = await task;
    if (!mounted) return;
    setState(
        () => _autoError = report == null || report.ok ? null : report.message);
  }

  /// 后台把接口目录**一次补齐**：不再只翻 1 批，也不要求用户点「加载更多」。
  ///
  /// [kVodFullSyncMaxBatches] / [kVodFullSyncBudget] 是慢站与内存天花板兜底；
  /// `preserveExisting: true` 保证后台刷新不会先把用户眼前几百张卡片清空。
  Future<void> _revalidateInBackground(
      String url, bool allowInsecureHttp, bool allowExternalCode) async {
    try {
      final boot = widget.services.vodBoot;
      // 第二道闸：调用方（[_ensureDefaultSource]）已经判过一次，这里再判一次
      // 是给「boot 在本函数让出执行权之后才出结论」留的安全网 —— 少一次请求
      // 与多转一圈相比，前者明显更划算。
      await boot.settled;
      if (!mounted || boot.hasLocalIndex) return;
      final s = widget.services.vodSession;
      await s.start(
        url: url,
        allowInsecureHttp: allowInsecureHttp,
        allowExternalCode: allowExternalCode,
        autoBatches: kVodFullSyncMaxBatches,
        budget: kVodFullSyncBudget,
        preserveExisting: true,
      );
      // 会话已由设置页导入过的话 start() 会直接复用，这里继续把剩余页翻完。
      final deadline = DateTime.now().add(kVodFullSyncBudget);
      var batches = 0;
      while (mounted &&
          s.active &&
          !s.done &&
          !s.busy &&
          !boot.hasLocalIndex &&
          batches < kVodFullSyncMaxBatches &&
          DateTime.now().isBefore(deadline)) {
        await s.loadMore();
        batches++;
      }
    } catch (_) {
      // 后台核对失败不该弹错：本地记录仍然完整可用。
    }
  }

  @override
  void didUpdateWidget(covariant VodPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 第二十次修（用户红标）：左侧栏目切换后，搜索框要清空恢复初始态。
    // 六个栏目页在 IndexedStack 里保活，不主动清的话切回「电视剧」还留着
    // 上次在「电影」里输的词，列表却是新栏目的 —— 看着像筛选没生效。
    if (widget.active != oldWidget.active) _resetSearchOnSectionSwitch();
    if (widget.active && !oldWidget.active) {
      _bindQueue();
      unawaited(_ensureDefaultSource());
      // 重新进入栏目要重新校验：期间用户可能换过接口或生成了新索引目录。
      unawaited(_enterIndexGate());
      unawaited(_syncFacetDirectory());
    } else if (!widget.active && oldWidget.active) {
      _unbindQueue();
      // 切走栏目必须**彻底退出播放态**：只暂停不移出播放视图的旧行为会让
      // 直播页/点播页共用同一个内核实例时画面串台 —— 三个栏目页在
      // IndexedStack 里都保活，哪一个停在 playing，它的渲染面就一直在树上。
      // 用户看到的就是「从直播切到电视剧，直播画面在电视剧里继续放」。
      if (_view == _VodView.playing) {
        // 注意：这里**不能**走 setState —— didUpdateWidget 发生在父级 build 期间，
        // 在 build 里 markNeedsBuild 会触发「setState() called during build」。
        // 但 didUpdateWidget 之后本组件必然重建一次，直接改字段就够了。
        _leavePlaying(rebuild: false);
      }
    }
  }

  /// 栏目切换时把检索态复位：输入框、关键词、全目录命中、在途检索一起作废。
  ///
  /// 这里**不能** setState —— `didUpdateWidget` 发生在父级 build 期间；
  /// TextEditingController 自身是 Listenable，改 text 会通知输入框重建，
  /// 其余字段在紧接着的本组件 build 里生效。
  void _resetSearchOnSectionSwitch() {
    _indexTimer?.cancel();
    _indexTimer = null;
    // 作废在途扫描：晚到的旧栏目命中不能拼进新栏目列表。
    _indexSeq++;
    if (_search.text.isEmpty &&
        _query.isEmpty &&
        _indexHits.isEmpty &&
        _indexHitsTotal == 0) {
      return;
    }
    _search.text = '';
    _query = '';
    _indexHits = const <VodItem>[];
    _indexHitsQuery = '\u0000';
    _indexHitsTotal = 0;
    _filterQuery = '\u0000';
  }

  /// 退出播放态（停播 + 回到列表）。
  ///
  /// [rebuild] 为 false 时只改字段不 setState（在 `didUpdateWidget` 里调用）。
  void _leavePlaying({bool rebuild = true}) {
    _ticker?.cancel();
    _ticker = null;
    _hideTimer?.cancel();
    _detailTimer?.cancel();
    _detailTimer = null;
    // 作废在途回源：回包晚到会在列表页上把 `_item` 又写回来，
    // 更糟的是它接着会调 `_resumeOrPlay` —— 列表上莫名其妙开始放片。
    _resolveSeq++;
    _resolving = false;
    _resolveError = null;
    widget.services.queue.detach();
    unawaited(_pauseForLeave());
    // 第二十二次修：详情页已删除，播放页的上一级就是列表。
    _view = _VodView.browse;
    _item = null;
    _detailExpanded = true;
    _session = null;
    _paused = false;
    _showEpisodes = false;
    _awaitingPicture = false;
    _awaitingTicks = 0;
    _position.value = 0;
    _duration.value = 0;
    if (rebuild && mounted) setState(() {});
  }

  @override
  void dispose() {
    // 作废在途回源：页面没了还回包，setState 会打到已 dispose 的 State 上。
    _resolveSeq++;
    widget.services.vodLibrary.removeListener(_onLibraryChanged);
    widget.services.vodSession.removeListener(_onLibraryChanged);
    widget.services.vodBoot.removeListener(_onLibraryChanged);
    widget.services.vodIndexGate.removeListener(_onIndexGateChanged);
    widget.services.vodFacetDirectory.removeListener(_onFacetDirectoryChanged);
    _indexTimer?.cancel();
    _unbindQueue();
    _ticker?.cancel();
    _hideTimer?.cancel();
    _detailTimer?.cancel();
    _position.dispose();
    _duration.dispose();
    _buffered.dispose();
    _resolution.dispose();
    _volumeN.dispose();
    _search.dispose();
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
    _hideTimer?.cancel();
    try {
      await widget.services.player.pause();
    } catch (_) {
      // 离开页面时暂停失败不影响切栏目。
    }
    // 关键：把内核缓冲档切回直播档。点播档是大缓存（30 秒），
    // 留着它去切台会白白多等几秒才出画面。
    await _applyLiveProfile();
    _paused = true;
  }

  /// 让内核切到点播档（大缓存 + 断线重连）。内核不支持时静默跳过。
  Future<void> _applyVodProfile() async {
    // 声明成 Object 才能被 `is PlaybackTuner` 提升：Dart 的类型提升要求
    // 目标类型是当前类型的子类型，而 PlaybackTuner 与 PlayerController 是两个
    // 互不相交的接口（内核「能播」不代表「能调缓冲档」）。
    final Object player = widget.services.player;
    if (player is PlaybackTuner) {
      try {
        await player.applyVodProfile();
      } catch (_) {}
    }
  }

  Future<void> _applyLiveProfile() async {
    final Object player = widget.services.player;
    if (player is PlaybackTuner) {
      try {
        await player.applyLiveProfile();
      } catch (_) {}
    }
  }

  // ── 播放 ────────────────────────────────────────────────

  Future<void> _play(VodItem item, VodEpisode episode,
      {double seconds = 0}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // 起播前先确保直播停干净：直播与点播共用同一个内核实例，
      // 直播若还在 tune/看门狗里，会在点播 load 之后又把上游地址打回来，
      // 表现就是「点了部电影，放出来的是电视台」。
      //
      // 1.0.5 第八次修：**加超时**。`LiveController.stop()` 的同步部分
      // （`_epoch++` / 看门狗 / `_phase=idle`）在第一个 await 之前就跑完了，
      // 后面那句 `_gate.run(_safePause)` 只是暂停内核，而它会**排在正在进行的
      // tune 之后**（AsyncSerialGate 是严格串行的）。弱源一次 tune 实测能占
      // 8–12 秒，于是「从直播切过来点播放」会先干等十几秒才轮到 load ——
      // 这是「进入具体视频加载很慢」里唯一一处**纯等待**。
      //
      // 超时后继续是安全的：串台的三层修复（attachSurface + 渲染面摘除 +
      // 起播前 stop）里，真正决定画面的不是 pause 是否完成，而是
      // 点播的 load 会立刻覆盖内核状态、以及失活页不建渲染面。所以这里
      // 宁可少等，也不要为了一个 pause 把起播拖长十几秒。
      try {
        await widget.services.live
            .stop()
            .timeout(const Duration(milliseconds: 900));
      } catch (_) {}
      // 缓冲档要在 load 之前切：mpv 的 cache-secs 对**当前**打开的流生效，
      // load 之后再设只影响下一条。
      await _applyVodProfile();
      final s = await widget.services.orchestrator.startPlayback(
        // 内置条目恒为 VodCatalog.sourceId；第三方条目带自己的源 id，
        // 由 VodLibrary 注册对应适配器，播放链路完全复用。
        sourceId: item.sourceId.isEmpty ? VodCatalog.sourceId : item.sourceId,
        mediaId: item.id,
        mediaTitle: item.title,
        canonicalEpisode: episode.number,
        canonicalSeconds: seconds,
      );
      // 剧集表交给播放列表层：看完一集才能自动进下一集。
      widget.services.queue.setEpisodes(
        item.episodes
            .map((e) => EpisodeInfo(episode: e.number, title: e.title)),
      );
      widget.services.queue.attach(s);
      if (!mounted) return;
      setState(() {
        _session = s;
        _paused = false;
        _busy = false;
        _showEpisodes = false;
        _view = _VodView.playing;
        // load 只是「命令发出去了」，出画还要等首帧（见 _awaitingPicture）。
        _awaitingPicture = true;
        _awaitingTicks = 0;
      });
      _startTicker();
      _pokeControls();
      // 起播这一刻画面才有内容，右栏的 8 秒从「真的开始放」重新算；
      // 已经收起的不主动弹出（换集时突然弹一层详情很烦）。
      _touchDetailPanel();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // 播放页没有详情页可退：失败原因写进右栏（并强制展开），
        // 不再额外弹 SnackBar —— 同一件事说两遍，用户还得看两处。
        _resolveError = '播放失败：$e';
      });
      _pokeDetail(VodDetailInput.pointerOnPanel);
    }
  }

  /// 续播入口：有记录就从记录点继续；已看完的直接进下一集。
  Future<void> _resumeOrPlay(VodItem item) async {
    // 回源还没回来 / 回来是空的时剧集表为空，`first` 会直接抛 StateError。
    // 播放页没有详情页可以退回，只能用错误条把原因说清楚 + 给重试。
    if (item.episodes.isEmpty) {
      if (mounted) {
        setState(() => _resolveError = '这个片源没有可播放的剧集，换一部或重新获取片源');
      }
      return;
    }
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
    // 立刻读一次：首帧就在 0 秒，用户不该先看到 1 秒的 --:--。
    unawaited(_tick());
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  Future<void> _tick() async {
    final p = widget.services.player;
    try {
      final pos = await p.currentRawSeconds();
      final dur = await p.duration();
      if (!mounted) return;
      _position.value = pos;
      _duration.value = dur;
    } catch (_) {
      // 读数失败就跳过这一拍，不打断播放。
    }
    // 缓冲位置与实测分辨率同属「内核能力探测」，拿不到就是 0 / 空串。
    final Object probe = p;
    _buffered.value = probe is BufferProbe ? probe.bufferedSeconds : 0;
    if (probe is PictureProbe && probe.hasPicture) {
      final label = vodResolutionLabel(probe.pictureWidth, probe.pictureHeight);
      if (label.isNotEmpty) _resolution.value = label;
    }
    // 首帧遮罩：每秒看一次有没有画，出画就撤；源端一直不给画面时按兜底撤。
    //
    // 用 `PictureProbe.hasPicture` 而不是「位置是否前进」：点播起播阶段
    // `time-pos` 也可能停在 0（mpv 要等时间轴稳定才推进），拿它判断会把
    // 「正在出画」误判成「还没开始」。`hasPicture` 是「已经拿到视频参数」，
    // 与首帧同源，直播侧早就靠它判起播（见 PictureProbe 的注释）。
    if (_awaitingPicture && mounted) {
      _awaitingTicks++;
      final Object probe = p;
      final ready = probe is PictureProbe && probe.hasPicture;
      if (ready || _awaitingTicks >= _awaitingMaxTicks) {
        setState(() => _awaitingPicture = false);
      }
    }
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
    _pokeControls();
  }

  Future<void> _seekBy(double delta) async {
    final p = widget.services.player;
    try {
      final pos = await p.currentRawSeconds();
      final target = vodSeekTarget(pos, _duration.value, delta);
      await p.seek(target);
      _position.value = target;
    } catch (_) {}
    _pokeControls();
  }

  Future<void> _seekTo(double target) async {
    try {
      await widget.services.player.seek(target);
      _position.value = target;
    } catch (_) {}
  }

  /// 音量滑块 / 静音键。
  Future<void> _setVolume(double volume) async {
    final v = volume.clamp(0.0, 100.0);
    try {
      await widget.services.player.setVolume(v);
      if (mounted) _volumeN.value = v;
    } catch (_) {}
  }

  /// 静音 / 取消静音：记住静音前的音量，取消时回到那个值而不是硬跳 100。
  ///
  /// 硬跳 100 是很多播放器的通病：半夜把音量调到 15% 静音，再取消静音直接
  /// 炸出一声 100%。这里存一份 `_volumeBeforeMute`。
  double _volumeBeforeMute = 100;

  void _toggleMute() {
    if (_volumeN.value > 0.5) {
      _volumeBeforeMute = _volumeN.value;
      unawaited(_setVolume(0));
    } else {
      unawaited(_setVolume(_volumeBeforeMute <= 0.5 ? 100 : _volumeBeforeMute));
    }
    _pokeControls();
  }

  /// 倍速切换。内核不支持变速时**不改 UI**：
  /// 改了标签却没生效，用户会以为「1.5 倍速听起来和原来一样」是 bug。
  Future<void> _setRate(double rate) async {
    final Object p = widget.services.player;
    if (p is! PlaybackRateControl) return;
    try {
      await p.setRate(rate);
      if (mounted) setState(() => _rate = p.rate);
    } catch (_) {}
    _pokeControls();
  }

  /// 清晰度面板的选项。
  ///
  /// **只有「自动」一项**，而且这不是偷懒：抓一份真实的采集接口看，
  /// `vod_play_from` 是 `dytt$$$dyttm3u8` 这种**线路名**，`vod_play_url` 里
  /// 每集只有一个地址 —— 根本没有「720P / 1080P」的档位存在。摆一排
  /// 点了永远不生效的「1080P/720P」就是假按钮（与 §55 拒绝做「资费/奖项」筛选行同理）。
  ///
  /// 所以面板如实给出两件事：唯一可选的「自动」，以及内核实测解码分辨率
  /// （作为 `detail` 显示）—— 后者是真实信息，用户能据此判断源站给的到底是什么画质。
  List<PlayerQualityOption> _qualityOptions() {
    final res = _resolution.value;
    return <PlayerQualityOption>[
      PlayerQualityOption(
        id: 'auto',
        label: '自动',
        detail: res.isEmpty ? '跟随源' : '实测 $res',
      ),
    ];
  }

  static const String _qualityNote = '采集源每条线路只提供一档清晰度（接口里没有画质档位），'
      '所以这里无法切换 —— 徽标显示的是内核实测解码分辨率。';

  /// 上一集 / 下一集。集号可能跳号，用 [vodAdjacentEpisode] 在有序集号表里取相邻项。
  Future<void> _playAdjacent(int direction) async {
    final item = _item;
    final session = _session;
    if (item == null || _busy) return;
    final numbers = item.episodes.map((e) => e.number).toList(growable: false)
      ..sort();
    final current = session?.contentEpisode ?? numbers.first;
    final target = vodAdjacentEpisode(numbers, current, direction);
    if (target == null) {
      _toast(direction > 0 ? '已经是最后一集了' : '已经是第一集了');
      return;
    }
    final episode = item.episodes.firstWhere(
      (e) => e.number == target,
      orElse: () => item.episodes.first,
    );
    await _play(item, episode);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  /// 点卡片 → **直接进播放页**（1.0.5 第二十二次修）。
  ///
  /// **触发条件只有一条**：用户在列表里点击 / 遥控器确认某张卡片
  /// （`_VodCard.onTap`）。没有「先看详情再点播放」这一步 —— 影片介绍
  /// 随播放页右栏一起出来，用户不必为一个「确认」多按一次键。
  ///
  /// 两条路径：
  /// * 内置索引命中（只有片名 + `vod_id`，没有剧集表）→ 立刻切到播放视图
  ///   显示「正在获取播放地址…」，后台回源，回来的那一刻直接起播；
  /// * 已有完整条目（网络同步来的自带剧集表）→ 取一次续播记录后直接起播。
  ///
  /// 回源失败**不退回列表**：停在播放页给一条原因 + 「重试」，
  /// 退回去等于让用户重新找这部片。
  Future<void> _openAndPlay(VodItem item) async {
    if (_busy || _resolving) return;
    final seq = ++_resolveSeq;
    setState(() {
      _item = item;
      _resume = null;
      _session = null;
      _view = _VodView.playing;
      _showEpisodes = false;
      _resolveError = null;
      _awaitingPicture = true;
      _awaitingTicks = 0;
    });
    _enterDetailPanel();

    if (!isBuiltinHitId(item.id)) {
      ResumeRecord? rec;
      try {
        rec = await widget.services.orchestrator.resumeFor(item.id);
      } catch (_) {
        rec = null;
      }
      if (!mounted || seq != _resolveSeq) return;
      _resume = rec;
      await _resumeOrPlay(item);
      return;
    }

    // 第二十四次修：`hitById` 查的是「本次会话由命中转出来的条目」表，
    // 它有容量上限（[BuiltinIndexService.kHitIndexCap]）、到顶会清，
    // 也不跨重启 —— 而屏幕上的卡片还在。查不到就按 id 结构
    // （`builtin:站点下标:vod_id`）重建一条命中：回源只需要这两个字段，
    // 所以「表里没有」不等于「这条记录失效」。
    final hit = await widget.services.vodBuiltin.hitByIdOrRebuild(
      item.id,
      name: item.title,
      section: widget.section.name,
      year: item.year,
    );
    if (!mounted || seq != _resolveSeq) return;
    if (hit == null) {
      // id 都解析不出站点下标 / 下标已越界：这份索引确实对不上了。
      _leavePlaying();
      _toast('这条索引记录已失效，请重新检索');
      return;
    }
    setState(() => _resolving = true);
    await _playResolved(hit, seq);
  }

  /// 回源 → 取续播 → 起播。`_openAndPlay` 与「重试」共用这一段。
  Future<void> _playResolved(BuiltinIndexHit hit, int seq) async {
    VodItem? resolved;
    try {
      resolved = await widget.services.vodBuiltin.resolve(hit);
    } catch (_) {
      resolved = null;
    }
    if (!mounted || seq != _resolveSeq) return;
    if (resolved == null || resolved.episodes.isEmpty) {
      setState(() {
        _resolving = false;
        _resolveError = '暂时取不到播放地址，可能是片源接口超时';
      });
      // 失败必须让右栏露出来：原因和「重试」都在里面，收着等于没说。
      _pokeDetail(VodDetailInput.pointerOnPanel);
      return;
    }
    ResumeRecord? rec;
    try {
      rec = await widget.services.orchestrator.resumeFor(resolved.id);
    } catch (_) {
      rec = null;
    }
    if (!mounted || seq != _resolveSeq) return;
    setState(() {
      _item = resolved;
      _resume = rec;
      _resolving = false;
      _resolveError = null;
    });
    // 状态变了（从「正在获取」变成「有剧集了」），8 秒重新算。
    _pokeDetail(VodDetailInput.pointerOnPanel);
    await _resumeOrPlay(resolved);
  }

  /// 播放页错误条上的「重试」：只重跑回源，不退回列表。
  Future<void> _retryOpen() async {
    final item = _item;
    if (item == null || _resolving) return;
    // 与 [_openAndPlay] 同一条反查口径（见那里的第二十四次修说明）。
    final hit = await widget.services.vodBuiltin.hitByIdOrRebuild(
      item.id,
      name: item.title,
      section: widget.section.name,
      year: item.year,
    );
    if (!mounted || !identical(_item, item)) return;
    if (hit == null) {
      _toast('这条索引记录已失效，请返回重新检索');
      return;
    }
    final seq = ++_resolveSeq;
    setState(() {
      _resolving = true;
      _resolveError = null;
    });
    await _playResolved(hit, seq);
  }

  void _back() {
    if (_showEpisodes) {
      setState(() => _showEpisodes = false);
      return;
    }
    // 全屏时「返回」先退全屏，而不是直接退出播放 —— 与主流播放器一致，
    // 也与 `AppShell` 的 `canPop: !_fullscreen` 语义对齐（否则外壳先吃掉这次返回）。
    if (widget.fullscreen) {
      widget.onToggleFullscreen();
      return;
    }
    // 第二十二次修：详情页没了，播放页的上一级**直接是列表**。
    if (_view == _VodView.playing) {
      // 必须停播：否则列表回来了，声音还在响，用户只能退出 App。
      _leavePlaying();
      return;
    }
  }

  // ── 控制条 ──────────────────────────────────────────────

  void _pokeControls() {
    _hideTimer?.cancel();
    if (!_controlsVisible && mounted) {
      setState(() => _controlsVisible = true);
    }
    // 鼠标移动、按音量键、切集都算「用户还在操作」：右栏的 8 秒跟着刷新，
    // 但不改变展开状态（收起态不会因为动一下鼠标就弹出来）。
    // 注意：悬停在右栏上时**不设计时**（[VodDetailInput.pointerOnPanel] 已经
    // 取消了它），所以这里必须走 [_touchDetailPanel] 而不是直接排计时。
    _touchDetailPanel();
    if (_showEpisodes) return;
    _hideTimer = Timer(kVodControlsIdleTimeout, () {
      if (!mounted) return;
      // 拖进度条 / 展开内联面板时不许自动收起：用户正在操作，一淡出就得重来。
      if (_scrubbing || _panelOpen) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    _hideTimer?.cancel();
    if (_controlsVisible) {
      setState(() => _controlsVisible = false);
    } else {
      _pokeControls();
    }
    // 点画面也是交互：右栏若还开着，8 秒从这一下重新算（不改变展开状态）。
    _pokeDetail(VodDetailInput.pointerElsewhere);
  }

  /// 遥控器 / 键盘。返回 [KeyEventResult.handled] 表示已经消费掉，
  /// 未识别的键交回框架（否则方向键在选集浮层里就移不动焦点了）。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final name = event.logicalKey.debugName ?? event.logicalKey.keyLabel;
    // 第二十二次修：右栏详情的键盘入口。
    //
    // 遥控器没有鼠标，不给一个键位就等于「收起之后再也要不回来」。
    // 用 I（Info）/ D（Detail）两个字母 + 遥控器信息键：`debugName` 在
    // 桌面是「Key I」、在 web 是「KeyI」，所以四种写法都收。
    final rawKey = name.toLowerCase().replaceAll(' ', '').replaceAll('_', '');
    if (rawKey == 'i' ||
        rawKey == 'd' ||
        rawKey == 'keyi' ||
        rawKey == 'keyd' ||
        rawKey == 'info' ||
        rawKey == 'guide') {
      _toggleDetail();
      return KeyEventResult.handled;
    }
    final action = vodActionFor(name);

    // 「确认键」必须先让给内部控件：用户把焦点移到「下一集」按钮上再按 OK，
    // 期望的是切下一集，不是暂停。只有焦点在本页（舞台）自己身上时才当成播放控制。
    if (action == VodControlAction.togglePlay && !node.hasPrimaryFocus) {
      return KeyEventResult.ignored;
    }

    // 选集浮层打开时，方向键留给焦点遍历，只接「关闭 / 选集开关」。
    if (_showEpisodes &&
        action != VodControlAction.close &&
        action != VodControlAction.toggleEpisodes) {
      return KeyEventResult.ignored;
    }
    switch (action) {
      case VodControlAction.togglePlay:
        unawaited(_togglePause());
        return KeyEventResult.handled;
      case VodControlAction.forward:
        unawaited(_seekBy(kVodSeekStepSeconds));
        return KeyEventResult.handled;
      case VodControlAction.backward:
        unawaited(_seekBy(-kVodSeekStepSeconds));
        return KeyEventResult.handled;
      case VodControlAction.nextEpisode:
        unawaited(_playAdjacent(1));
        return KeyEventResult.handled;
      case VodControlAction.previousEpisode:
        unawaited(_playAdjacent(-1));
        return KeyEventResult.handled;
      case VodControlAction.volumeUp:
        unawaited(_setVolume(_volumeN.value + kVodVolumeStep));
        _pokeControls();
        return KeyEventResult.handled;
      case VodControlAction.volumeDown:
        unawaited(_setVolume(_volumeN.value - kVodVolumeStep));
        _pokeControls();
        return KeyEventResult.handled;
      case VodControlAction.toggleEpisodes:
        setState(() => _showEpisodes = !_showEpisodes);
        _pokeControls();
        return KeyEventResult.handled;
      case VodControlAction.toggleFullscreen:
        widget.onToggleFullscreen();
        _pokeControls();
        return KeyEventResult.handled;
      case VodControlAction.close:
        _back();
        return KeyEventResult.handled;
      case VodControlAction.none:
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 点播页是页内切换，没有路由可弹：必须自己接管返回键，
    // 否则在播放页按返回会直接退出 App（电视上尤其致命）。
    return PopScope(
      canPop: _view == _VodView.browse,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _back();
      },
      child: switch (_view) {
        _VodView.browse => _buildBrowse(),
        _VodView.playing => _buildPlaying(),
      },
    );
  }

  // ── 浏览 ────────────────────────────────────────────────

  Widget _buildBrowse() {
    // 1.0.5 第十六次修：**播放列表 = 最终采用的索引目录**，来源唯一。
    // 不再读 VodLibrary.inSection —— 那是另一条链路上的外部目录缓存，
    // 把它和索引片源拼在一起等于同时采用两个来源（需求明确禁止）。
    // gate 未 ready 时池子为空，页面会显示对应的状态与「设定接口」入口。
    final gate = widget.services.vodIndexGate;
    // **来源唯一守卫**：状态机采用的索引与池子记录的不一致时（用户刚换了
    // 接口、新列表还在加载），宁可显示空态，也不把上一份索引的片源混进来。
    // 判据是「来源枚举 + 记录的接口地址」两条都对得上，缺一条就当没有列表。
    final sameSource = gate.ready &&
        _poolOrigin == gate.activeOrigin &&
        _poolSourceUrl == gate.lastUrl;
    final all = sameSource ? _indexPool : const <VodItem>[];
    // 第十七次修：筛选条件**不再**从「当前已加载的那 120 条」统计，
    // 改为按目录身份异步加载整份目录的全部可筛项。目录没就绪 / 读失败时
    // 这里只给出空条件 + 状态文案，列表与关键词检索完全不受影响。
    final scope = _directoryScope();
    final catalog =
        widget.services.vodFacetDirectory.catalogFor(scope, widget.section);
    final facets =
        catalog != null && catalog.usable ? catalog.facets : VodFacets.empty;
    if (widget.active && catalog == null && !_facetSyncScheduled) {
      _facetSyncScheduled = true;
      scheduleMicrotask(() async {
        _facetSyncScheduled = false;
        await _syncFacetDirectory();
      });
    }
    // 筛选条件变了 ⇒ 按整份目录重扫一次（microtask，不在 build 里做 IO）。
    final facetKey = _facetKey();
    if (widget.active && !_facetScanScheduled) {
      final needScan = _filter.isActive && _facetHitsKey != facetKey;
      final needClear = !_filter.isActive && _facetHits.isNotEmpty;
      if (needScan || needClear) {
        _facetScanScheduled = true;
        scheduleMicrotask(() {
          _facetScanScheduled = false;
          if (!mounted) return;
          if (!_filter.isActive) {
            _facetScanSeq++;
            setState(() {
              _facetHits = const <VodItem>[];
              _facetHitsKey = '\u0000';
              _facetHitsTotal = 0;
            });
            return;
          }
          unawaited(_runFacetScan(facetKey, ++_facetScanSeq));
        });
      }
    }
    final items = _filteredFor(all);
    return NotificationListener<ScrollNotification>(
      // 1.0.5 第四项：**「加载更多」按钮已彻底移除**，这里只剩「滚到底顺手接
      // 一批」这一个兜底动作 —— 主路径是后台按 [kVodFullSyncMaxBatches] 全量补齐。
      // 留 800 px 提前量：电视端遥控器一路按「下」到快见底时就把下一批发出去，
      // 卡片接上时用户还没看到空白，不会出现「划到底停住等转圈」的断点。
      onNotification: (n) {
        if (n.metrics.axis != Axis.vertical) return false;
        if (n.metrics.extentAfter < 800) unawaited(_loadMore());
        return false;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 第二十次修（用户红标）：一行里卡片之间空得太宽，按爱奇艺的竖版
          // 海报网格重排。根因不是 crossAxisSpacing —— 是旧版把
          // `mainAxisExtent` 钉死 186，而 Column 给子节点的是**宽松宽度约束**，
          // `Image.network` 只按「固定高度 × 图片宽高比」取宽：5 列时槽位
          // 330 px、海报实际只有 ~90 px，左右各空一大块。
          // 现在让海报撑满卡片宽度（见 _VodCard 的 stretch），高度按 2:3
          // 从卡片宽度反算；列数 +1、槽间距 14 → 10，横向空白就此消失。
          const sidePadding = 20.0;
          const crossSpacing = 10.0;
          const mainSpacing = 10.0;
          final columns = constraints.maxWidth >= 1100
              ? 6
              : constraints.maxWidth >= 820
                  ? 5
                  : constraints.maxWidth >= 560
                      ? 4
                      : 3;
          final innerWidth = constraints.maxWidth - sidePadding * 2;
          final cardWidth =
              (innerWidth - crossSpacing * (columns - 1)) / columns;
          // 海报 2:3；下面再留 padding 8 + 海报/片名 6 + 片名 ~17 + 2 + 副标题 ~14。
          final posterHeight = (cardWidth - 8) * 1.5;
          final mainAxisExtent = posterHeight + 47;
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                  child: _header(items.length, all.length, facets, catalog)),
              // 校验未通过时列表必然为空：给一个说得清原因的空态，
              // 而不是一片什么都没有的网格。
              if (!widget.services.vodIndexGate.ready)
                SliverToBoxAdapter(child: _gateEmptyState()),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisExtent: mainAxisExtent,
                    crossAxisSpacing: crossSpacing,
                    mainAxisSpacing: mainSpacing,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    // SliverGrid 只 build 进入视口的 child，因此海报请求天然是
                    // 「仅当前页可见条目」；翻页 / 续载会 build 新卡片继续取图。
                    // 用 id 作 key：列表刷新时 Element 跟着条目走，不会把
                    // 上一张卡的请求结果留在新条目上。
                    (context, i) => _VodCard(
                      key: ValueKey<String>('${scope}\u0000${items[i].id}'),
                      item: items[i],
                      services: widget.services,
                      scope: scope,
                      // 海报按栏目分桶：切到别的栏目再切回来时，
                      // 这里命中缓存直接出图，不再发一次回源请求。
                      posterGroup: widget.section.name,
                      onTap: () => unawaited(_openAndPlay(items[i])),
                    ),
                    childCount: items.length,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 检索结果缓存：同一版本 + 同一个查询 + **同一套筛选项** + 同一个源列表时
  /// 直接复用，避免每次 build 都对几千条跑一遍过滤。
  List<VodItem> _filteredFor(List<VodItem> all) {
    final rev = widget.services.vodLibrary.revision;
    // 内置索引命中也参与缓存键：命中集变了必须重算，否则搜「斗罗」出 3 条、
    // 再搜「斗罗大陆」还显示那 3 条。
    if (rev == _filterRevision &&
        _query == _filterQuery &&
        _filter == _filterOn &&
        identical(all, _filterSource) &&
        identical(_indexHits, _filterIndexHits) &&
        identical(_facetHits, _filterFacetHits)) {
      return _filtered;
    }
    _filterRevision = rev;
    _filterQuery = _query;
    _filterOn = _filter;
    _filterSource = all;
    _filterIndexHits = _indexHits;
    _filterFacetHits = _facetHits;
    // 1.0.5 第十一次修：检索**优先查本地内容检索目录**（纯内存、不发网络），
    // 拿到命中 id 后再叠加栏目与筛选项，最后才展示。这样「本地记录 →
    // 检索结果 → 栏目卡片」是同一份数据，不会出现搜到了却点不开。
    final q = _query.trim();
    List<VodItem> pool = all;
    if (q.isNotEmpty) {
      final ids = <String>{
        for (final i in widget.services.vodLibrary.localMatches(q)) i.id,
        // 第十六次修：播放列表本身就是最终采用的索引，这些条目不进
        // VodLibrary（60 万条 vs 1 万条缓存上限）。若只取本地检索记录的
        // 命中 id，输入关键词会得到「索引明明有片却一部都搜不到」。
        // 在本页池内自行做一次纯内存匹配，同样不发网络请求。
        for (final i in all)
          if (vodMatches(i, q)) i.id,
      };
      pool = <VodItem>[
        for (final i in all)
          if (ids.contains(i.id)) i
      ];
    }
    // 先 facet 再关键词：两者是叠加关系，顺序不影响结果集，
    // 但先 facet 能让关键词过滤跑在更小的集合上。
    final local = filterVodItems(applyVodFilter(pool, _filter), _query);
    // 1.0.5 第 1 项：内置索引命中接在本地命中**后面**。
    //
    // 顺序有意义：本地记录里的条目已经有播放地址、点开即播；内置索引命中
    // 还要回源一次。先本地后索引 = 「能直接播的排前面」，也是主流播放器
    // 的做法。同名的内置命中会被本地条目挤掉（见下面 title 去重），
    // 所以用户不会看到同一部片两个卡片。
    var merged = q.isEmpty ? _mergeFacetHits(local) : _mergeIndexHits(local, q);
    // 排序要覆盖**合并后的整体**：只对本地池子排序的话，索引命中会
    // 整块挂在最后，选「最新年份」看到的仍是「本地部分有序、后面乱序」。
    if (_filter.sort != VodSort.relevance) {
      merged = applyVodFilter(merged, VodFilter(sort: _filter.sort));
    }
    _filtered = merged;
    return _filtered;
  }

  /// 把「整份目录里符合当前筛选条件」的命中接到本地可播条目后面。
  ///
  /// 只在条件快照对得上时合并：用户刚点了新条件、扫描还没回来时，
  /// [_facetHitsKey] 仍是旧条件，拼旧结果就会「点了日本出来美国」。
  List<VodItem> _mergeFacetHits(List<VodItem> local) {
    if (_facetHits.isEmpty) return local;
    if (_facetHitsKey != _facetKey()) return local;
    final seen = <String>{for (final i in local) i.title.trim().toLowerCase()};
    final extra = <VodItem>[];
    for (final hit in _facetHits) {
      if (hit.section != widget.section) continue;
      final key = hit.title.trim().toLowerCase();
      if (key.isEmpty || !seen.add(key)) continue;
      extra.add(hit);
    }
    if (extra.isEmpty) return local;
    return List<VodItem>.unmodifiable(<VodItem>[...local, ...extra]);
  }

  List<VodItem>? _filterSource;
  List<VodItem>? _filterIndexHits;
  List<VodItem>? _filterFacetHits;

  /// 本地命中 + 内置索引命中（同名去重）。
  ///
  /// 只在「关键词与索引结果对得上」时合并：输入刚变、结果还没回来时
  /// [_indexHitsQuery] 仍是旧词，此时拼旧结果会出现「搜 A 显示 B 的结果」。
  List<VodItem> _mergeIndexHits(List<VodItem> local, String q) {
    if (q.isEmpty || q != _indexHitsQuery || _indexHits.isEmpty) return local;
    // 第十八次修：筛选项必须同时作用于索引命中。
    // 原来只对本地池子跑 `applyVodFilter`，索引命中直接拼在后面 ——
    // 选了「日本 + 2020」却仍然混进别国 / 别年的条目，等于筛选对
    // 「整份目录检索」失效（用户看到的就是「筛选没用」）。
    // 索引条目在 `toItem` 里带上了 `genre / area / year`，
    // 所以这里和本地条目走完全同一套过滤口径。
    final hits =
        _filter.isActive ? applyVodFilter(_indexHits, _filter) : _indexHits;
    final seen = <String>{for (final i in local) i.title.trim().toLowerCase()};
    final extra = <VodItem>[];
    for (final hit in hits) {
      // 栏目分片已按栏目切好，这里再校一次：`other` 分片的内容不该出现在
      // 电影栏目里（分片归属由打包侧定，读取侧只做最后一道闸）。
      if (hit.section != widget.section) continue;
      final key = hit.title.trim().toLowerCase();
      if (key.isEmpty || !seen.add(key)) continue;
      extra.add(hit);
    }
    if (extra.isEmpty) return local;
    return List<VodItem>.unmodifiable(<VodItem>[...local, ...extra]);
  }

  /// 继续翻页（单飞由 VodSession 保证；索引模式下由 [_poolSeq] 保证）。
  ///
  /// 第十六次修：ready 时列表来自索引目录，滚到底应续载**同一份索引**的下一批，
  /// 而不是去翻旧分页会话 —— 后者会把另一来源的条目混进来。
  Future<void> _loadMore() async {
    final gate = widget.services.vodIndexGate;
    if (gate.ready) {
      unawaited(_loadIndexPage());
      return;
    }
    final session = widget.services.vodSession;
    if (!session.active || session.busy || session.done) return;
    await session.loadMore();
  }

  /// 计数文案。没有外部源时保持 1.0.4 的原话（门禁锁着）；
  /// 接入第三方后必须改口径 —— 否则「180 部 · 公开授权示例片库」会被理解成
  /// 这些片也是内置的公开素材。
  ///
  /// 1.0.5 第 1 项再加一档：检索结果里混着内置索引命中（那部分条目不进
  /// [VodLibrary]，所以 `total` 数不到它们）。此时必须显式说明命中有多少条
  /// 来自索引，否则「30 / 2 部 · 已筛选」这种自相矛盾的计数会直接暴露。
  String _countLabel(int count, int total) {
    if (widget.services.vodIndexGate.ready) {
      // 没有关键词、也没有筛选项时整行不显示：条数已经在「全部」右侧
      // （用户红标）。有筛选项时这里报「全目录命中」—— 同样是为了说明
      // 条件作用于整份目录，而不是已经加载的那一页。
      final q = _query.trim();
      if (q.isEmpty) {
        if (!_filter.isActive) return '';
        if (_facetHitsKey != _facetKey()) return '正在按整份栏目目录筛选…';
        if (_facetHitsTotal == 0) return '全目录无匹配';
        final only = StringBuffer('全目录命中 ${_bigCount(_facetHitsTotal)}条');
        if (_facetHits.length >= _indexHitLimit) {
          only.write(' · 显示前 ${_facetHits.length} 条');
        }
        return only.toString();
      }
      // 关键词刚改、结果还没回来：明说在查，而不是沿用上一次的数字。
      if (_indexHitsQuery != q) return '正在检索整份栏目目录…';
      if (_indexHitsTotal == 0) return '全目录无匹配';
      final buf = StringBuffer('全目录命中 ${_bigCount(_indexHitsTotal)}条');
      if (_filter.isActive) buf.write(' · 筛出 $count 条');
      if (_indexHits.length >= _indexHitLimit) {
        buf.write(' · 显示前 ${_indexHits.length} 条');
      }
      return buf.toString();
    }
    final indexed = _indexedCountIn();
    final localCount = count - indexed;
    if (indexed > 0) {
      return widget.services.vodLibrary.externalCount == 0
          ? '本地 $localCount 部 · 索引命中 $indexed 条'
          : '本地 $localCount + 索引 $indexed 条';
    }
    if (widget.services.vodLibrary.externalCount == 0) {
      return vodCountLabel(count, total);
    }
    return count == total ? '$count 部 · 内置 + 第三方接口' : '$count / $total 部 · 已筛选';
  }

  /// 「万」前面不留空格：这个结果会和「条」直接拼成「60.5万条」，
  /// 留空格就会变成「60.5 万 条」（十六次修踩过同一个坑）。
  String _bigCount(int n) =>
      n >= 10000 ? '${(n / 10000).toStringAsFixed(1)}万' : '$n';

  /// 当前**合并后**的结果里有多少条来自内置索引。
  ///
  /// 直接数 [_filtered] 里 id 带 `builtin:` 前缀的条目，不用「总数相减」——
  /// 相减在有筛选项时会把「被 facet 滤掉的本地条目」也算成索引贡献。
  int _indexedCountIn() {
    if (_query.trim().isEmpty || _indexHitsQuery != _query.trim()) return 0;
    var n = 0;
    for (final i in _filtered) {
      if (isBuiltinHitId(i.id)) n++;
    }
    return n;
  }

  /// 顶部区域：标题栏 → 源说明 → 加载状态 → 分类 tab → 筛选面板。
  ///
  /// 1.0.5 第八次修：原来是「标题 / 说明 / 按钮 / 搜索框」四行散着堆，
  /// 层级全靠字号，看着像调试面板。现在按设计稿的**分区**重排：
  /// 一块信息（标题 + 计数 + 检索），一条分类轴（tab），一组筛选项（标签 + 值）。
  ///
  /// 视觉口径照设计稿：tab 选中态用「白字 + 短下划线」，筛选项用「深色圆角标签 +
  /// 浅灰值词」，选中值换主题色；但没有搬爱奇艺的绿色 —— 本项目 accent 是蓝色，
  /// 搬绿色会让整个应用出现两套主色。
  Widget _header(
      int count, int total, VodFacets facets, VodFacetCatalog? catalog) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titleBar(count, total),
          // 第十六次修：进入点播的分支状态统一由这一行说明。
          _gateRow(),
          _bootRow(),
          // 外部目录缓存的进度 / 来源说明只在「还没采用索引目录」时有意义；
          // ready 之后列表与它们无关，继续显示会让人以为还在同步。
          if (!widget.services.vodIndexGate.ready) ...[
            if (widget.services.vodLibrary.externalCount > 0) _sourceNote(),
            _loadStateRow(),
          ],
          // 第十七次修：检索条件区**始终存在**。加载中 / 目录为空 / 读取异常
          // 都由 _facetStatus 在这里明确说明，而不是整块消失；下面的列表与
          // 关键词检索不依赖这个状态，任何时候都能正常使用。
          const SizedBox(height: 12),
          _facetStatus(catalog),
          _typeTabs(),
          if (_refreshNotice.isNotEmpty) _refreshNoticeRow(),
          const SizedBox(height: 6),
          _filterPanel(facets, catalog),
        ],
      ),
    );
  }

  /// 重试结果提示：成功不播报，失败才留一行，且不遮挡列表。
  Widget _refreshNoticeRow() {
    final failed = _refreshNotice.startsWith('重试失败');
    final color = failed ? AppTheme.danger : AppTheme.ok;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(
            failed ? Icons.error_outline_rounded : Icons.refresh_rounded,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _refreshNotice,
              style: TextStyle(fontSize: 11, color: color),
            ),
          ),
        ],
      ),
    );
  }

  /// 检索区域的条件状态条：loading / ready / empty / error 四态可见。
  Widget _facetStatus(VodFacetCatalog? catalog) {
    final phase = catalog?.phase ?? VodFacetPhase.idle;
    if (phase == VodFacetPhase.ready) {
      // 用户红标（第十八次修）：「✓ 检索条件已从片源索引目录载入 · 共 N 个
      // 可筛选选项」不要显示。条件本身已经在下面四行里全部铺开，
      // 再播报一句「已载入 N 项」只是噪音。
      // 唯一保留的情形：目录换过、旧选中值被清掉 —— 那件事用户必须知道。
      if (_facetResetNotice.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            const Icon(Icons.info_outline_rounded,
                size: 13, color: AppTheme.warn),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _facetResetNotice,
                style:
                    const TextStyle(fontSize: 11, color: AppTheme.textTertiary),
              ),
            ),
          ],
        ),
      );
    }
    final gate = widget.services.vodIndexGate;
    final waiting =
        phase == VodFacetPhase.idle || phase == VodFacetPhase.loading;
    final text = waiting
        ? (catalog?.message ?? '正在从片源索引目录读取筛选条件…')
        : phase == VodFacetPhase.empty
            ? (gate.ready
                ? catalog!.message
                : '检索目录尚未就绪：${gate.state.note} · ${catalog!.message}')
            : catalog!.message;
    final color = waiting
        ? AppTheme.accent
        : phase == VodFacetPhase.error
            ? AppTheme.danger
            : AppTheme.warn;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(
            waiting ? Icons.hourglass_top_rounded : Icons.info_outline_rounded,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '$text · 列表与检索可继续使用',
              style: TextStyle(fontSize: 11, color: color),
            ),
          ),
          if (!waiting)
            TextButton(
              // 第二十次修：常驻刷新按钮去掉后，「重试」就是唯一的人工重读入口，
              // 走完整的 _manualRefresh（条件 + 条数 + 列表 + 海报一起重来），
              // 不再只是重取一次条件。
              onPressed: _refreshing ? null : () => unawaited(_manualRefresh()),
              style: TextButton.styleFrom(
                foregroundColor: color,
                disabledForegroundColor: AppTheme.textTertiary,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 26),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(_refreshing ? '处理中' : '重试',
                  style: const TextStyle(fontSize: 11)),
            ),
        ],
      ),
    );
  }

  /// 进入点播的索引校验状态行 + 各分支的操作入口（第十六次修）。
  ///
  /// 五个状态各自有独立文案（都来自状态机 [VodIndexGateVerdict.note]）：
  /// checking / ready / needAddress / building / failed。只有后两种需要用户
  /// 动作时给出按钮；ready 时这一行只报「已加载哪一份索引、多少条」。
  Widget _gateRow() {
    final gate = widget.services.vodIndexGate;
    final s = gate.state;
    // 用户红标（第十八次修）：ready 时这行「已加载内置片源索引目录 60.5 万条
    // （2026-11-12 打包）」不要显示 —— 条数已经在「全部」右侧，打包时间
    // 对用户没有任何操作价值。正常态下一行状态都不留，页面从标题直接进筛选区。
    if (s.phase == VodIndexGatePhase.ready && !gate.busy) {
      return const SizedBox.shrink();
    }
    final warn = s.phase == VodIndexGatePhase.needAddress ||
        s.phase == VodIndexGatePhase.failed;
    // 第二十六次修：`building` 期间显示真实进度（来自 VodSession 的逐批上报）。
    // 之前这里只有一个 11 px 的小转圈，用户看不出到底还在取还是已经卡死。
    final p = gate.buildProgress;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          if (gate.busy) ...[
            SizedBox(
              width: 64,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: p?.fraction,
                  minHeight: 3,
                  backgroundColor: AppTheme.divider,
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(AppTheme.accent),
                ),
              ),
            ),
            const SizedBox(width: 7),
          ],
          Expanded(
            child: Text(
              p?.note ?? s.note,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: warn ? AppTheme.textSecondary : AppTheme.textTertiary,
              ),
            ),
          ),
          if (warn)
            TextButton(
              onPressed: () => unawaited(_maybePromptAddress(force: true)),
              child: Text(
                s.phase == VodIndexGatePhase.failed ? '重试 / 改地址' : '设定片源接口',
                style: const TextStyle(fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  /// 未采用索引时网格区的空态：不让人对着一片空白猜「是不是卡死了」。
  Widget _gateEmptyState() {
    final gate = widget.services.vodIndexGate;
    final s = gate.state;
    final p = gate.buildProgress;
    final warn = s.phase == VodIndexGatePhase.needAddress ||
        s.phase == VodIndexGatePhase.failed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 48, 20, 48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              warn ? Icons.link_off : Icons.hourglass_empty,
              size: 40,
              color: AppTheme.textTertiary,
            ),
            const SizedBox(height: 12),
            Text(p?.note ?? s.note,
                style:
                    const TextStyle(fontSize: 14, color: AppTheme.textPrimary)),
            // 生成新接口目录时，网格是空的 —— 这块空白正适合把进度摊开讲清楚，
            // 比顶部那行 64 px 的小条更显眼（用户等的时候盯的就是这里）。
            if (p != null) ...<Widget>[
              const SizedBox(height: 14),
              SizedBox(
                width: 240,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: p.fraction,
                    minHeight: 3,
                    backgroundColor: AppTheme.divider,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(AppTheme.accent),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 6),
            Text(s.reason,
                style: const TextStyle(
                    fontSize: 11, color: AppTheme.textTertiary)),
            if (warn) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => unawaited(_maybePromptAddress(force: true)),
                child: const Text('设定片源接口'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 启动期索引状态（1.0.5 第 2 项要求的「各加载状态用户提示」）。
  ///
  /// 文案全部来自 [VodBootController.note]，页面只负责显示 —— 状态机与
  /// 文案放一处，才不会出现「诊断页说已加载、页面说正在下载」。
  ///
  /// 不显示的情形：`idle`（还没开始）与「已经用上内置索引且没有异常」
  /// （这时多一行字只是噪音，用户不需要知道索引是哪来的）。
  Widget _bootRow() {
    final boot = widget.services.vodBoot;
    final note = boot.note;
    if (note.isEmpty || boot.phase == VodBootPhase.idle) {
      return const SizedBox.shrink();
    }
    final warn = boot.phase == VodBootPhase.fallbackBuiltin ||
        boot.phase == VodBootPhase.incomplete;
    // 第十六次修：正常态统一由 [_gateRow] 说明，避免两行重复写
    // 「已加载 60.5 万条」。这一行只在启动校验给出**警告**时补一句。
    if (!warn) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          if (boot.busy) ...[
            const SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            ),
            const SizedBox(width: 7),
          ],
          Expanded(
            child: Text(
              note,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: warn ? AppTheme.textSecondary : AppTheme.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 第一行：栏目名 + 计数，检索框靠右对齐 —— 与设计稿「主标题在左、
  /// 检索入口在右」的分工一致，也让搜索不再单独吃掉一整行高度。
  ///
  /// 窄窗口（< 720）下检索框落到第二行：标题 + 计数 + 300 宽输入框在
  /// 手机竖屏/小窗里横向放不下，硬挤会溢出黄黑条纹。
  /// 栏目图标：与左侧导航 `AppSection` 同一套 Material 图标、同一档尺寸。
  ///
  /// 1.0.5 第十一次修：左栏每项都有图标，页内标题却只有光秃秃一行字，
  /// 短视频栏目尤其明显（用户红标「加个图标」）。这里补齐并让五个栏目
  /// 统一取同一份口径，颜色仍用次要文字色，不抢标题。
  IconData get _sectionIcon => switch (widget.section) {
        VodSection.movies => Icons.movie_outlined,
        VodSection.series => Icons.video_library_outlined,
        VodSection.documentaries => Icons.public_outlined,
        VodSection.shortVideo => Icons.smart_display_outlined,
        VodSection.anime => Icons.animation_outlined,
        VodSection.other => Icons.category_outlined,
      };

  Widget _titleBar(int count, int total) {
    // 索引就绪时 [_countLabel] 返回空串（用户红标：这行统计不用显示）。
    // 空串时连前置间距一起省掉，否则标题右边会留一截莫名其妙的空隙。
    final countText = _countLabel(count, total);
    final heading = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(_sectionIcon, size: 22, color: AppTheme.textSecondary),
        const SizedBox(width: 10),
        Text(
          widget.section.label,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
            height: 1.2,
          ),
        ),
        if (countText.isNotEmpty) ...[
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              countText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 12, color: AppTheme.textTertiary),
            ),
          ),
        ],
      ],
    );
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 720) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [heading, const SizedBox(height: 8), _searchBox()],
          );
        }
        return Row(
          children: [
            Expanded(child: heading),
            const SizedBox(width: 12),
            _searchBox(),
          ],
        );
      },
    );
  }

  /// 检索框：深色实底 + 圆角 + 左放大镜，**无边框**（设计稿里所有输入面都是无边框的）。
  ///
  /// 宽度固定 300 而不是撑满：撑满会把右侧变成一片长条深色，
  /// 在深色页面上比标题还抢眼。
  Widget _searchBox() {
    return SizedBox(
      width: 300,
      height: 34,
      child: TextField(
        controller: _search,
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: AppTheme.surfaceHigh,
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          prefixIcon: const Padding(
            padding: EdgeInsets.only(left: 10, right: 6),
            child: Icon(Icons.search_rounded,
                size: 16, color: AppTheme.textTertiary),
          ),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 0, minHeight: 0),
          // 本地检索记录的四个基本字段都能搜；字段前缀写法见 vod_search.dart。
          hintText: '片名 / 类型 / 年份 / 地区（可写 类型:喜剧）',
          hintStyle:
              const TextStyle(fontSize: 12, color: AppTheme.textTertiary),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(
                color: AppTheme.accent.withValues(alpha: 0.7), width: 1.2),
          ),
        ),
        style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
        onChanged: (v) {
          setState(() => _query = v);
          _scheduleIndexSearch(v);
        },
      ),
    );
  }

  /// 源说明（第三方接口的授权提示，必须留在页面上）。
  Widget _sourceNote() {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        '已接入第三方点播源：'
        '${widget.services.vodLibrary.activeSourceName ?? '外部源'} · '
        '${widget.services.vodLibrary.externalCount} 部'
        ' · 本地检索记录 ${widget.services.vodLibrary.externalCount} 条'
        '${_totalHint()}'
        '（内容版权与授权由接口方及使用者自行确认）',
        style: const TextStyle(fontSize: 11, color: AppTheme.textTertiary),
      ),
    );
  }

  /// 加载中 / 出错 / 同步状态，三选一。
  ///
  /// 「加载中」只在**一条本地记录都没有**时占位：那时页面确实空着，
  /// 需要转圈解释为什么没卡片。一旦本地目录有内容，同步进度交给
  /// [_moreRow] 那行小字，不该把整页钉在加载态上。
  Widget _loadStateRow() {
    if (widget.services.vodSession.busy &&
        widget.services.vodLibrary.externalCount == 0) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            const SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                // 有了分页，这里要显示「已经进来多少部」和「接口总共多少部」——
                // 只写「加载中」，用户看到卡片不增加会以为卡死了。
                '正在加载点播源：已接入 '
                '${widget.services.vodLibrary.externalCount} 部'
                '${_totalHint()}，本批通常在 5–15 秒内出结果',
                style: const TextStyle(
                    fontSize: 11, color: AppTheme.textSecondary),
              ),
            ),
          ],
        ),
      );
    }
    if (_autoError != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          '默认源未加载成功：$_autoError',
          style: const TextStyle(fontSize: 11, color: AppTheme.textTertiary),
        ),
      );
    }
    return _moreRow();
  }

  /// 一级条：`全部` + 本栏目片源统计。
  ///
  /// 用户红标：原来「全部」后面还跟着一排「剧情片 / 喜剧片 / 恐怖片 …」，
  /// 与下面「类型」整行**完全重复**（同一批词、同一个筛选项），要去掉，
  /// 位置留给片源统计。
  ///
  /// 第二十次修：右端常驻的「⟳ 刷新」按钮按红标**去除**。手动重读目录的
  /// 能力保留在 [_facetStatus] 的非就绪态「重试」入口里 —— 条件加载失败 /
  /// 目录为空时本来就需要一个可点的按钮，不必在每屏都挂一个用不上的刷新。
  ///
  /// 「全部」本身保留：它是「一键清空全部筛选」的出口 —— 下方筛选行是
  /// toggle（再点一次才取消），长尾词选中后没有这个入口就回不到全量。
  Widget _typeTabs() {
    // 片源统计走目录口径（内置=分片 records，生成=文档条目数），
    // 不是当前已加载的 120 条；目录没读到时**不显示**，而不是显示 0。
    final badge = _sectionTotal > 0 ? '共 ${_bigCount(_sectionTotal)}条' : null;
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              _tabItem('全部', !_filter.isActive, () {
                // 「全部」= 清空**整组**条件（类型 / 地区 / 时间），
                // 不只是类型。原来只清类型，选了「地区 · 日本」再点「全部」
                // 看着像回到全量，其实还筛着日本 —— 点了没反应的那种坏。
                setState(() => _filter = _filter.copyWith(
                      type: '',
                      area: '',
                      time: '',
                    ));
              }, badge: badge),
            ],
          ),
        ),
      ],
    );
  }

  /// 一个 tab：文字 +（可选）统计数 + 选中短下划线。
  ///
  /// [badge] 只给「全部」用，显示本栏目整份目录的条数 —— 它是目录口径，
  /// 所以用弱化的字号与颜色，避免被误读成「当前列表条数」。
  Widget _tabItem(String label, bool selected, VoidCallback onTap,
      {String? badge}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected
                        ? AppTheme.textPrimary
                        : AppTheme.textSecondary,
                    height: 1.3,
                  ),
                ),
                if (badge != null) ...[
                  const SizedBox(width: 5),
                  Text(
                    badge,
                    style: TextStyle(
                      fontSize: 11,
                      color: selected ? AppTheme.accent : AppTheme.textTertiary,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 5),
            // 选中短下划线：宽 22、高 3、圆角 —— 设计稿里就是这一条，
            // 它比「整块底色」更轻，不会在深色页面上糊成一片。
            Container(
              width: 22,
              height: 3,
              decoration: BoxDecoration(
                color: selected ? AppTheme.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 筛选面板：类型 / 地区 / 时间 / 排序。「展开」控制长尾词。
  ///
  /// 第二十三次修（用户红标）：原来的「分类」整行删掉 —— 那一行是采集站
  /// 原始类目名（`剧情片 / 国产剧 / Netflix电影`），既不是用户理解的类型，
  /// 又与「类型」「地区」两行语义重叠。类型行改为固定词表（[kVodGenreVocabulary]），
  /// 顺序照爱奇艺。
  Widget _filterPanel(VodFacets facets, VodFacetCatalog? catalog) {
    // 默认 `_filtersExpanded = true` ⇒ 目录里全部可筛项一次性铺出来（完整覆盖）。
    // 收起只是给用户一个紧凑视图，不改变目录里实际加载了多少项。
    final typeLimit = _filtersExpanded ? facets.types.length : 18;
    final areaLimit = _filtersExpanded ? facets.areas.length : 12;
    final hasMore = facets.types.length > 18 || facets.areas.length > 12;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (facets.types.isNotEmpty)
          _filterRow(
            '类型',
            facets.types.take(typeLimit).toList(),
            _filter.type,
            (v) => setState(() =>
                _filter = _filter.copyWith(type: v == _filter.type ? '' : v)),
          ),
        if (facets.areas.isNotEmpty)
          _filterRow(
            '地区',
            facets.areas.take(areaLimit).toList(),
            _filter.area,
            (v) => setState(() =>
                _filter = _filter.copyWith(area: v == _filter.area ? '' : v)),
          ),
        if (facets.times.isNotEmpty)
          _filterRow(
            '时间',
            facets.times,
            _filter.time,
            (v) => setState(() =>
                _filter = _filter.copyWith(time: v == _filter.time ? '' : v)),
          ),
        _filterRow(
          '排序',
          [for (final s in VodSort.values) s.label],
          _filter.sort.label,
          (v) => setState(() => _filter = _filter.copyWith(
                sort: VodSort.values.firstWhere((s) => s.label == v),
              )),
        ),
        // 第十八次修：原来这里还有一行「目录共 N 个可筛项（类型 a / 地区 b /
        // 时间 c）…本目录未提供 XX 字段」的说明。现在四个维度都有数据，
        // 这行只剩噪音；真的缺维度时（老索引 v1）由 _facetStatus 的 empty
        // 态统一说明，不需要每个维度再报告一次。
        if (hasMore)
          Padding(
            padding: const EdgeInsets.only(left: 0, top: 2),
            child: TextButton.icon(
              onPressed: () =>
                  setState(() => _filtersExpanded = !_filtersExpanded),
              icon: Icon(
                _filtersExpanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 16,
              ),
              label: Text(_filtersExpanded ? '收起' : '展开',
                  style: const TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.textSecondary,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
      ],
    );
  }

  /// 一行筛选：左侧固定宽度的深色圆角标签 + 右侧可以换行的值词。
  Widget _filterRow(String label, List<String> values, String selected,
      ValueChanged<String> onPick) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 46,
            padding: const EdgeInsets.symmetric(vertical: 3),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppTheme.surfaceHigh,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.accent,
                height: 1.2,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(
              spacing: 4,
              runSpacing: 2,
              children: [
                for (final v in values)
                  _filterValue(v, v == selected, () => onPick(v)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterValue(String label, bool selected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            height: 1.3,
            color: selected ? AppTheme.accent : AppTheme.textSecondary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  /// 「/ 接口统计 N 部」的补充说明（接口没给总数时返回空串）。
  String _totalHint() {
    final s = widget.services.vodSession;
    if (!s.active || s.discoveredTotal <= 0) return '';
    return '，接口统计 ${s.discoveredTotal} 部';
  }

  /// 「目录同步状态」一行（1.0.5 第四项：**这里不再有「加载更多」按钮**）。
  ///
  /// 交互口径改成主流播放软件的样子 —— 用户永远不需要点按钮才能看到片子：
  /// 1. 冷启动 `main()` 就把 `vod-library.json` 整份读回，首屏直接是完整本地目录；
  /// 2. 后台按 [kVodFullSyncMaxBatches] 批 / [kVodFullSyncBudget] 把接口全量补齐，
  ///    进度只在落盘上限处停，不需要人守着；
  /// 3. 列表滚到底只是「顺手再接一批」（[kAutoLoadExtentAfter]），不点也会接。
  ///
  /// 因此这一行只做**状态告知**：还在补 / 已经到底。给个转圈是因为「后台在动」
  /// 这件事本身需要可见，否则用户会以为片子就那么点。
  Widget _moreRow() {
    final s = widget.services.vodSession;
    if (!s.active) return const SizedBox.shrink();
    final loaded = widget.services.vodLibrary.externalCount;
    if (s.done) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          '目录已完整：共 $loaded 部可播放条目（已到接口末尾）',
          style: const TextStyle(fontSize: 11, color: AppTheme.textTertiary),
        ),
      );
    }
    // 分母口径（1.0.5 第十五次修）：以前这里拼 `_totalHint()`，写出的是
    // 「接口统计 1475989 部」。可单次同步有 `kVodCacheMaxItems`（1 万条）硬上限，
    // 那个分母**注定追不到** —— 进度永远停在 0.6%，用户读到的是「同步不完了」。
    // 现在只报两个能兑现的数字：本地已加载多少、内置索引可检索多少。
    final boot = widget.services.vodBoot;
    final indexedTotal = boot.manifest?.total ?? 0;
    final hint = boot.hasLocalIndex && indexedTotal > 0
        ? ' · 内置索引 ${_wanCount(indexedTotal)} 条已可直接检索'
        : '';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          const SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(strokeWidth: 1.4),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              '后台增量同步中：已加载 $loaded 部$hint',
              style:
                  const TextStyle(fontSize: 11, color: AppTheme.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  /// 1 万以上折成「60.5 万」—— 和启动校验那行（[VodBootController.note]）
  /// 同一个量级口径，避免同一屏出现「605106 条」和「60.5 万条」两种写法。
  static String _wanCount(int n) {
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)} 万';
    return '$n';
  }

  // ── 播放页右栏（影片详情）────────────────────────────────

  /// 指针是否停在右栏内（第二十三次修：改成像左栏那样按悬停伸缩）。
  ///
  /// 停在栏上时**不启动**收缩计时 —— 否则读到一半，面板会在光标底下缩回去。
  /// 左栏就是这套时序：`onEnter` 取消计时、`onExit` 才安排收缩。
  bool _detailHovering = false;

  /// 进入播放页：右栏默认展开，并安排一次兜底收缩。
  ///
  /// 兜底是为了遥控器 / 触屏：没有指针悬停，只能靠计时器把画面让出来。
  /// 鼠标用户一旦把指针移进来，计时器就取消（[_pokeDetail]）。
  void _enterDetailPanel() {
    _detailExpanded = true;
    _detailHovering = false;
    _scheduleDetailCollapse(kVodDetailIdleTimeout);
  }

  /// 右栏的唯一输入入口。任何交互都走这里：需要时展开，并决定要不要计时。
  ///
  /// 第二十三次修（用户红标「参考左栏的模式」）：
  /// * 指针进栏 ⇒ 展开且**不计时**（停在上面就一直开着）；
  /// * 指针离开栏 ⇒ 1.2 秒后收起（与左栏 `_scheduleSideHide` 同一档）；
  /// * 其余输入（I/D/信息键、快进、音量、换集）⇒ 重新计 8 秒。
  ///
  /// 第二十四次修：收起后**不留竖条**，所以「点窄条」这一路不存在了，
  /// 换成右边缘热区（[VodDetailInput.pointerOnEdge]）。
  void _pokeDetail([VodDetailInput input = VodDetailInput.pointerOnPanel]) {
    if (!mounted) return;
    final next = vodDetailExpandedAfter(_detailExpanded, input);
    if (next != _detailExpanded) {
      setState(() => _detailExpanded = next);
    }
    switch (input) {
      case VodDetailInput.pointerOnPanel:
        _detailHovering = true;
        _cancelDetailTimer();
      case VodDetailInput.pointerLeftPanel:
        _detailHovering = false;
        _scheduleDetailCollapse(kVodDetailHoverExitDelay);
      case VodDetailInput.enterPlayback:
      case VodDetailInput.pointerOnEdge:
      case VodDetailInput.toggleKey:
        if (vodDetailRestartsTimer(next)) {
          _scheduleDetailCollapse(kVodDetailIdleTimeout);
        } else {
          _cancelDetailTimer();
        }
      case VodDetailInput.pointerElsewhere:
        // 点画面只刷新计时，不改变展开状态；指针还停在栏上时也不该收起。
        if (next && !_detailHovering) {
          _scheduleDetailCollapse(kVodDetailIdleTimeout);
        }
      case VodDetailInput.idleTimeout:
        _cancelDetailTimer();
    }
  }

  /// 有别的交互时把右栏的收起计时往后推；悬停在栏上则不设计时。
  void _touchDetailPanel() {
    if (!_detailExpanded || _detailHovering) return;
    _scheduleDetailCollapse(kVodDetailIdleTimeout);
  }

  void _cancelDetailTimer() {
    _detailTimer?.cancel();
    _detailTimer = null;
  }

  /// [after] 之后把右栏整块收起（滑出屏幕，屏幕上一个像素都不留）。
  ///
  /// 正在取播放地址 / 已经取失败时**不收起**：那是用户必须看见的状态，
  /// 藏起来等于把「为什么没画面」也一起藏了。
  void _scheduleDetailCollapse(Duration after) {
    _cancelDetailTimer();
    if (_resolving || _resolveError != null) return;
    _detailTimer = Timer(after, () {
      if (!mounted || !_detailExpanded) return;
      setState(() => _detailExpanded = false);
    });
  }

  void _toggleDetail() {
    _pokeDetail(VodDetailInput.toggleKey);
  }

  /// 右栏本体：展开时贴住右边（`right: 0`），收起时**整块滑出屏幕**
  /// （`right: -width`）—— 与左栏 `left: -188` 完全同构。
  ///
  /// 第二十四次修（用户红标「隐藏后还会有详情条，要参考左栏完全隐藏」）：
  /// 原来收起后还留一条 44 px 的「详情」竖条，既不干净，也和左栏不一致
  /// （左栏收起时屏幕上什么都没有）。现在收起到位后这块区域只剩画面。
  ///
  /// 面板**覆盖在画面上**（不压缩 PlayerStage）：改播放器的渲染几何会连带
  /// 影响解码器重建，切来切去最容易出现黑屏一帧。右栏是信息层，浮在上面。
  ///
  /// 第二十三次修（用户红标「参考左栏的交互模式」）：原来用 `onHover`
  /// 给每次移动续命 + 8 秒固定计时，鼠标停在栏上也会到点缩回。现在拆成
  /// `onEnter` / `onExit` 两个事件，与左栏 `_buildSideBarOverlay` 完全同构：
  /// 进栏即展开并取消计时，离栏 1.2 秒后收起。
  Widget _detailPanel(VodItem? item, double width) {
    return AnimatedPositioned(
      // 与左栏同一档滑出时长：两块侧栏在同一个播放页上，节奏得一样。
      duration: kVodDetailSlideDuration,
      curve: Curves.easeOut,
      top: 0,
      right: _detailExpanded ? 0 : -width,
      bottom: 0,
      width: width,
      child: MouseRegion(
        onEnter: (_) => _pokeDetail(VodDetailInput.pointerOnPanel),
        onExit: (_) => _pokeDetail(VodDetailInput.pointerLeftPanel),
        child: Listener(
          onPointerDown: (_) => _pokeDetail(VodDetailInput.pointerOnPanel),
          child: _detailBody(item, width),
        ),
      ),
    );
  }

  /// 播放页右栏这一层：面板本身 + 收起态的**右边缘热区**。
  ///
  /// 返回的是 Stack 的**多个 children**：`EdgeRevealHandle` 自己就是
  /// `Positioned`，只能直接放进 Stack，不能塞进别的容器里。
  ///
  /// 热区是「完全隐藏」之后唯一的鼠标入口（遥控器走 I / D / 信息键，
  /// 见 [_toggleDetail]）；它和左栏用的是同一个组件、同一套策略
  /// （贴边 400 ms 自动展开，也可以点一下、或从边缘往内拖）。
  List<Widget> _detailLayer(VodItem? item) {
    final width = vodDetailWidth(MediaQuery.sizeOf(context).width);
    return <Widget>[
      _detailPanel(item, width),
      if (!_detailExpanded)
        EdgeRevealHandle(
          side: EdgeSide.right,
          onActivate: () => _pokeDetail(VodDetailInput.pointerOnEdge),
        ),
    ];
  }

  /// 展开态：海报 + 标题 + 类型 + 播放状态 + 简介 + 授权说明。可滚动。
  Widget _detailBody(VodItem? item, double width) {
    return Container(
      key: const ValueKey<String>('vod-detail-body'),
      decoration: BoxDecoration(
        // 与左栏 `_railBackground` 同一个值（surface @0.78），不再另调
        // 一档更黑的黑 —— 用户红标要的就是「两块栏看起来是一套」。
        color: AppTheme.panelScrim,
        border: Border(
          left: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 44,
            child: Row(
              children: [
                const SizedBox(width: 16),
                const Text(
                  '详情',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                // 第二十三次修：右上角的「收起」箭头**删除**（用户红标）。
                // 收缩由悬停移出 / 8 秒兜底计时 / I·D 键完成，不再需要一个
                // 只在这一格里出现的按钮。
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              // 底部多留 120 px：控制条压在右栏之上，不让最后一行被挡住。
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 120),
              child: item == null
                  ? const SizedBox.shrink()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(AppTheme.radius),
                          child: AspectRatio(
                            aspectRatio: 16 / 9,
                            child: _Poster(
                              key: ValueKey<String>(
                                  'detail|${_directoryScope()}|${item.id}'),
                              item: item,
                              services: widget.services,
                              scope: _directoryScope(),
                              group: widget.section.name,
                              large: true,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 17,
                            height: 1.35,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                        if (item.subtitle.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            item.subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: Colors.white.withValues(alpha: 0.55),
                            ),
                          ),
                        ],
                        const SizedBox(height: 10),
                        _detailStatus(),
                        const SizedBox(height: 12),
                        Text(
                          item.description,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.65,
                            color: Colors.white.withValues(alpha: 0.76),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          item.license,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.5,
                            color: Colors.white.withValues(alpha: 0.38),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// 右栏里的播放状态行：正在取地址 / 取不到 + 重试 / 续播位置。
  Widget _detailStatus() {
    if (_resolving) {
      return Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Colors.white70),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '正在获取播放地址…',
              style: TextStyle(
                  fontSize: 12, color: Colors.white.withValues(alpha: 0.7)),
            ),
          ),
        ],
      );
    }
    if (_resolveError != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppTheme.radius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _resolveError!,
              style: const TextStyle(
                  fontSize: 12, height: 1.5, color: Colors.white),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _retryOpen,
                child: const Text('重试', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
      );
    }
    final rec = _resume;
    if (rec != null) {
      return Text(
        rec.finished
            ? '上次已看完 · 将从下一集开始'
            : '上次看到 第 ${rec.canonicalEpisode} 集 ${vodClock(rec.canonicalSeconds)}',
        style:
            TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.6)),
      );
    }
    return const SizedBox.shrink();
  }

  // ── 播放 ────────────────────────────────────────────────

  Widget _buildPlaying() {
    final s = _session;
    final item = _item;
    final episodes = item?.episodes ?? const <VodEpisode>[];
    final numbers = episodes.map((e) => e.number).toList(growable: false)
      ..sort();
    final current = s?.contentEpisode ?? 0;
    final hasPrev = vodAdjacentEpisode(numbers, current, -1) != null;
    final hasNext = vodAdjacentEpisode(numbers, current, 1) != null;

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: MouseRegion(
        onHover: (_) => _pokeControls(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: PlayerStage(
                player: widget.services.player,
                fill: true,
                // 切走栏目后摘掉渲染面：三个点播页在 IndexedStack 里同时存活，
                // 停在播放态的那一页如果一直挂着渲染面，就会把上一路
                // （直播 / 别的栏目）的末帧留在画面上。
                attachSurface: widget.active,
                // 遮罩要覆盖到**首帧出现**，不只是 load 发出为止。
                centerMessage:
                    _awaitingPicture ? (s == null ? '正在载入…' : '正在打开…') : null,
                showSpinner: s == null || _awaitingPicture,
              ),
            ),
            // 点画面：显示 / 收起控制条（主流播放器的一致行为）。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
              ),
            ),
            // 第二十二次修：右栏影片详情。**放在控制层下面** —— 顶栏的
            // 「关闭」和底部控制条必须浮在它上面，否则进度条末端会被面板挡掉。
            // 第二十四次修：这一层现在可能返回两个 widget（面板 + 收起后的
            // 右边缘热区），所以用展开而不是单条。
            ..._detailLayer(item),
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Column(
                    children: [
                      _topBar(item, s),
                      const Spacer(),
                      _controlBar(item, hasPrev, hasNext),
                    ],
                  ),
                ),
              ),
            ),
            if (_showEpisodes) _episodePanel(episodes, current),
          ],
        ),
      ),
    );
  }

  Widget _topBar(VodItem? item, PlaybackSession? s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 14, 26),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Colors.black.withValues(alpha: 0.78),
            Colors.transparent,
          ],
        ),
      ),
      child: Row(
        children: [
          // 第二十次修（用户红标）：左上角「返回」箭头去掉，右上角「选集」
          // 改成唯一的「关闭」出口。播放页原本有三个语义重叠的返回入口
          // （顶栏返回 / 顶栏选集 / 控制条），电视上焦点来回跳反而找不到
          // 该按哪个。选集仍可从底部控制条与遥控器 M 键打开。
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item?.title ?? s?.mediaTitle ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                if (s != null)
                  Text(
                    _episodeLabel(item, s.contentEpisode),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.66),
                    ),
                  ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: _closePlayback,
            icon:
                const Icon(Icons.close_rounded, size: 18, color: Colors.white),
            label: const Text('关闭',
                style: TextStyle(fontSize: 12, color: Colors.white)),
          ),
        ],
      ),
    );
  }

  /// 关闭当前影片：停播 + 返回上一页（详情页；无详情时回片库列表）。
  ///
  /// 与 [_back] 的区别：按钮不处理「先关选集浮层 / 先退全屏」这类中间态，
  /// 语义就是「这部片不看了」——一次点击必须离开播放视图。Esc / 物理返回键
  /// 仍走 [_back] 的分层返回，两套入口最终都落在 [_leavePlaying]。
  void _closePlayback() {
    if (widget.fullscreen) widget.onToggleFullscreen();
    _leavePlaying();
  }

  String _episodeLabel(VodItem? item, int episode) {
    if (item == null || !item.isSeries) return '单集内容';
    final numbers = item.episodes.map((e) => e.number).toList(growable: false)
      ..sort();
    final ordinal = vodEpisodeOrdinal(numbers, episode);
    final title = item.episodes
        .firstWhere((e) => e.number == episode,
            orElse: () => item.episodes.first)
        .title;
    return ordinal == 0 ? title : '第 $ordinal / ${numbers.length} 集 · $title';
  }

  /// 底部控制栏（1.0.5 第九次修：整条按主流播放器的分栏重做）。
  ///
  /// 读数走 [_readout] 合并监听，**不 setState** —— 每秒一次 setState 会把
  /// 整个点播页（含几千条卡片网格）重建一次，拖进度条时直接掉帧。
  Widget _controlBar(VodItem? item, bool hasPrev, bool hasNext) {
    return AnimatedBuilder(
      animation: _readout,
      builder: (context, _) {
        final duration = _duration.value;
        final position = _position.value;
        return PlayerControlBar(
          playing: !_paused,
          position: position,
          duration: duration,
          buffered: _buffered.value,
          volume: _volumeN.value,
          rate: _rate,
          qualityId: _qualityId,
          qualityLabel: _resolution.value.isEmpty ? '自动' : _resolution.value,
          qualities: _qualityOptions(),
          qualityNote: _qualityNote,
          hasPrevious: hasPrev,
          hasNext: hasNext,
          canPickEpisodes: item?.isSeries ?? false,
          episodesOpen: _showEpisodes,
          fullscreen: widget.fullscreen,
          visible: _controlsVisible,
          showHints: true,
          onPanelChanged: (open) {
            _panelOpen = open;
            if (open) {
              // 面板开着时把控制条的自动收起计时停掉，否则 4 秒后一起淡出。
              _hideTimer?.cancel();
            } else {
              _pokeControls();
            }
          },
          onTogglePlay: () => unawaited(_togglePause()),
          onSkip: (delta) => unawaited(_seekBy(delta)),
          // 拖动中只钉住控制条，不 setState：实时时间显示由控制栏内部维护。
          onScrub: (_) {
            _scrubbing = true;
            _hideTimer?.cancel();
          },
          onSeek: (fraction) {
            _scrubbing = false;
            unawaited(_seekTo(duration > 0 ? fraction * duration : 0));
            _pokeControls();
          },
          onPrevious: () => unawaited(_playAdjacent(-1)),
          onNext: () => unawaited(_playAdjacent(1)),
          onVolume: (v) => unawaited(_setVolume(v)),
          onMute: _toggleMute,
          onRate: (r) => unawaited(_setRate(r)),
          onQuality: (id) {
            // 目前只有 auto 一档；setState 只为让面板勾选状态回落。
            setState(() => _qualityId = id);
            _pokeControls();
          },
          onEpisodes: () {
            setState(() => _showEpisodes = !_showEpisodes);
            _pokeControls();
          },
          onFullscreen: () {
            widget.onToggleFullscreen();
            _pokeControls();
          },
        );
      },
    );
  }

  /// 选集浮层：右侧抽屉，列出全部剧集，当前集高亮。
  ///
  /// 第二十八次修：外面套一层 [PanelIdleHider]，**6 秒无响应自动收起**
  /// （[kVodEpisodeIdleHide]）。这正是用户红标的诉求 —— 之前这个抽屉只能靠
  /// 右上角那个 X 或再按一次 M 关掉，鼠标用户点开去泡杯茶回来它还杵在画面右侧。
  /// 计时器跟着浮层的生命周期走（条件渲染），关闭路径再多也不会漏掉取消。
  Widget _episodePanel(List<VodEpisode> episodes, int current) {
    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      width: 320,
      child: PanelIdleHider(
        idle: kVodEpisodeIdleHide,
        onIdle: () {
          // 双检：到点时浮层可能已经被别的路径关掉了（换集 / 退出播放），
          // 那种情况下不能再 setState 一次。
          if (!mounted || !_showEpisodes) return;
          setState(() => _showEpisodes = false);
          // 抽屉收走后控制条要跟着亮一下 —— 用户下一步多半是拖进度或选集。
          _pokeControls();
        },
        child: Material(
          color: AppTheme.surface.withValues(alpha: 0.96),
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      Text(
                        '选集（${episodes.length}）',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '收起选集',
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () {
                          setState(() => _showEpisodes = false);
                          _pokeControls();
                        },
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
                    itemCount: episodes.length,
                    itemBuilder: (context, i) {
                      final e = episodes[i];
                      final active = e.number == current;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Material(
                          color:
                              active ? AppTheme.accentDim : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            focusColor: AppTheme.accentDim,
                            autofocus: active,
                            onTap: () {
                              final item = _item;
                              if (item == null) return;
                              setState(() => _showEpisodes = false);
                              unawaited(_play(item, e));
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 11),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 28,
                                    child: Text(
                                      '${i + 1}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: active
                                            ? AppTheme.accent
                                            : AppTheme.textTertiary,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      e.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        color: active
                                            ? Colors.white
                                            : AppTheme.textSecondary,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
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

// ── 小部件 ────────────────────────────────────────────────

/// 海报 / 色块主视觉。
///
/// 1.0.5 第四次修：之前**从不加载网络海报**，所有卡片都是色块 + 首字，
/// 用户看到的就是「图片全都加载不出来」。现在：
///  * 有 `posterUrl` 就真的去拉，按卡片宽度解一张足够清晰的图（`cacheWidth`），
///    避免 1080p 海报原图解码把内存和帧时间吃光；
///  * 拉失败 / 超时就从失败名单里记住，回落成色块，不再对同一张图反复重试；
///  * 加载中显示色块 + 首字，不留白闪。
/// 1.0.5 第十七次修：本地索引条目**自带字段里没有海报**，这里在卡片进入
/// 视口时按 `目录身份 + 条目 id` 异步补齐。请求只由 build 出来的卡片发起
/// （网格是 SliverChildBuilderDelegate），所以天然只覆盖当前可见条目；
/// 加载中 / 失败 / 无图一律先画色块，条目文字与点击完全不受影响。
class _Poster extends StatefulWidget {
  const _Poster({
    super.key,
    required this.item,
    required this.services,
    required this.scope,
    this.group = '',
    this.large = false,
  });

  final VodItem item;
  final ShunboServices services;

  /// 目录身份串；换片源后旧海报不会串到新条目上。
  final String scope;

  /// 栏目标识。海报按「目录身份 + 栏目」分桶缓存 —— 同一份目录下切栏目
  /// 不会互相挤占，切回已访问过的栏目直接用缓存，不再发请求。
  final String group;
  final bool large;

  @override
  State<_Poster> createState() => _PosterState();
}

class _PosterState extends State<_Poster> {
  // getter 让下面原有的渲染代码逐字不变（原来是无状态字段）。
  VodItem get item => widget.item;
  bool get large => widget.large;

  /// 已确认取不到的图片地址 → 记下的时刻。放在 State 类里而不是实例里：
  /// 卡片被回收重建后不该立刻重试，否则滚动一次又是一批超时请求。
  ///
  /// 但**不能永久记**：实测 12 个采集站的图床里，`p.bfvp26.com`（占电影栏目
  /// 四分之一）是「时通时断」，另外三家的 TLS 会直接被中断。永久记死意味着
  /// 图床一恢复，用户滚回去还是色块。所以过了 [kPosterDeadTtl] 允许再试一次。
  static final Map<String, DateTime> _deadAt = <String, DateTime>{};
  static const Duration kPosterDeadTtl = Duration(seconds: 60);

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

  String get _cacheKey => VodPosterService.keyOf(widget.scope, item.id);

  @override
  void initState() {
    super.initState();
    // 先请求再订阅：首次请求可能触发 switchScope 的空广播，别让它在本卡片
    // 还没 build 时就调 setState。
    _request();
    widget.services.vodPosters.addListener(_onPosters);
  }

  @override
  void didUpdateWidget(covariant _Poster old) {
    super.didUpdateWidget(old);
    // 列表刷新 / 翻页 / 切换片源导致的条目或目录变化都要重新对齐图片。
    if (old.scope != widget.scope ||
        old.group != widget.group ||
        old.item.id != item.id ||
        old.item.posterUrl != item.posterUrl) {
      _request();
    }
  }

  @override
  void dispose() {
    widget.services.vodPosters.removeListener(_onPosters);
    super.dispose();
  }

  void _onPosters(Set<String> keys) {
    // 空集合 = 目录整体切换，所有卡片都要按新 scope 重画。
    if (mounted && (keys.isEmpty || keys.contains(_cacheKey))) {
      setState(() {});
    }
  }

  void _request() => widget.services.vodPosters
      .request(widget.scope, item, group: widget.group);

  void _markDead(String url) {
    if (_deadAt.length > 400) _deadAt.clear();
    _deadAt[url] = DateTime.now();
  }

  /// 这条地址现在算不算「试过了，别再试」。
  bool _isDead(String url) {
    final at = _deadAt[url];
    if (at == null) return false;
    if (DateTime.now().difference(at) < kPosterDeadTtl) return true;
    _deadAt.remove(url);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final fallback = _fallback();
    final posters = widget.services.vodPosters;
    final cached = posters.posterOf(widget.scope, item.id, group: widget.group);
    // 条目自带海报优先（生成目录 / 外部条目）；否则用本条目异步取回的那张。
    final url = item.posterUrl.isNotEmpty ? item.posterUrl : (cached ?? '');
    if (url.isEmpty || _isDead(url)) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(large ? AppTheme.radius : 8),
      child: Image.network(
        url,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        // 解码尺寸按卡片实际像素宽度给，别让 GPU 纹理按原图尺寸分配。
        cacheWidth: large ? 720 : 400,
        frameBuilder: (context, child, frame, wasSync) {
          if (wasSync) return child;
          return AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: const Duration(milliseconds: 180),
            child: child,
          );
        },
        // 加载中也画色块，但右下角有个小转圈：图床实测 0.6–3 s、慢的时候 30 s，
        // 没有这个角标时「正在下载」和「这张根本没图」在屏幕上完全一样，
        // 用户只能得出「图不显示」的结论。
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : _loadingFallback(fallback),
        errorBuilder: (context, error, stack) {
          _markDead(url);
          return fallback;
        },
      ),
    );
  }

  Widget _loadingFallback(Widget fallback) {
    return Stack(
      fit: StackFit.expand,
      children: [
        fallback,
        Positioned(
          right: 6,
          bottom: 6,
          child: SizedBox(
            width: large ? 16 : 12,
            height: large ? 16 : 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              valueColor: AlwaysStoppedAnimation<Color>(
                Colors.white.withValues(alpha: 0.55),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _fallback() {
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
              item.title.isEmpty ? '影' : item.title.characters.first,
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
  const _VodCard({
    super.key,
    required this.item,
    required this.services,
    required this.scope,
    required this.posterGroup,
    required this.onTap,
  });

  final VodItem item;
  final ShunboServices services;
  final String scope;

  /// 栏目标识（`VodSection.name`）。海报按「目录身份 + 栏目」分桶缓存，
  /// 切栏目不会把别栏目的图挤掉，切回来直接命中。
  final String posterGroup;
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
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: _hover ? AppTheme.surfaceHigh : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: _hover
                  ? AppTheme.accent.withValues(alpha: 0.5)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Column(
            // stretch 是关键：海报必须吃满卡片宽度，否则 Image.network 只按
            // 自身宽高比取宽，槽位里剩下的就全变成「看着像间距」的空白。
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _Poster(
                  key: ValueKey<String>(
                      'card|${widget.scope}|${widget.item.id}'),
                  item: widget.item,
                  services: widget.services,
                  scope: widget.scope,
                  group: widget.posterGroup,
                ),
              ),
              const SizedBox(height: 6),
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
                style:
                    const TextStyle(fontSize: 11, color: AppTheme.textTertiary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
