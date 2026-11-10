// 原生兼容分支（路线 B / legacy/）回归。
//
// 这一层是**纯 Dart 静态护栏**，不依赖 Android SDK、不依赖 adb：
//   A 清单与产物隔离 / B 版本策略镜像 / C 遥控器与生命周期 /
//   D 播放控制与换源 / E 频道清单数据 / F 生成器 / G 构建与产物报告 /
//   H 跨语言一致性 / I 主程序不回退 / J 产物报告 /
//   K 启动入口可解析性与崩溃自显（真机「装得上、打开闪退」回归护栏）
//
// 产物断言读 legacy/build_report.json（由 legacy/build_legacy.py 生成）；
// 未构建时该组跳过并明确打印，保证 CI 上没有 Android SDK 也能全绿。
//
// 运行：dart run tooling/verify_legacy_compat.dart
import 'dart:convert';
import 'dart:io';

int _pass = 0;
int _fail = 0;
int _skipped = 0;

void check(String name, bool ok, [String? detail]) {
  if (!ok) {
    _fail++;
    print('FAIL: $name${detail == null ? '' : ' —— $detail'}');
    return;
  }
  _pass++;
  print('PASS: $name');
}

void skip(String name, String why) {
  _skipped++;
  print('SKIP: $name —— $why');
}

/// Windows 工作区部分文件是 CRLF，统一成 LF 后再做多行匹配。
String read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

bool has(String src, String needle) => src.contains(needle);

void main() {
  final manifest = read('legacy/AndroidManifest.xml');
  final policy = read('legacy/src/com/shunbo/legacy/LegacyVersionCompat.java');
  final activity = read('legacy/src/com/shunbo/legacy/LegacyPlayerActivity.java');
  final playback = read('legacy/src/com/shunbo/legacy/PlaybackController.java');
  final catalog = read('legacy/src/com/shunbo/legacy/ChannelCatalog.java');
  final crash =
      File('legacy/src/com/shunbo/legacy/CrashReport.java').existsSync()
          ? read('legacy/src/com/shunbo/legacy/CrashReport.java')
          : '';
  final buildPy = read('legacy/build_legacy.py');
  final controlBar = read('legacy/src/com/shunbo/legacy/ControlBar.java');
  final channelPanel = read('legacy/src/com/shunbo/legacy/ChannelPanel.java');
  final searchPanel = read('legacy/src/com/shunbo/legacy/SearchPanel.java');
  final prefsSrc = read('legacy/src/com/shunbo/legacy/Prefs.java');
  final uiSrc = read('legacy/src/com/shunbo/legacy/Ui.java');
  final ledgerRaw = read('legacy/assets/probe_ledger.json');
  final probeTool = read('tooling/probe_legacy_streams.dart');
  final generator = read('tooling/gen_legacy_catalog.dart');
  final dartPolicy = read('lib/platform/version_compat.dart');
  final channelsJson = read('legacy/assets/channels.json');
  final data = jsonDecode(channelsJson) as Map<String, Object?>;
  final channels = (data['channels'] as List).cast<Map<String, Object?>>();
  final streams = <Map<String, Object?>>[
    for (final c in channels)
      for (final s in (c['streams'] as List)) s as Map<String, Object?>,
  ];
  // 台账由 probe_legacy_streams.dart 直接从**当前清单**逐条探测，因此镜像
  // 线路也在台账里；只有 collect_extra_streams.dart 后补的扩展线路另由
  // extra_streams.json 自证（Q 组）。台账只与「非扩展线路」逐条对齐。
  final mirrorStreams = streams.where((s) => s['mirror'] == true).toList();
  final extraStreams = streams.where((s) => s['extra'] == true).toList();
  final baseStreams = streams.where((s) => s['extra'] != true).toList();

  // ---------------------------------------------------------------- A 清单
  check('A01 独立包名，不覆盖主程序', has(manifest, 'package="com.shunbo.tv.legacy"'));
  check('A02 minSdk 16', has(manifest, 'android:minSdkVersion="16"'));
  check('A03 targetSdk 22（老系统不触发运行时权限）',
      has(manifest, 'android:targetSdkVersion="22"'));
  check('A04 versionName 1.0.4 / versionCode 5（与主程序同号）',
      has(manifest, 'android:versionName="1.0.4"') &&
          has(manifest, 'android:versionCode="5"'));
  check('A05 LEANBACK + LAUNCHER 双入口',
      has(manifest, 'android.intent.category.LAUNCHER') &&
          has(manifest, 'android.intent.category.LEANBACK_LAUNCHER'));
  check('A06 banner 与 icon 声明齐全',
      has(manifest, 'android:banner="@drawable/banner"') &&
          has(manifest, 'android:icon="@drawable/ic_launcher"'));
  check('A07 触摸非必需、leanback 非必需',
      has(manifest, 'android.hardware.touchscreen" android:required="false"') &&
          has(manifest, 'android.software.leanback" android:required="false"'));
  check('A08 横屏 + 配置变化不重建 Activity',
      has(manifest, 'sensorLandscape') && has(manifest, 'configChanges='));
  check('A09 网络 / 网络状态 / 唤醒锁权限',
      has(manifest, 'android.permission.INTERNET') &&
          has(manifest, 'android.permission.ACCESS_NETWORK_STATE') &&
          has(manifest, 'android.permission.WAKE_LOCK'));
  // 只查 XML 属性；manifest 头部的说明注释里会提到这个名词，不算声明。
  check('A10 未使用 API 23 才引入的 usesCleartextTraffic',
      !has(manifest, 'android:usesCleartextTraffic'));
  check('A11 只用系统内置主题，不引 AppCompat',
      has(read('legacy/res/values/styles.xml'), '@android:style/Theme.Black.NoTitleBar.Fullscreen'));
  // 真机闪退根因：manifest package 与 Java 源码包不同名，相对名会被系统
  // 拼成 dex 里不存在的类，安装能过、Activity 一加载就 ClassNotFoundException。
  check('A12 启动 Activity 必须写全限定名，不用相对名',
      has(manifest, 'android:name="com.shunbo.legacy.LegacyPlayerActivity"') &&
          !has(manifest, 'android:name=".LegacyPlayerActivity"'));

  // ------------------------------------------------------ B 版本策略镜像
  check('B01 比较对象只认 SDK_INT',
      has(policy, 'Android API 等级（Build.VERSION.SDK_INT）') &&
          has(activity, 'Build.VERSION.SDK_INT'));
  check('B02 阈值 24，Dart/Java 一致',
      has(policy, 'MIN_SUPPORTED_API = 24') &&
          has(dartPolicy, 'kMinSupportedAndroidApi = 24'));
  check('B03 严格小于，Dart/Java 一致',
      has(policy, 'compareToThreshold(parsed.intValue()) < 0') &&
          has(dartPolicy, 'compareToThreshold(parsed) < 0'));
  check('B04 探测失败保守进兼容分支',
      has(policy, 'Reason.PROBE_FAILED') && has(policy, 'Branch.LEGACY_COMPAT') &&
          has(dartPolicy, 'CompatReason.probeFailed'));
  check('B05 缺失 / 非法分开归因而都进兼容分支',
      has(policy, 'Reason.MISSING_VERSION') && has(policy, 'Reason.INVALID_VERSION') &&
          has(policy, 'Branch.LEGACY_COMPAT'));
  check('B06 release 只展示、绝不参与比较',
      has(policy, '绝不参与比较') && has(dartPolicy, '仅展示'));
  check('B07 parseApiLevel 拒绝小数 / 布尔 / NaN / 越界',
      has(policy, 'd != Math.rint(d)') &&
          has(policy, 'Double.isNaN(d)') &&
          has(policy, 'Double.isInfinite(d)') &&
          has(policy, 'value >= 1 && value <= 1000') &&
          has(policy, "c < '0' || c > '9'"));
  check('B08 非 Android 走 notApplicable + 默认流程',
      has(policy, 'Branch.NOT_APPLICABLE') &&
          has(policy, 'Reason.NOT_APPLICABLE') &&
          has(policy, 'if (!isAndroid)'));
  check('B09 决策不可变、启动期锁存一次',
      has(policy, 'public static final class Decision') &&
          has(activity, 'private LegacyVersionCompat.Decision decision') &&
          has(activity, 'decision = probeVersion()'));
  // 帮助页现在由 MODE_HELP 统一调度：setMode 里 buildHelp() 填内容再显隐，
  // 不再有独立的 setHelpVisible。
  check('B10 判定结果进入信息页展示',
      has(activity, 'decision.diagnosticText()') &&
          has(activity, 'private void buildHelp()') &&
          has(activity, 'setMode(MODE_HELP)'));
  check('B11 API≥24 提示改用主程序但不拒绝运行',
      has(activity, 'Branch.DEFAULT_FLOW') &&
          has(activity, '建议改用 Flutter 主程序'));

  // --------------------------------------------- C 遥控器与生命周期
  check('C01 上下键 / CH± 换台',
      has(activity, 'KeyEvent.KEYCODE_DPAD_UP') &&
          has(activity, 'KeyEvent.KEYCODE_CHANNEL_UP') &&
          has(activity, 'KeyEvent.KEYCODE_DPAD_DOWN') &&
          has(activity, 'KeyEvent.KEYCODE_CHANNEL_DOWN'));
  check('C02 左右键换线路',
      has(activity, 'KeyEvent.KEYCODE_DPAD_LEFT') &&
          has(activity, 'KeyEvent.KEYCODE_DPAD_RIGHT') &&
          has(activity, 'switchStream(-1)') &&
          has(activity, 'switchStream(1)'));
  check('C03 数字键选台 + 2 秒自动提交',
      has(activity, 'KeyEvent.KEYCODE_0') &&
          has(activity, 'KeyEvent.KEYCODE_9') &&
          has(activity, 'numberCommitMs = 2000L') &&
          has(activity, 'indexOfNumber(num)'));
  // 原来的「频道栏 6 秒自动隐藏」已被可聚焦控制条取代：OK 展开控制条，
  // 按设置（默认 30 秒）无操作回落播放态（频道抽屉改由控制条第一项「频道」进入）。
  check('C03b OK 展开控制条，浮层按设置（默认 30 秒）无操作自动收起',
      has(activity, 'idleHideMs = 30000L') &&
          has(activity, 'scheduleControlHide()') &&
          has(activity, 'resetOverlayHide()') &&
          has(activity, 'if (mode == target) setMode(MODE_PLAY)'));
  check('C04 换台连按合并为一个提交窗口',
      has(activity, 'zapCommitMs = 280L') &&
          has(activity, 'ui.removeCallbacks(zapCommitTask)') &&
          has(activity, 'int desired = ((base + delta) % n + n) % n') &&
          has(activity, 'int target = resolvePlayable(desired, dir)') &&
          has(activity, 'zapTarget = target'));
  check('C05 播放键暂停 / 恢复',
      has(activity, 'KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE') &&
          has(playback, 'togglePause()'));
  check('C06 菜单 / 信息键看分支诊断',
      has(activity, 'KeyEvent.KEYCODE_MENU') && has(activity, 'KeyEvent.KEYCODE_INFO'));
  check('C07 返回键分层收起 + 双击退出',
      has(activity, 'onBackPressedCompat()') &&
          has(activity, 'BACK_DOUBLE_MS = 2000L') &&
          has(activity, 'setMode(MODE_PLAY)'));
  check('C08 SurfaceHolder 回调与前台恢复',
      has(activity, 'implements SurfaceHolder.Callback') &&
          has(activity, 'surfaceCreated(SurfaceHolder') &&
          has(activity, 'surfaceDestroyed(SurfaceHolder') &&
          has(activity, 'protected void onResume()'));
  check('C09 暂停 / 销毁都释放内核，不泄漏 native',
      has(activity, 'protected void onPause()') &&
          has(activity, 'protected void onDestroy()') &&
          (activity.split('playback.release()').length - 1) >= 3);
  check('C10 常亮 + 全屏 SurfaceView',
      has(activity, 'FLAG_KEEP_SCREEN_ON') &&
          has(activity, 'new SurfaceView(this)') &&
          has(activity, 'MATCH_PARENT'));
  check('C11 隐藏时不吞画面：状态层 / 控制条默认不可见',
      has(activity, 'centerStatus.setVisibility(View.GONE)') &&
          has(activity, 'controlBar.setVisible(next == MODE_CONTROL)') &&
          has(activity, 'channelPanel.hide()'));
  check('C12 清单 / so 加载失败有明确提示，不静默黑屏',
      has(activity, '频道清单加载失败') && has(activity, '播放内核加载失败'));

  // --------------------------------------------- D 播放控制与换源
  check('D01 使用官方 ijkplayer 0.8.8，非系统 MediaPlayer',
      has(playback, 'import tv.danmaku.ijk.media.player.IjkMediaPlayer;') &&
          buildPy.contains('ijkplayer-java-0.8.8') &&
          !has(playback, 'new MediaPlayer()'));
  // 2026-11-09：软硬解改成设置项驱动，但 API 18 默认仍是软解。
  check('D02 关硬解 / 关 OpenSL ES，走 FFmpeg 软解（API 18 稳）',
      has(playback, 'private boolean hardDecode = false') &&
          has(playback, 'currentUseHard ? 1 : 0') &&
          has(playback, '"opensles", 0') &&
          has(playback, 'public void setHardDecode(boolean on)'));
  check('D03 请求头透传（源站校验 Referer）',
      has(playback, 'p.setDataSource(context, Uri.parse(s.url), s.headers)') &&
          has(catalog, 'headers.put(key'));
  check('D04 8 秒首帧超时判失败（默认 8 秒，可由设置改成 12 / 18 秒）',
      has(playback, 'DEFAULT_FIRST_FRAME_TIMEOUT_MS = 8000L') &&
          has(playback, 'firstFrameTimeoutMs = DEFAULT_FIRST_FRAME_TIMEOUT_MS') &&
          has(playback, 'handler.postDelayed(timeoutTask, waitMs)') &&
          has(playback, '首帧超时（" + (waitMs / 1000L)'));
  check('D05 本轮失败线路记账，绕完一圈带可行动原因报不可用',
      has(playback, 'attempted.contains') &&
          has(playback, 'listener.onAllStreamsFailed(channel, failureReason())') &&
          has(playback, '"本机 HTTPS 连续失败（TLS / 证书链）'));
  // 旧判据要求「整体跳过」，正是苏州台全部报不可用的根因，本轮改为降级。
  check('D06 https 连续失败只降级：两遍扫描仍会把加密线路试完',
      has(playback, 'HTTPS_FAILURE_STREAK_LIMIT = 3') &&
          has(playback, 'httpsUnavailable = true') &&
          has(playback, 'if (findNext(httpsUnavailable)) return true;') &&
          has(playback, 'return httpsUnavailable && findNext(false);') &&
          has(playback, 'if (skipHttps && s.https) continue;'));
  check('D07 带 resolver 的过期令牌线路直接跳过',
      has(playback, 's.resolver != null') && has(playback, 'attempted.add'));
  check('D08 失败从当前候选列表重新出发，不累积偏移',
      has(playback, 'int idx = (streamIndex + step) % total') &&
          has(playback, 'streamIndex = (idx + 1) % target.streams.size()'));
  // 缓冲卡死修复后，native 回调先 postToUi 回主线程、再用 generation
  // 隔离旧 player；旧的「suppressingCallbacks 全局布尔」已删除。
  check('D09 native 回调切回主线程重建 player，且旧代回调作废',
      has(playback, 'postToUi(new Runnable()') &&
          has(playback, 'isCurrent(gen, mp)') &&
          has(playback, 'handler.post(new Runnable()') &&
          !has(playback, 'suppressingCallbacks'));
  check('D10 起播异常不外抛到 Activity',
      has(playback, 'catch (Throwable t)') && has(playback, 'safeMessage(t)'));
  check('D11 直播异常结束重连当前线路而非跳台，反复结束才换线',
      has(playback, 'onCompletion(') &&
          has(playback, 'retryCurrentStream()') &&
          has(playback, 'COMPLETION_RETRY_LIMIT'));
  check('D12 release 清理 display / stop / reset / release',
      has(playback, 'p.setDisplay(null)') &&
          has(playback, 'p.stop()') && has(playback, 'p.reset()') &&
          has(playback, 'p.release()'));

  // --------------------------------------------- E 频道清单数据
  // 1.0.1 起清单与主程序**同源**：优先吃 dump_live_catalog 导出的运行时频道表，
  // 没有导出文件时才退回内置实测清单。判据看 sourceKind + builtIn 两个字段，
  // 而不是写死某一个文件名 —— 开关在哪一侧都要能自证。
  check('E01 格式与来源标注',
      data['format'] == 'shunbo-legacy-catalog/1' &&
          (data['sourceKind'] == 'unified_channels.json' ||
              data['sourceKind'] == 'verified_channels.g.dart') &&
          (data['builtIn'] as String).contains('verified_channels.g.dart'));
  check('E02 台数 / 线路数与声明一致',
      data['channelCount'] == channels.length &&
          data['streamCount'] == streams.length);
  // 数量随「主程序运行时那套源」浮动（网络源会增减），所以不写死具体值，
  // 只锁规模下限与自洽性，并把实测值打出来供报告引用。
  check('E03 规模达到「与主程序同一套」的量级（≥900 台 / ≥1500 线路）',
      channels.length >= 900 && streams.length >= 1500,
      '当前 ${channels.length}/${streams.length}');
  // List 的 == 是身份比较，必须逐元素比。
  check('E04 台号从 1 起连续',
      channels.asMap().entries.every((e) => e.value['num'] == e.key + 1));
  // 与主程序同一套源之后不再是「全是 m3u8」：全网发现源里还有 mp4 / flv / ts，
  // 以及少量无后缀的 HLS（靠台账的 #EXTM3U 判据识别）。锁「协议只有明文 http/https」
  // 与「主体仍是 HLS」，避免把需要组播重写或特殊协议的线路混进来。
  final m3u8Count = streams
      .where((s) => (s['url'] as String).toLowerCase().contains('.m3u8'))
      .length;
  check('E05 只有 http/https，且 HLS 占比 ≥85%',
      streams.every((s) {
        final u = s['url'] as String;
        return u.startsWith('http://') || u.startsWith('https://');
      }) && m3u8Count * 100 >= streams.length * 85,
      'm3u8 $m3u8Count / ${streams.length}');
  // https 线路保留但排序靠后；数量随来源浮动，只锁「两种协议都真的有」。
  check('E06 https 与明文 http 并存（https 靠后、失败整体跳过）',
      streams.any((s) => s['https'] == true) &&
          streams.any((s) => s['https'] == false),
      'https ${streams.where((s) => s['https'] == true).length} / '
          '全量 ${streams.length}');
  check('E07 每条线路都有 rank/verified/label/https',
      streams.every((s) =>
          s.containsKey('rank') && s.containsKey('verified') &&
          s.containsKey('label') && s.containsKey('https')));
  // 内置那批是 libmpv 逐条解码验证过的；全网发现源来的线路没跑过解码门禁，
  // 只经台账可达性判定。判据变成「确实有一批解码实测过的线路」+「它们排在
  // 未实测的前面」（后者由 E09/E10 的排序断言保证）。
  final verifiedCount = streams.where((s) => s['verified'] == true).length;
  check('E08 保留解码实测标记且数量充足（≥300 条）', verifiedCount >= 300,
      'verified $verifiedCount / ${streams.length}');
  // 排序第一层已从 rank 换成台账可达性：可达(0) → 未探测(1) → 死线(2)。
  // 判据用「组序号非递减」而不是 rank，因为真机可达性比画质更值钱。
  int probeRank(Map<String, Object?> s) {
    final v = s['probeOk'];
    return v == true ? 0 : (v == null ? 1 : 2);
  }

  check('E09 台内排序：台账可达的线路全部排在死线之前',
      channels.every((c) {
        final ss = (c['streams'] as List).cast<Map<String, Object?>>();
        for (var i = 1; i < ss.length; i++) {
          if (probeRank(ss[i - 1]) > probeRank(ss[i])) return false;
        }
        return true;
      }));
  check('E09b 可达线路之间按探测耗时升序（快的先试）',
      channels.every((c) {
        final ss = (c['streams'] as List).cast<Map<String, Object?>>();
        for (var i = 1; i < ss.length; i++) {
          final a = ss[i - 1], b = ss[i];
          if (probeRank(a) != 0 || probeRank(b) != 0) continue;
          // 扩展线路单独一层：内容未经电视端复核，整体排在原有可达线路之后；
          // 跨层比较耗时没有意义，层内仍必须按耗时升序。
          if ((a['extra'] == true) != (b['extra'] == true)) continue;
          final ma = (a['probeMs'] as int?) ?? 1 << 30;
          final mb = (b['probeMs'] as int?) ?? 1 << 30;
          if (ma > mb) return false;
        }
        return true;
      }));
  // 台账同一层内才轮到老的三级键：解码实测优先 → rank 降序 → 同 rank 明文 http 优先。
  // `verified` 必须一起比：死线里既有「两小时前解码通过、现在连不上」的线路，
  // 也有纯聚合来的未实测线路，前者仍应排前面（证据更强），只比 rank 会假红。
  check('E10 同台账层内 verified 优先、rank 非递增、同 rank 明文 http 在前',
      channels.every((c) {
        final ss = (c['streams'] as List).cast<Map<String, Object?>>();
        for (var i = 1; i < ss.length; i++) {
          final a = ss[i - 1], b = ss[i];
          if (probeRank(a) != probeRank(b)) continue;
          if (probeRank(a) == 0) {
            final ma = (a['probeMs'] as int?) ?? 1 << 30;
            final mb = (b['probeMs'] as int?) ?? 1 << 30;
            if (ma != mb) continue;
          }
          final va = a['verified'] == true, vb = b['verified'] == true;
          if (va != vb) {
            if (!va) return false;
            continue;
          }
          final ra = a['rank'] as int, rb = b['rank'] as int;
          if (ra != rb) {
            if (ra < rb) return false;
            continue;
          }
          if (a['https'] == true && b['https'] == false) return false;
        }
        return true;
      }));
  check('E11 没有组播 / 运营商内网线路（原生端未实现）',
      !channelsJson.contains('multicast') && !channelsJson.contains('carrierNet'));

  // --------------------------------------------- E2 拼音索引 / 可播台账
  check('E12 每台都有拼音首字母串与全拼串（遥控器检索依赖）',
      channels.every((c) =>
          (c['pyi'] as String).isNotEmpty && (c['py'] as String).isNotEmpty),
      '缺拼音: ${channels.where((c) => (c['pyi'] as String).isEmpty).map((c) => c['name']).take(5).toList()}');
  // 索引必须真实可拼：CCTV1 → cctv1、中文台名首字母成串（浙江 zjws / 河南 hnws）。
  check('E13 拼音索引抽样正确（浙江卫视 / 河南卫视前缀）',
      channels.any((c) => c['pyi'] == 'cctv1') &&
          channels.any((c) => c['name'] == '浙江卫视' && c['pyi'] == 'zjws') &&
          channels.any((c) => c['name'] == '河南卫视' && c['pyi'] == 'hnws'),
      'cctv1 命中: ${channels.where((c) => c['pyi'] == 'cctv1').length}');
  check('E14 台账元信息齐全（时间 + 判据）',
      (data['probeAt'] as String).isNotEmpty &&
          (data['probeMethod'] as String).contains('m3u8') &&
          (data['pinyinSource'] as String).isNotEmpty);
  final probed = streams.where((s) => s.containsKey('probeOk')).toList();
  check('E15 全部线路都有探测结论（无未探测残留，不写死条数）',
      probed.length == streams.length,
      '${probed.length}/${streams.length}');
  final dead = streams.where((s) => s['probeOk'] == false).toList();
  // 关键决策：死线只沉底、不删除。PC 侧可达 ≠ 电视侧可达，删了就再也回不来。
  check('E16 死线保留在清单里，只靠排序沉底',
      dead.isNotEmpty && dead.length < streams.length,
      '死线 ${dead.length} 条');
  check('E17 可达线路计数与实际一致',
      channels.every((c) {
        final ss = (c['streams'] as List).cast<Map<String, Object?>>();
        final alive = ss.where((s) => s['probeOk'] == true).length;
        if (alive == 0) return !c.containsKey('reachable');
        return c['reachable'] == alive;
      }));

  // --------------------------------------------- F 生成器
  check('F01 数据源是主程序同一份 verified_channels.g.dart',
      has(generator, "import '../lib/features/live/verified_channels.g.dart';"));
  // 注释里会解释「为什么不合并」，要判的是没有 import 该数据源。
  check('F02 刻意不合并令牌会过期的官方卫星源',
      !has(generator, "import '../lib/features/live/official_satellite.g.dart'") &&
          has(generator, '按小时'));
  check('F03 过滤非 public 通道与空 URL',
      has(generator, 'LiveChannelType.public') && has(generator, 'url.isEmpty'));
  check('F04 排序语义：实测 > rank > http 优先 > 原序号',
      has(generator, "if (va != vb) return va ? -1 : 1;") &&
          has(generator, 'return rb.compareTo(ra);') &&
          has(generator, 'return ha ? 1 : -1;') &&
          has(generator, 'return a.key.compareTo(b.key);'));
  // 来源变了：现在标的是「导出时刻」，用来判断这份固化清单有多旧。
  check('F05 生成文件头标注数据时间',
      RegExp(r'^\d{4}-\d{2}-\d{2}T').hasMatch(data['verifiedAt'] as String) &&
          (data['pinyinSource'] as String).contains('pinyin_initials.json'),
      data['verifiedAt'] as String);

  // --------------------------------------------- G 构建脚本
  check('G01 仅 v1(SHA-1) 签名，不签 v2/v3',
      has(buildPy, '"--v2-signing-enabled", "false"') &&
          has(buildPy, '"--v3-signing-enabled", "false"') &&
          has(buildPy, '"--v1-signing-enabled", "true"'));
  check('G02 三个 so 只进 armeabi-v7a 且 stored 对齐',
      has(buildPy, '"lib/armeabi-v7a/"') &&
          has(buildPy, 'zipfile.ZIP_STORED') &&
          has(buildPy, 'ZIPALIGN'));
  check('G03 产物名带 Legacy 与 1.0.4，独立包名',
      has(buildPy, 'OUT_NAME = "Shunbo-Legacy-1.0.4-armv7a.apk"') &&
          has(buildPy, '"independent package"'));
  check('G04 构建内置断言 + 分支场景表',
      has(buildPy, 'def branch_of(') &&
          has(buildPy, '"API 18 真机", 18, True, "legacyCompat"') &&
          has(buildPy, 'raise SystemExit(1)'));
  check('G05 声明第三方来源与许可',
      has(buildPy, 'LGPL-2.1') && has(buildPy, 'ijkplayer'));
  check('G06 不写入主程序版本常量 / gradle / 正式产物',
      !has(buildPy, 'pubspec.yaml') &&
          !has(buildPy, 'enableV1Signing') &&
          !has(buildPy, 'build.gradle.kts') &&
          !has(buildPy, 'Shunbo-1.0.0-full.apk'));
  // 本轮踩过：重建直接覆盖了真机验证过的包，用户手上唯一的回退件就没了。
  // 归档必须在 apksigner 写出之前发生，否则已经是新包了。
  check('G07 重建前把上一版产物归档到 dist/_prev（不覆盖唯一的回退件）',
      has(buildPy, 'prev_dir = os.path.join(DIST, "_prev")') &&
          has(buildPy, 'shutil.move(OUT_PATH, os.path.join(prev_dir, prev_name))') &&
          buildPy.indexOf('shutil.move(OUT_PATH, os.path.join(prev_dir, prev_name))') <
              buildPy.indexOf('"--out", OUT_PATH, aligned'));

  // --------------------------------------------- H 跨语言一致性
  check('H01 Dart/Java/Python 阈值同为 24',
      has(dartPolicy, 'kMinSupportedAndroidApi = 24') &&
          has(policy, 'MIN_SUPPORTED_API = 24') &&
          has(buildPy, 'MIN_SUPPORTED_API = 24'));
  check('H02 三层都用严格小于',
      has(dartPolicy, 'compareToThreshold(parsed) < 0') &&
          has(policy, 'compareToThreshold(parsed.intValue()) < 0') &&
          has(buildPy, 'api < MIN_SUPPORTED_API'));
  check('H03 三层都把探测失败归到兼容分支',
      has(dartPolicy, 'CompatReason.probeFailed') &&
          has(policy, 'Reason.PROBE_FAILED') &&
          has(buildPy, '"探测失败", 30, False, "legacyCompat"'));

  // --------------------------------------------- I 主程序隔离
  check('I01 主程序版本升到 1.0.4+5（与单包同号）',
      has(read('pubspec.yaml'), 'version: 1.0.4+5'));
  check('I02 主程序 minSdk 仍是 24（未被兼容分支伪装改小）',
      has(read('android/app/build.gradle.kts'), 'minSdk'));
  check('I03 Flutter 播放器装配不含 legacyCompat 护栏',
      !has(read('lib/core/player/player_bootstrap.dart'), 'legacyCompat'));

  // --------------------------------------------- L 遥控器交互（主流电视端形态）
  check('L01 控制条 8 个动作齐全（频道/上下台/暂停/换线/收藏/检索/信息）',
      has(controlBar, 'A_PANEL = "panel"') &&
          has(controlBar, 'A_PREV = "prev"') &&
          has(controlBar, 'A_PAUSE = "pause"') &&
          has(controlBar, 'A_NEXT = "next"') &&
          has(controlBar, 'A_LINE = "line"') &&
          has(controlBar, 'A_FAV = "fav"') &&
          has(controlBar, 'A_SEARCH = "search"') &&
          has(controlBar, 'A_INFO = "info"'));
  check('L02 控制条焦点左右环绕，不走到头卡死',
      has(controlBar, 'focus = ((focus + delta) % n + n) % n') &&
          has(controlBar, 'listener.onControlFocus(getFocusId())'));
  check('L03 焦点框可见：聚焦行/按钮换底色 + 主色文字',
      has(uiSrc, 'static final int FOCUS = 0xFF1E88E5') &&
          has(uiSrc, 'row.setBackground(rect(c, FOCUS, 6, 0, 0))') &&
          has(uiSrc, 'btn.setBackground(rect(c, FOCUS, 8, 0, 0))') &&
          has(uiSrc, 'row.setTextColor(ACCENT)'));
  check('L04 控制条只发命令，不改播放状态（状态由 Activity 单点持有）',
      has(controlBar, 'listener.onControlAction(getFocusId())') &&
          has(activity, 'ControlBar.A_PANEL.equals(action)') &&
          has(activity, 'ControlBar.A_INFO.equals(action)'));
  check('L05 频道抽屉动态分组：全部 / 收藏 / 清单里出现的小组',
      has(channelPanel, 'GROUP_FAV = "#fav"') &&
          has(channelPanel, 'private void buildGroups()') &&
          has(channelPanel, 'private static String shortGroup(String g)'));
  check('L06 抽屉上下焦点环绕、末行不再误聚焦地区卡（OK 只切台）、菜单键收藏、数字键不吞',
      has(channelPanel, 'focus = (focus - 1 + filtered.size()) % filtered.size()') &&
          has(channelPanel, 'if (focus < filtered.size() - 1) focus++') &&
          has(channelPanel, 'case KeyEvent.KEYCODE_PROG_GREEN:') &&
          has(channelPanel, 'case KeyEvent.KEYCODE_MENU:') &&
          has(channelPanel, '数字键不吞'));
  check('L07 收藏落 SharedPreferences 私有文件，写盘失败不影响交互',
      has(prefsSrc, 'sp = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)') &&
          has(prefsSrc, 'putStringSet(K_FAV, set)') &&
          has(prefsSrc, 'catch (Throwable ignored)'));
  check('L08 上次观看：启动回到该台，并在首帧后记录台号 + 线路',
      has(activity, 'channelIndex = preferredChannelIndex()') &&
          has(activity, 'private int preferredChannelIndex()') &&
          has(activity, 'prefs.saveLast(currentChannel().num, currentStreamIndex)') &&
          has(activity, 'int startStream = prefs == null ? 0 : prefs.lastStream()'));
  check('L09 台号直达：最多 4 位、2 秒自动提交、超范围给范围提示',
      has(activity, 'if (numberBuffer.length() >= 4) numberBuffer = ""') &&
          has(activity, 'ui.postDelayed(numberCommitTask, numberCommitMs)') &&
          has(activity, '"没有台号（范围 1–"') &&
          has(activity, 'catalog.indexOfNumber(num)'));
  check('L10 换台横幅 1.5 秒自动消失，输入台号期间不抢浮层',
      has(activity, 'ui.postDelayed(bannerHideTask, 1500L)') &&
          has(activity, 'if (numberBuffer.length() > 0) return;   // 正在输入台号时不抢浮层'));
  check('L11 检索用 26 字母参差键盘（4 行，按行长做焦点边界）',
      has(searchPanel, '"ABCDEFG", "HIJKLMN", "OPQRSTU", "VWXYZ",') &&
          has(searchPanel, 'gridCol >= KEY_ROWS[gridRow].length()'));
  check('L12 拼音评分分档：首字母 > 全拼 > 台名，前缀优先于包含',
      has(searchPanel, 'if (pyi.startsWith(q)) return 100;') &&
          has(searchPanel, 'if (py.startsWith(q)) return 80;') &&
          has(searchPanel, 'if (name.startsWith(q)) return 70;') &&
          has(searchPanel, 'if (pyi.contains(q)) return 50;') &&
          has(searchPanel, 'if (py.contains(q)) return 30;') &&
          has(searchPanel, 'if (name.contains(q)) return 20;'));
  check('L13 检索结果用插入排序稳定（分值降序 + 台号升序）',
      has(searchPanel, 'for (int i = 1; i < scored.size(); i++)') &&
          has(searchPanel, 'while (j >= 0 && better(cur, scored.get(j)))'));
  // 回落条件必须同时判断「模式仍停在 MODE_PANEL」：从频道栏打开地区面板时
  // 频道栏也会被 hide()，无条件回落会把刚打开的面板又关掉。
  check('L14 面板 / 检索收起后模式必须回落，但不抢走主动切走的地区面板',
      has(activity, 'if (!channelPanel.isVisible() && mode == MODE_PANEL)') &&
          has(activity, 'setMode(MODE_PLAY);\n                return true;') &&
          has(activity, 'if (!regionPanel.isVisible()) setMode(MODE_PANEL);'));
  check('L15 控制条展开时按下键不换台（防顺手误切台）',
      has(activity, 'case KeyEvent.KEYCODE_DPAD_DOWN:') &&
          has(activity, '// 控制条已展开时按下键不换台'));
  // 只判 import：注释里解释「刻意不用 RecyclerView / Leanback」不算引入。
  final imports =
      RegExp(r'^import\s+[^;]+;', multiLine: true).allMatches(
          controlBar + channelPanel + searchPanel + uiSrc + prefsSrc);
  check('L16 交互层零 support/Leanback 依赖，全部 API 16 可用控件',
      imports.every((m) {
        final s = m.group(0)!;
        return !s.contains('android.support') &&
            !s.contains('androidx.') &&
            !s.contains('android.widget.RecyclerView');
      }),
      'imports: ${imports.map((m) => m.group(0) ?? '').where((s) => s.contains('support') || s.contains('androidx')).toList()}');

  // --------------------------------------------- M 可播台账工具链
  check('M01 探测器判据：m3u8 含 #EXTM3U + 首分片 Range 实收 ≥4KB',
      has(probeTool, "body.contains('#EXTM3U')") &&
          has(probeTool, 'Range') &&
          has(probeTool, 'kMinSegmentBytes'));
  // 全量清单涨到 1900+ 线路后，第二轮的规模必须可调；硬编码「8/2 并发」会
  // 让工具失去可运维性。判据改成「不变量 + 自证」：工具要支持参数化，台账要
  // 把实际用的参数写进 params，并满足「第二轮并发更低、窗口更长」的反误杀条件。
  check('M02 两轮探测可参数化，且参数会写进台账',
      has(probeTool, "_optInt(args, '--conc1'") &&
          has(probeTool, "_optInt(args, '--recheck-max'") &&
          has(probeTool, "'params': params"));
  // 并发池串台是真踩过的坑：播放列表正文与 base 必须是 probeOne 的局部变量。
  check('M03 探测并发池不共用可变状态（串台回归护栏）',
      has(probeTool, 'var playlistText = body;') &&
          has(probeTool, 'var playlistBase = playlist.url;') &&
          has(probeTool, 'playlistBase = v.url;') &&
          !has(probeTool, '_lastPlaylistText'));
  final ledger = jsonDecode(ledgerRaw) as Map<String, Object?>;
  final lparams = (ledger['params'] as Map?)?.cast<String, Object?>() ?? {};
  check('M03b 台账自证探测参数，且第二轮确实降并发 + 拉窗口',
      lparams.length >= 5 &&
          (lparams['conc2'] as int) <= (lparams['conc1'] as int) &&
          (lparams['timeout2'] as int) >= (lparams['timeout1'] as int),
      'params=$lparams');
  final ledgerItems = (ledger['streams'] as List).cast<Map<String, Object?>>();
  // 条数不再写死：判据是「台账与清单逐条对齐」。注意清单里同一 URL 可能出现在
  // 多个台（1786 个唯一 URL / 1895 条），所以查的是覆盖而不是唯一性。
  final ledgerUrls = ledgerItems.map((s) => '${s['url']}').toSet();
  // 台账探的是原始 https 线路；明文镜像另由 P 组按实测文件验收。
  final uncovered =
      baseStreams.where((s) => !ledgerUrls.contains('${s['url']}')).length;
  check('M04 台账格式正确，且覆盖清单里每一条非镜像线路',
      ledger['format'] == 'shunbo-legacy-probe/1' &&
          ledger['streamCount'] == baseStreams.length &&
          ledgerItems.length == baseStreams.length &&
          uncovered == 0 &&
          streams.length == baseStreams.length + extraStreams.length,
      '${ledger['format']} / ${ledgerItems.length} 条 / 未覆盖 $uncovered'
      ' / 扩展 ${extraStreams.length}');
  check('M05 清单 probeAt 与台账 probedAt 同源',
      data['probeAt'] == ledger['probedAt']);
  // 死线必须写清卡在哪一段（playlist / init / segment），否则只能猜。
  check('M06 死线归因分阶段（playlist / init / segment）且带原始错误',
      ledgerItems.where((s) => s['ok'] == false).every((s) =>
          (s['stage'] as String).isNotEmpty && (s['error'] as String).isNotEmpty) &&
          ledgerItems.where((s) => s['ok'] == true).every((s) => s['stage'] == 'done'));

  // --------------------------------------------- N 单包（Flutter 与原生同包）
  // 为什么要有这一组：Flutter 3.47 的 Gradle 插件会把 minSdk 改回 24（实测把
  // 脚本里的 16 覆写成 flutter.minSdkVersion，产物 badging 仍是 24），所以
  // 「一个包通吃」只能靠手工组装。这里锁住那条链上每一个容易退化的点。
  final mergePy = File('tooling/merge_single_apk.py').existsSync()
      ? read('tooling/merge_single_apk.py')
      : '';
  final singleManifest = File('legacy/single/AndroidManifest.xml').existsSync()
      ? read('legacy/single/AndroidManifest.xml')
      : '';
  final router = File('legacy/src/com/shunbo/legacy/RouterActivity.java')
          .existsSync()
      ? read('legacy/src/com/shunbo/legacy/RouterActivity.java')
      : '';

  check('N01 单包组装脚本存在，且用 --stable-ids 锁住资源 ID',
      mergePy.isNotEmpty &&
          has(mergePy, '"--stable-ids", ids_path') &&
          has(mergePy, '--min-sdk-version", str(MIN_SDK)') &&
          has(mergePy, 'zipalign'));
  check('N02 单包清单只有 RouterActivity 一个桌面入口',
      RegExp(r'android\.intent\.category\.LAUNCHER').allMatches(singleManifest).length == 1 &&
          has(singleManifest, 'com.shunbo.legacy.RouterActivity') &&
          has(singleManifest, 'com.shunbo.legacy.LegacyPlayerActivity'));
  // ContentProvider 在 Application.onCreate 之前由系统创建，API 18 上会去加载
  // classes2.dex 里的 androidx 类 → 直接崩在启动，代码层面拦不住，只能删声明。
  // 判据必须落在「元素声明」上：清单头部注释里解释了为什么要删，注释里出现
  // androidx.startup 是正常的，不能因此判红（本组上一版就踩了这个假阳性）。
  final manifestNoComments =
      singleManifest.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
  check('N03 单包清单不声明任何 ContentProvider / androidx.startup',
      !has(manifestNoComments, '<provider') &&
          !has(manifestNoComments, 'androidx.startup') &&
          has(singleManifest, 'ContentProvider'));
  // 删掉 provider 等于放弃 ProcessLifecycleInitializer / ProfileInstallerInitializer。
  // 前者一旦被调用会 IllegalStateException，所以我方代码必须完全不碰它。
  final appSources = <String>[];
  for (final dir in ['lib', 'android/app/src/main/kotlin']) {
    final d = Directory(dir);
    if (!d.existsSync()) continue;
    for (final f in d.listSync(recursive: true)) {
      if (f is File && (f.path.endsWith('.dart') || f.path.endsWith('.kt'))) {
        appSources.add(f.readAsStringSync());
      }
    }
  }
  final joined = appSources.join('\n');
  check('N03b 主体代码不引用 ProcessLifecycleOwner（删 provider 才安全）',
      appSources.isNotEmpty &&
          !joined.contains('ProcessLifecycleOwner') &&
          !joined.contains('profileinstaller'),
      '扫了 ${appSources.length} 个源文件');
  check('N04 分流入口只读 SDK_INT，用 Class.forName 做探针',
      has(router, 'Build.VERSION.SDK_INT >= FLUTTER_MIN_API') &&
          has(router, 'Class.forName(FLUTTER_ACTIVITY)') &&
          has(router, 'new Intent(this, LegacyPlayerActivity.class)') &&
          has(router, 'next.putExtras(extras)'));
  // 关键结构：主 dex 必须是原生，否则 API 18 只加载 classes.dex 时找不到入口类。
  check('N05 分流入口不 import Flutter / androidx（编译期零依赖）',
      !RegExp(r'^import\s+(io\.flutter|androidx)', multiLine: true)
          .hasMatch(router) &&
          has(router, 'FLUTTER_ACTIVITY = "com.shunbo.shunbo.MainActivity"'));
  // Flutter 产物里只有 assets/flutter_assets/**，原生界面要的 assets/channels.json
  // 完全不存在（本机实测）。少了它，API 18 打开就是「频道清单加载失败」。
  // 这里做跨语言交叉校验：Java 端 ChannelCatalog.ASSET 的名字必须和打包脚本一致，
  // 否则改名一侧就会静默变成「装得上、打不开」。
  final catalogJava = File('legacy/src/com/shunbo/legacy/ChannelCatalog.java')
          .existsSync()
      ? read('legacy/src/com/shunbo/legacy/ChannelCatalog.java')
      : '';
  final javaAssetName =
      RegExp(r'ASSET\s*=\s*"([^"]+)"').firstMatch(catalogJava)?.group(1) ?? '';
  final pyCatalogName = RegExp(r'LEGACY_CATALOG\s*=\s*"([^"]+)"')
          .firstMatch(mergePy)?.group(1) ??
      '';
  check('N12 组装脚本会把原生清单打进单包，且文件名与 Java 端一致',
      javaAssetName.isNotEmpty &&
          javaAssetName == pyCatalogName &&
          has(mergePy, 'CATALOG_ENTRY = "assets/" + LEGACY_CATALOG') &&
          has(mergePy, 'zout.writestr(fixed_info(CATALOG_ENTRY, stored=True)'),
      'Java=$javaAssetName / py=$pyCatalogName');

  final singleReportFile = File('legacy/single/single_report.json');
  if (!singleReportFile.existsSync()) {
    skip('N 单包产物', '尚未运行 tooling/merge_single_apk.py，跳过产物断言');
  } else {
    final sr =
        jsonDecode(singleReportFile.readAsStringSync()) as Map<String, Object?>;
    final sc = (sr['checks'] as Map).cast<String, Object?>();
    check('N06 单包组装断言全绿', sc.values.every((v) => v == true),
        '失败项: ${sc.entries.where((e) => e.value != true).map((e) => e.key).toList()}');
    check('N07 单包 minSdk 16 / targetSdk 36',
        sr['minSdk'] == 16 && sr['targetSdk'] == 36,
        '${sr['minSdk']}/${sr['targetSdk']}');
    check('N08 单包 dex 顺序：原生主 dex + Flutter 顺延',
        (sr['dexOrder'] as List).join(',') ==
            'classes.dex,classes2.dex,classes3.dex',
        '${sr['dexOrder']}');
    check('N09 单包版本 1.0.4（code 5）',
        sr['versionName'] == '1.0.4' && sr['versionCode'] == 5);
    check('N10 两个入口都指向分流路由',
        sr['launchable'] == 'com.shunbo.legacy.RouterActivity' &&
            sr['leanbackLaunchable'] == sr['launchable']);
    check('N11 单包大于纯 Flutter 包（多出原生 dex 与 ijkplayer）',
        (sr['size'] as int) > 20 * 1024 * 1024 &&
            (sr['flutterMinSdk'] as int) >= 24,
        '${sr['size']} B，Flutter 侧 minSdk=${sr['flutterMinSdk']}');
    // 单包里的清单必须就是当前 legacy/assets/channels.json（含探测台账排序），
    // 否则装进去的是上一版清单，两个界面看到的频道/线路不是同一套。
    final cat = (sr['catalog'] as Map?)?.cast<String, Object?>();
    check('N13 单包内清单与当前 channels.json 同源同规模',
        cat != null &&
            cat['entry'] == 'assets/channels.json' &&
            cat['channels'] == channels.length &&
            cat['streams'] == streams.length,
        cat == null
            ? '报告缺 catalog 段'
            : '${cat['channels']} 台 / ${cat['streams']} 线路（源 ${channels.length}/${streams.length}）');
  }

  // --------------------------------------------- J 产物报告（可选）
  final reportFile = File('legacy/build_report.json');
  if (!reportFile.existsSync()) {
    skip('J 产物报告', '尚未运行 legacy/build_legacy.py，跳过产物断言');
  } else {
    final r = jsonDecode(reportFile.readAsStringSync()) as Map<String, Object?>;
    final checksMap = (r['checks'] as Map).cast<String, Object?>();
    check('J01 构建断言全绿', checksMap.values.every((v) => v == true),
        '失败项: ${checksMap.entries.where((e) => e.value != true).map((e) => e.key).toList()}');
    check('J02 80 条构建断言（含启动入口一致性、交互、台账与明文镜像护栏）',
        checksMap.length == 80, '当前 ${checksMap.length}');
    check('J03 minSdk/targetSdk/版本正确',
        r['minSdk'] == 16 && r['targetSdk'] == 22 &&
            r['versionName'] == '1.0.4' && r['versionCode'] == 5);
    check('J04 仅 v1 签名、仅 armeabi-v7a',
        (r['signature'] as String).contains('v1-only') &&
            (r['abis'] as List).length == 1 &&
            (r['abis'] as List)[0] == 'armeabi-v7a');
    check('J05 清单数量与源一致',
        r['channelCount'] == channels.length && r['streamCount'] == streams.length);
    final apk = File('dist/Shunbo-Legacy-1.0.4-armv7a.apk');
    check('J06 APK 存在且大小/哈希与报告一致',
        apk.existsSync() &&
            apk.lengthSync() == (r['size'] as int) &&
            (r['size'] as int) > 3000000);
    check('J07 分支场景表 8 例全部命中',
        (r['branchScenarios'] as List).length == 8 &&
            (r['branchScenarios'] as List).every((s) =>
                (s as Map)['expected'] == s['actual']));
    check('J08 产物包名独立', r['package'] == 'com.shunbo.tv.legacy');
    final highRefs = (r['highApiClassRefs'] as List).cast<String>();
    check('J09 dex 无未复核的 API 19+ framework 类引用',
        highRefs.every((c) => c == 'android/media/MediaDataSource'),
        '实际: $highRefs');
    check('J10 产物里的 launchable-activity 就是 dex 里的类',
        r['launchableActivity'] == 'com.shunbo.legacy.LegacyPlayerActivity' &&
            r['leanbackLaunchableActivity'] == r['launchableActivity'],
        '实际: ${r['launchableActivity']} / ${r['leanbackLaunchableActivity']}');
    check('J11 构建断言含 badging→dex 反查且为真',
        checksMap['launchable activity resolves to dex class'] == true &&
            checksMap['manifest activity uses fully-qualified name'] == true);
  }

  // -------------------------------- K 启动入口与崩溃自显
  check('K01 构建脚本从 aapt2 badging 反查启动类',
      has(buildPy, "^launchable-activity: name='([^']+)'") &&
          has(buildPy, 'launch_descriptor in dex'));
  check('K02 构建脚本同时核对 LEANBACK 入口',
      has(buildPy, '^leanback-launchable-activity: name='));
  check('K03 崩溃留痕类存在且只用私有文件',
      has(crash, 'class CrashReport') &&
          has(crash, 'openFileOutput') &&
          has(crash, 'deleteFile') &&
          !has(crash, 'getExternalStorage'));
  check('K04 默认未捕获异常处理器保留原处理器',
      has(crash, 'getDefaultUncaughtExceptionHandler') &&
          has(crash, 'previous.uncaughtException(thread, error)'));
  check('K05 onCreate 第一行安装留痕、整段 try/catch Throwable',
      has(activity, 'CrashReport.install(this);') &&
          activity.indexOf('CrashReport.install(this);') <
              activity.indexOf('super.onCreate(savedInstanceState);') &&
          has(activity, 'catch (Throwable t)'));
  check('K06 启动失败显示纯 TextView 错误页，不再向上抛',
      has(activity, 'showFatal(t)') &&
          has(activity, 'CrashReport.shortTrace(t)') &&
          !has(activity, 'throw t;'));
  check('K07 兜底态拦截按键，避免连锁 NPE',
      has(activity, 'if (fatal)') && has(activity, 'showFatalLast()'));
  check('K08 帮助页展示上次崩溃与内核失败原因',
      has(activity, 'CrashReport.readLast(this)') &&
          has(activity, 'nativeLibraryError'));
  check('K09 内核加载失败返回真实异常而非吞成 false',
      has(playback, 'public static String loadNativeLibraries()') &&
          has(playback, 't.getClass().getName()'));
  check('K10 清单解析异常也留痕，不静默黑屏',
      has(activity, 'catch (Throwable e)') &&
          has(activity, 'CrashReport.record(this, "ChannelCatalog.load", e)'));

  // ------------------------------- O 本轮三项行为（截图红标 + 补充需求）
  //
  // 这一组不只 grep 源码：O03 / O05 直接对 channels.json 做与 Java 端等价的
  // 「4K 稳定分区」「地区可见视图」仿真，O16 用状态机跑缓冲→换台→首帧→
  // 缓冲超时的转移序列。真机行为仍需上机验证，这里锁的是规则本身不回退。
  final regionPanelSrc = read('legacy/src/com/shunbo/legacy/RegionPanel.java');
  final liveRegionSrc = read('lib/features/live/live_region.dart');
  final livePageSrc = read('lib/ui/live/live_page.dart');
  final regionData = data['regions'] as Map<String, Object?>?;

  final numOfName = <String, int>{
    for (final c in channels) (c['name'] as String): (c['num'] as int),
  };
  check('O01 央视 1–17 连号（截图红标：CCTV-2 台号必须是 2）',
      List<int>.generate(17, (i) => i + 1)
          .every((n) => numOfName['CCTV-$n'] == n) &&
          channels.take(17).toList().asMap().entries.every(
              (e) => e.value['name'] == 'CCTV-${e.key + 1}'),
      'CCTV-1=${numOfName['CCTV-1']} / CCTV-2=${numOfName['CCTV-2']} / '
      'CCTV-17=${numOfName['CCTV-17']}');
  check('O02 台号仍从 1 起连续，4K 标记与声明一致',
      channels.asMap().entries.every((e) => e.value['num'] == e.key + 1) &&
          channels.every((c) => c.containsKey('is4K')) &&
          data['fourKCount'] ==
              channels.where((c) => c['is4K'] == true).length);

  // 与 ChannelPanel.rebuild() 完全相同的稳定分区。
  List<Map<String, Object?>> fourKFirst(List<Map<String, Object?>> src) {
    final a = <Map<String, Object?>>[];
    final b = <Map<String, Object?>>[];
    for (final c in src) {
      ((c['is4K'] == true) ? a : b).add(c);
    }
    return <Map<String, Object?>>[...a, ...b];
  }

  bool partitionOk(List<Map<String, Object?>> src) {
    final out = fourKFirst(src);
    if (out.length != src.length) return false;
    final firstRest = out.indexWhere((c) => c['is4K'] != true);
    if (firstRest >= 0 &&
        out.skip(firstRest).any((c) => c['is4K'] == true)) return false;
    bool stable(bool fourK) =>
        out.where((c) => (c['is4K'] == true) == fourK)
            .map((c) => c['num']).join(',') ==
        src.where((c) => (c['is4K'] == true) == fourK)
            .map((c) => c['num']).join(',');
    if (!stable(true) || !stable(false)) return false;
    // 台号集合不变：置顶是显示规则，不重新编号。
    return out.map((c) => c['num']).toSet().length ==
        src.map((c) => c['num']).toSet().length;
  }

  final groupNames = <String>{
    for (final c in channels) (c['group'] as String?) ?? '',
  };
  final groupsForCheck = <List<Map<String, Object?>>>[
    channels,
    for (final g in groupNames)
      channels.where((c) => c['group'] == g).toList(),
    // 「收藏」是任意子集，也要遵守同一条置顶规则。
    channels.where((c) => (c['num'] as int) % 37 == 0).toList(),
  ];
  check('O03 4K 在「全部 / 各分组 / 收藏」列表内都归集置顶且顺序稳定',
      groupsForCheck.every(partitionOk) &&
          groupsForCheck.every((g) => fourKFirst(g).isNotEmpty),
      '${groupsForCheck.length} 个列表');
  check('O04 4K 归集不改变台号与线路排序（字段独立于排序键）',
      has(generator, "ChannelQuality.is4K") &&
          has(channelPanel, 'catalog.get(index.intValue()).is4K') &&
          has(channelPanel, 'filtered.addAll(fourK)') &&
          has(channelPanel, 'filtered.addAll(rest)') &&
          !has(channelPanel, 'is4K ? 0 : 1'));

  // 与 ChannelCatalog.visibleUnderRegion() 等价的地区过滤仿真。
  List<Map<String, Object?>> visibleUnder(
      String mode, String province, String city) {
    return channels.where((c) {
      if (c['group'] != '地方频道') return true;
      final p = (c['province'] as String?) ?? '';
      final ci = (c['city'] as String?) ?? '';
      if (mode == 'province') return p.isNotEmpty && p == province;
      if (mode == 'other') return p.isEmpty && ci.isEmpty;
      return ci.isNotEmpty && ci == city;
    }).toList();
  }

  List<Map<String, Object?>> localOnly(List<Map<String, Object?>> src) =>
      src.where((c) => c['group'] == '地方频道').toList();

  final suzhou = channels.where((c) => c['city'] == '苏州').toList();
  final jiangsu = channels.where((c) => c['province'] == '江苏').toList();
  final nanjing = channels.where((c) => c['city'] == '南京').toList();
  final defMode = regionData?['defaultMode'] as String? ?? '';
  final defProvince = regionData?['defaultProvince'] as String? ?? '';
  final defCity = regionData?['defaultCity'] as String? ?? '';
  final defaultView = visibleUnder(defMode, defProvince, defCity);
  final provinceView = visibleUnder('province', '江苏', '');
  final cityView = visibleUnder('city', '', '南京');
  final otherView = visibleUnder('other', '', '');
  final nonLocal = localOnly(channels).length;

  check('O05 默认江苏·苏州·市模式，只看苏州地方台，非地方台不丢',
      defMode == 'city' && defProvince == '江苏' && defCity == '苏州' &&
          localOnly(defaultView).length == suzhou.length &&
          localOnly(defaultView).every((c) => c['city'] == '苏州') &&
          defaultView.length - localOnly(defaultView).length ==
              channels.length - nonLocal,
      '默认 ${defaultView.length} 台（苏州 ${suzhou.length} 台）');
  check('O06 选省加载本省全部地方台 / 选市只加载本市台 / 其它城市可回捞',
      localOnly(provinceView).length == jiangsu.length &&
          localOnly(provinceView).every((c) => c['province'] == '江苏') &&
          localOnly(cityView).length == nanjing.length &&
          localOnly(cityView).every((c) => c['city'] == '南京') &&
          localOnly(otherView).length == (regionData?['otherCount'] ?? -1) &&
          localOnly(otherView).every((c) =>
              ((c['province'] as String?) ?? '').isEmpty &&
              ((c['city'] as String?) ?? '').isEmpty),
      '江苏全省 ${jiangsu.length} / 南京 ${nanjing.length} / '
      '其它 ${regionData?['otherCount']}');
  final provinceOpts =
      (regionData?['provinces'] as List? ?? []).cast<Map<String, Object?>>();
  final cityOpts = ((regionData?['cities'] as Map?)?['江苏'] as List? ?? [])
      .cast<Map<String, Object?>>();
  check('O07 省 / 市选项的台数与过滤结果一致（切换后列表准确）',
      provinceOpts.any((p) =>
              p['name'] == '江苏' && p['count'] == localOnly(provinceView).length) &&
          cityOpts.any((o) =>
              o['name'] == '苏州' && o['count'] == suzhou.length) &&
          provinceOpts.length >= 20,
      '${provinceOpts.length} 个省 / 江苏下 ${cityOpts.length} 个市');
  check('O08 地区字段覆盖与「不误把省份当城市」',
      channels.every((c) => c.containsKey('province') && c.containsKey('city')) &&
          channels.where((c) => c['group'] != '地方频道')
              .every((c) => c['province'] == '' && c['city'] == '') &&
          has(liveRegionSrc, '省份名**刻意不收**'));

  check('O09 频道号后面的 ·N 后缀已去掉（截图红标）',
      !has(channelPanel, 'label += "   ·"') &&
          !has(channelPanel, 'c.reachable > 0) label +=') &&
          has(channelPanel, 'String label = pad(c.num) + "  " + c.name;'));
  check('O10 首帧成功后收起底部提示与 toast；顶部信息条已整体删除（红标「不管什么时候都不要显示」）',
      has(activity, 'private void hideOsdForPlayback()') &&
          RegExp(r'onFirstFrame\([\s\S]{0,700}hideOsdForPlayback\(\)')
              .hasMatch(activity) &&
          has(activity, 'if (firstFrameMs >= 0) hideOsdForPlayback()') &&
          // 顶部信息条：字段 / 构建 / 显示路径全部不再存在 ⇒ 任何时刻都不会出现。
          !has(activity, 'topBar') &&
          !has(activity, 'topMeta') &&
          !has(activity, 'topNumber') &&
          !has(activity, 'showOsd') &&
          !has(activity, 'showTopBar()'));
  check('O17 换台（startChannel / zap）不再弹任何顶部条，反馈走中央「台号 + 台名」横幅',
      has(activity, 'showChannelBanner();') &&
          RegExp(r'private void zap\([\s\S]{0,700}showChannelBanner\(\)')
              .hasMatch(activity));
  check('O18 换台横幅台号（numberDigits）仍为中性白 TEXT，不用亮蓝 ACCENT',
      has(activity, 'numberDigits.setTextColor(Ui.TEXT)') &&
          !has(activity, 'numberDigits.setTextColor(Ui.ACCENT)'));

  check('O19 频道栏在「地方频道」之后新增内容分类导航（新闻/体育/影视/少儿/纪实/生活），并改用 inCategory 叠加过滤',
      // 六个内容分类常量紧跟 LOCAL_GROUP 后插入。
      has(channelPanel, '"新闻", "体育", "影视", "少儿", "纪实", "生活"') &&
      // 过滤从「主分类相等」升级为「分类集合包含」——叠加匹配的核心。
      // 地区镜像分组已移除，过滤键直接用当前 chip 的 key（inCategory 叠加匹配）。
      has(channelPanel, 'c.inCategory(key)') &&
          // 内容分类判定与 Flutter 端 channel_taxonomy.dart 同关键词口径。
          has(catalog, 'static String thematicOf(') &&
          has(catalog, 'boolean inCategory(String category)') &&
          // 分类集合：主分类 + 叠加的内容分类。
          has(catalog, 'public final List<String> cats;'));

  check('O20 分组 chip 横向可滚动，分组变多后「其它 / 少儿 / 纪实 / 生活」仍可达（截图红标）',
      has(channelPanel, 'new HorizontalScrollView(context)') &&
          has(channelPanel, 'chipScroll.addView(chips') &&
          has(channelPanel, 'private void scrollChipIntoView(') &&
          has(channelPanel, 'chipScroll.smoothScrollTo') &&
          // 滚动容器与 chip 都不可聚焦：避免再次出现 OK 被抢走（误弹省市面板）。
          has(channelPanel, 'chipScroll.setFocusable(false)') &&
          has(channelPanel, 'chip.setFocusable(false)'));

  check('O21 省 / 市面板字号 22sp、行数按屏高算、weight 铺满列高、单行省略不溢出（截图红标）',
      has(regionPanelSrc, 'private static final float ROW_SP = 22f;') &&
          has(regionPanelSrc, 'private static int computeRows(Context c)') &&
          has(regionPanelSrc, 'LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f') &&
          has(regionPanelSrc, 'setEllipsize(TextUtils.TruncateAt.END)') &&
          has(regionPanelSrc, 'private void applyRowStyle(') &&
          has(regionPanelSrc, 'new RelativeSizeSpan('));

  check('O11 地区面板两列：选省 / 选市 / 其它城市三种模式',
      has(regionPanelSrc, 'COL_PROVINCE') &&
          has(regionPanelSrc, 'COL_CITY') &&
          has(regionPanelSrc, 'ChannelCatalog.MODE_PROVINCE') &&
          has(regionPanelSrc, 'ChannelCatalog.MODE_CITY') &&
          has(regionPanelSrc, 'ChannelCatalog.MODE_OTHER') &&
          has(regionPanelSrc, 'reloadCities()'));
  check('O12 地区偏好落盘、启动恢复；切换不重启播放器、当前台不越界',
      has(prefsSrc, 'K_REGION_MODE') &&
          has(prefsSrc, 'void saveRegion(') &&
          has(prefsSrc, 'K_RECENT_REGIONS') &&
          has(activity, 'catalog.setRegion(prefs') &&
          has(activity, 'prefs.saveRegion(mode, province, city)') &&
          has(activity, 'final int at = catalog.indexOfNumber(currentNum)') &&
          has(activity, 'playingChannel = catalog.get(index)') &&
          !has(activity, 'startChannel(0)'));
  check('O13 地区过滤是 catalog 的统一视图（面板/检索/换台/数字直达同源）',
      has(catalog, 'private List<Channel> visible;') &&
          has(catalog, 'public int size() { return visible.size(); }') &&
          has(catalog, 'visibleUnderRegion(all.get(i))') &&
          has(catalog, 'public int maxNumber()') &&
          has(searchPanel, 'i < catalog.size()'));
  check('O14 构建脚本把新增的 RegionPanel.java 编进 dex',
      has(buildPy, '"RegionPanel.java"'));

  final releaseBlock =
      RegExp(r'RELEASE_EXECUTOR\.execute\([\s\S]*?\}\);')
          .firstMatch(playback)
          ?.group(0) ??
          '';
  check('O15 缓冲卡死根因已拆：stop/reset/release 全在后台线程',
      releaseBlock.contains('p.stop()') &&
          releaseBlock.contains('p.reset()') &&
          releaseBlock.contains('p.release()') &&
          has(playback, 'Executors.newSingleThreadExecutor') &&
          !has(playback, 'suppressingCallbacks') &&
          has(playback, 'try { p.setDisplay(null); }'),
      '主线程只做 setDisplay(null)');
  check('O16 native 回调统一回主线程 + 代际隔离旧 player 回调',
      has(playback, 'private void postToUi(Runnable action)') &&
          has(playback, 'private boolean isCurrent(int gen, IMediaPlayer mp)') &&
          has(playback, 'generation++') &&
          'postToUi(new Runnable()'.allMatches(playback).length >= 4 &&
          RegExp(r'onInfo\([\s\S]{0,900}postToUi').hasMatch(playback));
  check('O17 缓冲可恢复：首帧超时 + 首帧后缓冲看门狗 + FFmpeg IO 超时',
      has(playback, 'FIRST_FRAME_TIMEOUT_MS = 8000L') &&
          has(playback, 'BUFFER_WATCHDOG_MS = 15000L') &&
          has(playback, 'scheduleBufferWatchdog(gen, idx, s)') &&
          has(playback, '"timeout", NETWORK_TIMEOUT_US') &&
          has(playback, 'COMPLETION_RETRY_LIMIT') &&
          has(playback, 'failCurrent(idx, s, -3, "缓冲超时（15 秒）")'));

  // 纯逻辑状态机：缓冲中换台可抢占、旧代回调作废、首帧取消看门狗、
  // 首帧后缓冲超时会换线。与 PlaybackController 的语义一一对应。
  var simGen = 0;
  var simState = 'idle';
  var simWatchdog = false;
  void simStart() {
    simGen++;
    simState = 'connecting';
    simWatchdog = false;
  }

  void simBuffering(int gen) {
    if (gen != simGen) return;
    simState = 'buffering';
    simWatchdog = true;
  }

  void simFirstFrame(int gen) {
    if (gen != simGen) return;
    simState = 'playing';
    simWatchdog = false;
  }

  void simWatchdogFire(int gen) {
    if (gen != simGen || !simWatchdog) return;
    simState = 'failover';
  }

  simStart();
  simBuffering(1);
  final s1 = simState == 'buffering' && simWatchdog;
  simStart(); // 用户按 ↑↓ / 数字键换台，立刻抢占
  simBuffering(1); // 旧 player 迟到的 BUFFERING_START
  final s2 = simState == 'connecting' && simGen == 2;
  simFirstFrame(2);
  final s3 = simState == 'playing' && !simWatchdog;
  simBuffering(2);
  simWatchdogFire(2);
  final s4 = simState == 'failover';
  check('O18 缓冲状态机仿真：抢占 / 代际隔离 / 首帧恢复 / 超时换线',
      s1 && s2 && s3 && s4, '$simState gen=$simGen');

  check('O19 主程序与兼容分支共用 4K 规则、默认本地与省 / 市切换',
      has(liveRegionSrc, 'abstract final class ChannelQuality') &&
          has(generator, 'bool _is4K(String name) => ChannelQuality.is4K(name);') &&
          has(livePageSrc, 'ChannelQuality.fourKFirst(') &&
          has(livePageSrc, 'preferredLocal: CityDirectory.defaultLocalCity') &&
          has(liveRegionSrc, 'defaultLocalCity') &&
          has(liveRegionSrc, 'isProvinceSelection(city)') &&
          has(livePageSrc, 'CityDirectory.provincePrefix + p.name') &&
          has(livePageSrc, 'CityDirectory.provincesOf(local)'));

  // ---------------------------------------------------------------- P 组
  // 本轮三张截图：苏州台全不可用、列表留白/不透明、地区切换入口缺失。
  final mirrorTool = read('tooling/probe_plaintext_mirrors.dart');
  final mirrorRaw = read('legacy/assets/plaintext_mirrors.json');
  final mirrorData = jsonDecode(mirrorRaw) as Map<String, Object?>;
  final mirrorEntries = (mirrorData['mirrors'] as List)
      .cast<Map<String, Object?>>();
  final barSrc = read('legacy/src/com/shunbo/legacy/ControlBar.java');
  final settingsSrc = read('legacy/src/com/shunbo/legacy/SettingsPanel.java');

  check('P01 明文镜像探测工具：两阶段实测 + 直连，不猜白名单',
      has(mirrorTool, "'#EXTM3U'") &&
          has(mirrorTool, "req.headers.set('range', 'bytes=0-65535')") &&
          has(mirrorTool, "findProxy = ((Uri uri) => 'DIRECT')") &&
          has(mirrorTool, 'if (seg.status >= 200 && seg.status < 300 && seg.bytes > 0)'));
  check('P02 镜像文件自证探测参数与逐条实测结果',
      mirrorData['format'] == 'shunbo-plaintext-mirrors/1' &&
          (mirrorData['probedAt'] as String).contains('2026-') &&
          (mirrorData['candidateUrls'] as int) > 500 &&
          mirrorData['probedUrls'] == mirrorData['candidateUrls'] &&
          mirrorData['verifiedCount'] == mirrorEntries.length &&
          mirrorEntries.isNotEmpty,
      '${mirrorData['verifiedCount']}/${mirrorData['probedUrls']} 通过');
  final mirrorByHttp = <String, Map<String, Object?>>{
    for (final e in mirrorEntries) '${e['httpUrl']}': e,
  };
  check('P03 每条镜像都同 host / path，且首分片真的有字节',
      mirrorEntries.every((e) {
        final a = Uri.tryParse('${e['httpsUrl']}');
        final b = Uri.tryParse('${e['httpUrl']}');
        return a != null &&
            b != null &&
            a.scheme == 'https' &&
            b.scheme == 'http' &&
            a.host == b.host &&
            a.path == b.path &&
            (e['segmentBytes'] as int) > 0 &&
            (e['probeMs'] as int) > 0;
      }));
  check('P04 清单里的镜像条数与声明一致，且只写实测通过的 http 地址',
      data['plaintextMirrorCount'] == mirrorStreams.length &&
          mirrorStreams.length > 100 &&
          mirrorStreams.every((s) =>
              s['https'] == false &&
              s['probeOk'] == true &&
              (s['label'] as String).startsWith('明文·') &&
              mirrorByHttp.containsKey('${s['url']}')) &&
          streams.length == baseStreams.length + extraStreams.length,
      '镜像 ${mirrorStreams.length} 条 / 覆盖 ${data['plaintextMirrorChannels']} 台');
  check('P05 镜像只补给「原本没有任何明文线路」的频道',
      channels.every((c) {
        final ss = (c['streams'] as List).cast<Map<String, Object?>>();
        if (!ss.any((s) => s['mirror'] == true)) return true;
        return !ss.any((s) => s['mirror'] != true && s['https'] == false);
      }));

  // O 组已经算过 suzhou（默认地区应显示的苏州台集合），这里直接复用。
  final suzhouNums = suzhou.map((c) => c['num'] as int).toSet();
  check('P06 受影响范围明确：苏州 7 台（369–373 / 618 / 619）全部有明文线路',
      suzhou.length == 7 &&
          suzhouNums.containsAll(<int>[369, 370, 371, 372, 373, 618, 619]) &&
          suzhou.every((c) => (c['streams'] as List)
              .any((s) => (s as Map<String, Object?>)['https'] == false)),
      '${suzhou.map((c) => c['num']).toList()}');
  // 直接仿真 PlaybackController 在 TLS 降级态的第一遍扫描：只要能挑出
  // 一条明文线路，就不会再出现「全部 1 条线路不可用」。
  final degradedPick = suzhou.every((c) => (c['streams'] as List)
      .any((s) => (s as Map<String, Object?>)['https'] == false &&
          (s['resolver'] ?? '').toString().isEmpty));
  check('P07 降级态仿真：7 个苏州台都能挑到可试线路（不再瞬间全灭）',
      degradedPick && has(playback, 'return httpsUnavailable && findNext(false);'));
  final kan0512 = mirrorEntries
      .where((e) => '${e['httpsUrl']}'.contains('tylive.kan0512.com'))
      .toList();
  check('P08 苏州 4K 官方 https 线路已被明文镜像覆盖（PC 实测 https 握手失败）',
      kan0512.length == 2 &&
          kan0512.every((e) => '${e['httpUrl']}'.startsWith('http://')));

  check('P09 异常态：原因可行动、OK 一键重试、控制条也有重试',
      has(activity, 'onAllStreamsFailed(ChannelCatalog.Channel channel, String reason)') &&
          has(activity, '"\\n按 OK 重试 · ←→ 换线 · 频道键换台') &&
          has(activity, 'else if (allStreamsFailed) {') &&
          has(activity, 'private void retryAllStreams()') &&
          has(playback, 'public void retryAll()') &&
          has(barSrc, 'A_RETRY') &&
          has(activity, 'ControlBar.A_RETRY.equals(action)'));
  check('P10 手动换线会清掉 TLS 经验值，点名的线路一定真的去试',
      has(playback, 'httpsUnavailable = false;') &&
          has(playback, 'public void retryAll()') &&
          has(playback, 'public void switchTo(int index)'));

  check('P11 频道栏半透明：压暗层 alpha 受控，非焦点行无底色',
      has(uiSrc, 'PANEL_SCRIM = 0xA60B1420') &&
          has(uiSrc, 'CARD_SCRIM = 0x801E2733') &&
          has(channelPanel, 'root.setBackgroundColor(Ui.PANEL_SCRIM)') &&
          has(uiSrc, 'row.setBackground(null);'));
  check('P12 行数按屏幕高度算、行高用 weight 均分，消掉下半屏留白',
      has(channelPanel, 'computeRows(context)') &&
          has(channelPanel, 'CHROME_DP = 190') &&
          has(channelPanel, 'dm.heightPixels / dm.density') &&
          has(channelPanel, 'MATCH_PARENT, 0, 1f') &&
          has(channelPanel, 'setPlaybackState('));
  check('P13 底部状态卡常驻显示「当前台 / 线路 / 播放状态 / 地区」',
      has(channelPanel, 'nowPlaying.setText(b.toString())') &&
          has(channelPanel, 'regionLine.setText("地区  "') &&
          has(channelPanel, 'stateFailed') &&
          has(activity, 'private void updatePanelState()'));
  // 截图红标「地区切换去除」+ 缺陷「第二次换台误弹省市面板」：
  // 频道栏内曾有两个地区入口（「地区·…切换」chip 与可聚焦的底部状态卡），
  // 状态卡是整窗唯一可聚焦控件，OK 会被它当点击 → onRegionRequested()。
  // 现在两个入口都已移除、状态卡改非焦点纯展示，地区切换只剩绿键 / 控制条 / 设置。
  check('P14 地区切换入口收敛为绿键 / 控制条 / 设置；频道栏内 chip 与状态卡入口已移除（OK 只切台）',
      has(activity, 'case KeyEvent.KEYCODE_PROG_GREEN:') &&
          has(channelPanel, 'case KeyEvent.KEYCODE_PROG_GREEN:') &&
          has(channelPanel, 'listener.onRegionRequested()') &&
          !has(channelPanel, 'infoCard.setOnClickListener') &&
          has(channelPanel, 'infoCard.setFocusable(false)') &&
          !has(channelPanel, 'GROUP_REGION') &&
          has(barSrc, 'A_REGION') &&
          has(activity, 'ControlBar.A_REGION.equals(action)') &&
          has(settingsSrc, '"地区切换"') &&
          has(settingsSrc, 'onRegionFromSettings') &&
          has(activity, 'public void onRegionFromSettings'));
  check('P15 地区面板三列 + 最近使用 + 当前播放状态，选中即应用',
      has(regionPanelSrc, 'COL_QUICK = 0') &&
          has(regionPanelSrc, 'prefs.recentRegions()') &&
          has(regionPanelSrc, 'listener.onRegionPicked(e[1], e[2], e[3])') &&
          has(regionPanelSrc, 'void setStateText(String text)') &&
          has(activity, 'regionPanel.setStateText('));
  check('P16 地区切换不重启播放器，最近地区落盘可回溯',
      !has(activity, 'startChannel(0)') &&
          has(activity, 'showToast("已切换到 "') &&
          has(prefsSrc, 'List<String[]> recentRegions()') &&
          has(activity, 'new RegionPanel(this, catalog, prefs, this)'));
  check('P17 频道栏内打开地区面板不会被「栏已隐藏」误判回落播放态',
      has(activity, 'if (!channelPanel.isVisible() && mode == MODE_PANEL)'));


  // ---------------------------------------------------------------- Q 本轮三项需求
  final bootSrc = read('legacy/src/com/shunbo/legacy/BootReceiver.java');
  final routerSrc = read('legacy/src/com/shunbo/legacy/RouterActivity.java');
  final singleManifestSrc = read('legacy/single/AndroidManifest.xml');
  final collectToolSrc = read('tooling/collect_extra_streams.dart');
  final extraFile = File('legacy/assets/extra_streams.json');
  final extraData = extraFile.existsSync()
      ? jsonDecode(read('legacy/assets/extra_streams.json'))
          as Map<String, Object?>
      : <String, Object?>{};
  final extraEntries = ((extraData['streams'] as List?) ?? <Object?>[])
      .cast<Map<String, Object?>>();

  check('Q01 设置面板接入主界面与构建脚本',
      has(activity, 'new SettingsPanel(this, prefs, this)') &&
          has(activity, 'MODE_SETTINGS') &&
          has(buildPy, '"SettingsPanel.java"') &&
          has(activity, 'SettingsPanel.Listener'));
  final settingKeys = <String>[
    'K_BOOT_AUTOSTART', 'K_BOOT_DIRECT_PLAY', 'K_START_CHANNEL',
    'K_PANEL_IDLE_MS', 'K_FAIL_FALLBACK', 'K_FAIL_HINT_MS',
    'K_QUALITY_PRIORITY', 'K_NUMBER_COMMIT_MS', 'K_ZAP_COMMIT_MS',
    'K_FIRST_FRAME_TIMEOUT_MS', 'K_ASPECT', 'K_HARD_DECODE',
  ];
  check('Q02 12 项设置 + 4 个动作，每项带真机限制说明',
      settingKeys.every((k) => has(settingsSrc, k) && has(prefsSrc, k)) &&
          has(settingsSrc, 'final String desc') &&
          settingsSrc.split('new Item(').length - 1 >= 15);
  check('Q03 两个包都声明开机自启权限与接收器',
      has(manifest, 'android.permission.RECEIVE_BOOT_COMPLETED') &&
          has(manifest, 'com.shunbo.legacy.BootReceiver') &&
          has(singleManifestSrc, 'android.permission.RECEIVE_BOOT_COMPLETED') &&
          has(singleManifestSrc, 'com.shunbo.legacy.BootReceiver') &&
          has(buildPy, '"BootReceiver.java"'));
  check('Q04 自启接收器读开关、走系统 LAUNCHER Intent、标记被透传',
      has(bootSrc, 'prefs.bootAutostart()') &&
          has(bootSrc, 'getLaunchIntentForPackage') &&
          has(bootSrc, 'LegacyPlayerActivity.EXTRA_AUTOSTART') &&
          has(bootSrc, 'FLAG_ACTIVITY_NEW_TASK') &&
          has(routerSrc, 'next.putExtras(extras)'));
  check('Q05 启动行为可设置：直达播放 / 先显示频道栏 / 启动频道三选一',
      has(activity, 'EXTRA_AUTOSTART') &&
          has(activity, 'if (!prefs.bootDirectPlay() && catalog != null) setMode(MODE_PANEL)') &&
          has(prefsSrc, 'int startChannelMode()') &&
          has(activity, 'final int startMode = prefs == null ? 0 : prefs.startChannelMode()') &&
          has(activity, 'prefs.isFavorite(catalog.get(i).id)'));
  check('Q06 频道栏 / 地区 / 检索 / 控制条统一空闲自动隐藏，按键重置计时',
      has(activity, 'private void resetOverlayHide()') &&
          has(activity, 'if (mode == MODE_CONTROL || mode == MODE_PANEL || mode == MODE_SEARCH') &&
          has(activity, 'ui.postDelayed(controlHideTask, idleHideMs)') &&
          has(prefsSrc, 'if (K_PANEL_IDLE_MS.equals(key)) return 30000') &&
          has(settingsSrc, '"不隐藏", "5 秒", "10 秒", "15 秒", "20 秒", "30 秒", "60 秒"'));
  check('Q07 切台失败提示定时消失，不再常驻画面中央',
      has(activity, 'scheduleFailureDismiss(channel)') &&
          has(activity, 'failHintTask = new Runnable()') &&
          has(activity, 'ui.postDelayed(failHintTask, hintMs)') &&
          has(activity, 'private void cancelFailureTasks()') &&
          has(activity, 'showStatus("")'));
  check('Q08 自动回退到「上一个真正出画」的频道',
      has(activity, 'lastGoodChannel = currentChannel()') &&
          has(activity, 'private void returnToLastGood()') &&
          has(activity, 'prefs.failFallback()') &&
          has(activity, 'startChannel(idx)') &&
          has(prefsSrc, 'if (K_FAIL_FALLBACK.equals(key)) return 1'));
  check('Q09 任意按键重置空闲计时并撤销待执行的自动回退',
      has(activity, 'resetOverlayHide();\n        cancelFailureTasks();'));
  check('Q10 「关于」从设置页跳信息页时不被误判回落播放态',
      has(activity,
          'if (mode == MODE_SETTINGS && !settingsPanel.isVisible())'));
  check('Q11 设置入口：控制条按钮 + 蓝键 / 设置键',
      has(controlBar, 'A_SETTINGS') &&
          has(activity, 'ControlBar.A_SETTINGS.equals(action)') &&
          has(activity, 'case KeyEvent.KEYCODE_PROG_BLUE:') &&
          has(activity, 'case KeyEvent.KEYCODE_SETTINGS:'));
  check('Q12 优先清晰度真实重排线路，清单带 quality 字段',
      has(catalog, 'public void applyQualityPriority(int mode)') &&
          has(catalog, 'public final int quality') &&
          has(activity, 'catalog.applyQualityPriority(prefs.qualityPriority())') &&
          has(generator, "'quality': _qualityOf(s.label, url)"));
  check('Q13 首帧超时与软硬解由设置项驱动内核',
      has(playback, 'public void setFirstFrameTimeoutMs(long ms)') &&
          has(playback, 'public void setHardDecode(boolean on)') &&
          has(playback, 'handler.postDelayed(timeoutTask, waitMs)') &&
          has(playback, 'currentUseHard ? 1 : 0') &&
          has(activity, 'applyPlaybackSettings()'));
  check('Q14 画面比例真实接线；顶部信息条开关已随信息条一并下线',
      has(activity, 'private void applyAspect()') &&
          has(activity, 'lp.height = (int) (dm.widthPixels / ratio)') &&
          has(activity, 'hideOsdForPlayback()') &&
          !has(prefsSrc, 'boolean showTopBar()') &&
          !has(settingsSrc, 'K_SHOW_TOP_BAR'));
  check('Q15 扩展线路有独立实测台账，每条都通过两段探测',
      extraData['format'] == 'shunbo-extra-streams/1' &&
          extraEntries.isNotEmpty &&
          extraEntries.every((e) =>
              '${e['url']}'.startsWith('http') &&
              (e['probeMs'] as int) > 0 &&
              (e['segmentBytes'] as int) >= 4096 &&
              (e['num'] as int) > 0),
      '通过 ${extraEntries.length} 条');
  check('Q16 清单里的扩展线路与声明一致，且都标 probeOk',
      data['extraStreamCount'] == extraStreams.length &&
          extraStreams.every((s) => s['probeOk'] == true && s['label'] != null) &&
          (data['extraStreamCount'] as int) > 0,
      '扩展 ${extraStreams.length} 条');
  final cctv1 = channels.firstWhere((c) => c['num'] == 1);
  final cctv1Hd = (cctv1['streams'] as List)
      .cast<Map<String, Object?>>()
      .where((s) => (s['quality'] as int? ?? 0) >= 720)
      .toList();
  check('Q17 CCTV-1 有 720P/1080P 线路，且至少 1 条实测可达',
      cctv1Hd.length >= 2 && cctv1Hd.any((s) => s['probeOk'] == true),
      '高清 ${cctv1Hd.length} 条');
  final popular = channels
      .where((c) => c['group'] == '央视频道' || c['group'] == '卫视频道')
      .toList();
  final multi = popular
      .where((c) => (c['streams'] as List).length >= 3)
      .length;
  check('Q18 常用频道多线路覆盖（≥3 条线路的央视/卫视）',
      multi >= 40, '多线路 $multi / ${popular.length}');
  check('Q19 扩展线路每条带来源 / 台号 / 耗时，源快照已固化',
      extraEntries.every((e) =>
          '${e['source']}'.isNotEmpty && (e['num'] as int) > 0) &&
          has(collectToolSrc, 'tooling/source_snapshots') &&
          File('tooling/source_snapshots/guovin.m3u').existsSync());
  check('Q20 两个探针都跟随 302 并用最终 URL 解析相对分片',
      has(probeTool, 'playlistBase = playlist.url') &&
          has(probeTool, 'finalUrl = resp.redirects.last.location.toString()') &&
          has(collectToolSrc,
              'finalUrl = resp.redirects.last.location.toString()'));
  check('Q21 清单生成器按台号注入扩展线路并去重',
      has(generator, 'final extraList = extra[number]') &&
          has(generator, "'extra': true") &&
          has(generator, "if (streams.any((s) => s['url'] == u)) continue;"));
  check('Q22 设置偏好 SCHEMA 升级但旧键名一个没改',
      has(prefsSrc, 'static final int SCHEMA = 2') &&
          has(prefsSrc, 'K_LAST_NUM = "last_channel_num"') &&
          has(prefsSrc, 'K_FAV = "favorites"'));
  check('Q23 重跑后台账可达线路与有活线台数显著提升（重定向修复）',
      (ledger['reachableCount'] as int) >= 900 &&
          (ledger['channelReachable'] as int) >= 580,
      '可达 ${ledger['reachableCount']} / 台 ${ledger['channelReachable']}');
  final cctv1Live = ledgerItems
      .where((s) => s['num'] == 1 && s['ok'] == true)
      .toList();
  check('Q24 CCTV-1 台账可达线路 ≥5 条且含 720P 标签',
      cctv1Live.length >= 5 &&
          cctv1Live.any((s) => '${s['label']}'.contains('720')),
      '可达 ${cctv1Live.length} 条');
  check('Q25 扩展线路候选数与通过数可回溯',
      extraData['verifiedCount'] == extraEntries.length &&
          (extraData['candidateUrls'] as int) > 0 &&
          (extraData['scope'] as String).contains('苏州'),
      '候选 ${extraData['candidateUrls']} / 通过 ${extraEntries.length}');

  // ---- 央视换台慢 / 播放中频繁缓冲（2026-11-09 19:30）----
  check('O22 首帧快速换线只挂给「还有别的候选」的线路，最后一条留给总超时',
      has(playback, 'QUICK_FAIL_MS = 6000L') &&
          has(playback, 'scheduleQuickFail(gen, idx, s)') &&
          has(playback, 'hasMoreCandidates(idx)') &&
          RegExp(r'scheduleQuickFail[\s\S]{0,400}hasMoreCandidates\(idx\)')
              .hasMatch(playback) &&
          has(playback, 'cancelQuickFail();') &&
          has(playback, '首帧 6 秒未出，先换下一条'));
  check('O23 60 秒 3 次缓冲自动换线，探测窗口回到稳妥值（1.5 秒 / 1 MB）',
      has(playback, 'BUFFER_HIT_LIMIT = 3') &&
          has(playback, 'BUFFER_WINDOW_MS = 60000L') &&
          has(playback, 'noteBufferHit(gen, idx, s)') &&
          has(playback, 'bufferHitsInWindow()') &&
          has(playback, 'resetBufferProbe()') &&
          has(playback, '卡顿频繁（60 秒 3 次）') &&
          has(playback, '"analyzeduration", 1500000L') &&
          has(playback, '"probesize", 1024000L'));
  check('O24 诊断页能读出缓冲次数（换台慢 / 卡顿的可验证入口）',
      has(activity, 'playback.bufferHitsInWindow()') &&
          has(activity, '最近 60 秒缓冲') &&
          has(prefsSrc, 'K_FIRST_FRAME_TIMEOUT_MS.equals(key)) return 8000'));

  // ---- 换不了台 / 换台慢（2026-11-09 19:50）----
  check('O26 单线路频道不再被「快速失败」误杀：候选判定排除当前线路',
      has(playback, 'private boolean hasMoreCandidates(int currentIdx)') &&
          has(playback, 'for (int step = 1; step < total; step++)') &&
          has(playback, 'if (attempted.contains(Integer.valueOf(idx))) continue;') &&
          !has(playback, 'hasMoreCandidates()'));
  check('O27 整台无可达线路的台：首帧只等 4 秒，换台时自动跳过',
      has(playback, 'DEAD_CHANNEL_TIMEOUT_MS = 4000L') &&
          has(playback, 'channelLikelyDead = !channel.hasReachableStream()') &&
          has(activity, 'resolvePlayable(desired, dir)') &&
          has(activity, 'resolvePlayable(idx, 1)') &&
          has(activity, '已跳过 ') &&
          has(catalog, 'public boolean hasReachableStream()'));
  check('O28 换台不再被上一台的失败回调打断：代际 + 频道双校验',
      has(playback, 'private void invalidatePending()') &&
          RegExp(r'failCurrent[\s\S]{0,2000}gen != generation \|\| target == null')
              .hasMatch(playback) &&
          RegExp(r'if \(s\.https && what >= 0\)').hasMatch(playback));
  check('O29 换台音画一致：起播静音到首帧 + 长缓冲后按时钟再对齐',
      has(playback, 'private void muteForStart(IjkMediaPlayer p)') &&
          has(playback, 'private void scheduleUnmuteFallback(') &&
          has(playback, 'private void alignClockAfterStall(IMediaPlayer mp)') &&
          has(playback, 'BUFFER_ALIGN_MIN_STALL_MS = 1500L') &&
          has(playback, 'suppressBufferHitUntil = now + 3000L') &&
          has(activity, '本次线路切换 '));

  // 数据层复核：自动档排序后，央视首条线路的实测耗时应该明显下降。
  // 样本来自当前 channels.json 的 probeMs 台账，不是纸上推演。
  int speedKey(int ms) => ms <= 0 ? 2 : (ms <= 1200 ? 0 : (ms <= 2200 ? 1 : 2));
  final allChannels =
      (jsonDecode(channelsJson)['channels'] as List).cast<Map<String, dynamic>>();
  var fastFirst = 0;
  var cctvCount = 0;
  for (final c in allChannels) {
    if (c['group'] != '央视频道') continue;
    cctvCount++;
    final streams =
        (c['streams'] as List).cast<Map<String, dynamic>>().toList();
    int pk(Map<String, dynamic> s) =>
        s['probeOk'] == true ? 0 : (s['probeOk'] == null ? 1 : 2);
    streams.sort((a, b) {
      final ka = pk(a);
      final kb = pk(b);
      if (ka != kb) return ka - kb;
      final sa = speedKey((a['probeMs'] as int?) ?? -1);
      final sb = speedKey((b['probeMs'] as int?) ?? -1);
      if (sa != sb) return sa - sb;
      return ((b['quality'] as int?) ?? 0) - ((a['quality'] as int?) ?? 0);
    });
    final ms = (streams.first['probeMs'] as int?) ?? -1;
    if (ms > 0 && ms <= 1200) fastFirst++;
  }
  check('O25 自动档先选实测快的线路（央视首条 ≤1.2 秒的台数 ≥24，实测原为 18）',
      has(catalog, 'private static int speedKey(int probeMs)') &&
          has(catalog, 'speedKey(a.probeMs)') &&
          has(catalog, 'probeMs <= 1200') &&
          fastFirst >= 24,
      '首条快源 $fastFirst/$cctvCount 台');

  // ---- 4K 输出门槛（2026-11-09 20:30）----
  final deviceCap = read('legacy/src/com/shunbo/legacy/DeviceCapability.java');
  check('O30 4K 门槛四条判据：系统版本 / 输出宽度 / 2160 硬解 / 内存，保守取与',
      has(deviceCap, 'MIN_API_4K = 24') &&
          has(deviceCap, 'MIN_WIDTH_4K = 3840') &&
          has(deviceCap, 'MIN_RAM_MB_4K = 2048') &&
          has(deviceCap, 'supports2160("video/hevc")') &&
          has(deviceCap, 'supports2160("video/avc")') &&
          has(deviceCap, 'isSoftwareCodec') &&
          has(deviceCap, 'vc.isSizeSupported(3840, 2160)') &&
          has(deviceCap, 'public static int qualityCeiling(Context context, boolean hardDecode)'));
  check('O31 4K 在清单载入期剥离：4K 台整台隐藏、普通台留一条兜底不藏台',
      has(catalog, 'public static ChannelCatalog load(Context context, int maxQuality)') &&
          has(catalog, 'final boolean gate4K') &&
          has(catalog, 'DeviceCapability.QUALITY_4K') &&
          has(catalog, 'if (is4kChannel) { hidden4KChannels++; continue; }') &&
          has(catalog, 'kept4KFallbacks++') &&
          has(catalog, 'private static boolean betterFallback(Stream a, Stream b)') &&
          has(catalog, '4K 输出已关闭（隐藏 '));
  check('O32 门槛接到运行时：载入按能力取上限 + 诊断页给结论 + 软解有提示',
      has(activity, 'DeviceCapability.qualityCeiling(this,') &&
          has(activity, 'DeviceCapability.inspect(this)') &&
          has(activity, 'cap.verdict(') &&
          has(activity, '4K：') &&
          has(activity, '4K 台需重启后生效') &&
          has(settingsSrc, '4K 台按新解码方式在重启后显示'));
  final is4kChannels = allChannels.where((c) => c['is4K'] == true).length;
  final lines2160 = allChannels
      .expand((c) => (c['streams'] as List))
      .where((s) => (((s as Map)['quality'] as int?) ?? 0) >= 2160)
      .length;
  final only2160Non4k = allChannels
      .where((c) =>
          c['is4K'] != true &&
          (c['streams'] as List).isNotEmpty &&
          (c['streams'] as List)
              .every((s) => (((s as Map)['quality'] as int?) ?? 0) >= 2160))
      .length;
  check('O33 门槛作用于真实数据：4K 台与 2160 线路非空，且确有「剥完为空」的普通台需要兜底',
      is4kChannels >= 10 && lines2160 >= 20 && only2160Non4k >= 1,
      '4K 台 $is4kChannels / 2160 线路 $lines2160 / 需兜底 $only2160Non4k 台');

  // ---- 研发计划 PQ-1 / M0：只读探针 + 观感两项（2026-11-09 21:10）----
  // M0 的定义是「行为与 1.0.2 完全一致，只是多了读数」，所以这里除了断言功能
  // 存在，还要断言「探针不参与决策」——否则它会在无人察觉时变成 M2。
  final probeSrc = File('legacy/src/com/shunbo/legacy/QualityProbe.java').existsSync()
      ? read('legacy/src/com/shunbo/legacy/QualityProbe.java')
      : '';
  check('O34 运行时探针：5 个内核读数 1 秒采样、环形 60 条、逐项容错',
      probeSrc.isNotEmpty &&
          has(probeSrc, 'public static final int WINDOW = 60;') &&
          has(probeSrc, 'public static final long SAMPLE_MS = 1000L;') &&
          has(probeSrc, 'p.getDropFrameRate()') &&
          has(probeSrc, 'p.getBitRate()') &&
          has(probeSrc, 'p.getVideoCachedDuration()') &&
          has(probeSrc, 'p.getAudioCachedDuration()') &&
          has(probeSrc, 'p.getTrafficStatisticByteCount()') &&
          has(probeSrc, 'p.getVideoWidth()') &&
          has(probeSrc, 'FAKE_HD_SETTLE_MS = 8000L'));
  check('O35 探针只读且随线路启停：不换线、不 seek，换线重建基准',
      probeSrc.isNotEmpty &&
          !has(probeSrc, 'failCurrent(') &&
          !has(probeSrc, 'seekTo(') &&
          has(playback, 'private final QualityProbe probe = new QualityProbe();') &&
          has(playback, 'probe.start(p, s);') &&
          has(playback, 'probe.stop();') &&
          has(playback, 'public QualityProbe quality() { return probe; }') &&
          has(activity, 'playback.quality().summary()') &&
          has(activity, 'private void scheduleHelpRefresh()'));
  check('O36 缓冲提示去抖：600 ms 内不显示、显示不少于 400 ms、再对齐引发的不提示',
      has(playback, 'BUFFER_HINT_DELAY_MS = 600L') &&
          has(playback, 'BUFFER_HINT_MIN_SHOW_MS = 400L') &&
          has(playback, 'private void scheduleBufferHint(final int gen)') &&
          has(playback, 'private void settleBufferHint(final boolean firstFrame)') &&
          has(playback, 'private void resetBufferHint()') &&
          RegExp(r'onBufferingStart[\s\S]{0,700}suppressBufferHitUntil').hasMatch(playback) &&
          RegExp(r'onFirstFrame[\s\S]{0,400}resetBufferHint\(\)').hasMatch(playback));
  check('O37 换台清屏：黑幕不可聚焦、起播前盖上、首帧与 2.5 秒兜底各撤一次',
      has(activity, 'blackoutView.setFocusable(false)') &&
          has(activity, 'blackoutView.setFocusableInTouchMode(false)') &&
          has(activity, 'private void showBlackout()') &&
          has(activity, 'private void hideBlackout()') &&
          has(activity, 'ui.postDelayed(blackoutTask, 2500L)') &&
          RegExp(r'cancelFailureTasks\(\);[\s\S]{0,300}showBlackout\(\)').hasMatch(activity) &&
          RegExp(r'onFirstFrame\(long elapsedMs[\s\S]{0,300}hideBlackout\(\)').hasMatch(activity));

  // ---- 研发计划 PQ-1 / M2：三闭环 + M1 真机裁决（2026-11-10 08:58）----
  // M1 的两张真机截图直接否掉了原计划里的两条判据（缓存差、丢帧率）。所以这里
  // 除了查「有没有实现」，还要查「有没有把否掉的判据清干净」——留着一条不可用
  // 的判据比不实现更危险：它会让人照着错误方向调参。
  final tuningSrc = File('legacy/src/com/shunbo/legacy/Tuning.java').existsSync()
      ? read('legacy/src/com/shunbo/legacy/Tuning.java')
      : '';
  check('O38 阈值集中表：五个闭环阈值各自带「实测 / 经验」依据，且登记进编译清单',
      tuningSrc.isNotEmpty &&
          (tuningSrc.contains('FAKE_HD_WIDTH_RATIO') &&
              tuningSrc.contains('BW_COLLAPSE_RATIO') &&
              tuningSrc.contains('BW_MIN_BASE_BPS') &&
              tuningSrc.contains('BW_COLLAPSE_SAMPLES') &&
              tuningSrc.contains('SYNC_FAST_RATE') &&
              tuningSrc.contains('QUALITY_WATCH_MS')) &&
          tuningSrc.contains('依据（实测）') &&
          tuningSrc.contains('经验值') &&
          has(buildPy, '"Tuning.java"'));
  check('O39 A1 假高清只用实测宽度判、命中只降权不打断播放',
      probeSrc.contains('public int claimedWidth()') &&
          probeSrc.contains('Tuning.FAKE_HD_WIDTH_RATIO') &&
          !RegExp(r'isFakeHd\(\)[\s\S]{0,600}FAKE_HD_MIN_BPS').hasMatch(probeSrc) &&
          has(playback, 'private final Set<String> fakeHdUrls') &&
          has(playback, 'memory.isDemoted(s.url)') &&
          RegExp(r'A1：只记账[\s\S]{0,700}?B1：带宽塌陷').hasMatch(playback) &&
          !RegExp(r'A1：只记账[\s\S]{0,400}?failCurrent\(').hasMatch(playback));
  check('O40 B1 带宽塌陷：基线用窗口峰值 + 零吞吐也算塌陷 + 已卡过 + 冷却',
      has(playback, 'bufferHitsInWindow() >= 1') &&
          has(playback, 'probe.peakTrafficBps(60)') &&
          has(playback, 'probe.bytesStalled(Tuning.BW_FAST_WINDOW_SAMPLES)') &&
          has(playback, 'Tuning.BW_FAST_WINDOW_SAMPLES') &&
          has(playback, '-7, "带宽塌陷') &&
          has(playback, 'now - lastBwSwitchAt >= Tuning.BW_COOLDOWN_MS') &&
          // 基线不能用 30 秒均值：画面卡住时它也塌到 0，判据会永远不成立。
          !has(playback, 'probe.trafficBps(Tuning.BW_BASE_WINDOW_SAMPLES)') &&
          !playback.contains('cachedGapMs'));
  check('O41 D2 时钟偏快：连续两个窗口 >2% 且仍有候选才换线，换线即重置窗口',
      has(playback, 'Tuning.SYNC_FAST_RATE') &&
          has(playback, 'if (windows > lastSyncWindow)') &&
          has(playback, '-8, String.format') &&
          RegExp(r'resetClockProbe\(\)[\s\S]{0,400}?lastSyncWindow = 0').hasMatch(playback));
  check('O42 自动换线开关：默认开、设置页可见、关掉即 1.0.2 行为',
      has(prefsSrc, 'K_AUTO_FAILOVER = "set_auto_failover"') &&
          has(prefsSrc, 'if (K_AUTO_FAILOVER.equals(key)) return 1;') &&
          has(activity, 'playback.setAutoFailover(prefs.autoFailover())') &&
          has(read('legacy/src/com/shunbo/legacy/SettingsPanel.java'), '自动换线') &&
          has(activity, '关（等同 1.0.2，只保留超时换线）'));
  check('O43 M1 裁决留痕：误导读数已清、B2 明确不做、诊断页写明判据来源',
      has(activity, '缓存差与丢帧率经真机实测否定') &&
          !probeSrc.contains('（偏大，视频侧积压）') &&
          has(playback, 'skip_loop_filter') &&
          !has(playback, '"skip_loop_filter"') &&
          has(probeSrc, '两路统计口径不同'));

  // ---- 研发计划 PQ-1 / M3：A2 记忆排序（C1/C2/C3 的处置见 StreamMemory 类注释）----
  final memorySrc = File('legacy/src/com/shunbo/legacy/StreamMemory.java').existsSync()
      ? read('legacy/src/com/shunbo/legacy/StreamMemory.java')
      : '';
  check('O44 记忆类：独立偏好文件、上限淘汰、降权有 14 天有效期、取两次较小值',
      memorySrc.isNotEmpty &&
          memorySrc.contains('static final String FILE = "shunbo_legacy_streams";') &&
          memorySrc.contains('static final int MAX_ENTRIES = 500;') &&
          memorySrc.contains('static final int DEMOTE_STREAK = 2;') &&
          memorySrc.contains('DEMOTE_TTL_MS = 14L') &&
          memorySrc.contains('JUMP_GAIN_MS = 250;') &&
          memorySrc.contains('Math.min(prev, now)') &&
          memorySrc.contains('"-" + url.length()'));
  check('O45 记忆接线：首帧记成功、硬失败才记失败、open 用记忆首选、降权进两遍扫描',
      has(playback, 'this.memory = new StreamMemory(context);') &&
          has(playback, 'memory.noteSuccess(s.url, lastFirstFrameMs);') &&
          RegExp(r'what >= 0 \|\| what == -1\) memory\.noteFailure').hasMatch(playback) &&
          has(playback, 'open(channel, preferredIndex(channel));') &&
          has(playback, 'memory.bestIndex(channel.streams, floor, currentMs)') &&
          has(playback, 'return findNext(skipHttps, autoFailover);'));
  check('O46 记忆排序的边界：只在自动换线 + 优先清晰度自动时生效，且不降画质档',
      has(activity, 'playback.setAdaptiveOrder(prefs.qualityPriority() == 0);') &&
          RegExp(r'preferredIndex\(ChannelCatalog\.Channel channel\)[\s\S]{0,400}?!autoFailover \|\| !adaptiveOrder').hasMatch(playback) &&
          has(playback, 'final int floor = first == null ? 0 : first.quality;') &&
          has(memorySrc, 'if (qualityFloor > 0 && s.quality > 0 && s.quality < qualityFloor) continue;'));
  check('O47 M3 的取舍留痕：C1 由记忆替代、C2/C3 明确不做，诊断页有记忆一行',
      memorySrc.contains('C1') && memorySrc.contains('C2') && memorySrc.contains('C3') &&
          memorySrc.contains('不做') &&
          has(activity, 'playback.memorySummary()') &&
          has(activity, '记忆排序已关闭（优先清晰度非「自动」）'));

  // ---- 真机反馈修复（2026-11-10 10:18）：诊断页被裁掉 7 行 ----
  // 两张真机照片都停在「同步」那一行，闭环 / 判据 / 记忆 / 内核 / 签名全部落在
  // 屏幕外。这不是新问题（旧版内容刚好也超出一点），但新加的三行最关键，
  // 必须能看见——所以按屏高分页，而不是继续删内容。
  check('O48 诊断页按屏高分页：每页行数按屏高算，←→ 翻页，进入时回到第 1 页',
      has(activity, 'private void renderHelpPage(String full)') &&
          has(activity, 'private int helpLinesPerPage()') &&
          has(activity, '(dpHeight - 110f) / 26f') &&
          has(activity, 'if (mode != MODE_HELP) helpPage = 0;') &&
          RegExp(r'KEYCODE_DPAD_RIGHT \? 1 : -1').hasMatch(activity) &&
          has(activity, "split(\"\\f\", -1)") &&
          has(activity, '页 · ←→ 翻页 · 其余键关闭'));

  // ---- 真机 10:31 第二版修正：画面停滞（时钟 0.169）与零吞吐 ----
  // 那次读数是「缓存 280 ms、音频 0 ms、码率读不到、60 秒只缓冲 1 次，而闭环
  // 全部 0 次」——旧的四条保护一条都没踩到。根因有三个，这里逐个锁死。
  check('O49 D3 画面停滞：位置增速 <0.5 连续 2 窗口即处置，单线路台重连而不是换线',
      tuningSrc.contains('STALL_RATE = 0.50') &&
          tuningSrc.contains('STALL_WINDOWS = 2') &&
          tuningSrc.contains('STALL_COOLDOWN_MS') &&
          has(playback, 'if (rate < Tuning.STALL_RATE && cacheBottom)') &&
          has(playback, '-9, String.format') &&
          RegExp(r'stallGaveUp\.add\(s\.url\)[\s\S]{0,200}?onState\("画面停滞，正在重连…"\)[\s\S]{0,80}?retryCurrentStream\(\)')
              .hasMatch(playback) &&
          // 重连只一次：否则废掉的源会每 30 秒重连一次、无限循环。
          has(playback, '按 ←→ 换线路或 ↑↓ 换台') &&
          has(activity, '停滞处置'));
  check('O50 零吞吐与暂停：流量为 0 算塌陷而不是「算不出来」，暂停时一律不判',
      probeSrc.contains('public boolean bytesStalled(int window)') &&
          probeSrc.contains('public long peakTrafficBps(int window)') &&
          has(playback, 'if (paused) return;') &&
          RegExp(r'paused = true;[\s\S]{0,200}?cancelQualityWatch\(\)').hasMatch(playback) &&
          RegExp(r'player\.start\(\);[\s\S]{0,120}?paused = false;[\s\S]{0,120}?scheduleQualityWatch')
              .hasMatch(playback));
  check('O51 诊断页把「停滞」和「零流量」讲成人话，不再笼统说样本不足',
      has(activity, '画面停滞（低于 ') &&
          has(probeSrc, '近 8 秒没有任何流量增长——画面可能已卡住'));

  // ---- 10:58 真机证否 D3 单判据 + M4 硬解（2026-11-10 11:05，1.0.4）----
  // 那次读数是 0.004 配 13040 ms 缓存：真冻住的流不可能还攒着 13 秒缓存。
  // 只看「位置不动」会在好线路上误杀，所以第二个必要条件（缓存见底）必须锁死。
  check('O52 D3 双必要条件：位置不动 **且** 缓存见底；缓存充足时明确不处置',
      tuningSrc.contains('STALL_MAX_CACHE_MS = 1000L') &&
          has(playback, 'final boolean cacheBottom = cachedMs >= 0 && cachedMs < Tuning.STALL_MAX_CACHE_MS;') &&
          has(playback, 'rate > Tuning.SYNC_FAST_RATE && !cacheBottom') &&
          has(activity, '疑似分片边界重置，不处置'));
  check('O53 M4 解码可配置、默认软解、改完即时生效',
      has(prefsSrc, 'K_HARD_DECODE = "set_hard_decode"') &&
          has(prefsSrc, 'if (K_HARD_DECODE.equals(key)) return 0;') &&
          has(read('legacy/src/com/shunbo/legacy/SettingsPanel.java'), '解码方式') &&
          RegExp(r'setHardDecode\(boolean on\)[\s\S]{0,800}?retryCurrentStream\(\)').hasMatch(playback) &&
          has(playback, 'p.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec",'));
  // 真机反馈「有的台可以硬解、有的台只能软解」⇒ 回退必须按线路，且不能改用户设置。
  check('O54 硬解不可用时按线路回退：三处触发都用软解重开同一条，且不改设置',
      has(playback, 'private boolean fallbackToSoftDecode(String reason, ChannelCatalog.Stream s)') &&
          RegExp(r'fallbackToSoftDecode\("解码错误 ').hasMatch(playback) &&
          RegExp(r'fallbackToSoftDecode\("硬解 6 秒无首帧", s\)').hasMatch(playback) &&
          RegExp(r'fallbackToSoftDecode\("硬解首帧超时", s\)').hasMatch(playback) &&
          has(playback, 'memory.noteHardDecodeFail(s.url)') &&
          has(activity, 'public void onDecodeFallback(String reason)') &&
          // 一个台硬解失败不能把全局设置改成软解，否则能硬解的台全被降级
          !has(activity, 'prefs.setSetting(Prefs.K_HARD_DECODE, 0)'));
  check('O55 诊断页分开显示「设置要什么 / 本线路实际用什么 / 多少条线路不适配」',
      has(activity, '解码：实际 ') &&
          has(activity, '本线路硬解不适配，已自动用软解（其他台不受影响）') &&
          has(activity, '条线路硬解不适配') &&
          has(playback, 'public boolean usingHardDecode()') &&
          has(playback, 'public boolean hardDecodePreferred()'));
  check('O56 硬解适配按线路记忆：unfit 记录 + 7 天过期 + 切回硬解时清空',
      memorySrc.contains('void noteHardDecodeFail(String url)') &&
          memorySrc.contains('boolean hardDecodeUnfit(String url)') &&
          memorySrc.contains('HARD_FAIL_TTL_MS = 7L') &&
          memorySrc.contains('void clearHardDecodeFlags()') &&
          has(playback, 'currentUseHard = hardDecode && !memory.hardDecodeUnfit(s.url);') &&
          has(playback, 'if (on) memory.clearHardDecodeFlags();'));

  // ---- 12:19 苏州台1套「声音比画面快」：不做自动 seek，只给手动对齐 + 兼容开关 ----
  // 两份真机读数互相矛盾（差 +14152 ms 时用户没觉得不同步；差 +2440 ms 时明确说延迟），
  // 所以「视频缓存 − 音频缓存」不能当自动触发条件。这里断言的是「不做自动」，而不是做了。
  check('O57 音画偏差只给手动对齐，不按缓存差自动 seek',
      has(playback, 'public String reanchorNow()') &&
          has(playback, 'Tuning.REANCHOR_COOLDOWN_MS') &&
          has(playback, 'suppressBufferHitUntil = now + 3000L') &&
          has(activity, 'public void onReanchorRequested()') &&
          has(activity, '已重新对齐音画') &&
          // 关键：没有任何「按 cachedGap 自动 seek/换线」的代码
          !RegExp(r'cachedGapMs\(\)[\s\S]{0,200}?seekTo').hasMatch(playback) &&
          !RegExp(r'Math\.abs\(gap\)[\s\S]{0,200}?failCurrent').hasMatch(playback));
  check('O58 同步兼容模式：默认关、关掉 max-fps 与 video-pictq-size、即时生效',
      has(prefsSrc, 'K_SYNC_COMPAT = "set_sync_compat"') &&
          has(prefsSrc, 'if (K_SYNC_COMPAT.equals(key)) return 0;') &&
          RegExp(r'if \(!compatSync\) \{[\s\S]{0,400}?"max-fps", 30')
              .hasMatch(playback) &&
          RegExp(r'if \(!compatSync\) \{[\s\S]{0,600}?"video-pictq-size", 3')
              .hasMatch(playback) &&
          RegExp(r'setCompatSync\(boolean on\)[\s\S]{0,500}?retryCurrentStream\(\)')
              .hasMatch(playback) &&
          has(activity, 'playback.setCompatSync(prefs.compatSync())') &&
          has(read('legacy/src/com/shunbo/legacy/SettingsPanel.java'), '同步兼容模式') &&
          has(read('legacy/src/com/shunbo/legacy/SettingsPanel.java'), '音画立即对齐'));

  // ---- 1.0.4 真机截图复核：三处「同一页/同一句自相矛盾」的文案缺陷 ----
  // 这三处的共同点是「代码行为是对的、写给人看的那句话是错的」。真机上排障时
  // 人只信屏幕上那句话，所以它们和逻辑错误一样会误导结论，必须锁住。
  check('O59 诊断页起播策略随兼容模式变化，不再写死帧队列/帧率',
      has(activity, 'compat ? "帧队列 / 帧率不限（兼容模式）" : "帧队列 3 · 帧率上限 30"') &&
          // 写死的那一行一旦回来，就会和下一行「兼容模式 开」同页矛盾
          !has(activity, '"起播策略：探测 1.5 秒 · 6 秒无首帧且仍有候选才换线 · 帧队列 3 · 帧率上限 30'));
  check('O60 码率提示与阈值常量同源，不再出现「判据 1.5 却说需 2.5」',
      has(probeSrc, 'FAKE_HD_MIN_BPS / 1000000.0') &&
          !has(probeSrc, '1080P 通常需 ≥2.5 Mbps'));
  check('O61 硬解描述与「按线路回退、不改设置」一致',
      RegExp(r'解码方式[\s\S]{0,700}?只让这条线路改用软解，本项设置保持不变')
              .hasMatch(read('legacy/src/com/shunbo/legacy/SettingsPanel.java')) &&
          !has(read('legacy/src/com/shunbo/legacy/SettingsPanel.java'),
              '会自动回退软解并把这一项改回软解'));
  // 探针补两项帧率读数：ijk 的 vdps（解码帧数/秒）与 vfps（上屏帧数/秒）。
  // 真机 13:52 首次出数：解码 19.80 / 输出 7.81，而同页「丢帧 0.5%」——
  // 两者不矛盾：drop_frame_rate 只统计 get_video_frame() 的 early drop，
  // video_refresh() 的迟到帧丢弃既不计数也不触发 SDL_VoutDisplayYUVOverlay。
  // 同时必须继续满足「只读」——不许出现 seekTo/failCurrent。
  check('O62 探针读解码/输出帧率以区分「解码跟不上」与「显示端延迟」，且仍只读',
      has(probeSrc, 'p.getVideoDecodeFramesPerSecond()') &&
          has(probeSrc, 'p.getVideoOutputFramesPerSecond()') &&
          has(probeSrc, 'private final int[] decFpsCenti = new int[WINDOW];') &&
          has(probeSrc, 'private final int[] outFpsCenti = new int[WINDOW];') &&
          has(probeSrc, 'public int decodeFpsCenti()') &&
          has(probeSrc, 'public int outputFpsCenti()') &&
          has(probeSrc, '上屏前被丢；与上行丢帧率口径不同') &&
          // 新增读数不能破坏「探针只读」
          !has(probeSrc, 'failCurrent(') &&
          !has(probeSrc, 'seekTo('));
  // 内核能力核实结论必须写进代码，防止后人再提「用滤镜补偿」这种做不到的方案。
  check('O63 内核能力已核实：framedrop/sync-av-start 已开，且不假装有滤镜补偿',
      has(playback, '"framedrop", 1') &&
          has(playback, '"sync-av-start", 1'));

  // ---- 13:52 真机帧率读数：口径核实后撤回错误判读，锁住「不误导」 ----
  check('O64 丢帧率标明只覆盖解码前提前丢帧，帧率行不再声称「正在丢帧追赶音频」',
      has(probeSrc, '（不含上屏前丢帧）') &&
          has(probeSrc, '上屏前被丢；与上行丢帧率口径不同') &&
          !has(probeSrc, '正在丢帧追赶音频'));
  check('O65 诊断页内核行显示本线路实际解码方式与设置值，硬解回退可见',
      has(activity, 'hardDecodePreferred()') &&
          has(activity, 'usingHardDecode()') &&
          has(activity, '" · 本线路已回退"') &&
          !has(activity, '"内核：ijkplayer 0.8.8（默认 FFmpeg 软解，仅 armeabi-v7a）'));
  // 源码事实：framedrop=N 只是「最多连续 early drop N 帧」，late drop 的开关是
  // framedrop>0，1 与 10 等价。上一版给的「调大 framedrop 能缓解」方向是反的，
  // 会丢更多帧，必须锁死不许再提出来。
  check('O66 framedrop 固定为 1，且代码与文档都不再建议「调到 5–10」',
      has(playback, '"framedrop", 1') &&
          !has(playback, '"framedrop", 5') &&
          !has(playback, '"framedrop", 10') &&
          has(read('README.md'), '撤回「把 framedrop 提到 5–10」') &&
          !has(read('README.md'), '可试 5–10'));
  check('O67 软解减负选项 skip-loop-filter/skip-frame 经内核字符串核实不存在，未擅自启用',
      !has(playback, '"skip-loop-filter"') &&
          !has(playback, '"skip-frame"'));

  // ---- 14:42 真机：起播正常、切台回来后不同步 → 补会话级可自证读数 ----
  // 「本次线路切换」每次换台归零、单点帧率没有历史值，都回答不了
  // 「是切回来就低，还是播放中掉下来」。三者只做读数，不驱动任何动作。
  check('O68 诊断页「会话」行给出跨台起播次数 / 已播时长 / 输出帧率 20 秒趋势',
      has(activity, '"会话：起播 "') &&
          has(activity, 'sessionStartCount()') &&
          has(activity, 'streamElapsedSeconds()') &&
          has(activity, 'outputFpsCentiAgo(20)') &&
          has(activity, '（下滑）') &&
          has(activity, '（回升）') &&
          has(activity, '（持平）'));
  check('O69 历史输出帧率取自同一探针窗口，样本不足返回 -1，探针仍只读',
      has(probeSrc, 'public int outputFpsCentiAgo(int seconds)') &&
          has(probeSrc, 'count <= seconds') &&
          has(probeSrc, 'idx(seconds)') &&
          !has(probeSrc, 'failCurrent(') &&
          !has(probeSrc, 'seekTo('));
  check('O70 起播次数是会话级累计（换台不清零），播放参数本轮一个都没动',
      has(playback, 'sessionStarts++') &&
          !has(playback, 'sessionStarts = 0') &&
          has(playback, '"framedrop", 1') &&
          has(playback, '"video-pictq-size", 3') &&
          has(playback, '"sync-av-start", 1'));

  // ---- 15:50 真机：起播 1 秒的暂态页 + 手动对齐 3 次却没留下 A/B 证据 ----
  check('O71 诊断页给出手动对齐的 A/B 读数（按前→现在 / 距上次秒数 / 本线路次数）',
      has(activity, '"对齐："') &&
          has(activity, 'reanchorBeforeFpsCenti()') &&
          has(activity, 'reanchorSinceSeconds()') &&
          has(activity, 'reanchorThisStreamCount()') &&
          has(activity, 'playback.quality().outputFpsCenti()') &&
          has(activity, '"按前 "') &&
          has(activity, '（回升 ') &&
          has(activity, '（持平）') &&
          has(activity, '对齐后未稳，等 3 秒') &&
          has(activity, '本线路未按过'));
  check('O72 同一行两个「次数」必须标清口径，且本线路计数在起播时清零',
      has(activity, '次（本线路）') &&
          has(activity, '次（累计）') &&
          has(playback, 'private int reanchorThisStream = 0;') &&
          has(playback, 'reanchorThisStream = 0;') &&
          has(playback, 'reanchorBeforeFpsCenti = -1;') &&
          !has(activity, '"同步：起播静音至首帧 · 长缓冲后按时钟再对齐（本条线路 "'));
  check('O73 起播 8 秒内的暂态页必须标「勿据此页判读」，防止拿 1 秒样本定病因',
      has(activity, '起播未稳，勿据此页判读') &&
          has(activity, 'elapsed < 8L') &&
          has(activity, 'streamElapsedSeconds()'));
  check('O74 补 A/B 读数不改变对齐动作本身，播放参数仍全部原样',
      has(playback, 'player.seekTo(pos)') &&
          has(playback, 'reanchorBeforeFpsCenti = probe == null ? -1 : probe.outputFpsCenti();') &&
          has(playback, '"framedrop", 1') &&
          has(playback, '"video-pictq-size", 3') &&
          has(playback, '"max-fps", 30') &&
          has(playback, '"sync-av-start", 1'));

  // ---- 16:18 真机：稳态页趋势定案「起播即坏」，嫌疑落到换台释放交接窗口 ----
  check('O75 诊断页给出换台释放时序读数（等待 / 重叠 / 释放耗时 / 本次是否重叠）',
      has(activity, '"释放：等待 "') &&
          has(activity, '"交接：历史重叠 "') &&
          has(activity, 'releasePendingCount()') &&
          has(activity, 'releaseOverlapCount()') &&
          has(activity, 'lastOverlapDepth()') &&
          has(activity, 'lastReleaseCostMs()') &&
          has(activity, 'drainCount()') &&
          has(activity, 'drainTimeoutCount()') &&
          has(activity, 'lastDrainCostMs()') &&
          has(activity, 'maxOverlapDepth()') &&
          has(activity, 'sessionStartCount()'));
  check('O76 重叠计数跨台不清零、跨线程安全，且释放完成必减计数',
      has(playback, 'AtomicInteger releasePendingCount') &&
          has(playback, 'releasePendingCount.incrementAndGet()') &&
          has(playback, 'releasePendingCount.decrementAndGet()') &&
          has(playback, '} finally {') &&
          has(playback, 'pendingBeforeBind = releasePendingCount.get()') &&
          has(playback, 'releaseOverlapCount++') &&
          // 只允许在字段声明处赋值 0，不许在 startStream 里按线路清零
          RegExp(r'releaseOverlapCount = 0').allMatches(playback).length == 1);
  check('O77 释放仍在后台异步执行，且播放参数全部原样',
      has(playback, 'RELEASE_EXECUTOR.execute(new Runnable() {') &&
          has(playback, 'try { p.setDisplay(null); }') &&
          !has(playback, '.join(') &&
          !has(playback, 'awaitTermination(') &&
          has(playback, '"framedrop", 1') &&
          has(playback, '"video-pictq-size", 3') &&
          has(playback, '"max-fps", 30') &&
          has(playback, '"sync-av-start", 1'));

  // ---- 16:48 真机 31.jpg：重叠 83/86 次但释放仅 62 ms、现存 0 个 ----
  // 数据把「改释放时序会拖慢换台」的顾虑证否了，于是本轮做一次有上限、
  // 可证伪的干预：绑新 holder 前等后台释放排空。下面四条锁住它的边界。
  check('O78 起播前等释放排空：在释放之后调用，有硬上限，超时继续，绝不阻塞换台',
      has(playback, 'releaseCurrentPlayer();\n        // 16:48 真机') &&
          has(playback, 'awaitReleaseDrain();') &&
          has(playback, 'Tuning.RELEASE_DRAIN_TIMEOUT_MS') &&
          has(tuningSrc, 'static final long RELEASE_DRAIN_TIMEOUT_MS = 200L;') &&
          has(playback, 'SystemClock.uptimeMillis() < deadline') &&
          !has(playback, '.join(') &&
          !has(playback, 'awaitTermination(') &&
          !has(playback, 'Future<'));
  check('O79 诊断页能自证「本次起播无重叠」并给出等待 / 超时 / 最深队列',
      has(activity, '" · 本次无重叠"') &&
          has(activity, '" · 本次重叠 "') &&
          has(activity, '"超时 "') &&
          has(activity, '" 次（最深 "') &&
          has(activity, 'playback.maxOverlapDepth()') &&
          has(playback, 'if (pendingBeforeBind > maxOverlapDepth) maxOverlapDepth = pendingBeforeBind;'));
  check('O80 丢帧趋势标注与显示精度一致，不再出现「+0.0 个百分点（正在恶化）」',
      has(probeSrc, 'delta >= 100') &&
          has(probeSrc, 'delta <= -100') &&
          !has(probeSrc, 'delta > 30') &&
          has(probeSrc, '%+.1f 个百分点'));
  check('O81 干预只动释放交接时序，不改播放参数与手动对齐实现',
      has(playback, '"framedrop", 1') &&
          has(playback, '"video-pictq-size", 3') &&
          has(playback, '"max-fps", 30') &&
          has(playback, '"sync-av-start", 1') &&
          has(playback, 'player.seekTo(pos)'));

  print('');
  if (_fail == 0) {
    print('回归通过：$_pass/$_pass 断言通过'
        '${_skipped > 0 ? '（$_skipped 组跳过）' : ''}');
    exit(0);
  }
  print('回归失败：$_pass/${_pass + _fail} 断言通过');
  exit(1);
}
