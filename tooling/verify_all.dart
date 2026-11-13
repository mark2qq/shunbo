// 一条命令跑完全部门禁。
//
// 背景：本机 `flutter test` 不可用（flutter_tester 握手失败），可验证性完全依赖
// 十二套 `dart run tooling/verify_*.dart` + `flutter analyze` + Python 原型。
// 手工逐条敲既慢又容易漏，交接/回归时几乎必然有人只跑其中几条就宣布「全绿」。
// 这个脚本把「跑哪些、跑几次断言、有没有静默跳过」固化成一次可复现的判定。
//
// 用法：
//   dart run tooling/verify_all.dart
//   dart run tooling/verify_all.dart -v              # 实时流式输出子进程日志
//   dart run tooling/verify_all.dart --only=cross    # 只跑名字含 cross 的步骤
//   dart run tooling/verify_all.dart --skip=analyze  # 跳过某步
//   dart run tooling/verify_all.dart --timeout=600   # 单步超时（秒），默认 300
//
// 设计要点：
// 1. **不 fail-fast**：一步失败也要跑完其余步骤，一次看到全部缺口（与各回归脚本
//    的收集式断言一致）。
// 2. **防静默假成功**：声明 expectAssertions 的步骤若「退出码 0 但没报告断言数」，
//    判为失败 —— 脚本被改坏、提前 return、或断言被注释掉时不能悄悄变绿。
// 3. **纯 dart:io**：不依赖 package:flutter，也不依赖 shell，Windows/Linux 同源。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum GateKind { dartScript, flutterAnalyze, external }

/// 一个门禁步骤。
class Gate {
  final String id;
  final String note;
  final bool expectAssertions;
  final GateKind kind;

  /// dart 步骤：相对包根的脚本路径。
  final String dartScript;

  /// 非 dart 步骤：完整命令（首个元素为可执行文件）。
  final List<String> command;

  /// 相对包根的工作目录。
  final String cwdRelative;

  Gate.dart(
    this.id,
    this.dartScript, {
    required this.note,
    this.expectAssertions = true,
  })  : kind = GateKind.dartScript,
        command = const <String>[],
        cwdRelative = '.';

  Gate.analyze(this.id, {required this.note})
      : kind = GateKind.flutterAnalyze,
        expectAssertions = false,
        dartScript = '',
        command = const <String>[],
        cwdRelative = '.';

  Gate.command(
    this.id,
    this.command, {
    required this.note,
    this.cwdRelative = '.',
  })  : kind = GateKind.external,
        dartScript = '',
        expectAssertions = false;
}

/// 从脚本输出里解析出的断言统计。
class AssertionStats {
  final int passed;
  final int total;

  const AssertionStats(this.passed, this.total);

  bool get allPassed => total > 0 && passed == total;
}

class GateResult {
  final Gate gate;
  final bool ok;
  final String reason;
  final AssertionStats? stats;
  final Duration elapsed;
  final List<String> failures;
  final String tail;

  const GateResult({
    required this.gate,
    required this.ok,
    required this.reason,
    required this.stats,
    required this.elapsed,
    required this.failures,
    required this.tail,
  });
}

class _Options {
  final bool verbose;
  final Set<String> only;
  final Set<String> skip;
  final Duration timeout;

  const _Options({
    required this.verbose,
    required this.only,
    required this.skip,
    required this.timeout,
  });

  static _Options parse(List<String> args) {
    var verbose = false;
    var only = <String>{};
    var skip = <String>{};
    var timeout = const Duration(seconds: 300);

    for (final a in args) {
      if (a == '-v' || a == '--verbose') {
        verbose = true;
      } else if (a.startsWith('--only=')) {
        only = a
            .substring('--only='.length)
            .split(',')
            .map((e) => e.trim().toLowerCase())
            .where((e) => e.isNotEmpty)
            .toSet();
      } else if (a.startsWith('--skip=')) {
        skip = a
            .substring('--skip='.length)
            .split(',')
            .map((e) => e.trim().toLowerCase())
            .where((e) => e.isNotEmpty)
            .toSet();
      } else if (a.startsWith('--timeout=')) {
        final secs = int.tryParse(a.substring('--timeout='.length));
        if (secs != null && secs > 0) timeout = Duration(seconds: secs);
      } else if (a == '-h' || a == '--help') {
        stdout.writeln(
            '用法: dart run tooling/verify_all.dart [-v] [--only=a,b] [--skip=x] [--timeout=秒]');
        exit(0);
      }
    }
    return _Options(
        verbose: verbose, only: only, skip: skip, timeout: timeout);
  }
}

// ---------------------------------------------------------------------------
// 门禁清单。顺序 = 由快到慢、由逻辑到真实网络；新增回归脚本请同步这里与 CI。
// ---------------------------------------------------------------------------
final List<Gate> _gates = <Gate>[
  Gate.analyze('analyze', note: 'flutter analyze 静态分析'),
  Gate.dart('channel-contract', 'tooling/verify_channel_contract.dart',
      note: 'Dart↔原生通道契约：通道名/方法名/事件名/指标键（19 项）'),
  Gate.dart('core-logic', 'tooling/verify_logic.dart',
      note: 'M0/E2/E3/E5/E6/E7/E9 纯逻辑（169 项）'),
  Gate.dart('live-http', 'tooling/verify_live_http.dart',
      note: '三类站点真实 socket 取数 + 网络边界（43 项）'),
  Gate.dart('multi-source', 'tooling/verify_source_config.dart',
      note: '配置驱动多源聚合/隔离/换源（47 项）'),
  Gate.dart('onboarding', 'tooling/verify_onboarding_import.dart',
      note: '引导导入门禁/落盘/重启恢复（60 项）'),
  Gate.dart('url-import', 'tooling/verify_url_import.dart',
      note: 'URL 导入：本地拦截/下载边界/编排隔离（37 项）'),
  Gate.dart('progress', 'tooling/verify_progress.dart',
      note: '播放中进度落盘：换算/节流/串行写/换源护栏/片尾判定（102 项）'),
  Gate.dart('queue', 'tooling/verify_queue.dart',
      note: '自动连播：排序去重/迟到事件/最后一集/换源/并发去重（28 项）'),
  Gate.dart('live-catalog', 'tooling/verify_live_catalog.dart',
      note: '直播频道表：M3U 解析/台名规范化/分组推断/画质分级/合并去重/回退/线路准入（175 项）'),
  Gate.dart('live-regions', 'tooling/verify_live_regions.dart',
      note: '直播分类切换/卫视归一/购物剔除/IP 城市定位/偏好落盘/城市台补充（184 项）'),
  Gate.dart('live-discovery', 'tooling/verify_live_discovery.dart',
      note: '全网检索/高清优先/全线路失败自动切台/失败流程防崩溃（134 项）'),
  Gate.dart('live-failover', 'tooling/verify_live_failover.dart',
      note: '真实控制器状态机：全线路失败按序自动切台/终态收敛/防并发 open/探测并行不挡起播（48 项）'),
  Gate.dart('channel-numbers', 'tooling/verify_channel_numbers.dart',
      note: '频道分类来源策略/数字编号唯一稳定/央视一套=1/遥控器数字输入（92 项）'),
  Gate.dart('preferred-stream', 'tooling/verify_preferred_stream.dart',
      note: '每频道流畅线路记忆：记录/读取/TTL/落盘往返/限容（17 项）'),
  Gate.dart('live-selection', 'tooling/verify_live_selection.dart',
      note: '直播选台：失效登记 TTL/主机连带/线路降级/探测分批/内核错误分级（37 项）'),
  Gate.dart('decode-gate', 'tooling/verify_decode_gate.dart',
      note: '官方源解码门禁：日志分类/判决状态机/记忆 TTL/302 解析与凭据隔离/占位源拦截/内置清单/选源排序（100 项）'),
  Gate.dart('official-playback', 'tooling/verify_official_playback.dart',
      note: '官方源真实起播：运行时解析/解析失败退回/加扰自动换线/迟到事件隔离（14 项）'),
  Gate.dart('carrier-channel', 'tooling/verify_carrier_channel.dart',
      note: '运营商通道 + 平台网络事件：三网自动识别/蜂窝零请求/异网剔除不污染健康分/组播默认关闭与重写/地址表导入回滚/设置落盘/ConnectivityManager 事件净化与零请求暂停（275 项）'),
  Gate.dart('source-trust', 'tooling/verify_source_trust.dart',
      note: '来源可信度：规范摘要/TOFU 首用与变更确认/HMAC 签名自动放行/防签名降级/信任库落盘容错/真实响应头不外泄/导入服务串联（80 项）'),
  Gate.dart('content-gate', 'tooling/verify_content_gate.dart',
      note: '内容级帧抽样判据：黑屏/静帧/纯色/循环垫片/采样不足绝不容许判通过/判定优先级（46 项）'),
  Gate.dart('live-sources', 'tooling/verify_live_sources.dart',
      note: '直播多源：tvg-id 关联/备用源合并/健康度排序/落盘恢复（45 项）'),
  Gate.dart('file-import', 'tooling/verify_source_config_file.dart',
      note: '本地文件导入边界 + 真实可播（84 项）'),
  Gate.dart('export', 'tooling/verify_source_config_export.dart',
      note: '导出/备份 + 导出→导入往返（46 项）'),
  Gate.dart('cross-origin', 'tooling/verify_cross_origin.dart',
      note: '跨主机取数/凭据隔离/源级优先级（63 项）'),
  Gate.dart('dlna-cast', 'tooling/verify_dlna_cast.dart',
      note: 'DLNA 投屏：SSDP/描述边界/SOAP 控制/降级（61 项）'),
  Gate.dart('cast-dual-mode', 'tooling/verify_cast_dual_mode.dart',
      note: '投屏双模式：直推→5s 未出图改串流/按源记忆/中继补鉴权头/指标（117 项）'),
  Gate.dart('live-cast', 'tooling/verify_live_cast.dart',
      note: '直播投屏换台重下发：后发先至/换源重启中继/双向退回/非法地址拦截（60 项）'),
  Gate.dart('edge-handles', 'tooling/verify_edge_handles.dart',
      note: '左右伸缩控件：默认隐藏/按需淡入/触摸常驻/左右一致（79 项）'),
  Gate.dart('mobile-layout', 'tooling/verify_mobile_layout.dart',
      note: '手机端：方向策略/竖屏列表高度/触摸常驻手柄/横屏双栏/全屏铺满与右侧频道入口（145 项）'),
  Gate.dart('auto-hide-controls', 'tooling/verify_auto_hide_controls.dart',
      note: '底部控制区自动隐藏：默认隐藏/短暂停留唤出/快速划过不误触发/显示期间可操作/离开与空闲自动隐藏/防重复唤出/形态开关与渲染护栏（147 项）'),
  Gate.dart('version-compat', 'tooling/verify_version_compat.dart',
      note: '版本兼容分支：比较对象=Android API 等级/阈值24严格小于/边界版本/缺失与非法/探测失败保守/非Android不适用/只切换一次/Dart-Kotlin-Java三层定义一致/分支范围不外溢'),
  Gate.dart('legacy-compat', 'tooling/verify_legacy_compat.dart',
      note: '原生兼容分支(路线B) + 单包：minSdk16/仅v1(SHA-1)/仅armeabi-v7a/独立包名/Leanback双入口/遥控器换台换线/ijkplayer软解/频道表与主程序同源(1046台2135线路，含实测明文镜像与扩展线路)/换源防绕圈+Dart-Java-Python三层判定一致/启动Activity全限定名与dex一致/崩溃自显/控制条焦点与台号直达/收藏与上次观看/拼音检索/可播台账302最终URL/HTTPS两遍扫描与一键重试/透明频道栏与三列地区切换/错误提示定时消失与自动回退/统一浮层空闲隐藏(默认30秒可调至60秒)/12项遥控设置(设置内新增地区切换入口，顶部信息条已下线)与开机自启/优先清晰度与CCTV-1高清/单包内清单字节一致/主程序不回退（203 项）'),
  Gate.dart('android-form', 'tooling/verify_android_form.dart',
      note: '安卓形态判定/单一入口/渠道分包/ABI/保活/无 GMS/电视端 v1+v2 双签与 1.0.0 回退契约（91 项）'),
  Gate.dart('vod-source-address', 'tooling/verify_vod_source_address.dart',
      note: '1.0.5 点播源地址(G1 开放接口默认关闭/候选清单/手动输入/E9 安全基线)+G2+G3 默认组合与片库检索(空查询等价 1.0.4)+版本与回退基线'),
  Gate.dart('third-party-vod', 'tooling/verify_third_party_vod.dart',
      note: '1.0.5 第三方点播数据真接入：契约 JSON / 苹果 CMS 采集站 / 播放地址解析 / 离线端到端(导入→栏目→适配器→可播地址) / 零代码执行护栏 / 1.0.4 行为不变'),
  Gate.dart('vod-playback', 'tooling/verify_vod_playback.dart',
      note: '1.0.5 第四次修：海报图(相对路径/编码/失败回落) + 站点上限100 + 允许执行外部代码(只走HTTP接口) + 分批进度与预算 + 播放页返回/选集/暂停/快进快退/下一集 + 点播缓冲档 + 分栏缓存'),
  Gate.dart('vod-content-index', 'tooling/verify_vod_content_index.dart',
      note: '1.0.5 第十次修：短视频栏目(类目表父链/文本兜底/老缓存迁移) + 接口数据本地内容检索记录(四字段持久化/upsert去重/元数据更新/TTL过期/v1升级/栏目-记录-检索一致/字段检索)'),
  Gate.dart('vod-builtin-index', 'tooling/verify_vod_builtin_index.dart',
      note: '1.0.5 第十三次修（第1项）：安装包内置检索索引——Python 打包产物 ↔ Dart 读取器双向一致（manifest 自洽/唯一片名数与每名上限/分片行数与 sha256/前端编码还原/词表逐字一致/栏目归属/发布资产声明，91 项）'),
  Gate.dart('vod-boot-index', 'tooling/verify_vod_boot_index.dart',
      note: '1.0.5 第十三次修（第2项）：启动期索引一致性校验与加载——六态状态机全转移图（一致零网络/地址不一致/过期/分片缺失/同步失败回退/无索引/allowSync=false/shouldReplaceCache 覆盖策略/文案与诊断理由，61 项）'),
  Gate.dart('vod-builtin-service', 'tooling/verify_vod_builtin_service.dart',
      note: '1.0.5 第十三次修（第1项）：内置索引运行期服务——真实产物检索/栏目隔离/limit/缓存与 clearCache/命中反查/回源参数不串/adoptResolved 不清外部目录且地址真可取/同名归并成一张卡片/回源失败自动换源（115 项）'),
  Gate.dart('vod-index-gate', 'tooling/verify_vod_index_gate.dart',
      note: '1.0.5 第十六次修：进入点播的片源索引校验与分支加载——五态全转移/初次必弹输入页/地址一致直接加载零网络/地址不一致重新生成目录/来源唯一不变式/生成目录编解码/等距采样续载/接线护栏'),
  Gate.dart('vod-posters-facets', 'tooling/verify_vod_posters_facets.dart',
      note: '1.0.5 第十七次修：可见卡片海报异步补齐（按目录身份+条目id精确匹配/批量取vod_pic/失败与加载不阻塞/换片源在途作废/缓存与并发上限）+ 检索条件从整份索引目录动态加载（全量覆盖/五态反馈/变更同步/过期选中值清理/真实分片统计/「全部」目录级统计数/手动刷新入口/静态接线，76 项）'),
  Gate.command(
      'python-m0',
      const <String>[
        '__PYTHON__',
        '-m',
        'unittest',
        'shunbo.spike.tests.test_alignment',
        '-v',
      ],
      note: 'M0 Python 原型（6 项）',
      cwdRelative: '..'),
];

Future<void> main(List<String> args) async {
  if (args.contains('--selftest')) {
    await _selftest();
    return;
  }
  final opt = _Options.parse(args);
  final root = _packageRoot();
  if (root == null) {
    stderr.writeln('找不到工程根目录（pubspec.yaml）；请在 shunbo 包内运行。');
    exit(2);
  }

  final selected = <Gate>[
    for (final g in _gates)
      if (_selected(g, opt)) g,
  ];
  if (selected.isEmpty) {
    stderr.writeln('没有匹配的门禁步骤：only=${opt.only} skip=${opt.skip}');
    exit(2);
  }

  stdout.writeln('顺播验证门禁 · ${selected.length} 个步骤 · 根目录 ${root.path}');
  final total = Stopwatch()..start();
  final results = <GateResult>[];

  for (var i = 0; i < selected.length; i++) {
    final gate = selected[i];
    final label = '[${i + 1}/${selected.length}] ${gate.id}';
    stdout.writeln('$label ... ${gate.note}');
    final r = await _runGate(gate, opt, root);
    results.add(r);

    final statText = r.stats == null
        ? ''
        : '  ${r.stats!.passed}/${r.stats!.total} 项';
    stdout.writeln('${' ' * label.length}   '
        '${r.ok ? 'PASS' : 'FAIL'}${statText}  ${_fmt(r.elapsed)}'
        '${r.reason.isEmpty ? '' : '  ${r.reason}'}');

    if (!r.ok) {
      for (final f in r.failures.take(15)) {
        stdout.writeln('${' ' * (label.length + 3)}$f');
      }
      if (r.failures.length > 15) {
        stdout.writeln(
            '${' ' * (label.length + 3)}... 另有 ${r.failures.length - 15} 条失败');
      }
      if (!opt.verbose && r.tail.trim().isNotEmpty) {
        stdout.writeln('${' ' * (label.length + 3)}--- 输出尾部 ---');
        for (final line in r.tail.trimRight().split('\n')) {
          stdout.writeln('${' ' * (label.length + 3)}$line');
        }
      }
    }
  }

  total.stop();
  stdout.writeln('-' * 64);

  final failed = results.where((r) => !r.ok).toList();
  final assertions = results
      .where((r) => r.stats != null)
      .fold<int>(0, (sum, r) => sum + r.stats!.passed);
  final expected = results
      .where((r) => r.stats != null)
      .fold<int>(0, (sum, r) => sum + r.stats!.total);

  if (failed.isEmpty) {
    stdout.writeln('全部门禁通过：${results.length} 个步骤，'
        '断言 $assertions/$expected，耗时 ${_fmt(total.elapsed)}');
    exit(0);
  }

  stdout.writeln('门禁失败：${failed.length}/${results.length} 个步骤未通过');
  for (final r in failed) {
    stdout.writeln('  - ${r.gate.id}: ${r.reason}');
  }
  exit(1);
}

/// 门禁脚本自身的自检：用合成子进程验证「判定逻辑」不会放行假成功。
///
/// 这些用例跑的是临时目录里的假脚本，不碰真实工程，也不会阻塞主流程；
/// 但它们能证明本脚本不是「跑一遍打印绿字」的摆设。
Future<void> _selftest() async {
  final dir = await Directory.systemTemp.createTemp('shunbo_gate_selftest');
  final opt = const _Options(
    verbose: false,
    only: <String>{},
    skip: <String>{},
    timeout: Duration(seconds: 60),
  );
  var failed = 0;
  var checks = 0;

  void expect(String name, bool ok, String detail) {
    checks++;
    if (ok) {
      stdout.writeln('PASS: $name');
    } else {
      failed++;
      stdout.writeln('FAIL: $name —— $detail');
    }
  }

  Future<File> fake(String name, String body) async {
    final f = File('${dir.path}${Platform.pathSeparator}$name.dart');
    await f.writeAsString(body);
    return f;
  }

  try {
    // 1. 退出 0 但没报告断言数 → 必须判失败（防脚本提前 return / 断言被注释）。
    final silent = await fake('silent', "void main() { print('PASS: 假装通过'); }");
    final r1 = await _runGate(
        Gate.dart('selftest-silent', silent.path, note: '静默通过'), opt, dir);
    expect('静默通过被判失败', !r1.ok && r1.reason.contains('未报告断言数'),
        'ok=${r1.ok} reason=${r1.reason}');

    // 2. 输出 FAIL 却退出 0 → 必须判失败（防退出码契约被改坏）。
    final liar = await fake('liar', "void main() { print('FAIL: 假装失败'); }");
    final r2 = await _runGate(
        Gate.dart('selftest-liar', liar.path, note: 'FAIL 但退出 0'), opt, dir);
    expect('FAIL 但退出 0 被判失败', !r2.ok && r2.reason.contains('退出码为 0'),
        'ok=${r2.ok} reason=${r2.reason}');

    // 3. 非零退出码 → 失败且带上退出码与输出尾部。
    final bad = await fake(
        'bad', "import 'dart:io';\nvoid main() { print('boom'); exit(3); }");
    final r3 = await _runGate(
        Gate.dart('selftest-exit', bad.path, note: '退出码 3'), opt, dir);
    expect('非零退出码被判失败', !r3.ok && r3.reason.contains('3'),
        'ok=${r3.ok} reason=${r3.reason}');
    expect('失败时保留输出尾部', r3.tail.contains('boom'), 'tail=${r3.tail}');

    // 4. 正常脚本 → 通过并解析出真实断言数（不能被误杀）。
    final good = await fake(
        'good',
        "void main() { print('PASS: a'); print('PASS: b');"
            " print('回归：2/2 断言通过'); }");
    final r4 = await _runGate(
        Gate.dart('selftest-good', good.path, note: '正常通过'), opt, dir);
    expect('正常脚本通过且断言数正确',
        r4.ok && r4.stats != null && r4.stats!.passed == 2 && r4.stats!.total == 2,
        'ok=${r4.ok} stats=${r4.stats?.passed}/${r4.stats?.total} reason=${r4.reason}');

    // 5. 汇总行格式兼容：verify_logic 的「全部断言通过：共 N 项」。
    final alt = await fake('alt', "void main() { print('全部断言通过：共 7 项'); }");
    final r5 = await _runGate(
        Gate.dart('selftest-alt', alt.path, note: '另一种汇总格式'), opt, dir);
    expect('兼容「共 N 项」汇总格式', r5.ok && r5.stats?.total == 7,
        'ok=${r5.ok} stats=${r5.stats?.total}');
  } finally {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 临时目录清理失败不影响判定结论。
    }
  }

  if (failed == 0) {
    stdout.writeln('门禁自检通过：$checks/$checks 条判定符合预期');
    exit(0);
  }
  stdout.writeln('门禁自检失败：${checks - failed}/$checks 条判定符合预期');
  exit(1);
}

bool _selected(Gate g, _Options opt) {
  final id = g.id.toLowerCase();
  if (opt.skip.contains(id)) return false;
  if (opt.only.isEmpty) return true;
  return opt.only.any((k) => id.contains(k));
}

Future<GateResult> _runGate(
    Gate gate, _Options opt, Directory root) async {
  final sw = Stopwatch()..start();
  final out = StringBuffer();
  final err = StringBuffer();
  Process? proc;
  var timedOut = false;

  try {
    proc = await _start(gate, root);
  } catch (e) {
    sw.stop();
    return GateResult(
      gate: gate,
      ok: false,
      reason: '无法启动：$e',
      stats: null,
      elapsed: sw.elapsed,
      failures: <String>['无法启动：$e'],
      tail: '',
    );
  }

  // 用 Completer 等流真正关闭再统计：process.exitCode 先于管道读完，
  // 直接 cancel 订阅会把最后几个 chunk（正好是汇总行）丢掉。
  final pumps = <Future<void>>[
    _pump(proc.stdout, out, opt.verbose ? stdout : null),
    _pump(proc.stderr, err, opt.verbose ? stderr : null),
  ];

  int code;
  try {
    code = await proc.exitCode.timeout(opt.timeout);
  } on TimeoutException {
    timedOut = true;
    proc.kill(ProcessSignal.sigkill);
    code = await proc.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () => -1,
    );
  }
  await Future.wait<void>(pumps);
  sw.stop();

  final text = '${out.toString()}\n${err.toString()}';
  final stats = _parseAssertions(text);
  final failures = <String>[
    for (final line in const LineSplitter().convert(text))
      if (_isFailureLine(line)) line.trim(),
  ];

  var ok = code == 0 && !timedOut;
  var reason = '';
  if (timedOut) {
    reason = '超时 ${opt.timeout.inSeconds}s';
  } else if (code != 0) {
    reason = '退出码 $code';
  } else if (failures.isNotEmpty) {
    // 输出里有 FAIL 却退出 0：脚本自身的退出码契约被改坏了，不能算通过。
    ok = false;
    reason = '输出含 ${failures.length} 条失败但退出码为 0';
  } else if (gate.expectAssertions && stats == null) {
    // 退出码 0 但没报告断言数：脚本可能提前 return 或断言被注释掉。
    ok = false;
    reason = '未报告断言数（疑似静默跳过）';
  } else if (gate.expectAssertions && stats != null && stats.total == 0) {
    ok = false;
    reason = '断言数为 0';
  }

  return GateResult(
    gate: gate,
    ok: ok,
    reason: reason,
    stats: stats,
    elapsed: sw.elapsed,
    failures: failures,
    tail: _tail(text, 20),
  );
}

/// 把子进程输出收集进 [buf]；[echo] 非空时同时实时打印（-v 模式）。
Future<void> _pump(Stream<List<int>> stream, StringBuffer buf, IOSink? echo) {
  final done = Completer<void>();
  stream.transform(utf8.decoder).listen(
    (chunk) {
      buf.write(chunk);
      echo?.write(chunk);
    },
    onError: (Object _) => done.isCompleted ? null : done.complete(),
    onDone: () => done.isCompleted ? null : done.complete(),
    cancelOnError: false,
  );
  return done.future;
}

Future<Process> _start(Gate gate, Directory root) async {
  final cwd = gate.cwdRelative == '.'
      ? root.path
      : '${root.path}${Platform.pathSeparator}${gate.cwdRelative}';

  switch (gate.kind) {
    case GateKind.flutterAnalyze:
      return _startFlutter(const <String>['analyze'], cwd);
    case GateKind.dartScript:
      return Process.start(
        _dartExe(),
        <String>['run', gate.dartScript],
        workingDirectory: cwd,
      );
    case GateKind.external:
      // 外部命令：python 名称按平台择一，Windows 上 .bat 需经 shell 解析。
      final cmd = <String>[
        for (final a in gate.command) a == '__PYTHON__' ? await _pythonExe() : a,
      ];
      return Process.start(
        cmd.first,
        cmd.sublist(1),
        workingDirectory: cwd,
        runInShell: Platform.isWindows,
      );
  }
}

Future<Process> _startFlutter(List<String> args, String cwd) async {
  final flutter = _resolveFlutter();
  if (flutter == null) {
    throw StateError('找不到 flutter 可执行文件（可用 FLUTTER_BIN 或 FLUTTER_ROOT 指定）');
  }
  return Process.start(flutter, args,
      workingDirectory: cwd, runInShell: Platform.isWindows);
}

/// 定位 flutter。注意 `dart run` 下 [Platform.resolvedExecutable] 是
/// `<flutter>/bin/cache/dart-sdk/bin/dart.exe`，直接取同目录会拿到不存在的路径；
/// 而本机 PATH 里通常没有 flutter（只有 dart 被加了 PATH），所以必须多路兜底。
String? _resolveFlutter() {
  final name = Platform.isWindows ? 'flutter.bat' : 'flutter';
  final sep = Platform.pathSeparator;

  final explicit = Platform.environment['FLUTTER_BIN'];
  if (explicit != null && explicit.isNotEmpty && File(explicit).existsSync()) {
    return explicit;
  }

  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null && root.isNotEmpty) {
    final c = '$root${sep}bin$sep$name';
    if (File(c).existsSync()) return c;
  }

  // 从 dart 所在目录逐级上溯，命中 <某级>/bin/flutter 即为 SDK 根。
  Directory? dir = File(_dartExe()).parent;
  for (var i = 0; i < 6 && dir != null; i++) {
    for (final candidate in <String>[
      '${dir.path}$sep$name',
      '${dir.path}${sep}bin$sep$name',
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
    final parent = dir.parent;
    dir = parent.path == dir.path ? null : parent;
  }

  // PATH 扫描（Windows 上 Process.start('flutter') 不走 shell 时找不到 .bat）。
  final pathEnv = Platform.environment['PATH'] ?? '';
  for (final raw in pathEnv.split(Platform.isWindows ? ';' : ':')) {
    final p = raw.trim();
    if (p.isEmpty) continue;
    final c = '$p$sep$name';
    if (File(c).existsSync()) return c;
  }
  return null;
}

String _dartExe() {
  final env = Platform.environment['DART_BIN'];
  if (env != null && env.isNotEmpty) return env;
  // 裸 `dart run` 下 resolvedExecutable 即 dart 本身。
  final exe = Platform.resolvedExecutable;
  return exe.isEmpty ? 'dart' : exe;
}

Future<String> _pythonExe() async {
  final env = Platform.environment['PYTHON_BIN'];
  if (env != null && env.isNotEmpty) return env;
  for (final c in <String>['python', 'python3', 'py']) {
    try {
      final r = await Process.run(c, const <String>['--version'],
          runInShell: Platform.isWindows);
      if (r.exitCode == 0) return c;
    } catch (_) {
      // 继续尝试下一个候选。
    }
  }
  return 'python';
}

/// 断言统计：兼容「N/M 断言通过」与「全部断言通过：共 N 项」两种汇总串。
AssertionStats? _parseAssertions(String text) {
  final ratio = RegExp(r'(\d+)\s*/\s*(\d+)\s*断言通过').allMatches(text);
  if (ratio.isNotEmpty) {
    final m = ratio.last;
    return AssertionStats(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
    );
  }
  final single = RegExp(r'全部断言通过：共\s*(\d+)\s*项').firstMatch(text);
  if (single != null) {
    final n = int.parse(single.group(1)!);
    return AssertionStats(n, n);
  }
  // Python unittest：`Ran 6 tests in 0.01s` + `OK`（-v 时 OK 不带数量）。
  final ran = RegExp(r'Ran\s+(\d+)\s+tests?').firstMatch(text);
  final ok = RegExp(r'^OK\b', multiLine: true).hasMatch(text);
  if (ran != null && ok) {
    final n = int.parse(ran.group(1)!);
    return AssertionStats(n, n);
  }
  final pyNone = RegExp(r'^OK\s*\((\d+)\s+tests?\)', multiLine: true)
      .firstMatch(text);
  if (pyNone != null) {
    final n = int.parse(pyNone.group(1)!);
    return AssertionStats(n, n);
  }
  return null;
}

bool _isFailureLine(String line) {
  final t = line.trimLeft();
  if (t.startsWith('FAIL:')) return true;
  if (t.startsWith('FAILED')) return true;
  if (t.startsWith('ERROR:')) return true;
  // flutter analyze：「3 issues found.」；「No issues found!」不匹配（非数字开头）。
  final issues = RegExp(r'(\d+)\s+issues?\s+found').firstMatch(t);
  if (issues != null && (int.tryParse(issues.group(1)!) ?? 0) > 0) return true;
  return false;
}

String _tail(String text, int lines) {
  final all = const LineSplitter()
      .convert(text)
      .where((l) => l.trim().isNotEmpty)
      .toList();
  if (all.isEmpty) return '';
  final start = all.length > lines ? all.length - lines : 0;
  return all.sublist(start).join('\n');
}

String _fmt(Duration d) {
  final s = d.inMilliseconds / 1000;
  return '${s.toStringAsFixed(1)}s';
}

/// 定位包根（含 pubspec.yaml）。优先从脚本位置回溯，其次从 cwd 回溯。
Directory? _packageRoot() {
  Directory? walk(Directory start) {
    var dir = start;
    for (var i = 0; i < 6; i++) {
      if (File('${dir.path}${Platform.pathSeparator}pubspec.yaml')
          .existsSync()) {
        return dir;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) return null;
      dir = parent;
    }
    return null;
  }

  try {
    final uri = Platform.script;
    if (uri.scheme == 'file') {
      final fromScript = walk(File.fromUri(uri).parent);
      if (fromScript != null) return fromScript;
    }
  } catch (_) {
    // 忽略，退回 cwd。
  }
  return walk(Directory.current);
}
