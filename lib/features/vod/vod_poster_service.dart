/// 点播卡片海报的「可见条目异步补齐」服务（1.0.5 第十七次修，纯 Dart）。
///
/// ## 为什么需要它
///
/// 第十六次修之后，播放列表来自**索引目录**（随包的精简索引或用户生成的
/// `vod-index.json`）。精简索引每行只有「站点下标 + vod_id + 类目 + 片名」，
/// 没有 `vod_pic`；`BuiltinIndexService.toItem()` 因此把 `posterUrl` 留空，
/// 列表卡片全部落成色块 —— 截图里那一排蓝底播放按钮就是这么来的。
///
/// 采集站的 `?ac=detail&ids=` 本来就带 `vod_pic`，只是以前只在**点开详情**
/// 时才去取。这里把同一次取数提前到「卡片进入可视区」，且只取海报地址，
/// 不组装可播条目、不改播放链路（`adoptResolved` 的副作用不在这里发生）。
///
/// ## 五条不变式（需求原文的可执行口径）
///
/// 1. **只取可见条目**：请求由 `_Poster` 在 `initState` 发出，而网格用的是
///    `SliverChildBuilderDelegate` —— 只有进入视口（含少量 cacheExtent）的
///    卡片才会被 build。翻页 / 续载自然触发新一批卡片请求，无需手动算视口。
/// 2. **图片与条目准确匹配**：缓存键是 `scope \u0000 item.id`，`scope` 由
///    「当前采用的索引 + 接口地址 + 目录时间戳」构成。列表新增只是多了新 id，
///    刷新复用同 id；切换片源时 [switchScope] 清空缓存并把在途结果作废。
/// 3. **不阻塞列表渲染**：`request()` 是同步入队、`fetchMany` 在后台跑；
///    加载中 / 失败 / 无图都由 `_Poster` 立即画色块，条目文字与点击照常。
/// 4. **失败不反复重试**：空结果记进 `_dead`，卡片被回收重建也不会再发请求。
/// 5. **按栏目分桶**（第十八次修）：同一份目录下六个栏目共用这个单例，但
///    **各自一个桶**。切栏目不清别人的图，切回已访问栏目直接命中缓存 ——
///    否则「电影 → 电视剧 → 电影」会把电影的图全重取一遍（缓存总量上限
///    一次清空的老做法，实测 6 栏目 × 120 张很快就撞上）。
///
/// 批量与并发：`request()` 用 60 ms 窗口把同一帧里出现的卡片合并成一批，
/// 每批最多 [batchSize] 条、最多 [maxConcurrent] 批在途；装配层再按站点
/// 分组，一次 `?ac=detail&ids=a,b,c` 取回多张海报，避免一屏几十个请求。
library;

import 'dart:async';

import 'vod_builtin_index.dart';
import 'vod_catalog.dart';

/// 批量取海报的**回包**：入参是一批内置索引命中，返回
/// `hit.id → 海报绝对地址` 外加「这批里哪些是网络原因没取到」。
///
/// 为什么非要区分「没取到」和「没有海报」：采集站的 `?ac=detail&ids=` 一次
/// 连十条时，实测同一批请求 2.3 s 与 24 s 都出现过（dyttzy / bfzy 都这样）。
/// 原来超时与「这部片确实没图」共用同一个空结果，于是一次超时就把卡片永久
/// 记成 dead —— 用户看到的就是「划过去一屏全是色块，来回切也不出来」。
typedef VodPosterFetch = Future<VodPosterBatch> Function(
    List<BuiltinIndexHit> hits);

/// 一批海报回包。
class VodPosterBatch {
  const VodPosterBatch({
    this.urls = const <String, String>{},
    this.failed = const <String>{},
  });

  /// `hit.id → 海报地址`。只有**确认取到**的才放进来。
  final Map<String, String> urls;

  /// 网络 / 超时 / 解析异常导致没取到的 `hit.id`。这些允许有限次重试，
  /// 不能直接判死。
  final Set<String> failed;
}

/// 条目 → 内置索引命中。找不到返回 null（该条目没有可回源的站点 / vod_id）。
typedef VodPosterResolve = BuiltinIndexHit? Function(VodItem item);

/// 只把变化的缓存键交给订阅者，避免一张图回来把整屏卡片全部重建。
typedef VodPosterListener = void Function(Set<String> keys);

class _QueuedPoster {
  const _QueuedPoster(this.key, this.hit, this.bucketId, [this.attempt = 0]);

  final String key;
  final BuiltinIndexHit hit;

  /// 回来时写进哪个桶。用字符串而不是对象引用：桶被 LRU 淘汰后
  /// 结果直接丢弃，不会写进一个已经没人看的桶里。
  final String bucketId;

  /// 这是第几次尝试（0 = 首次）。只对「网络失败」累加，命中海报就归零。
  final int attempt;
}

/// 一个栏目的海报缓存。
///
/// 桶的划分键是「目录身份 + 栏目」，因此：
/// * 换片源（目录身份变）⇒ 所有旧桶一次性作废；
/// * 换栏目 ⇒ 只影响该栏目自己的桶，其它栏目原样保留。
class _PosterBucket {
  final Map<String, String> urls = <String, String>{};
  final Set<String> dead = <String>{};

  /// 最近使用序号（越大越新），用于桶数量超限时做 LRU。
  int tick = 0;
}

/// 海报缓存 + 批量调度。进程内单例由 `ShunboServices` 持有。
class VodPosterService {
  VodPosterService({
    required this.fetchMany,
    required this.resolveHit,
    this.batchSize = 8,
    this.maxConcurrent = 3,
    this.coalesce = const Duration(milliseconds: 60),
  });

  final VodPosterFetch fetchMany;
  final VodPosterResolve resolveHit;
  final int batchSize;
  final int maxConcurrent;

  /// 合并窗口：同一帧里被 build 出来的卡片攒成一批再发请求。
  final Duration coalesce;

  /// **单个栏目**的缓存上限。超出只清空这一个桶（老的图重取一次，
  /// 好过把所有栏目的图一起清掉）。120 张一屏 × 5 屏足够覆盖常见滚动深度。
  static const int kGroupCap = 600;

  /// 桶数量上限（6 个栏目 × 换过几次片源）。超出按最久未用淘汰。
  static const int kMaxGroups = 24;

  /// 兼容旧口径：所有桶加起来的总条数上限只用于诊断展示。
  static const int kCacheCap = kGroupCap * kMaxGroups;

  /// 网络失败的额外重试次数。1 次就够：第一批超时的卡片隔 1.2 秒再问一次，
  /// 命中率明显回升；再多只是把弱网拖长。
  static const int kMaxRetry = 1;

  /// 重试前的等待。故意比 [coalesce] 大一个量级 —— 同一时刻打回去多半还是超时。
  static const Duration kRetryDelay = Duration(milliseconds: 1200);

  final Map<String, _PosterBucket> _buckets = <String, _PosterBucket>{};
  final Map<String, _QueuedPoster> _queue = <String, _QueuedPoster>{};
  final Set<String> _inflight = <String>{};
  final List<VodPosterListener> _listeners = <VodPosterListener>[];

  Timer? _timer;

  /// 网络失败重试用的延迟定时器（与 [ _timer ] 分开：那个是合批窗口）。
  Timer? _retryTimer;
  Completer<void>? _drainDone;
  String _scope = '';
  int _tickSeq = 0;

  /// 每换一次来源就 +1；在途批次回来时用它判「是不是过期结果」。
  int _generation = 0;

  int _requestCount = 0;
  int _fetchedCount = 0;
  int _retryCount = 0;

  /// 缓存键：**目录身份 + 条目 id**。换来源后旧图即使还在 Map 里也不会命中。
  static String keyOf(String scope, String id) => '$scope\u0000$id';

  /// 桶划分键：目录身份 + 栏目。空 group 归到一个匿名桶（回归脚本与
  /// 详情页单图预览用得到）。
  static String bucketKeyOf(String scope, String group) =>
      '$scope\u0000${group.isEmpty ? '*' : group}';

  String get scope => _scope;
  int get requestCount => _requestCount;
  int get fetchedCount => _fetchedCount;
  int get bucketCount => _buckets.length;
  int get cachedCount =>
      _buckets.values.fold(0, (n, b) => n + b.urls.length);
  int get deadCount => _buckets.values.fold(0, (n, b) => n + b.dead.length);
  int get queuedCount => _queue.length;
  int get inflightCount => _inflight.length;

  /// 因网络原因被重新排队的次数（诊断用）。
  int get retryCount => _retryCount;

  /// 某个栏目（[group]）已缓存的海报条数 —— 诊断与门禁用。
  int cachedCountOf(String scope, String group) =>
      _buckets[bucketKeyOf(scope, group)]?.urls.length ?? 0;

  String? posterOf(String scope, String id, {String group = ''}) =>
      _buckets[bucketKeyOf(scope, group)]?.urls[keyOf(scope, id)];

  bool isDead(String scope, String id, {String group = ''}) =>
      _buckets[bucketKeyOf(scope, group)]?.dead.contains(keyOf(scope, id)) ??
      false;

  void addListener(VodPosterListener l) => _listeners.add(l);
  void removeListener(VodPosterListener l) => _listeners.remove(l);

  void _emit(Set<String> keys) {
    for (final l in List<VodPosterListener>.of(_listeners)) {
      l(keys);
    }
  }

  /// 取（或建）桶，并记一次「最近使用」。
  _PosterBucket _bucketFor(String scope, String group) {
    final id = bucketKeyOf(scope, group);
    var b = _buckets[id];
    if (b == null) {
      b = _PosterBucket();
      _buckets[id] = b;
      _trimBuckets(keepId: id);
    }
    b.tick = ++_tickSeq;
    return b;
  }

  /// 桶数量超限时按「最久未用」淘汰。只淘汰**当前目录身份以外**的桶，
  /// 当前这一份目录的栏目图一个都不动 —— 那正是用户正在来回切的那几屏。
  void _trimBuckets({required String keepId}) {
    if (_buckets.length <= kMaxGroups) return;
    final ids = _buckets.keys.where((k) => k != keepId).toList()
      ..sort((a, b) => _buckets[a]!.tick.compareTo(_buckets[b]!.tick));
    var overflow = _buckets.length - kMaxGroups;
    for (final id in ids) {
      if (overflow <= 0) break;
      _buckets.remove(id);
      overflow--;
    }
  }

  /// 切换片源索引（或索引目录被重建）：清空**不属于新目录身份**的桶，
  /// 并让在途结果作废。
  ///
  /// 不清空的话会出现「用户换了接口，屏幕上还留着上一份索引的 poster」，
  /// 而那些图对应的 `vod_id` 在新站点里指向完全不同的片子。
  ///
  /// 但**同身份的其它栏目桶必须留下**：目录身份只含来源 / 地址 / 时间戳 /
  /// 总条数，与栏目无关；切栏目时这个函数其实会直接 return，真的换片源
  /// 才动手 —— 这样「切回已访问过的栏目无需重新加载」才成立。
  void switchScope(String newScope) {
    if (newScope == _scope) return;
    _scope = newScope;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _queue.clear();
    _inflight.clear();
    final prefix = '$newScope\u0000';
    _buckets.removeWhere((id, _) => !id.startsWith(prefix));
    // 通知一次（空集合）：让所有卡片重新按新 scope 取图，不带旧图。
    // 必须放到 microtask：`request()` 是由卡片的 initState（build 阶段）调进来的，
    // 同步 _emit 会让其他卡片在 build 里 setState，直接触发
    // 「setState() or markNeedsBuild() called during build」。
    scheduleMicrotask(() => _emit(<String>{}));
  }

  /// 一张卡片进入可视区时调用。**同步返回**，绝不 await 网络。
  ///
  /// [group] 是栏目标识（`VodSection.name`）。不同栏目各自一个桶，切换栏目
  /// 不会把别栏目的图挤掉。
  void request(String scope, VodItem item, {String group = ''}) {
    if (scope != _scope) switchScope(scope);
    // 生成目录 / 外部条目自带海报，直接用，不回源。
    if (item.posterUrl.isNotEmpty) return;
    final bucket = _bucketFor(scope, group);
    final key = keyOf(scope, item.id);
    if (bucket.urls.containsKey(key) ||
        bucket.dead.contains(key) ||
        _queue.containsKey(key) ||
        _inflight.contains(key)) {
      return;
    }
    final hit = resolveHit(item);
    if (hit == null) {
      // 没有可回源的站点 / vod_id：记 dead，卡片重建时不再反复解析。
      bucket.dead.add(key);
      return;
    }
    _requestCount++;
    _queue[key] = _QueuedPoster(key, hit, bucketKeyOf(scope, group));
    _timer ??= Timer(coalesce, () {
      _timer = null;
      unawaited(flush());
    });
  }

  /// 立即冲掉排队并等待全部在途批次（回归脚本用；生产路径由 Timer 调它）。
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    final running = _drainDone;
    if (running != null) return running.future;
    final done = Completer<void>();
    _drainDone = done;
    unawaited(_doDrain().whenComplete(() {
      _drainDone = null;
      done.complete();
      // 重试定时器可能在 drain 期间把条目塞回 `_queue`（那时 `flush()`
      // 只拿到正在跑的 Future，不会再起一次 drain）。这里补一刀，
      // 否则那些条目会永远躺在队列里等下一次 request 顺手带出去。
      if (_queue.isNotEmpty && _timer == null && _retryTimer == null) {
        _timer = Timer(coalesce, () {
          _timer = null;
          unawaited(flush());
        });
      }
    }));
    return done.future;
  }

  Future<void> _doDrain() async {
    final pending = <Future<void>>[];
    while (_queue.isNotEmpty) {
      final keys = _queue.keys.take(batchSize < 1 ? 1 : batchSize).toList();
      final batch = <_QueuedPoster>[];
      for (final k in keys) {
        final q = _queue.remove(k);
        if (q == null) continue;
        _inflight.add(k);
        batch.add(q);
      }
      if (batch.isEmpty) break;
      pending.add(_runBatch(batch, _generation));
      final cap = maxConcurrent < 1 ? 1 : maxConcurrent;
      if (pending.length >= cap) {
        await Future.wait(pending);
        pending.clear();
      }
    }
    if (pending.isNotEmpty) await Future.wait(pending);
  }

  /// 网络失败的那几条隔一会儿再问一次，不直接判死。
  void _requeue(_QueuedPoster q) {
    _retryCount++;
    _retryTimer?.cancel();
    _retryTimer = Timer(kRetryDelay, () {
      _retryTimer = null;
      if (_queue.containsKey(q.key) || _inflight.contains(q.key)) return;
      // 桶已经没了（换片源 / LRU 淘汰）就不再重试。
      if (_buckets[q.bucketId] == null) return;
      _queue[q.key] = _QueuedPoster(q.key, q.hit, q.bucketId, q.attempt + 1);
      unawaited(flush());
    });
  }

  Future<void> _runBatch(List<_QueuedPoster> batch, int generation) async {
    VodPosterBatch found;
    var hardFail = false;
    try {
      found = await fetchMany(<BuiltinIndexHit>[for (final q in batch) q.hit]);
    } catch (_) {
      // 整批抛异常 = 网络层挂了，按「全部失败」处理，不要让它们变 dead。
      found = const VodPosterBatch();
      hardFail = true;
    }
    // 来源在请求期间换了：整批结果作废，不能写进新 scope 的缓存。
    if (generation != _generation) {
      for (final q in batch) {
        _inflight.remove(q.key);
      }
      return;
    }
    final changed = <String>{};
    for (final q in batch) {
      _inflight.remove(q.key);
      final bucket = _buckets[q.bucketId];
      // 桶已被 LRU 淘汰（用户很久没看那个栏目了）：结果直接丢，不重建桶。
      if (bucket == null) continue;
      final poster = found.urls[q.hit.id] ?? '';
      if (poster.isEmpty) {
        // 关键分岔：**网络失败**允许重试，**接口明确说没图**才记 dead。
        final soft = hardFail || found.failed.contains(q.hit.id);
        if (soft && q.attempt < kMaxRetry) {
          _requeue(q);
          continue;
        }
        bucket.dead.add(q.key);
      } else {
        // 只清本栏目：其它栏目的图必须留着，切回去才不用重取。
        if (bucket.urls.length >= kGroupCap) {
          bucket.urls.clear();
          bucket.dead.clear();
        }
        bucket.urls[q.key] = poster;
        _fetchedCount++;
      }
      changed.add(q.key);
    }
    if (changed.isNotEmpty) _emit(changed);
  }
}
