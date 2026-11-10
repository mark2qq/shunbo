/// 线路健康度：记录每条线路「多久回数据」「失败过几次」，用来优先选又快又稳的源。
///
/// 为什么需要持久化 + 打分，而不是每次现场探测：
/// * 现场探测一次至少 3~4 秒，换台时这段时间用户看的是黑屏；
/// * 上一个会话里已经测过的事（某台只有 3 号线路能播、5 号线路总是 4 秒才回包），
///   下次启动应该直接知道，而不是重新踩一遍。
///
/// 打分只有一件事要做对：**别把「没测过」当成「好」**。默认分给中性偏下，
/// 这样「实测能播」一定会顶上去，而「实测总失败」一定沉到底。
///
/// 纯 Dart，无 Flutter 依赖 → 可以直接 `dart run` 回归。
library;

import 'dart:convert';

/// 单条线路的统计。
class StreamHealth {
  /// 指数滑动平均的**探测**耗时（毫秒）。0 表示还没测到。
  ///
  /// 它衡量「这条源回包快不快」，是换线时选谁的第一依据。
  double latencyMs;

  /// 指数滑动平均的**起播**耗时（毫秒）：从 `load` 到出画面。
  ///
  /// 为什么与探测分开记：探测只看 HTTP 回包（几十毫秒），而用户真正等的是
  /// 拉 playlist → 拉首个分片 → 解码首帧。实测同一个台两条线路探测都 200/80ms，
  /// 起播一个是 1.2 秒、另一个 9 秒——只按探测排序会一直选中那个慢的。
  double startupMs;

  /// 成功次数（探测通过 / 起播出画面）。
  int okCount;

  /// 失败次数。
  int failCount;

  /// 最近一次成功时间。
  DateTime? lastOkAt;

  /// 最近一次失败时间。
  DateTime? lastFailAt;

  StreamHealth({
    this.latencyMs = 0,
    this.startupMs = 0,
    this.okCount = 0,
    this.failCount = 0,
    this.lastOkAt,
    this.lastFailAt,
  });

  bool get hasData => okCount > 0 || failCount > 0;

  /// 连续失败且未再成功 → 可疑（但**不**等于失效：失效由 `DeadStreamRegistry` 记）。
  ///
  /// 为什么两者要分开：失效是「这条地址现在打不开」，可疑是「这条地址能开但很慢/常断」。
  /// 把慢源记成失效会让它 10 分钟内完全不被尝试，用户永远回不到一个「只是慢」的源。
  bool get isFlaky {
    if (lastFailAt == null) return false;
    if (lastOkAt == null) return failCount >= 1;
    return lastFailAt!.isAfter(lastOkAt!) && failCount >= 2;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'lat': latencyMs,
        'start': startupMs,
        'ok': okCount,
        'fail': failCount,
        'okAt': lastOkAt?.millisecondsSinceEpoch,
        'failAt': lastFailAt?.millisecondsSinceEpoch,
      };

  static StreamHealth? fromJson(Object? raw) {
    if (raw is! Map) return null;
    double numeric(String key) {
      final v = raw[key];
      return v is num ? v.toDouble() : 0;
    }

    int whole(String key) {
      final v = raw[key];
      return v is num ? v.toInt() : 0;
    }

    DateTime? stamp(String key) {
      final v = raw[key];
      return v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
    }

    return StreamHealth(
      latencyMs: numeric('lat'),
      startupMs: numeric('start'),
      okCount: whole('ok'),
      failCount: whole('fail'),
      lastOkAt: stamp('okAt'),
      lastFailAt: stamp('failAt'),
    );
  }
}

/// 全线路的健康度表。
class StreamHealthBoard {
  StreamHealthBoard({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// 记录条数上限：一个会话可能接触上千条线路，留最近的一批就够。
  static const int maxEntries = 800;

  /// 单条线路最多保留的失败累计，避免老记录把一条已恢复的线路永久压低。
  static const int _maxFailCount = 6;

  final Map<String, StreamHealth> _entries = <String, StreamHealth>{};

  int get length => _entries.length;

  StreamHealth? healthOf(String url) => _entries[url];

  /// 该线路是否在 [maxAge] 内被实测为可用（用来决定「换线时还要不要再探一次」）。
  ///
  /// 这是「切换平滑」的关键：换线时若已知一条线路几秒前刚探通，就直接交给内核，
  /// 省掉 3~4 秒的探测等待，用户感知到的中断从「黑屏几秒」变成「画面几乎连续」。
  /// 有效期给 5 分钟而不是更长：公开源经常几十秒内就从「能播」变成 403/404
  /// （CDN 换 token、限流）。信任窗口太长会让换线直接撞上失效源——
  /// 实测 10 分钟窗口下，冷启动第一条线路就吃了 403，白等一次加载。
  bool isFreshOk(String url, {Duration maxAge = const Duration(minutes: 5)}) {
    final h = _entries[url];
    if (h == null || h.lastOkAt == null) return false;
    if (h.isFlaky) return false;
    return _clock().difference(h.lastOkAt!) <= maxAge;
  }

  /// 记录一次成功探测（或起播成功）的耗时。
  void recordOk(String url, Duration latency) {
    final h = _entry(url);
    final ms = latency.inMilliseconds.toDouble();
    // EWMA：新值权重 0.4。单次抖动不该让排序翻盘，但持续变慢要能反映出来。
    h.latencyMs = h.latencyMs == 0 ? ms : (h.latencyMs * 0.6 + ms * 0.4);
    h.okCount++;
    h.lastOkAt = _clock();
    _trim();
  }

  /// 记录一次「载入到出画面」的耗时。
  void recordStartup(String url, Duration startup) {
    final h = _entry(url);
    final ms = startup.inMilliseconds.toDouble();
    h.startupMs = h.startupMs == 0 ? ms : (h.startupMs * 0.6 + ms * 0.4);
    h.okCount++;
    h.lastOkAt = _clock();
    _trim();
  }

  /// 记录一次失败。
  void recordFail(String url) {
    final h = _entry(url);
    h.failCount = (h.failCount + 1).clamp(0, _maxFailCount);
    h.lastFailAt = _clock();
    _trim();
  }

  /// 综合分（越大越先试）。
  ///
  /// 取值设计：
  /// * 没测过 → 55（中性偏下，让实测可用的线路顶上来，但不至于让新线路永远排最后）；
  /// * 实测可用 → 100 - 延迟惩罚 - 失败惩罚 + 成功加成；
  /// * 可疑（连续失败）→ 再压 45，基本等于排到最后。
  double scoreOf(String url) {
    final h = _entries[url];
    if (h == null || !h.hasData) return 55;

    var score = 100.0;
    // 探测延迟惩罚：每 100ms 扣 1.5 分，最多扣 20。
    if (h.latencyMs > 0) {
      score -= (h.latencyMs / 100 * 1.5).clamp(0, 20);
    }
    // 起播延迟惩罚：3 秒以内不罚；之后每秒扣 6 分，最多扣 42。
    // 用户对「点下去多久出画面」最敏感，所以这一项权重最高。
    if (h.startupMs > 3000) {
      score -= ((h.startupMs - 3000) / 1000 * 6).clamp(0, 42);
    }
    // 失败惩罚：每次 12 分，最多 48。
    score -= (h.failCount * 12).clamp(0, 48).toDouble();
    // 成功加成：最多 +18，奖励「稳定」而不是「只成功过一次」。
    score += (h.okCount * 6).clamp(0, 18).toDouble();
    if (h.isFlaky) score -= 45;

    // **只探测过、从未真正起播**的线路，分数压到「已验证线路」之下。
    //
    // 这条限制是实测逼出来的：某个备用源探测只要 138ms（HTTP 回包极快），
    // 实际起播花了 17.3 秒——探测只看「第一个数据块到没到」，而用户等的是
    // 「拉 playlist → 拉首个分片 → 解码首帧」。没有起播数据就给它高分，
    // 结果是每次换线都优先选那条最慢的，用户体感「换了反而更卡」。
    if (h.startupMs == 0) score = score.clamp(0, 78);
    return score;
  }

  StreamHealth _entry(String url) =>
      _entries.putIfAbsent(url, () => StreamHealth());

  /// 超上限时丢最久没被碰过的记录（按最近成功/失败时间）。
  void _trim() {
    if (_entries.length <= maxEntries) return;
    final ordered = _entries.entries.toList()
      ..sort((a, b) {
        final ta = _touchedAt(a.value);
        final tb = _touchedAt(b.value);
        return ta.compareTo(tb);
      });
    final excess = _entries.length - maxEntries;
    for (var i = 0; i < excess; i++) {
      _entries.remove(ordered[i].key);
    }
  }

  static DateTime _touchedAt(StreamHealth h) {
    final ok = h.lastOkAt;
    final fail = h.lastFailAt;
    if (ok == null) return fail ?? DateTime.fromMillisecondsSinceEpoch(0);
    if (fail == null) return ok;
    return ok.isAfter(fail) ? ok : fail;
  }

  /// 导出为可落盘的 JSON（只保留有价值的数据，不写空记录）。
  String encode() {
    final map = <String, Object?>{
      for (final e in _entries.entries)
        if (e.value.hasData) e.key: e.value.toJson(),
    };
    return jsonEncode(<String, Object?>{
      'version': 1,
      'streams': map,
    });
  }

  /// 从落盘 JSON 恢复。**任何异常都当作「没有历史」**：
  /// 健康度只是优化项，不应该让一份坏文件挡住开播。
  void loadEncoded(String? text) {
    if (text == null || text.isEmpty) return;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      final streams = decoded['streams'];
      if (streams is! Map) return;
      for (final e in streams.entries) {
        final key = e.key;
        if (key is! String || key.isEmpty) continue;
        final h = StreamHealth.fromJson(e.value);
        if (h != null) _entries[key] = h;
      }
      _trim();
    } catch (_) {
      // 损坏文件直接忽略。
    }
  }
}
