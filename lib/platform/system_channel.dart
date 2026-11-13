import 'package:flutter/services.dart';

import '../app/form_factor.dart';
import 'version_compat.dart';

/// 应用构建信息（R8/R10 诊断项：当前渠道与版本号）。
class AppBuildInfo {
  const AppBuildInfo({
    required this.applicationId,
    required this.versionName,
    required this.versionCode,
    required this.channel,
    required this.abis,
    this.source = 'unknown',
    this.sdkIntRaw,
    this.release = 'unknown',
  });

  final String applicationId;
  final String versionName;
  final int versionCode;

  /// 版本兼容分支的**比较对象**：原生 `Build.VERSION.SDK_INT` 原始值。
  ///
  /// 保留原始值而不是直接存 int，是为了区分「字段缺失」和「值非法」两种
  /// 检测失败；真正解析交给 [VersionCompatPolicy.parseApiLevel]。
  /// 旧包 / 桌面端没有此字段 → null，由决策层走确定性兜底。
  final Object? sdkIntRaw;

  /// `Build.VERSION.RELEASE` 展示字符串（如「4.3」），**不参与版本比较**。
  final String release;

  /// 解析后的 API 等级；缺失或非法为 null。
  int? get sdkInt => VersionCompatPolicy.parseApiLevel(sdkIntRaw);

  /// 渠道：`full`（完整版）或 `lite`（精简版）。
  final String channel;

  /// 本机 CPU 架构（Build.SUPPORTED_ABIS），用于判断装的是哪个 ABI 包体。
  final List<String> abis;

  /// 信息来自原生探测还是编译期常量。
  final String source;

  String get channelLabel => channel == 'lite' ? '精简版' : '完整版';

  String get displayName => '$versionName ($versionCode)';

  /// 诊断页展示：渠道 + 版本 + 包名 + ABI（R10 的「当前渠道与版本号」）。
  String diagnosticText() =>
      '渠道：$channelLabel（$channel）\n'
      '版本：$displayName\n'
      '应用标识：$applicationId\n'
      '设备架构：${abis.isEmpty ? '未知' : abis.join(' / ')}\n'
      '信息来源：$source';

  /// 启动引导层的版本兼容分支决策（比较对象 = sdkIntRaw，阈值 24）。
  ///
  /// `source == 'probe-failed'` 表示平台通道调用本身失败，决策层按保守策略
  /// 进入兼容分支；`pubspec-fallback` / `dart-default` 是桌面端正常兜底，
  /// 由 [isAndroid] 判定为「版本对象不适用」，不会误降级。
  CompatDecision compatDecision({required bool isAndroid}) =>
      VersionCompatPolicy.decide(
        isAndroid: isAndroid,
        sdkInt: sdkIntRaw,
        probeOk: source != 'probe-failed',
        release: release,
      );
}

/// 编译期兜底值。
///
/// 与 `pubspec.yaml` 的 `version:` 保持一致；原生通道不可用时（桌面端、
/// 或未注册 `shunbo/system` 的旧包）诊断页仍能给出确定的版本号，
/// 而不是「未知」。
const String kAppVersionName = '1.0.6';
// versionCode 逐版递增：签名证书未变，可直接覆盖升级；
// 回退到更低 versionCode 需先卸载（1.0.6 按用户指令归入本版本）。
const int kAppVersionCode = 7;
const String kAppIdFull = 'com.shunbo.tv';
const String kAppIdLite = 'com.shunbo.tv.lite';

/// 原生系统能力通道（`shunbo/system`）。
///
/// 与 `shunbo/mpv` 分开的原因：这是**能力探测**通道，与播放内核无关，
/// 桌面端不注册它也要能跑（所有方法都有确定性兜底），
/// 不应该让「探不到形态」变成启动失败。
class SystemChannel {
  SystemChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('shunbo/system');

  final MethodChannel _channel;

  /// 探测形态信号。
  ///
  /// 失败不抛：返回 [kFallbackFormFactorSignal]（手机形态），并标明来源
  /// `probe-failed`。误判到电视会让手机用户失去全部触摸交互，
  /// 误判到手机最多是电视上多点几下——两者代价不对称，所以选择保守的一侧。
  Future<FormFactorSignal> probeFormFactor() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('probeFormFactor');
      if (raw == null) return kFallbackFormFactorSignal;
      return FormFactorSignal(
        uiModeTelevision: raw['uiModeTelevision'] == true,
        hasTouchscreen: raw['hasTouchscreen'] != false,
        hasDpad: raw['hasDpad'] == true,
        source: (raw['source'] as String?) ?? 'android-probe',
        detail: <String>[
          for (final d in (raw['detail'] as List?) ?? const <Object?>[])
            if (d is String) d,
        ],
      );
    } on MissingPluginException {
      // 桌面端没有这个通道，属于正常分支而不是错误。
      return kDesktopFormFactorSignal;
    } catch (_) {
      return kFallbackFormFactorSignal;
    }
  }

  /// 读取构建信息（渠道 / 版本 / 包名 / ABI）。
  Future<AppBuildInfo> buildInfo() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('buildInfo');
      if (raw == null) return _fallbackBuildInfo();
      return AppBuildInfo(
        applicationId: (raw['applicationId'] as String?) ?? kAppIdFull,
        versionName: (raw['versionName'] as String?) ?? kAppVersionName,
        versionCode: (raw['versionCode'] as num?)?.toInt() ?? kAppVersionCode,
        channel: (raw['channel'] as String?) ?? 'full',
        abis: <String>[
          for (final a in (raw['abis'] as List?) ?? const <Object?>[])
            if (a is String) a,
        ],
        source: (raw['source'] as String?) ?? 'android-buildconfig',
        // 版本对象只做透传，绝不在这里比较或写死阈值；判定集中在策略层。
        sdkIntRaw: raw['sdkInt'],
        release: (raw['release'] as String?) ?? 'unknown',
      );
    } on MissingPluginException {
      return _fallbackBuildInfo(source: 'pubspec-fallback');
    } catch (_) {
      return _fallbackBuildInfo(source: 'probe-failed');
    }
  }

  AppBuildInfo _fallbackBuildInfo({String source = 'dart-default'}) => AppBuildInfo(
        applicationId: kAppIdFull,
        versionName: kAppVersionName,
        versionCode: kAppVersionCode,
        channel: 'full',
        abis: const <String>[],
        source: source,
        // 编译期兜底不伪造设备版本：缺失就是缺失，交给决策层保守处理。
        sdkIntRaw: null,
        release: 'unknown',
      );

  /// 应用私有数据目录（Android `context.filesDir`，R8 要求用户数据不被系统清理）。
  ///
  /// 返回 null 表示拿不到（桌面端 / 旧包），调用方退回默认推断。
  Future<String?> dataDir() async {
    try {
      final path = await _channel.invokeMethod<String>('dataDir');
      return (path == null || path.isEmpty) ? null : path;
    } catch (_) {
      return null;
    }
  }

  /// 播放期间的前台服务保活开关（R11c：酷开/小米等会强制结束进程）。
  ///
  /// 失败静默：保活是「尽量不被杀」，拿不到不该打断播放。
  /// 桌面端没有这个能力，同样静默。
  Future<bool> setKeepAlive(bool enabled) async {
    try {
      final ok = await _channel.invokeMethod<bool>('setKeepAlive', <String, dynamic>{
        'enabled': enabled,
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }
}
