import 'package:flutter/foundation.dart';

import '../data/form_factor_store.dart';
import '../platform/system_channel.dart';
import 'form_factor.dart';

/// 形态判定的运行时持有者（R1 + R10）。
///
/// 职责边界：
/// * 启动时探测一次、读回用户偏好、算出最终形态；
/// * 设置页改偏好时重新算并落盘；
/// * 把「自动判定 / 生效值 / 命中规则」原样暴露给诊断页。
///
/// 它**不**决定布局，也**不**碰 SystemChrome。布局由 `AppShell` 读 [report]，
/// 屏幕方向与系统栏由 `DisplayMode` 按形态 + 是否在播来应用。
/// 分开的原因：布局要在 build 里同步读，而系统栏/方向是副作用，
/// 混在一起会导致「每次 rebuild 都调一次 setPreferredOrientations」。
class FormFactorController extends ChangeNotifier {
  FormFactorController({
    required FormFactorStore store,
    SystemChannel? systemChannel,
    FormFactorSignal? signal,
    FormFactorPreference preference = FormFactorPreference.auto,
  })  : _store = store,
        _channel = systemChannel ?? SystemChannel(),
        _signal = signal ?? kFallbackFormFactorSignal,
        _preference = preference {
    _report = resolveFormFactor(_signal, _preference);
  }

  final FormFactorStore _store;
  final SystemChannel _channel;

  FormFactorSignal _signal;
  FormFactorPreference _preference;
  late FormFactorReport _report;

  /// 本机是否 Android（决定要不要真的去申请横屏/沉浸）。
  bool _onAndroid = false;
  bool get onAndroid => _onAndroid;
  set onAndroid(bool v) => _onAndroid = v;

  FormFactorReport get report => _report;

  FormFactorPreference get preference => _preference;

  DeviceForm get form => _report.effective.form;

  bool get isTv => _report.isTv;

  /// 桌面端不参与形态判定（UI 继续走窗口自适应）。
  bool get isDesktop => _report.isDesktop;

  /// 投屏入口是否可见（R12e：只有手机与桌面形态可见，电视形态不显示）。
  bool get castEntryVisible => !isTv;

  /// 是否按「触摸优先」设计交互。
  ///
  /// 手机形态一定是触摸设备（R1 规则 c：有触摸屏才判手机），而电视靠遥控器、
  /// 桌面靠鼠标。这个值决定「能不能用鼠标悬停当作呼出面板的唯一入口」——
  /// 触摸屏上没有悬停这回事，用它当唯一入口等于把面板永久关死。
  bool get touchFirst => !isDesktop && !isTv;

  /// 启动时调用：探测 → 读偏好 → 定形态。返回最终报告。
  ///
  /// 这里刻意**串行**做（先读取本地偏好再探测不是必须的，但都极快）：
  /// 首帧必须在正确的形态下渲染，否则电视用户会先看到一帧手机布局再跳变。
  Future<FormFactorReport> load() async {
    final results = await Future.wait(<Future<Object>>[
      _channel.probeFormFactor(),
      _store.load(),
    ]);
    _signal = results[0] as FormFactorSignal;
    _preference = results[1] as FormFactorPreference;
    _report = resolveFormFactor(_signal, _preference);
    _onAndroid = !_report.isDesktop;
    notifyListeners();
    return _report;
  }

  /// 设置页切换偏好（R1：自动 / 强制手机 / 强制电视）。
  Future<void> setPreference(FormFactorPreference p) async {
    if (p == _preference) return;
    _preference = p;
    _report = resolveFormFactor(_signal, _preference);
    notifyListeners();
    await _store.save(p);
  }

  /// 重新探测一次（插入/拔出遥控器接收器、外接键盘后可用于纠正）。
  Future<void> reprobe() async {
    _signal = await _channel.probeFormFactor();
    _report = resolveFormFactor(_signal, _preference);
    notifyListeners();
  }

  /// 仅供回归脚本注入信号。
  @visibleForTesting
  void debugOverrideSignal(FormFactorSignal s) {
    _signal = s;
    _report = resolveFormFactor(_signal, _preference);
    notifyListeners();
  }
}
