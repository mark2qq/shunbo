import 'source_config_validator.dart';

/// 首次配置引导步骤（E9：闭合评估报告「用户引导 / 首次配置流程未定义」缺口）。
enum OnboardingStep {
  /// 欢迎 + 免责声明（必须显式接受，才允许导入外部源配置）。
  welcome,

  /// 导入源配置（可跳过）。
  sourceImport,

  /// 确认当前设备形态（遥控器交互 / 平台裁剪源）。
  platformConfirm,

  /// 完成。
  done,
}

class OnboardingState {
  final OnboardingStep step;
  final bool disclaimerAccepted;
  final bool sourceImported;
  final bool skipped;
  final String platform;

  /// 成功导入（含完成后重新导入）的次数，用于 UI 展示与持久化一致性验证。
  final int importCount;

  const OnboardingState({
    this.step = OnboardingStep.welcome,
    this.disclaimerAccepted = false,
    this.sourceImported = false,
    this.skipped = false,
    this.platform = '',
    this.importCount = 0,
  });

  bool get completed => step == OnboardingStep.done;

  OnboardingState copyWith({
    OnboardingStep? step,
    bool? disclaimerAccepted,
    bool? sourceImported,
    bool? skipped,
    String? platform,
    int? importCount,
  }) =>
      OnboardingState(
        step: step ?? this.step,
        disclaimerAccepted: disclaimerAccepted ?? this.disclaimerAccepted,
        sourceImported: sourceImported ?? this.sourceImported,
        skipped: skipped ?? this.skipped,
        platform: platform ?? this.platform,
        importCount: importCount ?? this.importCount,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'step': step.name,
        'disclaimerAccepted': disclaimerAccepted,
        'sourceImported': sourceImported,
        'skipped': skipped,
        'platform': platform,
        'importCount': importCount,
      };

  factory OnboardingState.fromJson(Map<String, dynamic> j) => OnboardingState(
        step: OnboardingStep.values.firstWhere(
          (s) => s.name == j['step'],
          orElse: () => OnboardingStep.welcome,
        ),
        disclaimerAccepted: j['disclaimerAccepted'] as bool? ?? false,
        sourceImported: j['sourceImported'] as bool? ?? false,
        skipped: j['skipped'] as bool? ?? false,
        platform: j['platform'] as String? ?? '',
        importCount: (j['importCount'] as num?)?.toInt() ?? 0,
      );
}

/// 首次配置引导流程（纯状态机，可持久化、可验证）。
///
/// 安全不变量：**未显式接受免责声明前，禁止任何源配置导入**。
/// 不安全配置（含动态代码加载字段 / 非法 scheme / 未授权的 jar 后端）一律拒绝，
/// 且不推进流程 —— 用户必须修正或跳过，不能「带病通过」。
class OnboardingFlow {
  OnboardingState _state;

  /// 状态持久化回调（接 ConfigStore / 文件 / 账号云均可）。
  final Future<void> Function(Map<String, dynamic> state)? persist;

  OnboardingFlow({OnboardingState? initial, this.persist})
      : _state = initial ?? const OnboardingState();

  OnboardingState get state => _state;

  bool get needsOnboarding => !_state.completed;

  Future<void> _commit(OnboardingState next) async {
    _state = next;
    final p = persist;
    if (p != null) await p(next.toJson());
  }

  /// 步骤 1：接受免责声明 → 进入源配置导入。
  Future<void> acceptDisclaimer() async {
    if (_state.step != OnboardingStep.welcome) {
      throw StateError('引导步骤错误：只能在 welcome 接受免责声明');
    }
    await _commit(_state.copyWith(
        step: OnboardingStep.sourceImport, disclaimerAccepted: true));
  }

  /// 跳过引导 / 已完成引导的用户**补签**免责声明。
  ///
  /// 不改变步骤：这类用户不该被重新拖回 welcome，但在补签前必须禁止导入
  /// 外部配置，否则「跳过引导」会成为绕过安全声明的捷径。
  Future<void> acceptDisclaimerLater() async {
    if (_state.disclaimerAccepted) return;
    await _commit(_state.copyWith(disclaimerAccepted: true));
  }

  /// 步骤 2：校验并导入外部源配置。失败时不推进流程，返回具体拒绝原因。
  ///
  /// 调用方应传入 `LoadedSourceConfig.validatedConfig`（已完成逐条隔离的净化
  /// 配置），否则多源容器里只要有一条坏配置就会整体失败，造成
  /// 「好源已注册、引导却卡在导入步」的状态撕裂。
  Future<ConfigValidationResult> importSourceConfig(
    Object? raw, {
    bool allowUnsafeBackends = false,
  }) async {
    if (_state.step != OnboardingStep.sourceImport ||
        !_state.disclaimerAccepted) {
      throw StateError('安全约束：未接受免责声明或步骤不正确，禁止导入源配置');
    }
    final result = validateSourceConfig(raw,
        allowUnsafeBackends: allowUnsafeBackends);
    if (!result.ok) return result;
    await _commit(_state.copyWith(
      step: OnboardingStep.platformConfirm,
      sourceImported: true,
      importCount: _state.importCount + 1,
    ));
    return result;
  }

  /// 已过导入步骤后重新导入（换源配置）：只记状态，不回退步骤。
  ///
  /// 允许 `platformConfirm` 与 `done`：首次导入已经把步骤推到 platformConfirm，
  /// 若只允许 done，用户在引导中途想修正配置会被莫名拒绝。
  Future<void> recordReimport() async {
    if (!_state.disclaimerAccepted ||
        _state.step == OnboardingStep.welcome ||
        _state.step == OnboardingStep.sourceImport) {
      throw StateError('安全约束：未接受免责声明或尚未完成导入步骤，禁止重新导入');
    }
    await _commit(_state.copyWith(
      sourceImported: true,
      importCount: _state.importCount + 1,
    ));
  }

  /// 步骤 2 备选：跳过导入（使用内置源）。
  Future<void> skipImport() async {
    if (_state.step != OnboardingStep.sourceImport) {
      throw StateError('引导步骤错误：只能在 sourceImport 跳过导入');
    }
    await _commit(
        _state.copyWith(step: OnboardingStep.platformConfirm));
  }

  /// 步骤 3：确认设备形态 → 完成引导。
  Future<void> confirmPlatform(String platform) async {
    if (_state.step != OnboardingStep.platformConfirm) {
      throw StateError('引导步骤错误：只能在 platformConfirm 确认平台');
    }
    if (platform.isEmpty) throw ArgumentError.value(platform, 'platform');
    await _commit(_state.copyWith(
        step: OnboardingStep.done, platform: platform));
  }

  /// 全跳过（已完成引导的用户不会被再次打断）。
  Future<void> skipAll() async {
    await _commit(_state.copyWith(step: OnboardingStep.done, skipped: true));
  }
}
