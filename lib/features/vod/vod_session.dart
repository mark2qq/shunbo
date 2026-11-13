/// 点播接入会话（纯 Dart，可在裸 `dart run` 下回归）。
///
/// 持有当前第三方源的**分页器**，负责三件事：
///  1. 首屏自动翻几页（够把栏目铺满，又不至于让用户干等）；
///  2. 「加载更多」继续翻（滚到底 / 点按钮）；
///  3. 每批拿到就写进 [VodLibrary]，并落盘缓存，下次冷启动直接读本地。
///
/// 为什么单独抽一层：分页状态（每个站翻到第几页、接口统计总片量、是否已到底）
/// 不属于页面，也不属于网络服务，页面切换（电影 / 电视剧 / 记录片）时必须共享
/// 同一份进度，否则切一次栏目就会从头再拉一遍。
library;

import '../../data/onboarding/third_party_vod_service.dart';
import 'third_party_vod.dart';
import 'vod_build_progress.dart';
import 'vod_library.dart';
import 'vod_pager.dart';

/// 生成进度回调（第二十六次修）：把「翻到第几个站、已取多少条」交给 UI。
///
/// 做成可选参数而不是构造期注入：`VodSession` 平时被栏目页复用（加载更多），
/// 只有「按新接口生成索引」这一条链路需要进度，没必要为它改所有调用点。
typedef VodBuildProgressSink = void Function(VodBuildProgress progress);

/// 一次 `start()` 的结果（给设置页 / 自动加载用的可读摘要）。
class VodSessionResult {
  const VodSessionResult({
    required this.ok,
    required this.message,
    this.sourceId = '',
    this.sourceName = '',
    this.loadedItems = 0,
    this.totalAvailable = 0,
    this.hasMore = false,
    this.sites = 0,
  });

  final bool ok;
  final String message;
  final String sourceId;
  final String sourceName;
  final int loadedItems;
  final int totalAvailable;
  final bool hasMore;
  final int sites;
}

class VodSession {
  VodSession({
    required ThirdPartyVodService service,
    required VodLibrary library,
    Future<void> Function()? persist,
  })  : _service = service,
        _library = library,
        _persist = persist;

  final ThirdPartyVodService _service;
  final VodLibrary _library;

  /// 落盘回调（由装配层注入，避免本文件依赖 dart:io）。
  final Future<void> Function()? _persist;

  final List<void Function()> _listeners = <void Function()>[];

  VodSourcePager? _pager;
  String _url = '';
  bool _busy = false;
  bool _done = false;
  int _loaded = 0;
  int _discovered = 0;
  String _note = '';
  String _sourceName = '';
  String _sourceId = '';
  Future<void>? _pending;

  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);

  void _notify() {
    for (final l in List<void Function()>.of(_listeners)) {
      l();
    }
  }

  bool get busy => _busy;
  bool get active => _pager != null;
  bool get done => _done;
  int get loadedItems => _loaded;
  int get discoveredTotal => _discovered;
  String get note => _note;
  String get sourceName => _sourceName;
  String get sourceId => _sourceId;

  /// 已经拿到分页器（不重新打开配置）。
  bool isReadyFor(String url) => _pager != null && _url == url;

  /// 开始（或复用）一个接入会话。同一地址重复调用不会重新拉配置。
  Future<VodSessionResult> start({
    required String url,
    required bool allowInsecureHttp,
    bool allowExternalCode = true,
    int autoBatches = 3,
    Duration budget = const Duration(seconds: 40),
    int itemsPerPage = kVodItemsPerSitePage,
    int sitesPerBatch = kVodSitesPerBatch,
    // 冷启动已经从本地检索记录恢复出片库：这一轮只是后台差量核对，
    // 不能因为「源展示名不同」就把用户已经能看的卡片全清掉。
    bool preserveExisting = false,
    VodBuildProgressSink? onProgress,
  }) {
    if (isReadyFor(url) && _loaded > 0) {
      return Future.value(VodSessionResult(
        ok: true,
        message: _note,
        sourceId: _sourceId,
        sourceName: _sourceName,
        loadedItems: _loaded,
        totalAvailable: _discovered,
        hasMore: !_done,
        sites: _pager?.siteCount ?? 0,
      ));
    }
    final existing = _pending;
    if (existing != null) {
      return existing.then((_) => _result());
    }
    _pending = _runStart(
      url: url,
      allowInsecureHttp: allowInsecureHttp,
      allowExternalCode: allowExternalCode,
      autoBatches: autoBatches,
      budget: budget,
      itemsPerPage: itemsPerPage,
      sitesPerBatch: sitesPerBatch,
      preserveExisting: preserveExisting,
      onProgress: onProgress,
    );
    return _pending!.then((_) => _result());
  }

  VodSessionResult _result() => VodSessionResult(
        ok: _loaded > 0,
        message: _note,
        sourceId: _sourceId,
        sourceName: _sourceName,
        loadedItems: _loaded,
        totalAvailable: _discovered,
        hasMore: !_done,
        sites: _pager?.siteCount ?? 0,
      );

  Future<void> _runStart({
    required String url,
    required bool allowInsecureHttp,
    required bool allowExternalCode,
    required int autoBatches,
    required Duration budget,
    required int itemsPerPage,
    required int sitesPerBatch,
    required bool preserveExisting,
    VodBuildProgressSink? onProgress,
  }) async {
    _busy = true;
    _notify();
    try {
      // 第一步就只能给「不确定进度」：这时候连采集站有几个都还不知道。
      onProgress?.call(const VodBuildProgress.connecting());
      final start = await _service.open(
        url: url,
        allowInsecureHttp: allowInsecureHttp,
        allowExternalCode: allowExternalCode,
        itemsPerPage: itemsPerPage,
        sitesPerBatch: sitesPerBatch,
      );
      _sourceId = start.sourceId;
      _sourceName = start.sourceName;
      if (!start.ok) {
        _note = start.message;
        _done = true;
        return;
      }
      final pager = start.pager;
      if (pager == null) {
        // 契约 JSON：一次给全，没有分页。
        if (preserveExisting) {
          _library.append(
            sourceId: start.sourceId,
            incoming: start.contractItems,
            sourceName: start.sourceName,
            headers: start.headers,
          );
          _loaded = _library.externalCount;
        } else {
          _library.install(
            sourceId: start.sourceId,
            incoming: start.contractItems,
            sourceName: start.sourceName,
            headers: start.headers,
          );
          _loaded = start.contractItems.length;
        }
        _discovered = _loaded;
        _done = true;
        _note = start.message;
        onProgress?.call(VodBuildProgress(
          stage: VodBuildStage.fetching,
          sitesDone: 1,
          sitesTotal: 1,
          items: _loaded,
        ));
        await _persistQuietly(force: true);
        return;
      }
      _url = url;
      _pager = pager;
      _done = false;
      // 换源：清掉旧源，否则会同时存在两家条目。
      // 但「本地记录已恢复 + 后台差量核对」这一轮不清：源展示名可能因为
      // 配置改了标题而不同，同一 sourceId 的条目仍然有效；真正换地址时
      // VodLibrary.append 会按 sourceId 自己清空，不需要这里抢先动手。
      if (!preserveExisting && _library.activeSourceName != start.sourceName) {
        _library.clearExternal();
      }
      final watch = Stopwatch()..start();
      var batches = 0;
      // 站点总数已知：从这里起进度条是**确定**的（分母 = 采集站数）。
      onProgress?.call(VodBuildProgress(
        stage: VodBuildStage.fetching,
        sitesTotal: pager.siteCount,
      ));
      while (!pager.done && batches < autoBatches && watch.elapsed < budget) {
        final batch = await pager.next();
        batches++;
        _apply(batch, start.sourceName, start.headers);
        // 每批报一次：`finishedSites` 是「翻完 / 判死」的站点数，
        // 比批次数更接近用户理解的进度（一批里可能同时过 5 个站）。
        onProgress?.call(VodBuildProgress(
          stage: VodBuildStage.fetching,
          sitesDone: pager.finishedSites,
          sitesTotal: pager.siteCount,
          items: _loaded,
        ));
        await _persistQuietly();
        if (batch.fetched == 0) break;
      }
      await _persistQuietly(force: true);
    } catch (e) {
      _note = '接入异常：$e';
    } finally {
      _pending = null;
      _busy = false;
      _notify();
    }
  }

  /// 落盘节流：每批都写一次 JSON（几千条时约 1–2 MB）会抢主线程，
  /// 4 秒一次既够「断电不丢太多」，又不会翻页时一直卡写盘。
  DateTime? _lastSaved;

  Future<void> _persistQuietly({bool force = false}) async {
    final persist = _persist;
    if (persist == null) return;
    final now = DateTime.now();
    if (!force &&
        _lastSaved != null &&
        now.difference(_lastSaved!) < const Duration(seconds: 4)) {
      return;
    }
    _lastSaved = now;
    try {
      await persist();
      _library.markCached(now);
    } catch (_) {
      // 写盘失败不影响本次浏览，下次冷启动走网络即可。
    }
  }

  /// 继续翻一批（滚到底 / 点「加载更多」）。
  ///
  /// 单飞：连点只会跑一次；返回本批新增条目数。
  Future<int> loadMore() async {
    final pager = _pager;
    if (pager == null || _done || _busy) return 0;
    _busy = true;
    _notify();
    try {
      final batch = await pager.next();
      _apply(batch, _sourceName, _library.headers);
      await _persistQuietly();
      return batch.added;
    } catch (_) {
      return 0;
    } finally {
      _busy = false;
      _notify();
    }
  }

  void _apply(VodBatch batch, String sourceName, Map<String, String> headers) {
    if (batch.items.isNotEmpty) {
      _library.append(
        sourceId: _sourceId,
        incoming: batch.items,
        sourceName: sourceName,
        headers: headers,
      );
    }
    _loaded = _library.externalCount;
    _discovered = batch.discoveredTotal;
    _done = batch.done;
    final total = _discovered > 0 ? ' / 接口统计 $_discovered 部' : '';
    _note = '$_sourceName：已加载 $_loaded 部$total'
        '${_done ? '（已到底）' : '，可继续加载'}';
  }

  /// 换地址 / 重置时调用：丢掉分页器，下一次 start 重新识别。
  void reset() {
    _pager = null;
    _url = '';
    _done = false;
    _loaded = 0;
    _discovered = 0;
    _note = '';
  }
}
