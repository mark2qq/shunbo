/// 运行时版本兼容分支（启动引导层的**单一事实来源**）。
///
/// ── 三个必须先说清楚的定义 ──────────────────────────────────────────────
/// 1. **被比较的版本对象**：设备 Android API 等级 `Build.VERSION.SDK_INT`
///    （整数）。**不是**应用版本 1.0.0、**不是** `Build.VERSION.RELEASE`
///    展示字符串（如「4.3」）、**不是**厂商 UI 版本（eUI 8.0）。
///    理由：乐视 S50 Air 实测 API 18 / Android 4.3，而顺播 1.0.0 基于
///    Flutter 3.47，引擎 AAR 与 Java 层的下限是 minSdk 24（Android 7.0）。
///    决定「能否加载」的是 SDK_INT，其余三个都不是门槛，混用会产生
///    「9 > 10」这类字符串比较误判。
/// 2. **低版本阈值**：[kMinSupportedAndroidApi] = 24，判定用严格 `<`。
///    `sdk < 24` → [RuntimeBranch.legacyCompat]；`sdk >= 24` →
///    [RuntimeBranch.defaultFlow]。边界：23 进兼容、24 走默认、25 走默认。
/// 3. **兼容分支范围**：只覆盖「启动引导 + 能力探测 + 交付判定」三处：
///    版本读数、分支决策、原生精确网络回调的开关、诊断与设置页可观测性，
///    以及 minSdk 16 原生自检入口的分支显示。**不触碰**播放内核选择、
///    换源调度、投屏、续播同步、UI 布局、数据格式、清单/签名/版本号/产物。
///    兼容分支停用的是「API 24+ 专属增强能力」，播放主链路逐字不变，
///    因此检测失败时走保守分支也不会造成误降级。
///
/// ── 检测失败 / 缺失 ────────────────────────────────────────────────────
/// Android 上探测异常、字段缺失、值非法 → 一律进兼容分支并置 `degraded`，
/// 绝不静默当「满足要求」（保守侧）。非 Android 平台该版本对象**不适用**，
/// 无论读数是什么都返回默认流程，保证 Windows / 桌面 / 纯 Dart 工具链逐字不变。
///
/// ── 分支切换 ──────────────────────────────────────────────────────────
/// 决策只在启动时做一次并锁存（[CompatBranchSelector]），运行期不再切换，
/// 避免中途翻转导致「一半组件走新分支、一半走旧分支」的状态撕裂。
///
/// 纯 Dart：不 import flutter / dart:ui，可用 `dart run` 精确回归时序与边界。
library;

/// 被比较的版本对象（诊断展示用，不参与比较）。
const String kVersionCompatSubject = 'Android API 等级（Build.VERSION.SDK_INT）';

/// 低版本阈值：Flutter 3.47 引擎 AAR 下限 = minSdk 24（Android 7.0）。
const int kMinSupportedAndroidApi = 24;

/// 合理取值区间；越界视为探测数据损坏，而不是「一个很大的新版本」。
const int kMinPlausibleApi = 1;
const int kMaxPlausibleApi = 1000;

/// 运行分支。
enum RuntimeBranch {
  /// 版本满足要求（或非 Android 不适用）：现有启动装配与全部功能不变。
  defaultFlow,

  /// 低版本 / 探测失败：停用 API 24+ 专属增强能力，走既有兜底实现。
  legacyCompat,
}

extension RuntimeBranchLabel on RuntimeBranch {
  String get label => switch (this) {
        RuntimeBranch.defaultFlow => '默认流程',
        RuntimeBranch.legacyCompat => '兼容分支',
      };

  String get name => switch (this) {
        RuntimeBranch.defaultFlow => 'defaultFlow',
        RuntimeBranch.legacyCompat => 'legacyCompat',
      };
}

/// 判定依据（写进诊断，便于用户报障时直接复制）。
enum CompatReason {
  meetsRequirement,
  belowThreshold,
  notApplicable,
  probeFailed,
  missingVersion,
  invalidVersion,
}

extension CompatReasonLabel on CompatReason {
  String get name => switch (this) {
        CompatReason.meetsRequirement => 'meetsRequirement',
        CompatReason.belowThreshold => 'belowThreshold',
        CompatReason.notApplicable => 'notApplicable',
        CompatReason.probeFailed => 'probeFailed',
        CompatReason.missingVersion => 'missingVersion',
        CompatReason.invalidVersion => 'invalidVersion',
      };

  String get label => switch (this) {
        CompatReason.meetsRequirement => '版本满足要求（API ≥ 24），保持默认流程',
        CompatReason.belowThreshold => '设备 API < 24，进入兼容分支',
        CompatReason.notApplicable => '非 Android 平台，版本对象不适用，保持默认流程',
        CompatReason.probeFailed => '版本探测失败，按保守策略进入兼容分支',
        CompatReason.missingVersion => '版本信息缺失，按保守策略进入兼容分支',
        CompatReason.invalidVersion => '版本信息非法，按保守策略进入兼容分支',
      };
}

/// 一次决策的结果，不可变。启动后全程复用同一个实例。
class CompatDecision {
  const CompatDecision({
    required this.branch,
    required this.reason,
    required this.apiLevel,
    required this.degraded,
    required this.release,
  });

  final RuntimeBranch branch;
  final CompatReason reason;

  /// 解析成功的 API 等级；缺失/非法为 null。
  final int? apiLevel;

  /// true 表示「因探测失败而降级」，与「确知是低版本」区分开。
  final bool degraded;

  /// `Build.VERSION.RELEASE`，**仅展示**，绝不参与比较。
  final String release;

  bool get isLegacyCompat => branch == RuntimeBranch.legacyCompat;
  bool get isDefaultFlow => branch == RuntimeBranch.defaultFlow;

  /// 设置页 / 日志用的可读摘要。
  String diagnosticText() =>
      '运行分支：${branch.label}（${branch.name}）\n'
      '判定依据：${reason.label}\n'
      '比较对象：$kVersionCompatSubject\n'
      '低版本阈值：API < $kMinSupportedAndroidApi 进兼容分支，≥ 阈值走默认流程\n'
      '实测 API：${apiLevel ?? '未知'}\n'
      '系统版本字符串：${release.isEmpty ? '未知' : release}（仅展示，不参与比较）'
      '${degraded ? '\n检测状态：降级（探测未成功）' : ''}';

  Map<String, Object?> toMap() => <String, Object?>{
        'branch': branch.name,
        'reason': reason.name,
        'subject': kVersionCompatSubject,
        'threshold': kMinSupportedAndroidApi,
        'apiLevel': apiLevel,
        'degraded': degraded,
        'release': release,
      };

  @override
  bool operator ==(Object other) =>
      other is CompatDecision &&
      other.branch == branch &&
      other.reason == reason &&
      other.apiLevel == apiLevel &&
      other.degraded == degraded &&
      other.release == release;

  @override
  int get hashCode => Object.hash(branch, reason, apiLevel, degraded, release);

  @override
  String toString() => 'CompatDecision(${branch.name}, ${reason.name}, '
      'api=$apiLevel, degraded=$degraded)';
}

/// 版本比较 / 分支决策的全部规则。
class VersionCompatPolicy {
  const VersionCompatPolicy._();

  /// 把平台通道回传的原始值收敛成整数 API 等级。
  ///
  /// 严格拒绝：null、bool、非整数小数、负数、0、越界值、非纯数字字符串、
  /// 集合/Map，以及 `"4.3"` / `"1.0.0"` / `"18.0"` 这类**展示字符串**。
  /// 接受：`18`、`18.0`（double 整数值）、`" 18 "`、`"018"`。
  /// 任何不确定都返回 null，交给 [decide] 走保守分支。
  static int? parseApiLevel(Object? raw) {
    if (raw == null || raw is bool) return null;
    int? value;
    if (raw is int) {
      value = raw;
    } else if (raw is double) {
      if (!raw.isFinite || raw != raw.roundToDouble()) return null;
      value = raw.toInt();
    } else if (raw is String) {
      final text = raw.trim();
      if (text.isEmpty || !RegExp(r'^\d+$').hasMatch(text)) return null;
      value = int.tryParse(text);
    } else {
      return null;
    }
    if (value == null) return null;
    if (value < kMinPlausibleApi || value > kMaxPlausibleApi) return null;
    return value;
  }

  /// 唯一比较入口：**整数**与阈值相减，绝不做字符串比较。
  /// 负数=低于阈值，0=边界（满足），正数=高于阈值。
  static int compareToThreshold(int apiLevel) =>
      apiLevel - kMinSupportedAndroidApi;

  /// 运行时自动判定。
  ///
  /// - [isAndroid] 为 false：版本对象不适用 → 默认流程（不降级）。
  /// - [probeOk] 为 false：探测失败 → 兼容分支 + `degraded`（保守）。
  /// - [sdkInt] 缺失 / 非法 → 兼容分支 + `degraded`（保守）。
  /// - [sdkInt] < 24 → 兼容分支（确知低版本，不算降级）。
  /// - [sdkInt] ≥ 24 → 默认流程，与改动前逐字一致。
  ///
  /// [release] 只进诊断文本，不参与任何判定。
  static CompatDecision decide({
    required bool isAndroid,
    Object? sdkInt,
    bool probeOk = true,
    String? release,
  }) {
    final shownRelease = release ?? '';
    if (!isAndroid) {
      return CompatDecision(
        branch: RuntimeBranch.defaultFlow,
        reason: CompatReason.notApplicable,
        apiLevel: parseApiLevel(sdkInt),
        degraded: false,
        release: shownRelease,
      );
    }
    if (!probeOk) {
      return CompatDecision(
        branch: RuntimeBranch.legacyCompat,
        reason: CompatReason.probeFailed,
        apiLevel: parseApiLevel(sdkInt),
        degraded: true,
        release: shownRelease,
      );
    }
    final parsed = parseApiLevel(sdkInt);
    if (parsed == null) {
      return CompatDecision(
        branch: RuntimeBranch.legacyCompat,
        reason: sdkInt == null
            ? CompatReason.missingVersion
            : CompatReason.invalidVersion,
        apiLevel: null,
        degraded: true,
        release: shownRelease,
      );
    }
    final branch = compareToThreshold(parsed) < 0
        ? RuntimeBranch.legacyCompat
        : RuntimeBranch.defaultFlow;
    return CompatDecision(
      branch: branch,
      reason: branch == RuntimeBranch.legacyCompat
          ? CompatReason.belowThreshold
          : CompatReason.meetsRequirement,
      apiLevel: parsed,
      degraded: false,
      release: shownRelease,
    );
  }
}

/// 分支锁：启动期只选一次，之后的重复调用一律幂等返回首个决策。
///
/// 「分支切换」被限定为一次性的原子动作：即便后续某次探测返回了不同版本，
/// 也不会在运行中翻转分支，避免半程状态不一致。
class CompatBranchSelector {
  CompatDecision? _decision;
  int _switchCount = 0;

  /// 实际发生的分支切换次数：0（未选）、1（已锁定），永远 ≤ 1。
  int get switchCount => _switchCount;

  bool get isSelected => _decision != null;

  CompatDecision? get current => _decision;

  /// 首次调用锁存 [candidate]；后续调用忽略入参并返回已锁存的决策。
  CompatDecision select(CompatDecision candidate) {
    final existing = _decision;
    if (existing != null) return existing;
    _decision = candidate;
    _switchCount = 1;
    return candidate;
  }

  /// 仅供回归脚本复位；生产启动路径不调用。
  void resetForTest() {
    _decision = null;
    _switchCount = 0;
  }
}
