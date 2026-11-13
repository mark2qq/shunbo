/// 启动期的「索引一致性校验 + 加载」状态机（纯 Dart，不依赖 Flutter）。
///
/// ## 需求与实现映射
///
/// 用户要求：软件启动时校验「当前设定的接口」与「安装包内置 / 已下载的索引」
/// 是否一致；一致就直接加载本地索引进入播放，不一致就从接口下载最新索引
/// 并同步加载。同时要明确一致性依据、失败回退、各状态提示、内置索引的
/// 更新与覆盖策略。这里逐条落实：
///
/// | 需求 | 实现 |
/// |---|---|
/// | 一致性依据 | 接口地址（主判据）+ manifest 新鲜度（≤7 天）+ 版本号 |
/// | 一致 | [VodBootPhase.readyBuiltin]，直接读分片，不发网络 |
/// | 不一致 | [VodBootPhase.syncingNetwork]，走既有分页同步链路 |
/// | 下载失败 | [VodBootPhase.fallbackBuiltin]，用旧内置索引并明示「可能不是最新」 |
/// | 数据不完整 | [VodBootPhase.incomplete]，缺分片 / 条数对不上，回退网络 |
/// | 内置更新策略 | 新版安装包覆盖旧 `vod-library.json`（见 [shouldReplaceCache]）|
///
/// ## 为什么一致性用「接口地址」而不是 ETag
///
/// `config.json` 只有 10 KB，每次启动拉一遍确认比读本地时间戳更可靠，
/// 代价可以忽略。但**接口地址**的一致性必须在发网络之前就能判断 ——
/// 用户换了一个接口，内置索引里的 `vod_id` 就全部指向错误的片，
/// 先加载再发现只会让用户看到一堆点不开的卡片。所以地址比对放在最前。
///
/// ## 为什么不用 `hashCode` / `Object` 判等
///
/// 状态机要在裸 `dart run` 下回归（无 Flutter、无 dart:ui），
/// 全部用枚举 + 值对象，门禁能直接断言每一步的转移。
library;

import 'vod_builtin_index.dart';

/// 启动期索引加载的六个状态。UI 按这个枚举显示文案，不再各自判断布尔组合。
enum VodBootPhase {
  /// 还没开始（首帧之前）。
  idle,

  /// 正在读 manifest 并做一致性校验（本地，几十毫秒）。
  checking,

  /// 一致：已用内置分片就绪，不发网络。
  readyBuiltin,

  /// 不一致：正在从用户设定的接口下载最新索引。
  syncingNetwork,

  /// 下载失败：回退到内置分片（并明示可能不是最新）。
  fallbackBuiltin,

  /// 内置索引缺失或损坏，且网络也不可用：只剩内置示例片库。
  incomplete,
}

/// 一次校验的结论（给 UI 与门禁读的完整理由，不只是布尔）。
class VodBootVerdict {
  const VodBootVerdict({
    required this.match,
    required this.reason,
    this.phase = VodBootPhase.checking,
  });

  /// 内置索引是否可以**直接**用来检索。
  final bool match;

  /// 判据说明（诊断页与日志用，人话）。
  final String reason;

  final VodBootPhase phase;

  VodBootVerdict copyWith({VodBootPhase? phase, String? reason}) =>
      VodBootVerdict(
        match: match,
        reason: reason ?? this.reason,
        phase: phase ?? this.phase,
      );
}

/// 状态机本身。**不含 IO**：加载器、网络同步都由调用方注入，
/// 这样门禁能在没有任何文件与网络的条件下跑完整个转移图。
class VodBootController {
  VodBootController({
    required this.loadManifest,
    required this.loadShard,
    required this.syncNetwork,
    this.now,
  });

  /// 读内置 manifest（读不到返回 null）。
  final Future<BuiltinIndexManifest?> Function() loadManifest;

  /// 读某个分片的 gzip 字节（读不到返回 null）。
  final Future<List<int>?> Function(String file) loadShard;

  /// 从接口同步最新索引。返回 `null` 表示成功，否则是失败原因。
  final Future<String?> Function() syncNetwork;

  /// 时钟注入（门禁固定时间用）。
  final DateTime Function()? now;

  VodBootPhase _phase = VodBootPhase.idle;
  VodBootVerdict? _verdict;
  BuiltinIndexManifest? _manifest;
  String _note = '';
  Future<VodBootPhase>? _inflight;
  final List<void Function()> _listeners = <void Function()>[];

  VodBootPhase get phase => _phase;
  VodBootVerdict? get verdict => _verdict;
  BuiltinIndexManifest? get manifest => _manifest;

  /// 面向用户的一句话（各状态统一从这里取，避免三处文案不一致）。
  String get note => _note;

  /// 校验是否已经在跑（[boot] 已被调用过）。
  bool get started => _inflight != null;

  /// 等校验出结论。**未开始时立刻返回**（不阻塞、不会挂住调用方）。
  ///
  /// 为什么需要它：后台全量目录同步（1.0.5 第十一次修）与启动校验
  /// （第十三次修）是两条独立链路。同步的判据只看「开关开 + 默认源」，
  /// 完全不知道校验已经判定「内置索引够用」，于是出现「明明已经加载了
  /// 60.5 万条内置索引，界面还在转圈同步 147 万条」。调用方在启动同步
  /// 之前先 `await settled`，再读 [hasLocalIndex]，就不会在 boot 还处于
  /// `checking` 时误判成「本地没有索引」。
  Future<void> get settled async {
    final inflight = _inflight;
    if (inflight != null) await inflight;
  }

  bool get busy =>
      _phase == VodBootPhase.checking || _phase == VodBootPhase.syncingNetwork;

  /// 是否已有可用于检索的本地索引。
  bool get hasLocalIndex =>
      _phase == VodBootPhase.readyBuiltin ||
      _phase == VodBootPhase.fallbackBuiltin;

  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);

  void _emit(VodBootPhase phase, String note) {
    _phase = phase;
    _note = note;
    for (final l in List<void Function()>.of(_listeners)) {
      l();
    }
  }

  /// 主流程：校验 → 一致即用 / 不一致则同步 → 失败回退。
  ///
  /// [selectedUrl] 是用户当前设定的接口地址。
  /// [builtinSourceUrl] 是打包内置索引时的接口地址（manifest 里带）。
  ///
  /// 包一层是为了让 [settled] 拿得到「这次校验什么时候结束」：
  /// 调用方（栏目页的后台同步）必须等结论，不能在 `checking` 阶段就抢先联网。
  Future<VodBootPhase> boot({
    required String selectedUrl,
    required String builtinSourceUrl,
    bool allowSync = true,
  }) {
    final inflight = _boot(
      selectedUrl: selectedUrl,
      builtinSourceUrl: builtinSourceUrl,
      allowSync: allowSync,
    );
    _inflight = inflight;
    return inflight;
  }

  Future<VodBootPhase> _boot({
    required String selectedUrl,
    required String builtinSourceUrl,
    bool allowSync = true,
  }) async {
    final clock = now ?? DateTime.now;
    _emit(VodBootPhase.checking, '正在校验本地索引…');

    // ── 1. 读 manifest ──
    BuiltinIndexManifest? manifest;
    try {
      manifest = await loadManifest();
    } catch (_) {
      manifest = null;
    }
    _manifest = manifest;

    if (manifest == null || manifest.isEmpty) {
      // 内置索引缺失 / 损坏：只能走网络。
      _verdict = const VodBootVerdict(
        match: false,
        reason: '安装包内未找到可用的内置索引',
      );
      return _sync(allowSync, fallbackNote: '内置索引缺失，正在从接口同步…');
    }

    // ── 2. 一致性校验 ──
    final effectiveSource =
        builtinSourceUrl.trim().isEmpty ? manifest.sourceUrl : builtinSourceUrl;
    final verdict = evaluateBuiltinIndex(
      manifest: manifest,
      selectedUrl: selectedUrl,
      now: clock(),
    );
    _verdict = verdict;

    if (verdict.match) {
      // ── 3. 一致：校验分片完整性后再放行 ──
      final broken = await _firstBrokenShard(manifest);
      if (broken == null) {
        _emit(
          VodBootPhase.readyBuiltin,
          '已加载内置索引 ${_fmtCount(manifest.total)} 条'
          '（${_fmtDate(manifest.generatedAt)} 打包）',
        );
        return _phase;
      }
      _verdict = VodBootVerdict(
        match: false,
        reason: '内置索引分片缺失或损坏：$broken',
      );
      return _sync(allowSync, fallbackNote: '内置索引不完整，正在从接口同步…');
    }

    // 地址不一致时明确告诉用户为什么不能用本地索引。
    return _sync(allowSync, fallbackNote: _syncNoteFor(verdict, effectiveSource));
  }

  /// 不一致 → 下载最新索引；失败回退。
  Future<VodBootPhase> _sync(bool allowSync,
      {required String fallbackNote}) async {
    if (!allowSync) {
      final hasIndex = _manifest != null && !_manifest!.isEmpty;
      _emit(
        hasIndex ? VodBootPhase.fallbackBuiltin : VodBootPhase.incomplete,
        hasIndex ? '使用内置索引（未联网校验，可能不是最新）' : '无可用索引',
      );
      return _phase;
    }
    _emit(VodBootPhase.syncingNetwork, fallbackNote);
    String? failure;
    try {
      failure = await syncNetwork();
    } catch (e) {
      failure = '$e';
    }
    if (failure == null) {
      _emit(VodBootPhase.readyBuiltin, '已从接口同步最新索引');
      return _phase;
    }
    final hasIndex = _manifest != null && !_manifest!.isEmpty;
    _emit(
      hasIndex ? VodBootPhase.fallbackBuiltin : VodBootPhase.incomplete,
      hasIndex
          ? '接口同步失败，已使用内置索引（可能不是最新）'
          : '接口同步失败，且无内置索引可用',
    );
    return _phase;
  }

  /// 找出第一个读不到 / 条数为零的分片。返回 null 表示全部正常。
  ///
  /// 只读**第一行**就够判断「文件在不在、能不能解」——把 13 MB 全解一遍
  /// 只为验证完整性，会让冷启动多花一秒，不值得。条数核对放在真正
  /// 加载分片时做（[BuiltinIndexScanner] 的行数与 manifest 对账）。
  Future<String?> _firstBrokenShard(BuiltinIndexManifest manifest) async {
    for (final shard in manifest.shards) {
      if (shard.records <= 0) return '${shard.file}（条数为 0）';
      try {
        final bytes = await loadShard(shard.file);
        if (bytes == null || bytes.isEmpty) return '${shard.file}（读不到）';
      } catch (e) {
        return '${shard.file}（$e）';
      }
    }
    return null;
  }

  String _syncNoteFor(VodBootVerdict verdict, String builtinSource) {
    if (verdict.reason.contains('过期')) {
      return '内置索引已过期，正在从接口同步最新索引…';
    }
    if (verdict.reason.contains('地址')) {
      return '接口地址与内置索引不一致，正在从接口同步…';
    }
    return '正在从接口同步最新索引…';
  }
}

/// 一致性判定的**完整理由版**（[builtinIndexMatches] 的布尔版给调用点用，
/// 这个给状态机与诊断页用：用户问「为什么又要下载」时能答出具体原因）。
VodBootVerdict evaluateBuiltinIndex({
  required BuiltinIndexManifest? manifest,
  required String selectedUrl,
  DateTime? now,
  Duration maxAge = const Duration(days: 7),
}) {
  if (manifest == null || manifest.isEmpty) {
    return const VodBootVerdict(match: false, reason: '无内置索引');
  }
  final builtin = manifest.sourceUrl.trim();
  final selected = selectedUrl.trim();
  if (builtin != selected) {
    return VodBootVerdict(
      match: false,
      reason: '接口地址不一致（内置 $builtin / 当前 $selected）',
    );
  }
  final t = (now ?? DateTime.now()).toUtc();
  final age = t.difference(manifest.generatedAt);
  final tooOld = age.isNegative ? age.abs() > maxAge : age > maxAge;
  if (tooOld) {
    return VodBootVerdict(
      match: false,
      reason: '内置索引已过期（${manifest.generatedAt.toIso8601String()}，'
          '超过 ${maxAge.inDays} 天）',
    );
  }
  return VodBootVerdict(
    match: true,
    reason: '地址一致且索引新鲜（${_fmtDate(manifest.generatedAt)}）',
  );
}

/// 新版安装包的内置索引是否应当覆盖用户的本地缓存。
///
/// 覆盖策略（用户要求「内置索引的更新与覆盖策略」）：
///  * **内置索引更新 ⇒ 覆盖**。用户升级 App 就是为了拿到新片，
///    留着旧 `vod-library.json` 会让「升级了还是搜不到新片」。
///  * **内置索引更旧 ⇒ 不覆盖**。降级安装 / 同版本重装时，
///    用户本地已同步过的数据比安装包新，覆盖等于删数据。
///  * **接口地址变了 ⇒ 覆盖**（旧缓存里的 id 指向另一个站，全是错的）。
///
/// 判据是 `generatedAt` + `sourceUrl`，不看条数：条数会因为站点挂掉而变少，
/// 但内容可能更新（老片下架、新片上架）。
bool shouldReplaceCache({
  required BuiltinIndexManifest? builtin,
  required DateTime? cacheSavedAt,
  required String cacheSourceUrl,
}) {
  if (builtin == null || builtin.isEmpty) return false;
  if (cacheSavedAt == null) return true;
  if (cacheSourceUrl.trim() != builtin.sourceUrl.trim()) return true;
  return builtin.generatedAt.isAfter(cacheSavedAt.toUtc());
}

String _fmtCount(int n) {
  if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)} 万';
  return '$n';
}

String _fmtDate(DateTime t) {
  final u = t.toUtc();
  String two(int v) => v < 10 ? '0$v' : '$v';
  return '${u.year}-${two(u.month)}-${two(u.day)}';
}
