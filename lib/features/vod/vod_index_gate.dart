/// 进入点播时的「片源索引目录校验 + 分支加载」状态机（纯 Dart，无 Flutter、无 IO）。
///
/// ## 需求与实现映射（1.0.5 第十六次修）
///
/// | 需求 | 实现 |
/// |---|---|
/// | 进入点播先检查「已保存索引是否有有效片源」 | [VodIndexSnapshot.valid]：`total > 0` 且 `sourceUrl` 非空 |
/// | 再检查「索引是否与当前设定的接口匹配」 | [evaluateVodIndexGate] 逐字比对 `sourceUrl` |
/// | 匹配且有效 ⇒ 直接把索引片源加载到播放列表 | [VodIndexGatePhase.ready] + [VodIndexGateVerdict.origin] |
/// | 索引片源缺失 / 接口未设定 / 地址不匹配 ⇒ 进入接口输入流程 | 三个分支各自给出不同的 [VodIndexGateVerdict.reason]，统一落 `needAddress` |
/// | 初次使用且未设定接口必须弹输入页 | `configured == false` 或 `selectedUrl` 为空 ⇒ `needAddress`；UI 见状态即弹 |
/// | 提交地址后，已有索引且记录地址一致 ⇒ 直接加载 | [decideVodIndexSubmit] 返回 `loadExisting` |
/// | 否则 ⇒ 按地址重新获取片源并生成新索引目录文件 | 返回 `rebuild`，[VodIndexGateController.rebuild] 落盘后重新校验 |
/// | 各分支加载来源唯一 | [VodIndexGateVerdict.origin] 是**单值枚举**，`needAddress/building/failed` 恒为 null |
/// | 播放列表内容与最终采用的索引一致 | UI 只用 `origin` 对应的那一份取数；状态离开 `ready` 即清空列表 |
///
/// ## 为什么与 [VodBootController] 分开
///
/// `vodBoot` 是**启动期**校验，回答「这份内置索引能不能拿来检索」；
/// 本状态机是**进入点播时**校验，回答「播放列表该用哪一份索引的片源」。
/// 两者判据不同（前者还有 7 天新鲜度与分片完整性），产物也不同（前者只置状态，
/// 后者决定列表数据源）。混在一起会让「明明已加载内置索引，列表却还是空的」。
library;

import 'dart:async';

import 'vod_build_progress.dart';

/// 一次「按新接口生成索引」的**硬截止时间**（第二十六次修）。
///
/// 用户红标：「无法获取时会一直闪……不能死循环」。生成过程本身在
/// [VodSession] 里有 90 秒预算，但预算是**按批检查**的：某一次
/// `pager.next()` 卡住时，整轮就会越过预算继续等。这里再加一道
/// 与具体实现无关的外层闸门 —— 到点一律判失败并给出可读理由，
/// 界面绝不允许永远停在「正在获取…」。
const Duration kVodIndexBuildDeadline = Duration(minutes: 3);

/// 片源索引目录的来源。**同一刻只能有一个生效**：
/// 播放列表绝不允许把两份索引的片源拼在一起 —— 那会让「地址不一致」时
/// 旧索引的 `vod_id` 混进新接口的列表，点了必然回源失败。
enum VodIndexOrigin {
  /// 随包分发的默认索引目录（`assets/vod_index/manifest.json` + 6 个分片）。
  /// 它的处理规则是「按栏目分片、流式扫描、点开再回源」。
  builtin,

  /// 用户填写新接口后按同一套规则生成、落在数据目录的索引目录
  /// （`vod-index.json`）。条目自带播放地址，点开即播。
  generated,
}

/// 进入点播后的五个状态。UI 只按这个枚举渲染，不自己拼布尔组合。
enum VodIndexGatePhase {
  /// 正在读设定与两份索引目录的清单（本地，几十毫秒）。
  checking,

  /// 校验通过：播放列表已由 [VodIndexGateVerdict.origin] 指定的唯一索引填充。
  ready,

  /// 校验不通过：需要用户进入片源接口输入流程。
  /// 细分理由见 [VodIndexGateVerdict.reason]（未设定 / 索引缺失 / 地址不匹配）。
  needAddress,

  /// 用户提交了新地址，且没有可复用的索引：正在按该地址获取片源并生成目录文件。
  building,

  /// 生成失败（接口不可达 / 没返回可播条目 / 写盘失败）。留在输入流程可重试。
  failed,
}

/// 一份索引目录的**清单摘要**。只用来判「有没有片源、记的是哪个接口」，
/// 不把几十万条读进内存 —— 真机 API18 / armv7a 撑不住。
class VodIndexSnapshot {
  const VodIndexSnapshot({
    required this.origin,
    required this.sourceUrl,
    required this.total,
    this.generatedAt,
  });

  final VodIndexOrigin origin;

  /// 这份目录记录的制作接口地址。与当前设定不一致 ⇒ 里面的 id 指向别的站。
  final String sourceUrl;

  /// 有效片源条数。
  final int total;

  final DateTime? generatedAt;

  /// 「存在有效片源」的判据：既要条数 > 0，也要记录着接口地址。
  /// 缺地址的历史文件不能算有效 —— 否则它会被当成「和任何地址都匹配」。
  bool get valid => total > 0 && sourceUrl.trim().isNotEmpty;

  bool matches(String selectedUrl) =>
      valid && sourceUrl.trim() == selectedUrl.trim();
}

/// 当前用户设定的接口。**configured 与 selectedUrl 是两件事**：
/// 用户可能进过设置页、保存过一次「内置片库（空地址）」，那不算设定了接口。
class VodIndexSettings {
  const VodIndexSettings({
    required this.configured,
    required this.selectedUrl,
    this.allowInsecureHttp = false,
    this.allowExternalCode = true,
  });

  /// 是否曾经显式保存过接口设定（首次使用为 false）。
  final bool configured;

  /// 当前设定的接口地址；空串表示「内置片库」，等同于**未设定接口**。
  final String selectedUrl;

  final bool allowInsecureHttp;
  final bool allowExternalCode;

  bool get hasAddress => configured && selectedUrl.trim().isNotEmpty;
}

/// 一次校验的完整结论。给 UI 与门禁读的不只是布尔，还有「为什么」。
class VodIndexGateVerdict {
  const VodIndexGateVerdict({
    required this.phase,
    required this.reason,
    required this.note,
    this.origin,
    this.total = 0,
  });

  final VodIndexGatePhase phase;

  /// 唯一生效的索引来源。`ready` 时**必须**非 null，其余状态**必须**为 null。
  /// 这条不变式由门禁断言锁住，是「加载来源唯一」的落点。
  final VodIndexOrigin? origin;

  /// 判据说明（诊断页 / 日志用，人话）。
  final String reason;

  /// 面向用户的一句话（各状态统一从这里取）。
  final String note;

  /// ready 时采用的索引总条数（文案与状态行用）。
  final int total;

  bool get ready => phase == VodIndexGatePhase.ready && origin != null;
  bool get needsAddress => phase == VodIndexGatePhase.needAddress;
}

/// 纯函数：进入点播时的三分支判定。
///
/// 顺序不可换：
///  1. **接口未设定** —— 离线就能判，且「初次使用必须弹输入页」由它保证；
///  2. **生成目录匹配** —— 用户最近按某个地址生成过，优先用它（比内置新）；
///  3. **内置目录匹配** —— 默认索引，打包时固化；
///  4. 其余统一 `needAddress`，但 reason 要区分「索引缺失」与「地址不匹配」，
///     否则用户不知道该重填地址还是该等它重新生成。
VodIndexGateVerdict evaluateVodIndexGate({
  required bool configured,
  required String selectedUrl,
  VodIndexSnapshot? builtin,
  VodIndexSnapshot? generated,
}) {
  final selected = selectedUrl.trim();
  if (!configured || selected.isEmpty) {
    return const VodIndexGateVerdict(
      phase: VodIndexGatePhase.needAddress,
      reason: '尚未设定片源接口（初次使用）',
      note: '首次使用：请先设定片源接口地址',
    );
  }
  if (generated != null && generated.matches(selected)) {
    return VodIndexGateVerdict(
      phase: VodIndexGatePhase.ready,
      origin: VodIndexOrigin.generated,
      total: generated.total,
      reason: '本地片源索引目录有效且记录的接口地址与当前设定一致',
      note: '已加载本地片源索引目录 ${_fmtCount(generated.total)}条'
          '（${_fmtDate(generated.generatedAt)} 生成）',
    );
  }
  if (builtin != null && builtin.matches(selected)) {
    return VodIndexGateVerdict(
      phase: VodIndexGatePhase.ready,
      origin: VodIndexOrigin.builtin,
      total: builtin.total,
      reason: '内置片源索引目录有效且记录的接口地址与当前设定一致',
      note: '已加载内置片源索引目录 ${_fmtCount(builtin.total)}条'
          '（${_fmtDate(builtin.generatedAt)} 打包）',
    );
  }
  final hasAnyValid = (generated?.valid ?? false) || (builtin?.valid ?? false);
  if (!hasAnyValid) {
    return const VodIndexGateVerdict(
      phase: VodIndexGatePhase.needAddress,
      reason: '片源索引目录缺失或不含有效片源',
      note: '未找到含有效片源的索引目录，请设定接口地址以生成',
    );
  }
  return const VodIndexGateVerdict(
    phase: VodIndexGatePhase.needAddress,
    reason: '索引目录记录的接口地址与当前设定不一致',
    note: '索引目录与当前接口不匹配，请确认地址或重新获取片源',
  );
}

/// 提交接口地址后的两种动作。
enum VodIndexSubmitAction {
  /// 已有索引且记录的接口地址与填写地址一致 ⇒ 直接加载，不发网络。
  loadExisting,

  /// 地址不一致 / 没有可用索引 ⇒ 按填写地址重新获取片源并生成新目录文件。
  rebuild,
}

class VodIndexSubmitPlan {
  const VodIndexSubmitPlan({
    required this.action,
    required this.reason,
    this.origin,
  });

  final VodIndexSubmitAction action;

  /// `loadExisting` 时指明用哪一份（仍然只有一个来源）。
  final VodIndexOrigin? origin;

  final String reason;
}

/// 纯函数：用户提交地址后走哪条分支。
///
/// 与 [evaluateVodIndexGate] 的差别：这里**不要求 configured**，
/// 因为提交动作本身就会把「已设定」写进配置；判据只看「地址对不对得上」。
/// 这正是需求里「若已存在片源索引目录且其记录的接口地址与填写地址一致，
/// 则直接加载已有索引片源」的落点 —— 初次使用填了默认源地址，就能秒开内置索引，
/// 不需要重新抓一遍 147 万条。
VodIndexSubmitPlan decideVodIndexSubmit({
  required String submittedUrl,
  VodIndexSnapshot? builtin,
  VodIndexSnapshot? generated,
}) {
  final url = submittedUrl.trim();
  if (url.isEmpty) {
    return const VodIndexSubmitPlan(
      action: VodIndexSubmitAction.loadExisting,
      reason: '未填写接口地址，不生成新索引',
    );
  }
  if (generated != null && generated.matches(url)) {
    return const VodIndexSubmitPlan(
      action: VodIndexSubmitAction.loadExisting,
      origin: VodIndexOrigin.generated,
      reason: '本地索引目录记录的接口与填写地址一致，直接加载',
    );
  }
  if (builtin != null && builtin.matches(url)) {
    return const VodIndexSubmitPlan(
      action: VodIndexSubmitAction.loadExisting,
      origin: VodIndexOrigin.builtin,
      reason: '内置索引目录记录的接口与填写地址一致，直接加载',
    );
  }
  return const VodIndexSubmitPlan(
    action: VodIndexSubmitAction.rebuild,
    reason: '没有地址一致的索引目录，按填写地址重新获取片源并生成新目录',
  );
}

/// 控制器：把纯判定接到真实 IO 上。**自身不发网络、不读文件**，
/// 全部由装配层注入，因此门禁能裸 `dart run` 跑完整转移图。
class VodIndexGateController {
  VodIndexGateController({
    required this.readSettings,
    required this.readBuiltin,
    required this.readGenerated,
    required this.saveSettings,
    required this.rebuild,
  });

  final Future<VodIndexSettings> Function() readSettings;
  final Future<VodIndexSnapshot?> Function() readBuiltin;
  final Future<VodIndexSnapshot?> Function() readGenerated;

  /// 把用户填写的地址落进配置（含「已设定」标记，之后不再弹首次输入页）。
  final Future<void> Function(String url, bool allowInsecureHttp) saveSettings;

  /// 按地址获取片源并生成新的索引目录文件。返回 null 表示成功，否则失败原因。
  ///
  /// 生成的新文件沿用默认索引目录的处理规则：同 version / sourceUrl /
  /// generatedAt / total / 按栏目分节，后续进入由 [readGenerated] 读回并加载。
  ///
  /// 第三个参数是「允许执行外部代码」的当前设定：由 [readSettings] 透传，
  /// 不能在装配层硬编码 true —— 那会让用户在设置页关掉的开关被悄悄打开。
  final Future<String?> Function(
      String url, bool allowInsecureHttp, bool allowExternalCode) rebuild;

  VodIndexGateVerdict _state = const VodIndexGateVerdict(
    phase: VodIndexGatePhase.checking,
    reason: '尚未校验',
    note: '正在校验片源索引目录…',
  );
  final List<void Function()> _listeners = <void Function()>[];
  Future<VodIndexGateVerdict>? _inflight;

  VodIndexGateVerdict get state => _state;
  VodIndexGatePhase get phase => _state.phase;

  /// 唯一生效的索引来源；非 ready 恒为 null。
  VodIndexOrigin? get activeOrigin => _state.origin;

  bool get ready => _state.ready;
  bool get busy =>
      _state.phase == VodIndexGatePhase.checking ||
      _state.phase == VodIndexGatePhase.building;

  /// 最后一次校验/提交用的接口地址（诊断页与 UI 预填用）。
  String _lastUrl = '';
  String get lastUrl => _lastUrl;

  /// 正在生成新接口索引时的进度（第二十六次修）。
  ///
  /// 只有 `_submit` 走到 `rebuild` 期间非 null，其余时刻一律 null ——
  /// 「有没有进度」由这一个字段回答，UI 不需要再拼 phase + 布尔。
  VodBuildProgress? _buildProgress;
  VodBuildProgress? get buildProgress => _buildProgress;

  /// 由 `rebuild` 的实现（装配层）在上报进度时调用。
  ///
  /// **构建已经结束就丢弃**：超时之后底层可能还会继续跑一会儿并回报进度，
  /// 那些数字属于一次用户已经看不到的构建，绝不能把界面从「失败」拉回
  /// 「正在获取 87%」。
  void reportBuildProgress(VodBuildProgress progress) {
    if (_buildProgress == null) return;
    if (_buildProgress == progress) return;
    _buildProgress = progress;
    for (final l in List<void Function()>.of(_listeners)) {
      l();
    }
  }

  /// 当前采用的那份索引目录的 `generatedAt`（UTC ISO8601）。
  ///
  /// 第十七次修新增：海报缓存与筛选条件目录都要按「目录身份」隔离，
  /// 而这个时间戳是唯一能区分「同一地址、同一条数、但目录被重新生成过」的
  /// 信号。只放在控制器里、由 `_check()` 统一写入，六个栏目页读到的是
  /// **同一个值**，不会各自算出不同 scope 互相清缓存。
  String _directoryStamp = '';
  String get directoryStamp => _directoryStamp;

  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);

  void _emit(VodIndexGateVerdict next) {
    _state = next;
    for (final l in List<void Function()>.of(_listeners)) {
      l();
    }
  }

  /// 等当前校验/提交结束。未开始时立刻返回，不挂住调用方。
  Future<void> get settled async {
    final inflight = _inflight;
    if (inflight != null) await inflight;
  }

  /// 进入点播：读设定 + 两份目录清单 → 判定分支。
  Future<VodIndexGateVerdict> check() {
    final task = _check();
    _inflight = task;
    return task;
  }

  Future<VodIndexGateVerdict> _check() async {
    _directoryStamp = '';
    _emit(const VodIndexGateVerdict(
      phase: VodIndexGatePhase.checking,
      reason: '正在读取索引目录清单',
      note: '正在校验片源索引目录…',
    ));
    VodIndexSettings settings;
    VodIndexSnapshot? builtin;
    VodIndexSnapshot? generated;
    try {
      settings = await readSettings();
      builtin = await readBuiltin();
      generated = await readGenerated();
    } catch (e) {
      _emit(VodIndexGateVerdict(
        phase: VodIndexGatePhase.failed,
        reason: '读取索引目录失败：$e',
        note: '读取索引目录失败，请重试或重新设定接口',
      ));
      return _state;
    }
    _lastUrl = settings.selectedUrl;
    final verdict = evaluateVodIndexGate(
      configured: settings.configured,
      selectedUrl: settings.selectedUrl,
      builtin: builtin,
      generated: generated,
    );
    _directoryStamp = verdict.origin == VodIndexOrigin.generated
        ? (generated?.generatedAt?.toUtc().toIso8601String() ?? '')
        : verdict.origin == VodIndexOrigin.builtin
            ? (builtin?.generatedAt?.toUtc().toIso8601String() ?? '')
            : '';
    _emit(verdict);
    return _state;
  }

  /// 用户提交接口地址：落配置 → 判「直接加载」或「重新生成」→ 重新校验。
  Future<VodIndexGateVerdict> submit(
    String rawUrl, {
    required bool allowInsecureHttp,
  }) {
    final task = _submit(rawUrl, allowInsecureHttp: allowInsecureHttp);
    _inflight = task;
    return task;
  }

  Future<VodIndexGateVerdict> _submit(
    String rawUrl, {
    required bool allowInsecureHttp,
  }) async {
    final url = rawUrl.trim();
    if (url.isEmpty) {
      _emit(const VodIndexGateVerdict(
        phase: VodIndexGatePhase.needAddress,
        reason: '接口地址为空',
        note: '请填写片源接口地址',
      ));
      return _state;
    }
    try {
      await saveSettings(url, allowInsecureHttp);
    } catch (e) {
      _emit(VodIndexGateVerdict(
        phase: VodIndexGatePhase.failed,
        reason: '保存接口设定失败：$e',
        note: '接口设定保存失败，请重试',
      ));
      return _state;
    }
    _lastUrl = url;
    final builtin = await readBuiltin();
    final generated = await readGenerated();
    final plan = decideVodIndexSubmit(
      submittedUrl: url,
      builtin: builtin,
      generated: generated,
    );
    if (plan.action == VodIndexSubmitAction.loadExisting) {
      // 直接采用已有索引：重新跑一次完整校验，保证 verdict.origin 与
      // 「刚提交的地址」一致，而不是拿 submit 里的临时结论硬塞给 UI。
      return _check();
    }
    _emit(VodIndexGateVerdict(
      phase: VodIndexGatePhase.building,
      reason: plan.reason,
      note: '正在按新接口获取片源并生成索引目录…',
    ));
    String? failure;
    // 第二十六次修：进度从此刻开始上报，`finally` 里一定清掉 ——
    // 无论成功、失败还是超时，界面都不该停在一条永远不动的进度条上。
    _buildProgress = const VodBuildProgress.connecting();
    try {
      final current = await readSettings();
      // 先把回包**规范化**成 `Future<String?>`：某个实现若只 `return null`，
      // 它的运行时泛型是 `Future<Null>`，而 `Future.timeout` 在 VM 里是按
      // 接收者的运行时类型参数做检查的 —— `onTimeout` 返回 String 会被判
      // 「不是 FutureOr<Null> Function()」直接抛 TypeError。`then<String?>`
      // 生成的新 Future 运行时泛型是对的，与实现怎么写无关。
      final Future<String?> building = rebuild(
        url,
        allowInsecureHttp,
        current.allowExternalCode,
      ).then<String?>((v) => v);
      failure = await building.timeout(
        kVodIndexBuildDeadline,
        onTimeout: () => '获取超时：超过 ${kVodIndexBuildDeadline.inSeconds} 秒仍未取到'
            '可播片源，已中止本次生成（未写入目录）',
      );
    } catch (e) {
      failure = '$e';
    } finally {
      _buildProgress = null;
    }
    if (failure != null) {
      _emit(VodIndexGateVerdict(
        phase: VodIndexGatePhase.failed,
        reason: failure,
        note: '片源获取失败：$failure，可改地址或重试',
      ));
      return _state;
    }
    return _check();
  }
}

String _fmtCount(int n) {
  if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)} 万';
  return '$n';
}

String _fmtDate(DateTime? t) {
  if (t == null) return '时间未知';
  final u = t.toUtc();
  String two(int v) => v < 10 ? '0$v' : '$v';
  return '${u.year}-${two(u.month)}-${two(u.day)}';
}
