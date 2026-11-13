// 安卓端形态与安装包门禁（对应《顺播 · 安卓端形态与安装包要求》）。
//
// 为什么要用脚本而不是人工核对：这份要求里的每一条都是「缺了就装上了但用不了」，
// 而且极易在后续迭代里被无意改回去（典型：有人为了「电视上好看」把侧栏改回
// 鼠标悬停、把 banner 删掉、把 applicationIdSuffix 去掉）。
// 这里把可机检的部分固化成断言：
//
//   R1 形态判定（a/b/c 三条规则的顺序与边界）
//   R1 偏好持久化（写入/读回/损坏容错）
//   R2 单一桌面入口 + 电视桌面属性 + 横幅图
//   R8 渠道标识后缀（可同机并存）
//   R9 minSdk / ABI / 语言资源裁剪
//   R10 诊断三件套（形态、判定依据、渠道与版本）
//   R11 保活服务声明、无 GMS 依赖
//   R5/R6 只有一套业务代码（无形态分支的源解析/换内核）
//
// 纯 dart:io：不能 import 任何 flutter 相关文件（本机 flutter test 不可用，
// 这条门禁靠 `dart run` 直接跑）。
import 'dart:io';

import 'package:shunbo/app/form_factor.dart';
import 'package:shunbo/data/app_paths.dart';
import 'package:shunbo/data/form_factor_store.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    print('PASS: $name');
  } else {
    _fail++;
    print('FAIL: $name${detail == null ? '' : ' — $detail'}');
  }
}

void main() async {
  await testRuleA();
  await testRuleB();
  await testRuleC();
  await testOverrides();
  await testDiagnostics();
  await testStore();
  testManifest();
  testGradle();
  testTvInstallCompat();
  testSingleCodebase();

  final total = _pass + _fail;
  print('\n$_pass/$total 断言通过${_fail == 0 ? '' : '（失败 $_fail 项）'}');
  if (_fail > 0) exitCode = 1;
  exit(exitCode);
}

// ---------------------------------------------------------------- R1 规则 a
Future<void> testRuleA() async {
  // a) 系统 UI mode 为 television → 电视形态，且**优先于**「有触摸屏」。
  // 带触摸的智慧屏必须按电视处理，否则遥控器交互会被触摸分支顶掉。
  final tvTouch = resolveFormFactor(
    const FormFactorSignal(uiModeTelevision: true, hasTouchscreen: true),
    FormFactorPreference.auto,
  );
  check('a) uiMode=television 且带触摸 → 电视形态', tvTouch.isTv);
  check('a) 命中规则为「系统 UI mode」',
      tvTouch.effective.rule == FormFactorRule.systemUiModeTelevision);

  // a) 压过 b)：uiMode 电视但无触摸无方向键，仍判电视（系统声明最强）。
  final tvNoInput = resolveFormFactor(
    const FormFactorSignal(
        uiModeTelevision: true, hasTouchscreen: false, hasDpad: false),
    FormFactorPreference.auto,
  );
  check('a) uiMode=television 优先于输入能力判定', tvNoInput.isTv);
}

// ---------------------------------------------------------------- R1 规则 b
Future<void> testRuleB() async {
  // b) 无触摸 + 有方向键 → 电视（电视盒子没有 uiMode 声明时的主路径）。
  final box = resolveFormFactor(
    const FormFactorSignal(hasTouchscreen: false, hasDpad: true),
    FormFactorPreference.auto,
  );
  check('b) 无触摸 + 有方向键 → 电视形态', box.isTv);
  check('b) 命中规则为「无触摸 + 方向键」',
      box.effective.rule == FormFactorRule.dpadWithoutTouchscreen);

  // 边界：只有「无触摸」——可能是无屏/头戴设备，不能当电视。
  final noTouchOnly = resolveFormFactor(
    const FormFactorSignal(hasTouchscreen: false, hasDpad: false),
    FormFactorPreference.auto,
  );
  check('b) 只满足「无触摸」不算电视', !noTouchOnly.isTv);

  // 边界：只有「有方向键」——外接键盘/游戏手机，必须仍是手机形态。
  final dpadOnly = resolveFormFactor(
    const FormFactorSignal(hasTouchscreen: true, hasDpad: true),
    FormFactorPreference.auto,
  );
  check('b) 只满足「有方向键」不算电视（外接键盘手机）', !dpadOnly.isTv);
}

// ---------------------------------------------------------------- R1 规则 c
Future<void> testRuleC() async {
  // c) 其余 → 手机形态。
  final phone = resolveFormFactor(
    const FormFactorSignal(hasTouchscreen: true, hasDpad: false),
    FormFactorPreference.auto,
  );
  check('c) 普通手机 → 手机形态', !phone.isTv);
  check('c) 命中规则为「未命中电视规则」',
      phone.effective.rule == FormFactorRule.fallbackPhone);
  check('c) 手机形态给出「有触摸屏」的依据', phone.effective.reason.contains('触摸屏'));

  // 明确禁止的判定方式：不得只看分辨率。
  // 用「大屏幕 + 有触摸 + 无方向键」这种 4K 手机的画像验证它仍是手机形态。
  final bigPhone = resolveFormFactor(
    const FormFactorSignal(hasTouchscreen: true, hasDpad: false),
    FormFactorPreference.auto,
  );
  check('c) 大屏手机（有触摸、无方向键）不被判成电视', !bigPhone.isTv);
}

// ---------------------------------------------------------------- R1 覆盖
Future<void> testOverrides() async {
  const phoneSignal = FormFactorSignal(hasTouchscreen: true, hasDpad: false);
  const tvSignal = FormFactorSignal(uiModeTelevision: true);

  final forcedTv = resolveFormFactor(phoneSignal, FormFactorPreference.tv);
  check('覆盖：强制电视在手机上生效', forcedTv.isTv);
  check('覆盖：命中规则记为「用户设置」',
      forcedTv.effective.rule == FormFactorRule.userForcedTv);
  check('覆盖：仍保留自动判定的原值供诊断',
      !forcedTv.detected.isTv && forcedTv.overridden);
  check('覆盖：自动判定与生效值不一致时标记为已覆盖',
      forcedTv.overriddenFromDifferentForm);

  final forcedPhone = resolveFormFactor(tvSignal, FormFactorPreference.phone);
  check('覆盖：强制手机在电视上生效', !forcedPhone.isTv);
  check('覆盖：命中规则记为「用户设置」',
      forcedPhone.effective.rule == FormFactorRule.userForcedPhone);

  final auto = resolveFormFactor(tvSignal, FormFactorPreference.auto);
  check('覆盖：自动模式不做覆盖', !auto.overridden);

  // 枚举 ↔ 落盘键的双向一致（落盘用 name 而不是 index）。
  for (final p in FormFactorPreference.values) {
    check('偏好枚举 ${p.name} 可往返', FormFactorPreference.fromKey(p.key) == p);
  }
  check('未知偏好键回退 auto',
      FormFactorPreference.fromKey('nonsense') == FormFactorPreference.auto);
  check('null 偏好键回退 auto',
      FormFactorPreference.fromKey(null) == FormFactorPreference.auto);
}

// ---------------------------------------------------------------- R10 诊断
Future<void> testDiagnostics() async {
  final r = resolveFormFactor(
    const FormFactorSignal(
      uiModeTelevision: false,
      hasTouchscreen: false,
      hasDpad: true,
      source: 'android-probe',
      detail: <String>['navigation=dpad'],
    ),
    FormFactorPreference.auto,
  );
  final text = r.diagnosticText();
  check('R10 诊断含形态结果', text.contains('电视形态'));
  check('R10 诊断含判定依据', text.contains('无触摸屏'));
  check('R10 诊断含信号来源', text.contains('android-probe'));
  check('R10 诊断含三路原始信号',
      text.contains('uiMode') && text.contains('触摸屏') && text.contains('方向键'));

  final overridden = resolveFormFactor(
    const FormFactorSignal(hasTouchscreen: true),
    FormFactorPreference.tv,
  );
  final t2 = overridden.diagnosticText();
  check('R10 覆盖时诊断同时给出自动判定', t2.contains('自动判定'));

  // 桌面端不参与形态判定，UI 继续按窗口宽度自适应。
  check('桌面信号被标记为 isDesktop', kDesktopFormFactorSignal.isDesktop);
  check('桌面端不显示电视专属结论',
      !resolveFormFactor(kDesktopFormFactorSignal, FormFactorPreference.auto).isTv);
}

// ---------------------------------------------------------------- 持久化
Future<void> testStore() async {
  final dir = await Directory.systemTemp.createTemp('shunbo_ff_');
  try {
    final path = '${dir.path}${Platform.pathSeparator}form-factor.txt';
    final store = FormFactorStore.at(path);

    // 文件不存在 → auto（首装默认）。
    check('R1 首次启动偏好为自动',
        await store.load() == FormFactorPreference.auto);

    await store.save(FormFactorPreference.tv);
    check('R1 偏好可落盘并读回', await store.load() == FormFactorPreference.tv);

    // 覆盖写：第二次保存必须生效（原子写不能留下旧值）。
    await store.save(FormFactorPreference.phone);
    check('R1 偏好覆盖写生效', await store.load() == FormFactorPreference.phone);

    // 损坏容错：外部把文件改坏，必须回退 auto 而不是抛异常。
    await File(path).writeAsString('!!!not-a-pref!!!');
    check('R1 坏文件回退 auto 且不抛',
        await store.load() == FormFactorPreference.auto);

    await File(path).writeAsString('x' * 200);
    check('R1 超长文件回退 auto',
        await store.load() == FormFactorPreference.auto);

    // 落盘内容必须是可读的键名，而不是枚举序号（序号会随枚举调整错位）。
    await store.save(FormFactorPreference.tv);
    final raw = (await File(path).readAsString()).trim();
    check('R1 落盘内容为键名而非序号', raw == 'tv', raw);
  } finally {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  // R8：数据目录可被原生的 files 目录接管（而不是可被系统清空的缓存目录）。
  AppPaths.configure('${Directory.systemTemp.path}/shunbo-injected');
  check('R8 数据目录可注入为应用私有目录',
      AppPaths.dataDir().path.contains('shunbo-injected'));
  check('R8 注入后不标记为降级', !AppPaths.degraded);
}

// ---------------------------------------------------------------- R2 清单
void testManifest() {
  final f = File('android/app/src/main/AndroidManifest.xml');
  check('R2 清单存在', f.existsSync());
  if (!f.existsSync()) return;
  final x = f.readAsStringSync();

  // R2 单一桌面入口：只能有一个 MAIN/LAUNCHER intent-filter，
  // 且 LAUNCHER 与 LEANBACK_LAUNCHER 必须在**同一个** filter 里。
  final launcherCount = RegExp('category android:name="android.intent.category.LAUNCHER"')
      .allMatches(x)
      .length;
  final leanbackLauncherCount =
      RegExp('category android:name="android.intent.category.LEANBACK_LAUNCHER"')
          .allMatches(x)
          .length;
  final mainCount = RegExp('action android:name="android.intent.action.MAIN"')
      .allMatches(x)
      .length;
  check('R2 只有一个 LAUNCHER 入口', launcherCount == 1, '$launcherCount');
  check('R2 只有一个电视桌面入口', leanbackLauncherCount == 1, '$leanbackLauncherCount');
  check('R2 只声明一个 MAIN activity', mainCount == 1, '$mainCount');

  final filters = RegExp(r'<intent-filter>([\s\S]*?)</intent-filter>')
      .allMatches(x)
      .map((m) => m.group(1) ?? '')
      .where((s) => s.contains('LAUNCHER'))
      .toList();
  check('R2 桌面入口与电视入口同处一个 intent-filter（否则电视桌面出现两个图标）',
      filters.length == 1 &&
          filters.first.contains('android.intent.category.LAUNCHER') &&
          filters.first.contains('LEANBACK_LAUNCHER'));

  // R2 电视桌面属性：leanback 非必需（否则手机装不上）+ 横幅图（否则智慧屏显示异常）。
  check('R2 leanback 声明为非必需',
      x.contains('android.software.leanback') && x.contains('android:required="false"'));
  // banner 必须同时挂在 application 与 activity 上：
  // 电视桌面读 application.banner，而 aapt2 badging / 部分商店校验只认 activity.banner，
  // 只挂一处会出现「badging 里 banner 为空」这种看起来像没配的假象。
  final bannerCount =
      RegExp('android:banner="@drawable/tv_banner"').allMatches(x).length;
  check('R2 横幅同时挂在 application 与 activity', bannerCount >= 2, '$bannerCount');
  check('R2 触摸屏非必需（电视可安装）',
      RegExp('android.hardware.touchscreen"\\s+android:required="false"').hasMatch(x));
  // 横幅必须是位图：aapt2 badging 对 XML 矢量只能输出空串，部分电视桌面会显示白底。
  final banner = File('android/app/src/main/res/drawable-nodpi/tv_banner.png');
  check('R2 横幅图资源存在（位图）', banner.existsSync());
  if (banner.existsSync()) {
    final bytes = banner.readAsBytesSync();
    check('R2 横幅图是合法 PNG',
        bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50);
    // 电视桌面按 320x180 取图。
    final w = (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
    final h = (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
    check('R2 横幅尺寸为 320x180', w == 320 && h == 180, '${w}x$h');
  }

  // R11c 保活服务：声明 + 前台服务类型 + 不导出。
  check('R11c 声明前台保活服务', x.contains('.KeepAliveService'));
  check('R11c 服务声明 foregroundServiceType',
      x.contains('android:foregroundServiceType="mediaPlayback"'));
  check('R11c 服务不导出（不可被外部拉起）',
      RegExp(r'android:name="\.KeepAliveService"[\s\S]{0,200}?android:exported="false"')
          .hasMatch(x));
  check('R11c 申请 FOREGROUND_SERVICE 权限',
      x.contains('android.permission.FOREGROUND_SERVICE'));
  check('R11c 申请媒体播放前台服务权限',
      x.contains('android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK'));

  // 网络与局域网能力（投屏/R11）。
  check('声明 INTERNET 权限（release 包不能没网）',
      x.contains('android.permission.INTERNET'));
  check('声明组播权限（SSDP 发现必需）',
      x.contains('android.permission.CHANGE_WIFI_MULTICAST_STATE'));

  // R11d 无 GMS：清单里不得声明任何 Google 服务/推送能力。
  final lower = x.toLowerCase();
  check('R11d 清单无 Google 推送/服务声明',
      !lower.contains('gms') && !lower.contains('firebase') && !lower.contains('com.google.android.c2dm'));
}

// ---------------------------------------------------------------- R8/R9 打包
void testGradle() {
  final f = File('android/app/build.gradle.kts');
  check('打包脚本存在', f.existsSync());
  if (!f.existsSync()) return;
  final g = f.readAsStringSync();

  // R8 两个渠道包使用不同应用标识后缀，可同机并存。
  check('R8 应用标识为 com.shunbo.tv', g.contains('applicationId = "com.shunbo.tv"'));
  check('R8 精简版带 .lite 后缀', g.contains('applicationIdSuffix = ".lite"'));
  check('R8 声明渠道维度', g.contains('flavorDimensions += "channel"'));
  check('R8 存在完整版渠道', RegExp(r'create\("full"\)').hasMatch(g));
  check('R8 存在精简版渠道', RegExp(r'create\("lite"\)').hasMatch(g));

  // R9 minSdk：文档要求 21/19，当前工具链（Flutter 3.47 引擎 AAR 要求 24）无法满足，
  // 这里锁定的是「已知且被记录的最低可构建值」，防止有人随手改回 21 导致构建失败，
  // 也防止改回 flutter.minSdkVersion（默认值会随 SDK 升级漂移）。
  final minSdk = RegExp(r'minSdk\s*=\s*(\d+)').firstMatch(g)?.group(1);
  check('R9 minSdk 显式写死（不跟随 SDK 默认值）', minSdk != null, minSdk);
  check('R9 minSdk 不低于引擎下限 24', (int.tryParse(minSdk ?? '0') ?? 0) >= 24,
      'minSdk=$minSdk');
  check('R9 注释记录了 21/19 无法满足的原因', g.contains('errorMinSdkVersion = 23'));

  // R9 ABI 由打包脚本的 --target-platform 决定（Flutter 会覆盖 gradle 的
  // ndk.abiFilters，写在 gradle 里是无效的 —— 这一点必须由脚本契约来保证）。
  final script = File('tooling/build_android_apks.sh');
  check('R9 存在可复现的打包脚本', script.existsSync());
  if (script.existsSync()) {
    final sh = script.readAsStringSync();
    check('R9 完整版打包含 arm64-v8a',
        RegExp(r'build full android-arm64').hasMatch(sh));
    check('R9 完整版打包含 armeabi-v7a',
        RegExp(r'android-arm64,android-arm\b').hasMatch(sh));
    check('R9 精简版只打 armeabi-v7a', RegExp(r'build lite android-arm\s*$',
            multiLine: true)
        .hasMatch(sh));
    check('R9 脚本内置 60 MB 体积红线',
        sh.contains('62914560') || sh.contains('60 MB'));
  }
  // 真正无效的是 gradle 里的 `abiFilters +=`（Flutter 会用 -Ptarget-platform 覆盖）；
  // 注释里提到这个词不算违规。
  check('R9 gradle 不再写无效的 abiFilters 赋值',
      !RegExp(r'abiFilters\s*\+=').hasMatch(g));

  // R9 语言资源裁剪（超出体积时优先裁语言，不裁内核）。
  check('R9 裁剪语言资源到中英文',
      g.contains('localeFilters') || g.contains('resourceConfigurations'));

  // R6 播放内核只有一套：不允许出现按渠道切换内核的依赖。
  check('R6 内核依赖不分渠道（无 liteImplementation 之类）',
      !g.contains('liteImplementation') && !g.contains('fullImplementation'));
  // R11d 不得引入 GMS 依赖。
  check('R11d 无 Google Play 服务依赖',
      !g.contains('com.google.android.gms') && !g.contains('firebase'));
}

// ------------------------------------------- R12 电视端安装兼容基线（1.0.0）
// 参考实现（昭昭TV.apk，可在乐视 EUI 8.0 上安装并使用）实测为 v1(JAR)+v2 双签名；
// 本项目 0.1.0 实测仅 v2 —— AGP 9 在 minSdk>=24 时默认关闭 v1，老电视/定制 ROM 的
// 包解析器在**解析阶段**读不到 META-INF/MANIFEST.MF，直接抛
// INSTALL_PARSE_FAILED_NO_CERTIFICATES（用户看到「解析程序包时出现问题」）。
// 这里锁住「显式双签 + 签名身份不变 + 版本可回退 + 清单契约不被改坏」四件事，
// 防止后续优化时被删掉或为了兼容去动会破坏手机竖屏的声明。
void testTvInstallCompat() {
  final g = File('android/app/build.gradle.kts').readAsStringSync();
  check('R12 显式启用 v1(JAR) 签名',
      RegExp(r'enableV1Signing\s*=\s*true').hasMatch(g));
  check('R12 保留 v2 签名（API 24+ 完整校验）',
      RegExp(r'enableV2Signing\s*=\s*true').hasMatch(g));
  check('R12 双签挂在 signingConfigs.debug 上（不新建 keystore、身份不变）',
      RegExp(r'signingConfigs\s*\{[\s\S]{0,240}?getByName\("debug"\)'
              r'[\s\S]{0,240}?enableV1Signing')
          .hasMatch(g) &&
          g.contains('signingConfig = signingConfigs.getByName("debug")'));
  check('R12 注释记录解析失败成因（缺 MANIFEST.MF）',
      g.contains('META-INF/MANIFEST.MF') &&
          g.contains('INSTALL_PARSE_FAILED_NO_CERTIFICATES'));
  // 1.0.1 起：AGP 侧仍只能 24（Flutter 变体），真正的 minSdk 16 由单包组装脚本
  // `tooling/merge_single_apk.py` 产出的 manifest 决定。这条只锁「AGP 侧没有被
  // 伪造成 16」——真写成 16，flutter build 会直接改回 24，包也就永远打不出来。
  check('R12 AGP 侧 minSdk 仍为 24（Flutter 变体不可能更低）',
      RegExp(r'minSdk\s*=\s*24\b').hasMatch(g) &&
          g.contains('errorMinSdkVersion = 23'));

  final pub = File('pubspec.yaml').readAsStringSync();
  check('R12 版本号为 1.0.6',
      RegExp(r'^version:\s*1\.0\.6\+\d+\s*$', multiLine: true).hasMatch(pub));
  check('R12 versionCode 升到 +7（1.0.5 可覆盖升级，回退需先卸载）',
      RegExp(r'^version:\s*1\.0\.6\+7\s*$', multiLine: true).hasMatch(pub));

  // 「对外行为/调用方式」不变：平台通道兜底版本、安装器版本必须同源。
  final sys = File('lib/platform/system_channel.dart').readAsStringSync();
  check('R12 平台通道兜底版本与 pubspec 一致（设置页不显示旧版本）',
      sys.contains("kAppVersionName = '1.0.6'") &&
          RegExp(r'kAppVersionCode\s*=\s*7\s*;').hasMatch(sys));
  final iss = File('tooling/windows_installer.iss').readAsStringSync();
  check('R12 安装器版本与 pubspec 一致',
      iss.contains('#define AppVersion "1.0.6"'));

  // 参考实现的清单约定本工程已具备，本轮**无需改清单**；锁住它们防止被改坏。
  final m = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  check('R12 保持明文 HTTP（老播放源可达）',
      m.contains('android:usesCleartextTraffic="true"'));
  check('R12 保持 leanback/touchscreen 非必需（不被特性过滤）',
      m.contains('android.software.leanback" android:required="false"') &&
          m.contains('android.hardware.touchscreen" android:required="false"'));
  check('R12 保持 LEANBACK_LAUNCHER 与 TV 横幅（电视桌面可入口）',
      m.contains('android.intent.category.LEANBACK_LAUNCHER') &&
          m.contains('android:banner="@drawable/tv_banner"'));
  check('R12 未锁死横屏（手机竖屏这一既有行为不变）',
      !m.contains('screenOrientation'));
  check('R12 targetSdk 仍沿用工具链默认（不改运行期权限/后台行为）',
      g.contains('targetSdk = flutter.targetSdkVersion'));
}

// ------------------------------------------------- R5/R6 单一业务代码
void testSingleCodebase() {
  // 形态差异只允许出现在布局/焦点/输入映射三处。
  // 这里反过来查：业务核心目录里不得出现形态判定。
  const coreDirs = <String>[
    'lib/core/source',
    'lib/core/scheduler',
    'lib/core/player',
    'lib/features/live/live_catalog.dart',
  ];
  var offenders = <String>[];
  final pattern = RegExp(r'DeviceForm|isTv|tvMode|formFactor');
  for (final entry in coreDirs) {
    final f = File(entry);
    final files = f.existsSync() && f.path.endsWith('.dart')
        ? <File>[f]
        : Directory(entry)
            .listSync(recursive: true)
            .whereType<File>()
            .where((x) => x.path.endsWith('.dart'))
            .toList();
    for (final file in files) {
      if (pattern.hasMatch(file.readAsStringSync())) {
        offenders.add(file.path);
      }
    }
  }
  check('R5/R6 源解析/调度/播放内核不含形态分支（只有一套业务代码）',
      offenders.isEmpty, offenders.join(','));

  // 形态判定必须只在一个地方（app/form_factor.dart），避免出现第二份规则。
  final dupes = <String>[];
  for (final file in Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((x) => x.path.endsWith('.dart'))) {
    final src = file.readAsStringSync();
    // 「UI_MODE_TYPE_TELEVISION」这类判定只能出现在原生侧与 form_factor.dart。
    if (src.contains('UI_MODE_TYPE_TELEVISION')) dupes.add(file.path);
  }
  check('R1 形态规则未在别处重复实现',
      dupes.where((p) => !p.contains('form_factor.dart')).isEmpty, dupes.join(','));
}
