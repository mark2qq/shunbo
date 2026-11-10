// 版本兼容分支回归。
//
// 分两层：
//   ① 纯 Dart 策略（version_compat.dart）——版本对象收敛、整数比较、边界版本、
//      版本信息缺失 / 非法、探测失败、非 Android 不适用、幂等、分支锁；
//   ② 源码静态护栏——Dart / Kotlin / Java 三侧共用同一阈值与保守策略，
//      启动装配只决策一次，兼容分支范围不外溢到播放器/清单/版本号/产物。
//
// 运行：dart run tooling/verify_version_compat.dart
import 'dart:convert';
import 'dart:io';

import 'package:shunbo/platform/version_compat.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (!ok) {
    _fail++;
    print('FAIL: $name${detail == null ? '' : ' —— $detail'}');
    return;
  }
  _pass++;
  print('PASS: $name');
}

/// Windows 工作区部分文件是 CRLF，统一成 LF 后再做多行匹配。
String _src(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  // ── A. 版本对象收敛：只有整数 Android API 等级能通过 ──────────────────
  check('A01 null → 缺失', VersionCompatPolicy.parseApiLevel(null) == null);
  check('A02 int 1（下界）', VersionCompatPolicy.parseApiLevel(1) == 1);
  check('A03 int 16（老设备）', VersionCompatPolicy.parseApiLevel(16) == 16);
  check('A04 int 18（乐视实测）', VersionCompatPolicy.parseApiLevel(18) == 18);
  check('A05 int 23（阈值下边界）', VersionCompatPolicy.parseApiLevel(23) == 23);
  check('A06 int 24（阈值）', VersionCompatPolicy.parseApiLevel(24) == 24);
  check('A07 int 25（阈值上边界）', VersionCompatPolicy.parseApiLevel(25) == 25);
  check('A08 int 36（targetSdk）', VersionCompatPolicy.parseApiLevel(36) == 36);
  check('A09 int 1000（合理上界）', VersionCompatPolicy.parseApiLevel(1000) == 1000);
  check('A10 int 0 → 非法', VersionCompatPolicy.parseApiLevel(0) == null);
  check('A11 int -1 → 非法', VersionCompatPolicy.parseApiLevel(-1) == null);
  check('A12 int 1001 → 越界非法', VersionCompatPolicy.parseApiLevel(1001) == null);
  check('A13 int 999999 → 越界非法', VersionCompatPolicy.parseApiLevel(999999) == null);
  check('A14 double 18.0 → 18', VersionCompatPolicy.parseApiLevel(18.0) == 18);
  check('A15 double 24.0 → 24', VersionCompatPolicy.parseApiLevel(24.0) == 24);
  check('A16 double 18.5 → 非法', VersionCompatPolicy.parseApiLevel(18.5) == null);
  check('A17 double 4.3（展示串的数值形态）→ 非法',
      VersionCompatPolicy.parseApiLevel(4.3) == null);
  check('A18 double NaN → 非法',
      VersionCompatPolicy.parseApiLevel(double.nan) == null);
  check('A19 double +∞ → 非法',
      VersionCompatPolicy.parseApiLevel(double.infinity) == null);
  check('A20 double -∞ → 非法',
      VersionCompatPolicy.parseApiLevel(double.negativeInfinity) == null);
  check("A21 String '18' → 18", VersionCompatPolicy.parseApiLevel('18') == 18);
  check("A22 String '018' → 18", VersionCompatPolicy.parseApiLevel('018') == 18);
  check("A23 String ' 18 ' → 18", VersionCompatPolicy.parseApiLevel(' 18 ') == 18);
  check("A24 String '24' → 24", VersionCompatPolicy.parseApiLevel('24') == 24);
  check("A25 String '' → 非法", VersionCompatPolicy.parseApiLevel('') == null);
  check("A26 String '   ' → 非法", VersionCompatPolicy.parseApiLevel('   ') == null);
  check("A27 String '4.3'（Android 版本展示串）→ 非法",
      VersionCompatPolicy.parseApiLevel('4.3') == null);
  check("A28 String '1.0.0'（应用版本）→ 非法",
      VersionCompatPolicy.parseApiLevel('1.0.0') == null);
  check("A29 String '18.0' → 非法", VersionCompatPolicy.parseApiLevel('18.0') == null);
  check("A30 String '+18' → 非法", VersionCompatPolicy.parseApiLevel('+18') == null);
  check("A31 String '-1' → 非法", VersionCompatPolicy.parseApiLevel('-1') == null);
  check("A32 String '18a' → 非法", VersionCompatPolicy.parseApiLevel('18a') == null);
  check("A33 String 'abc' → 非法", VersionCompatPolicy.parseApiLevel('abc') == null);
  check("A34 String 全角数字 → 非法", VersionCompatPolicy.parseApiLevel('１８') == null);
  check('A35 bool true → 非法', VersionCompatPolicy.parseApiLevel(true) == null);
  check('A36 bool false → 非法', VersionCompatPolicy.parseApiLevel(false) == null);
  check('A37 List → 非法', VersionCompatPolicy.parseApiLevel(<int>[18]) == null);
  check('A38 Map → 非法', VersionCompatPolicy.parseApiLevel(<String, int>{'sdk': 18}) == null);
  check('A39 Object → 非法', VersionCompatPolicy.parseApiLevel(Object()) == null);
  check('A40 阈值常量为 24', kMinSupportedAndroidApi == 24);
  check('A41 比较对象常量明示 SDK_INT',
      kVersionCompatSubject.contains('SDK_INT'));
  check('A42 合理区间常量', kMinPlausibleApi == 1 && kMaxPlausibleApi == 1000);

  // ── B. 版本比较：整数相减，绝不做字符串比较 ────────────────────────────
  check('B01 compare(17) < 0', VersionCompatPolicy.compareToThreshold(17) < 0);
  check('B02 compare(23) == -1', VersionCompatPolicy.compareToThreshold(23) == -1);
  check('B03 compare(24) == 0', VersionCompatPolicy.compareToThreshold(24) == 0);
  check('B04 compare(25) == 1', VersionCompatPolicy.compareToThreshold(25) == 1);
  check('B05 compare(36) == 12', VersionCompatPolicy.compareToThreshold(36) == 12);
  check('B06 字符串 "9" 不会被当作版本比较输入',
      VersionCompatPolicy.parseApiLevel('9') == 9 &&
          VersionCompatPolicy.compareToThreshold(9) < 0);
  check('B07 "10" 大于 "9" 时按整数比较（不是字典序）',
      VersionCompatPolicy.parseApiLevel('10')! >
          VersionCompatPolicy.parseApiLevel('9')!);

  // ── C. 分支决策：满足要求 → 默认流程；低于阈值 → 兼容分支 ────────────────
  CompatDecision d({
    required int? api,
    bool android = true,
    bool ok = true,
    String? release,
  }) =>
      VersionCompatPolicy.decide(
        isAndroid: android,
        sdkInt: api,
        probeOk: ok,
        release: release,
      );

  for (final api in <int>[16, 17, 18, 21, 22, 23]) {
    final x = d(api: api);
    check('C-low-$api 进兼容分支', x.isLegacyCompat);
    check('C-low-$api 依据 belowThreshold', x.reason == CompatReason.belowThreshold);
    check('C-low-$api 不算检测降级', !x.degraded);
    check('C-low-$api 保留实测读数', x.apiLevel == api);
  }
  for (final api in <int>[24, 25, 26, 28, 30, 36]) {
    final x = d(api: api);
    check('C-high-$api 保持默认流程', x.isDefaultFlow);
    check('C-high-$api 依据 meetsRequirement',
        x.reason == CompatReason.meetsRequirement);
    check('C-high-$api 不降级', !x.degraded);
    check('C-high-$api 保留实测读数', x.apiLevel == api);
  }
  check('C-boundary 23/24 结果相反',
      d(api: 23).isLegacyCompat && d(api: 24).isDefaultFlow);
  check('C-string 字符串 "24" 也能正确收敛',
      VersionCompatPolicy.decide(isAndroid: true, sdkInt: '24').isDefaultFlow);
  check('C-string 字符串 "18" 进兼容分支',
      VersionCompatPolicy.decide(isAndroid: true, sdkInt: '18').isLegacyCompat);
  check('C-release 展示串不参与比较（4.3 配 API 24）',
      d(api: 24, release: '4.3').isDefaultFlow);
  check('C-release 不同展示串得到同一分支决策',
      d(api: 24, release: '4.3').branch == d(api: 24, release: '14').branch &&
          d(api: 24, release: '4.3').reason == d(api: 24, release: '14').reason &&
          d(api: 24, release: '4.3').degraded ==
              d(api: 24, release: '14').degraded);
  check('C-release 写进诊断文本但不改分支',
      d(api: 24, release: '4.3').release == '4.3');
  check('C-idempotent 重复决策结果相等', d(api: 18) == d(api: 18));
  check('C-idempotent 不同参数结果不等', d(api: 18) != d(api: 24));

  // ── D. 检测失败 / 版本信息缺失：一律保守进兼容分支 ──────────────────────
  final failed = d(api: 36, ok: false);
  check('D01 探测失败进兼容分支', failed.isLegacyCompat);
  check('D02 探测失败依据 probeFailed', failed.reason == CompatReason.probeFailed);
  check('D03 探测失败标记降级', failed.degraded);
  check('D04 探测失败即便带高版本读数也不放行', failed.apiLevel == 36 && failed.isLegacyCompat);
  final missing = d(api: null);
  check('D05 版本缺失进兼容分支', missing.isLegacyCompat);
  check('D06 版本缺失依据 missingVersion', missing.reason == CompatReason.missingVersion);
  check('D07 版本缺失标记降级', missing.degraded);
  check('D08 版本缺失 apiLevel 为 null', missing.apiLevel == null);
  for (final bad in <Object?>['4.3', '1.0.0', 'abc', -1, 0, 1001, true, 18.5]) {
    final x = VersionCompatPolicy.decide(isAndroid: true, sdkInt: bad);
    check('D-invalid($bad) 进兼容分支', x.isLegacyCompat);
    check('D-invalid($bad) 依据 invalidVersion',
        x.reason == CompatReason.invalidVersion);
    check('D-invalid($bad) 标记降级', x.degraded);
  }
  check('D09 失败/缺失/低版本三种原因互不相同',
      failed.reason != missing.reason &&
          missing.reason != d(api: 18).reason &&
          failed.reason != d(api: 18).reason);
  check('D10 诊断文本含阈值与比较对象',
      missing.diagnosticText().contains('24') &&
          missing.diagnosticText().contains('SDK_INT'));
  check('D11 诊断文本标注降级', failed.diagnosticText().contains('降级'));
  check('D12 toMap 字段齐全',
      failed.toMap()['branch'] == 'legacyCompat' &&
          failed.toMap()['threshold'] == 24 &&
          failed.toMap()['degraded'] == true &&
          failed.toMap()['subject'] == kVersionCompatSubject);
  check('D13 分支名与原生侧一致',
      RuntimeBranch.legacyCompat.name == 'legacyCompat' &&
          RuntimeBranch.defaultFlow.name == 'defaultFlow');
  check('D14 原因名与原生侧一致',
      CompatReason.belowThreshold.name == 'belowThreshold' &&
          CompatReason.meetsRequirement.name == 'meetsRequirement' &&
          CompatReason.probeFailed.name == 'probeFailed');

  // ── E. 非 Android：版本对象不适用，默认流程逐字不变 ──────────────────────
  for (final api in <int?>[18, 23, 24, 36, null]) {
    final x = d(api: api, android: false);
    check('E-na-$api 保持默认流程', x.isDefaultFlow);
    check('E-na-$api 依据 notApplicable', x.reason == CompatReason.notApplicable);
    check('E-na-$api 不降级', !x.degraded);
  }
  check('E-fail 非 Android 探测失败也不降级',
      d(api: null, android: false, ok: false).isDefaultFlow);
  check('E-invalid 非 Android 非法读数也不降级',
      VersionCompatPolicy.decide(isAndroid: false, sdkInt: '4.3').isDefaultFlow);

  // ── F. 分支锁：只切换一次，运行期不翻转 ────────────────────────────────
  final selector = CompatBranchSelector();
  check('F01 初始未选择', !selector.isSelected);
  check('F02 初始切换次数 0', selector.switchCount == 0);
  check('F03 初始 current 为 null', selector.current == null);
  final first = selector.select(d(api: 18));
  check('F04 首次选择生效', first.isLegacyCompat && selector.isSelected);
  check('F05 切换次数 = 1', selector.switchCount == 1);
  final second = selector.select(d(api: 24));
  check('F06 重复选择幂等（不翻转）', second.isLegacyCompat);
  check('F07 重复选择不增加切换次数', selector.switchCount == 1);
  check('F08 current 与首次一致', selector.current == first);
  check('F09 第三次选择仍幂等', selector.select(d(api: 36)) == first);
  selector.resetForTest();
  check('F10 复位后未选择', !selector.isSelected && selector.switchCount == 0);
  check('F11 复位后可重新选择默认流程',
      selector.select(d(api: 24)).isDefaultFlow && selector.switchCount == 1);
  check('F12 复位后也不会被后续读数翻转',
      selector.select(d(api: 16)).isDefaultFlow);

  // ── G. 源码静态护栏：三层定义一致 + 分支范围不外溢 ──────────────────────
  final policy = _src('lib/platform/version_compat.dart');
  final kt = _src('android/app/src/main/kotlin/com/shunbo/shunbo/SystemProbe.kt');
  final sys = _src('lib/platform/system_channel.dart');
  final mainDart = _src('lib/main.dart');
  final services = _src('lib/app/services.dart');
  final watch = _src('lib/platform/network_watch.dart');
  final settings = _src('lib/ui/settings/settings_page.dart');
  final bootstrap = _src('lib/core/player/player_bootstrap.dart');
  final all = _src('tooling/verify_all.dart');
  final java = _src('../.apk_analysis/device_probe/src/com/shunbo/probe/ProbeActivity.java');
  final py = _src('../.apk_analysis/device_probe/build_probe.py');
  final manifest = _src('android/app/src/main/AndroidManifest.xml');
  final gradle = _src('android/app/build.gradle.kts');
  final pub = _src('pubspec.yaml');

  check('G01 策略文件是纯 Dart（不依赖 flutter / dart:ui）',
      !RegExp("import\\s+['\"]package:flutter").hasMatch(policy) &&
          !RegExp("import\\s+['\"]dart:ui").hasMatch(policy));
  check('G02 阈值常量只定义在策略层',
      policy.contains('const int kMinSupportedAndroidApi = 24;'));
  check('G03 比较用整数相减',
      policy.contains('apiLevel - kMinSupportedAndroidApi'));
  check('G04 判定用严格小于',
      policy.contains('compareToThreshold(parsed) < 0'));
  check('G05 策略层不引用应用版本常量',
      !policy.contains('kAppVersionName') && !policy.contains('kAppVersionCode'));
  check('G06 策略层明示 release 只展示',
      policy.contains('仅展示') && policy.contains('不参与比较'));
  check('G07 Kotlin 暴露 sdkInt 原始整数',
      kt.contains('"sdkInt" to Build.VERSION.SDK_INT'));
  check('G08 Kotlin 暴露 release 展示串',
      kt.contains('"release" to Build.VERSION.RELEASE'));
  check('G09 Kotlin 保留原有 buildInfo 字段',
      kt.contains('"applicationId" to pkg') &&
          kt.contains('"versionName" to versionName') &&
          kt.contains('"versionCode" to versionCode'));
  check('G10 Dart 侧保留原始读数（可区分缺失/非法）',
      sys.contains('final Object? sdkIntRaw;') &&
          sys.contains('sdkIntRaw: raw[\'sdkInt\']'));
  check('G11 Dart 侧透明传值不在通道层比较',
      sys.contains('sdkInt: sdkIntRaw') &&
          !sys.contains('sdkInt < 24'));
  check('G12 探测失败信号来自 source',
      sys.contains("probeOk: source != 'probe-failed'"));
  check('G13 编译期兜底不伪造设备版本',
      sys.contains('sdkIntRaw: null') && sys.contains("release: 'unknown'"));
  // 版本号由用户决定（1.0.4 / +5 按研发计划 PQ-1 / M4 升版）。这里锁的是「常量与 pubspec 同源」，
  // 不是锁死某个具体数字为永久值；更早产物仍保留在 dist/ 作回退基线（R12）。
  check('G14 兜底版本常量与当前发布版本同源（1.0.4 / +5）',
      sys.contains("kAppVersionName = '1.0.4'") &&
          RegExp(r'kAppVersionCode\s*=\s*5\s*;').hasMatch(sys));
  check('G15 main 启动时决策一次并锁存',
      mainDart.contains('CompatBranchSelector().select(') &&
          mainDart.contains('buildInfo.compatDecision(isAndroid: Platform.isAndroid)'));
  check('G16 main 把决策注入服务容器',
      mainDart.contains('compatDecision: compat'));
  check('G17 main 把分支传给能力层',
      mainDart.contains('NetworkWatch(legacyCompat: compat.isLegacyCompat)'));
  check('G18 main 输出分支诊断', mainDart.contains('[compat]'));
  check('G19 services 持有不可变决策',
      services.contains('final CompatDecision compatDecision;') &&
          services.contains('required this.compatDecision'));
  check('G20 NetworkWatch 默认 false（默认流程逐字不变）',
      watch.contains('this.legacyCompat = false'));
  check('G21 兼容分支不发起原生快照调用',
      watch.contains('if (legacyCompat) return null;'));
  check('G22 兼容分支不订阅原生事件流',
      watch.contains('if (legacyCompat) return const Stream<NetworkSnapshot>.empty();'));
  check('G23 原有非 Android 兜底未被删除',
      watch.contains('if (!isSupported) return null;') &&
          watch.contains('if (!isSupported) return const Stream<NetworkSnapshot>.empty();'));
  check('G24 设置页展示分支与比较对象',
      settings.contains("label: '运行分支'") &&
          settings.contains('kVersionCompatSubject') &&
          settings.contains('kMinSupportedAndroidApi'));
  check('G25 兼容分支不触碰播放内核选择（范围边界）',
      !bootstrap.contains('legacyCompat') &&
          bootstrap.contains('PlayerController createPlatformPlayer()'));
  check('G26 门禁注册了 version-compat 步骤',
      all.contains("Gate.dart('version-compat'"));
  check('G27 Java 探针阈值与 Dart 一致',
      java.contains('MIN_SUPPORTED_API = 24'));
  check('G28 Java 探针用严格小于判定',
      java.contains('api < MIN_SUPPORTED_API'));
  check('G29 Java 探针检测失败走保守分支',
      java.contains('!probeOk') && java.contains('return "legacyCompat"'));
  check('G30 Java 探针判定依据名与 Dart 对齐',
      java.contains('"belowThreshold"') &&
          java.contains('"meetsRequirement"') &&
          java.contains('"probeFailed"'));
  check('G31 Java 探针明示范围不含低版本播放器',
      java.contains('不含低版本播放器实现'));
  check('G32 构建脚本做跨语言一致性校验',
      py.contains('"Dart threshold = 24"') &&
          py.contains('"Java threshold = 24"') &&
          py.contains('MIN_SUPPORTED_API = 24'));
  check('G33 清单 minSdk 不伪装成 16',
      manifest.contains('android:minSdkVersion') == false ||
          !manifest.contains('android:minSdkVersion="16"'));
  check('G34 Gradle minSdk 仍为 24（依赖版本下限不伪造）',
      RegExp(r'minSdk\s*=\s*24\b').hasMatch(gradle));
  check('G35 v1+v2 双签未被回退',
      gradle.contains('enableV1Signing = true') &&
          gradle.contains('enableV2Signing = true'));
  check('G36 pubspec 版本与发布版本一致（1.0.4+5）',
      RegExp(r'^version:\s*1\.0\.4\+5\s*$', multiLine: true).hasMatch(pub));

  // ── H. 探针构建产物：重建后的分支自检表与一致性结论 ────────────────────
  final reportPath = '../.apk_analysis/device_probe/probe_build_report.json';
  final reportExists = File(reportPath).existsSync();
  check('H01 探针构建报告存在', reportExists);
  if (reportExists) {
    final report = jsonDecode(_src(reportPath)) as Map<String, dynamic>;
    final consistency = (report['consistency'] as Map).cast<String, dynamic>();
    for (final entry in consistency.entries) {
      check('H-consistency(${entry.key})', entry.value == true);
    }
    final cases = (report['branchCases'] as List).cast<Map<String, dynamic>>();
    final expected = <String, String>{
      '实测 API 18': 'legacyCompat',
      '边界 API 23': 'legacyCompat',
      '边界 API 24': 'defaultFlow',
      '边界 API 25': 'defaultFlow',
      '更高 API 36': 'defaultFlow',
      '版本信息缺失': 'legacyCompat',
      '探测失败': 'legacyCompat',
    };
    check('H02 分支自检表覆盖 7 个场景', cases.length == 7);
    for (final c in cases) {
      check('H-case(${c['case']}) = ${expected[c['case']]}',
          c['branch'] == expected[c['case']]);
    }
    final results = (report['results'] as List).cast<Map<String, dynamic>>();
    check('H03 两个探针包各有 11 项断言且全绿',
        results.length == 2 &&
            results.every((r) =>
                (r['checks'] as Map).length == 11 &&
                (r['checks'] as Map).values.every((v) => v == true)));
    check('H04 探针产物真实存在',
        results.every((r) => File('dist/${r['name']}').existsSync()));
    check('H05 min16 包仍只有 v1（可在 API 18 上安装）',
        results.any((r) => r['name'] == 'Shunbo-Probe-min16.apk' && r['v2'] == false));
  }

  print('');
  if (_fail == 0) {
    print('回归通过：$_pass/$_pass 断言通过');
    exit(0);
  }
  print('回归失败：$_pass/${_pass + _fail} 断言通过');
  exit(1);
}
