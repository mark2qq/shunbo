/// 安卓端形态判定（R1）。
///
/// 本文件是**纯逻辑**：不 import Flutter，也不碰平台通道。
/// 这样形态判定的三条规则可以被 `dart run tooling/verify_*.dart` 直接回归，
/// 而不必起一个 Widget 环境（本机 `flutter test` 不可用，见 README 环境限制）。
///
/// 为什么形态判定必须独立成一层：
/// 1. 判定依据是**输入能力与系统 UI 模式**，不是屏幕尺寸。用「宽度 ≥ 1280 就当电视」
///    这类启发式会把 4K 手机、竖屏平板、带触摸的智慧屏全部误判，而误判的代价是
///    「遥控器点不动」——用户只能描述现象，排查成本极高。
/// 2. 判定结果要持久化、可被用户覆盖，还要在诊断页说明「命中了哪条规则」。
///    三件事都要求判定是个可测试的纯函数，而不是散在 UI 里的 if。
library;

/// 界面形态。按文档只允许两种：手机形态与电视形态。
///
/// 桌面端（Windows）不参与判定——它不是「手机/电视」二选一的对象，
/// 由 [FormFactorReport.isDesktop] 单独标记，UI 继续走窗口自适应布局。
enum DeviceForm {
  phone('手机形态'),
  tv('电视形态');

  const DeviceForm(this.label);

  final String label;
}

/// 判定命中的规则。
///
/// 顺序即 R1 的判定顺序（a → b → c），覆盖值排在最后：
/// 用户手动纠正的优先级永远最高，否则「设置页选了强制电视却仍是手机形态」
/// 就变成了无法修复的死角。
enum FormFactorRule {
  /// a) 系统 UI mode 为 television。
  systemUiModeTelevision('系统 UI mode = television'),

  /// b) 无触摸屏，且存在方向键输入。
  dpadWithoutTouchscreen('无触摸屏 + 存在方向键输入'),

  /// c) 其余情况。
  fallbackPhone('未命中电视规则，按手机形态处理'),

  /// 用户强制手机。
  userForcedPhone('用户设置为「强制手机」'),

  /// 用户强制电视。
  userForcedTv('用户设置为「强制电视」');

  const FormFactorRule(this.label);

  final String label;

  /// 是否为「用户覆盖」而非自动判定。
  bool get isUserOverride =>
      this == FormFactorRule.userForcedPhone || this == FormFactorRule.userForcedTv;
}

/// 设置页的三个选项（R1：自动 / 强制手机 / 强制电视）。
enum FormFactorPreference {
  auto('自动'),
  phone('强制手机'),
  tv('强制电视');

  const FormFactorPreference(this.label);

  final String label;

  /// 落盘键（写进 `form-factor.json` 的是这个字符串，不是枚举序号）：
  /// 用序号落盘的话，以后往枚举中间插一个值就会把老用户的设置读错。
  String get key => name;

  static FormFactorPreference fromKey(String? key) {
    for (final p in FormFactorPreference.values) {
      if (p.key == key) return p;
    }
    return FormFactorPreference.auto;
  }
}

/// 平台侧探测到的原始信号。
///
/// 刻意把「探测」和「判定」拆开：探测只在原生侧做（Android 才有 UiModeManager
/// 与 InputManager），判定是纯函数。这样换平台只换探测，规则不用重写第二份。
class FormFactorSignal {
  const FormFactorSignal({
    this.uiModeTelevision = false,
    this.hasTouchscreen = true,
    this.hasDpad = false,
    this.isDesktop = false,
    this.source = 'unknown',
    this.detail = const <String>[],
  });

  /// 系统 UI mode 是否为 television（`UiModeManager.getCurrentModeType()`）。
  final bool uiModeTelevision;

  /// 是否存在触摸屏（`FEATURE_TOUCHSCREEN` + 输入设备扫描）。
  final bool hasTouchscreen;

  /// 是否存在方向键输入（DPAD / 键盘 / 遥控器）。
  final bool hasDpad;

  /// 桌面端：不参与形态判定。
  final bool isDesktop;

  /// 信号来源，写进诊断（android-probe / desktop-default / probe-failed）。
  final String source;

  /// 探测过程中的补充说明（例如「只找到触摸设备」），用于诊断页自证。
  final List<String> detail;
}

/// 判定结果（含依据）。
class FormFactorDecision {
  const FormFactorDecision({
    required this.form,
    required this.rule,
    required this.reason,
  });

  final DeviceForm form;
  final FormFactorRule rule;

  /// 一句话说明，直接展示在诊断页（R10 要求「判定依据」可见）。
  final String reason;

  bool get isTv => form == DeviceForm.tv;
}

/// 完整报告：探测 → 自动判定 → 用户覆盖 → 生效值。
///
/// 诊断页要同时看到「自动判定成什么」和「最终生效什么」：
/// 只看生效值无法区分「设备被识别为电视」与「用户手动强制成电视」，
/// 而这两种情况的排查方向完全不同。
class FormFactorReport {
  const FormFactorReport({
    required this.signal,
    required this.detected,
    required this.preference,
    required this.effective,
  });

  final FormFactorSignal signal;

  /// 忽略用户覆盖时的自动判定结果。
  final FormFactorDecision detected;

  final FormFactorPreference preference;

  /// 实际生效的判定结果。
  final FormFactorDecision effective;

  bool get isDesktop => signal.isDesktop;

  bool get isTv => effective.form == DeviceForm.tv;

  /// 用户是否覆盖了自动判定。
  bool get overridden => effective.rule.isUserOverride;

  /// 自动判定与生效值不一致（用户覆盖生效）。
  bool get overriddenFromDifferentForm => detected.form != effective.form;

  /// 诊断页显示用的多行文本（R10 三项之一：判定依据）。
  String diagnosticText() {
    final b = StringBuffer()
      ..writeln('设备形态：${effective.form.label}'
          '${overridden ? '（用户覆盖）' : ''}')
      ..writeln('判定依据：${effective.rule.label}');
    if (overridden) {
      b.writeln('自动判定：${detected.form.label} · ${detected.rule.label}');
    }
    b.writeln('信号来源：${signal.source}');
    b.writeln('uiMode=television: ${signal.uiModeTelevision ? '是' : '否'} · '
        '触摸屏: ${signal.hasTouchscreen ? '有' : '无'} · '
        '方向键: ${signal.hasDpad ? '有' : '无'}');
    for (final d in signal.detail) {
      b.writeln('· $d');
    }
    return b.toString().trimRight();
  }
}

/// 自动判定（R1 的 a/b/c 三步），不考虑用户覆盖。
FormFactorDecision detectFormFactor(FormFactorSignal s) {
  // a) 系统 UI mode 为 television —— 最强的证据。
  //    华为智慧屏、Android TV、Google TV 都会把 mode 置为 television；
  //    此时即便面板带触摸（部分智慧屏确实带），也应按电视形态交互。
  if (s.uiModeTelevision) {
    return const FormFactorDecision(
      form: DeviceForm.tv,
      rule: FormFactorRule.systemUiModeTelevision,
      reason: '系统 UI mode 报告为 television',
    );
  }
  // b) 无触摸屏 + 有方向键。
  //    两个条件缺一不可：只有「无触摸」可能是无屏设备；只有「有方向键」
  //    可能是外接键盘的手机。必须同时成立才按电视处理。
  if (!s.hasTouchscreen && s.hasDpad) {
    return const FormFactorDecision(
      form: DeviceForm.tv,
      rule: FormFactorRule.dpadWithoutTouchscreen,
      reason: '未检测到触摸屏，且存在方向键输入设备',
    );
  }
  // c) 其余一律手机形态。
  return FormFactorDecision(
    form: DeviceForm.phone,
    rule: FormFactorRule.fallbackPhone,
    reason: s.hasTouchscreen ? '存在触摸屏，按手机形态处理' : '缺少方向键输入，按手机形态处理',
  );
}

/// 结合用户偏好得出最终报告。
FormFactorReport resolveFormFactor(
  FormFactorSignal signal,
  FormFactorPreference preference,
) {
  final detected = detectFormFactor(signal);
  final effective = switch (preference) {
    FormFactorPreference.auto => detected,
    FormFactorPreference.phone => const FormFactorDecision(
        form: DeviceForm.phone,
        rule: FormFactorRule.userForcedPhone,
        reason: '设置页选择「强制手机」',
      ),
    FormFactorPreference.tv => const FormFactorDecision(
        form: DeviceForm.tv,
        rule: FormFactorRule.userForcedTv,
        reason: '设置页选择「强制电视」',
      ),
  };
  return FormFactorReport(
    signal: signal,
    detected: detected,
    preference: preference,
    effective: effective,
  );
}

/// 桌面端默认信号（测试与 Windows 构建共用）。
///
/// 桌面端没有「电视形态」这回事，也不是手机；用 [isDesktop] 标记，
/// 让 UI 保持原有的窗口自适应，而不是被迫二选一。
const FormFactorSignal kDesktopFormFactorSignal = FormFactorSignal(
  isDesktop: true,
  source: 'desktop-default',
  detail: <String>['桌面端不参与形态判定，界面按窗口宽度自适应'],
);

/// 探测失败时的保守默认值。
///
/// 选「手机形态」而不是电视：手机形态保留触摸与手势，误判到手机最坏是
/// 「电视上多点几下」；误判到电视则会隐藏投屏入口、锁死横屏、并把触摸专属
/// 交互全部藏起来——在真正的手机上是不可用的。
const FormFactorSignal kFallbackFormFactorSignal = FormFactorSignal(
  source: 'probe-failed',
  detail: <String>['原生探测不可用，回退为手机形态（可在设置页手动切换）'],
);
