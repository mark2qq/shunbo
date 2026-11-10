// 源配置「从文件导入」端到端回归。
//
// 验证重点不是重复测 JSON 解析，而是本地文件这条新 IO 边界：
// Windows 复制路径带引号 / file:// URI / UTF-8 BOM / CRLF、目录与符号链接、
// 超大文件必须先 stat 再读、NUL 与非法 UTF-8 不能进 jsonDecode，
// 以及**任何读取失败都不能清空上一次已生效的源**。
//
// 文件是真实临时文件，取数是真实本地 HTTP（FixtureSite），不是 MockFetcher。
// 运行：dart run tooling/verify_source_config_file.dart
import 'dart:convert';
import 'dart:io';

import 'package:shunbo/core/player/mock_player_controller.dart';
import 'package:shunbo/core/scheduler/playback_orchestrator.dart';
import 'package:shunbo/core/scheduler/source_catalog.dart';
import 'package:shunbo/core/source/memory_source_adapter.dart';
import 'package:shunbo/core/source/site_rule.dart';
import 'package:shunbo/core/source/source_adapter.dart';
import 'package:shunbo/core/source/source_profile.dart';
import 'package:shunbo/core/source/source_registry.dart';
import 'package:shunbo/data/memory_resume_store.dart';
import 'package:shunbo/data/onboarding/onboarding_flow.dart';
import 'package:shunbo/data/onboarding/sample_source_config.dart';
import 'package:shunbo/data/onboarding/source_config_file.dart';
import 'package:shunbo/data/onboarding/source_config_validator.dart';
import 'package:shunbo/data/onboarding/source_import_service.dart';

import 'fixture_site.dart';

int _checkCount = 0;
int _failCount = 0;

void check(String name, bool ok) {
  if (!ok) {
    _failCount++;
    print('FAIL: $name');
    return;
  }
  _checkCount++;
  print('PASS: $name');
}

/// 与 App 的 FileConfigStore 语义等价的最小持久层（净化文本 + 引导状态）。
class MemorySaved {
  String? text;
  Map<String, dynamic>? onboarding;
  bool failWrites = false;
  int writes = 0;
}

/// 一次「启动」：全新注册表，但可共享同一份磁盘状态以模拟重启。
class Harness {
  final SourceRegistry registry = SourceRegistry();
  final SourceCatalog catalog = SourceCatalog();
  final MemorySaved saved;
  late final OnboardingFlow flow;
  late final SourceImportService svc;

  /// 文件 IO 次数：用于验证「免责门禁在读文件之前」。
  int fileReads = 0;

  Harness(this.saved, {SourceConfigFileLoader? loader}) {
    final builtin = MemorySourceAdapter(
      id: 'builtin',
      profile: const SourceProfile(name: 'builtin'),
      episodes: <String, List<EpisodeInfo>>{},
      urls: <String, List<PlayUrl>>{},
    );
    registry.register(builtin);
    catalog.register(builtin.profile);
    flow = OnboardingFlow(
      initial: saved.onboarding == null
          ? null
          : OnboardingState.fromJson(saved.onboarding!),
      persist: (s) async => saved.onboarding = Map<String, dynamic>.from(s),
    );
    svc = SourceImportService(
      registry: registry,
      catalog: catalog,
      flow: flow,
      readSaved: () async => saved.text,
      writeSaved: (t) async {
        if (saved.failWrites) throw StateError('simulated disk full');
        saved.text = t;
        saved.writes++;
      },
      readFile: (path) async {
        fileReads++;
        return loader != null ? loader(path) : readSourceConfigFile(path);
      },
    );
  }

  void close() => svc.close();
}

Map<String, dynamic> cfg(String id, String origin) => <String, dynamic>{
      'id': id,
      'name': '站点-$id',
      'baseUrl': origin,
      'parser': 'regex',
      'searchPath': 'search?q={keyword}',
      'playPath': 'detail/{mediaId}',
      'platforms': const <String>['desktop', 'tv'],
      'rules': <String, dynamic>{
        ...SiteRulePresets.legacy.toJson(),
        'baseUrl': origin,
      },
    };

String multi(List<Object?> sources) => jsonEncode(<String, dynamic>{
      'name': '文件导入样本',
      'version': 1,
      'sources': sources,
    });

/// 临时目录里造真实文件。
class FileBox {
  late final Directory dir;

  Future<void> init() async {
    dir = await Directory.systemTemp.createTemp('shunbo-file-import-');
  }

  Future<File> put(String name, List<int> bytes) async {
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  Future<File> text(String name, String body, {bool bom = false}) => put(
        name,
        <int>[
          if (bom) ...const <int>[0xEF, 0xBB, 0xBF],
          ...utf8.encode(body),
        ],
      );

  Future<void> clean() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

Future<bool> mediaReachable(String url) async {
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  try {
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    return resp.statusCode == 200 && body.contains('#EXTM3U');
  } catch (_) {
    return false;
  } finally {
    client.close();
  }
}

// ---------------------------------------------------------------------------
// A. 路径归一化（纯函数）
// ---------------------------------------------------------------------------
void _pathNormalize(FileBox box) {
  check('普通路径原样保留',
      normalizeSourceConfigPath('${box.dir.path}/a.json') ==
          '${box.dir.path}/a.json');
  check('首尾空白被去掉',
      normalizeSourceConfigPath('  ${box.dir.path}/a.json \n') ==
          '${box.dir.path}/a.json');
  check('成对双引号被剥离',
      normalizeSourceConfigPath('"${box.dir.path}/a.json"') ==
          '${box.dir.path}/a.json');
  check('成对单引号被剥离',
      normalizeSourceConfigPath("'${box.dir.path}/a.json'") ==
          '${box.dir.path}/a.json');
  check('不成对引号不被误删',
      normalizeSourceConfigPath('"${box.dir.path}/a.json') ==
          '"${box.dir.path}/a.json');
  check('空路径归一化后仍为空', normalizeSourceConfigPath('   ').isEmpty);
  check('非 file scheme 原样保留',
      normalizeSourceConfigPath('https://example.com/a.json') ==
          'https://example.com/a.json');
  check('坏 file URI 不抛异常',
      normalizeSourceConfigPath('file:///%%%bad').isNotEmpty);
  check('文件名展示不含目录',
      !sourceConfigFileName('${box.dir.path}/a.json').contains('/') &&
          sourceConfigFileName('${box.dir.path}/a.json') == 'a.json');
  check('超长文件名展示被截断',
      sourceConfigFileName('C:/${'a' * 200}.json').length <= 80);
}

// ---------------------------------------------------------------------------
// B. 文件读取边界
// ---------------------------------------------------------------------------
Future<void> _readBoundaries(FileBox box) async {
  final good = await box.text('good.json', multi(<Object?>[cfg('src-a', 'http://127.0.0.1:1')]));
  final r0 = await readSourceConfigFile(good.path);
  check('正常文本文件读取成功', r0.ok);
  check('读取结果是完整 JSON 文本',
      r0.text != null && jsonDecode(r0.text!) is Map);
  check('结果带字节数与文件名',
      r0.bytes > 0 && r0.fileName == 'good.json');

  final bom = await box.text('bom.json', '  ${multi(<Object?>[cfg('src-a', 'http://127.0.0.1:1')])}\r\n',
      bom: true);
  final rBom = await readSourceConfigFile(bom.path);
  check('UTF-8 BOM 文件读取成功', rBom.ok);
  check('BOM 被剥离且 jsonDecode 可解析',
      rBom.text != null &&
          !rBom.text!.startsWith('\uFEFF') &&
          jsonDecode(rBom.text!) is Map);

  final doubleBom = await box.put(
      'double-bom.json',
      <int>[
        0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF,
        ...utf8.encode(multi(<Object?>[cfg('src-a', 'http://127.0.0.1:1')])),
      ]);
  final rDouble = await readSourceConfigFile(doubleBom.path);
  check('重复 BOM 也被剥离',
      rDouble.ok && rDouble.text != null && jsonDecode(rDouble.text!) is Map);

  final crlf = await box.text('crlf.json', '\r\n  ${multi(<Object?>[cfg('src-a', 'http://127.0.0.1:1')])}\r\n  ');
  final rCrlf = await readSourceConfigFile(crlf.path);
  check('CRLF 与首尾空白不影响解析',
      rCrlf.ok && rCrlf.text != null && jsonDecode(rCrlf.text!) is Map);

  final empty = await box.put('empty.json', const <int>[]);
  check('空文件被拒绝',
      (await readSourceConfigFile(empty.path)).failure ==
          SourceConfigFileFailure.empty);
  final onlyBom = await box.put('only-bom.json', const <int>[0xEF, 0xBB, 0xBF]);
  check('仅含 BOM 的文件被拒绝',
      (await readSourceConfigFile(onlyBom.path)).failure ==
          SourceConfigFileFailure.empty);

  check('目录被拒绝',
      (await readSourceConfigFile(box.dir.path)).failure ==
          SourceConfigFileFailure.notAFile);
  check('不存在的文件被拒绝',
      (await readSourceConfigFile('${box.dir.path}/nope.json')).failure ==
          SourceConfigFileFailure.notFound);
  final nul = await box.put('binary.json', <int>[0x7B, 0x00, 0x7D]);
  check('含 NUL 的二进制文件被拒绝',
      (await readSourceConfigFile(nul.path)).failure ==
          SourceConfigFileFailure.binary);
  final badUtf8 = await box.put('gbk.json', <int>[0x7B, 0xD6, 0xD0, 0x7D]);
  final rBadUtf8 = await readSourceConfigFile(badUtf8.path);
  check('非 UTF-8 编码被拒绝且提示另存为 UTF-8',
      rBadUtf8.failure == SourceConfigFileFailure.invalidEncoding &&
          rBadUtf8.message.contains('UTF-8'));

  final big = await box.put('big.json', List<int>.filled(300 * 1024, 0x61));
  check('超过默认 256 KB 上限被拒绝',
      (await readSourceConfigFile(big.path)).failure ==
          SourceConfigFileFailure.tooLarge);
  check('注入更小上限同样被拒绝（先 stat 不读全文）',
      (await readSourceConfigFile(good.path, maxBytes: 16)).failure ==
          SourceConfigFileFailure.tooLarge);
  final exact = await box.put('exact.json', utf8.encode('{}'));
  check('体积恰好等于上限可通过',
      (await readSourceConfigFile(exact.path, maxBytes: 2)).ok);

  check('空路径被拒绝',
      (await readSourceConfigFile('  ')).failure ==
          SourceConfigFileFailure.emptyPath);
  check('超长路径被拒绝',
      (await readSourceConfigFile('C:/${'a' * 9000}.json')).failure ==
          SourceConfigFileFailure.tooLongPath);
  check('路径含 NUL 被拒绝',
      (await readSourceConfigFile('C:/a\u0000.json')).failure ==
          SourceConfigFileFailure.invalidPath);
  check('远程 file://host URI 被拒绝（不发起 SMB 请求）',
      (await readSourceConfigFile('file://evil.example/share/a.json'))
          .failure ==
          SourceConfigFileFailure.remotePath);
  check('UNC 网络路径被拒绝',
      (await readSourceConfigFile(r'\\evil.example\share\a.json')).failure ==
          SourceConfigFileFailure.remotePath);

  // 路径形态：Windows「复制文件路径」与 file:// URI 都要能直达同一文件。
  final rQuoted = await readSourceConfigFile('"${good.path}"');
  check('带引号路径可真实读取', rQuoted.ok && rQuoted.text == r0.text);
  final uri = Uri.file(good.path).toString();
  final rUri = await readSourceConfigFile(uri);
  check('file:// URI 可真实读取', rUri.ok && rUri.text == r0.text);

  // 符号链接：部分 Windows 环境无创建权限，此时用目录路径覆盖同类型拒绝。
  Link? link;
  try {
    link = Link('${box.dir.path}/link.json');
    await link.create(good.path);
  } catch (_) {
    link = null;
  }
  if (link != null) {
    check('符号链接被拒绝（不跟随）',
        (await readSourceConfigFile(link.path)).failure ==
            SourceConfigFileFailure.symlink);
  } else {
    check('平台不允许创建符号链接，改由目录用例覆盖类型拒绝',
        (await readSourceConfigFile(box.dir.path)).failure ==
            SourceConfigFileFailure.notAFile);
  }
}

// ---------------------------------------------------------------------------
// C. 服务门禁与状态一致性
// ---------------------------------------------------------------------------
Future<void> _serviceCases(FileBox box, String origin) async {
  final saved = MemorySaved();
  final h = Harness(saved);
  final goodFile =
      await box.text('svc-good.json', multi(<Object?>[cfg('src-file-a', origin)]), bom: true);

  final blocked = await h.svc.importFromFile(goodFile.path);
  check('未接受免责声明时文件导入被拒绝',
      blocked.kind == ImportOutcomeKind.blockedByDisclaimer);
  check('免责门禁在读文件之前（零次 IO）', h.fileReads == 0);
  check('被拒文件导入未注册任何源', h.registry.ids.length == 1);
  check('被拒文件导入未落盘', saved.text == null && saved.writes == 0);

  await h.flow.acceptDisclaimer();
  check('接受免责声明后进入导入步骤',
      h.flow.state.step == OnboardingStep.sourceImport);

  final blank = await h.svc.importFromFile('  ');
  check('空路径被服务拒绝', blank.kind == ImportOutcomeKind.rejected);
  check('空路径同样不触发文件 IO', h.fileReads == 0);

  final missing = await h.svc.importFromFile('${box.dir.path}/missing.json');
  check('不存在文件被服务拒绝', missing.kind == ImportOutcomeKind.rejected);
  check('文件失败原因可读', missing.message.contains('文件不存在'));
  check('文件失败未注册 / 未落盘 / 未推进引导',
      h.registry.ids.length == 1 &&
          saved.writes == 0 &&
          h.flow.state.step == OnboardingStep.sourceImport);
  check('读取次数只增一次', h.fileReads == 1);

  final dirFail = await h.svc.importFromFile(box.dir.path);
  check('目录路径被服务拒绝', dirFail.kind == ImportOutcomeKind.rejected);
  final binFail = await h.svc.importFromFile('${box.dir.path}/binary.json');
  check('二进制文件被服务拒绝', binFail.kind == ImportOutcomeKind.rejected);
  final encFail = await h.svc.importFromFile('${box.dir.path}/gbk.json');
  check('非 UTF-8 文件被服务拒绝', encFail.kind == ImportOutcomeKind.rejected);
  check('四次失败后引导仍未推进',
      h.flow.state.step == OnboardingStep.sourceImport &&
          h.flow.state.importCount == 0);

  final ok = await h.svc.importFromFile(goodFile.path);
  check('BOM + 真实文件导入成功', ok.ok && ok.accepted == 1);
  check('结果带来源文件名且不回显完整路径',
      ok.originLabel == 'svc-good.json' && !ok.message.contains(box.dir.path));
  check('导入结果列出已生效源', ok.sourceIds.contains('src-file-a'));
  check('文件导入确实落盘', ok.persisted && saved.writes == 1);
  check('落盘的是净化配置（无 BOM、可解析）',
      saved.text != null &&
          !saved.text!.startsWith('\uFEFF') &&
          jsonDecode(saved.text!) is Map);
  check('引导推进到平台确认且计数为 1',
      h.flow.state.step == OnboardingStep.platformConfirm &&
          h.flow.state.importCount == 1);

  // 坏条隔离：文件里一条危险配置 + 一条好配置。
  final mixed = await box.text(
      'mixed.json',
      multi(<Object?>[
        <String, dynamic>{
          'id': 'evil',
          'baseUrl': origin,
          'script': 'doBadThings()',
        },
        cfg('src-file-b', origin),
      ]));
  final mixedResult = await h.svc.importFromFile(mixed.path);
  check('文件里部分坏条时好源仍导入成功',
      mixedResult.ok && mixedResult.accepted == 1);
  check('坏条给出可读拒绝明细',
      mixedResult.rejections.length == 1 &&
          mixedResult.message.contains('安全策略拒绝'));
  check('坏条未落盘（净化配置只含 1 源）',
      saved.text != null &&
          (jsonDecode(saved.text!)['sources'] as List).length == 1);

  // 零可用源：不能清空上一次已生效配置。
  final allBad = await box.text(
      'all-bad.json',
      multi(<Object?>[
        <String, dynamic>{'id': 'evil2', 'baseUrl': origin, 'eval': '1'},
      ]));
  final zero = await h.svc.importFromFile(allBad.path);
  check('零可用源文件被拒绝', zero.kind == ImportOutcomeKind.rejected);
  check('失败的文件导入不销毁已生效源',
      h.registry.ids.contains('src-file-b') &&
          h.catalog.contains('src-file-b'));
  check('失败的文件导入不覆盖已落盘配置',
      saved.text != null &&
          (jsonDecode(saved.text!)['sources'] as List).length == 1);
  check('失败的文件导入不增加引导计数', h.flow.state.importCount == 2);

  // 重复从另一个文件导入：替换旧源、注销画像、不留孤儿。
  final another = await box.text(
      'another.json', multi(<Object?>[cfg('src-file-c', origin)]));
  final replaced = await h.svc.importFromFile(another.path);
  check('引导中途可重新从文件导入', replaced.ok && replaced.accepted == 1);
  check('重复文件导入注销旧源，无孤儿',
      !h.registry.ids.contains('src-file-b') &&
          !h.catalog.contains('src-file-b') &&
          h.registry.ids.contains('src-file-c'));
  check('重新导入累加计数且步骤不回退',
      h.flow.state.importCount == 3 &&
          h.flow.state.step == OnboardingStep.platformConfirm);

  // 文件读取器抛异常：服务必须收敛为结构化失败。
  final throwing = Harness(MemorySaved(),
      loader: (p) async => throw const FileSystemException('disk ejected'));
  await throwing.flow.acceptDisclaimer();
  final thrown = await throwing.svc.importFromFile(goodFile.path);
  check('读取器异常被服务收敛为拒绝而非崩溃',
      thrown.kind == ImportOutcomeKind.rejected &&
          thrown.message.contains('异常'));
  check('读取器异常未注册源、未落盘',
      throwing.registry.ids.length == 1 &&
          throwing.svc.lastOutcome?.persisted == false);
  throwing.close();

  // 跳过引导的用户：未补签免责时仍不得从文件导入。
  final skippedSaved = MemorySaved();
  final skipped = Harness(skippedSaved);
  await skipped.flow.skipAll();
  check('跳过引导后状态完成但未接受免责',
      skipped.flow.state.completed && !skipped.flow.state.disclaimerAccepted);
  final skippedResult = await skipped.svc.importFromFile(goodFile.path);
  check('跳过引导未补签时文件导入被拒',
      skippedResult.kind == ImportOutcomeKind.blockedByDisclaimer &&
          skipped.fileReads == 0);
  await skipped.flow.acceptDisclaimerLater();
  final afterSign = await skipped.svc.importFromFile(goodFile.path);
  check('补签后可从文件导入且不回退引导步骤',
      afterSign.ok && skipped.flow.state.completed);
  skipped.close();

  // 写盘降级：源仍生效，但必须如实提示重启会丢失。
  saved.failWrites = true;
  final degradedFile = await box.text(
      'degraded.json', multi(<Object?>[cfg('src-file-d', origin)]));
  final degraded = await h.svc.importFromFile(degradedFile.path);
  check('写盘失败时文件导入仍生效', degraded.ok &&
      h.registry.ids.contains('src-file-d'));
  check('写盘失败被如实标记', !degraded.persisted &&
      degraded.message.contains('重启后需重新导入'));
  saved.failWrites = false;

  // 重启恢复：文件导入落盘的净化配置同样能被 restore 恢复。
  final restart = Harness(saved);
  final restored = await restart.svc.restore();
  check('文件导入的配置重启后可恢复',
      restored.kind == ImportOutcomeKind.restored && restored.ok);
  // 写盘降级那次只在内存生效：磁盘仍是上一次成功保存的 src-file-c，
  // 重启必须恢复到磁盘版本，不能把内存态的 src-file-d 悄悄复活。
  check('恢复的是最后一次成功落盘的配置，内存态新源不复活',
      restart.registry.ids.contains('src-file-c') &&
          !restart.registry.ids.contains('src-file-d'));
  check('恢复后画像与源注册表一致',
      restart.catalog.contains('src-file-c') &&
          !restart.catalog.contains('src-file-d') &&
          restart.svc.activeSourceIds.contains('src-file-c'));
  restart.close();
  h.close();
}

// ---------------------------------------------------------------------------
// D. 真实链路：文件 → 注册 → 真实 HTTP 搜索/取址 → 播放地址可达
// ---------------------------------------------------------------------------
Future<void> _liveChain(FileBox box, FixtureSite site) async {
  final saved = MemorySaved();
  final h = Harness(saved);
  await h.flow.acceptDisclaimer();
  final f = await box.text(
      'live.json', multi(<Object?>[cfg('src-live', site.origin)]));
  final outcome = await h.svc.importFromFile(f.path);
  check('指向真实样本站点的文件配置导入成功', outcome.ok && outcome.accepted == 1);

  final player = MockPlayerController();
  final orch = PlaybackOrchestrator(
    registry: h.registry,
    catalog: h.catalog,
    player: player,
    resumeStore: MemoryResumeStore(),
  );
  final hits = await orch.search('测试', SourcePlatform.desktop);
  check('文件导入的源在真实搜索中命中',
      hits.any((e) => e.sourceId == 'src-live'));
  final hit = hits.firstWhere((e) => e.sourceId == 'src-live');
  final session = await orch.startPlayback(
    sourceId: hit.sourceId,
    mediaId: hit.result.mediaId,
    mediaTitle: hit.result.title,
    canonicalEpisode: 1,
    canonicalSeconds: 650.0,
  );
  check('文件导入源走通对齐并真实载入播放器',
      session.contentSeconds == 650.0 &&
          (player.loadedUrl ?? '').startsWith(site.origin));
  check('播放地址真实可取回 m3u8', await mediaReachable(player.loadedUrl!));

  // 与粘贴链路的一致性：同一份文本两种入口得到同一批源。
  final saved2 = MemorySaved();
  final h2 = Harness(saved2);
  await h2.flow.acceptDisclaimer();
  final pasted = await h2.svc.importFromText(await f.readAsString());
  check('同一配置经粘贴与文件两条入口结果一致',
      pasted.ok &&
          pasted.sourceIds.length == outcome.sourceIds.length &&
          pasted.sourceIds.first == outcome.sourceIds.first);
  check('粘贴入口不带来源文件名', pasted.originLabel == null);
  h2.close();
  h.close();

  // UI「一键示例」写进文件也要能直接导入（防止示例与实际白名单脱节）。
  final saved3 = MemorySaved();
  final h3 = Harness(saved3);
  await h3.flow.acceptDisclaimer();
  final sampleText = sampleSourceConfigJson(baseUrl: site.origin);
  final sampleOk = validateSourceConfig(jsonDecode(sampleText)).ok;
  check('UI 示例配置通过 E9 白名单', sampleOk);
  final sampleFile = await box.text('sample.json', sampleText);
  final sampleResult = await h3.svc.importFromFile(sampleFile.path);
  check('UI 示例写入文件后可真实导入',
      sampleResult.ok && sampleResult.sourceIds.contains(kSampleSourceId));
  final orch3 = PlaybackOrchestrator(
    registry: h3.registry,
    catalog: h3.catalog,
    player: MockPlayerController(),
    resumeStore: MemoryResumeStore(),
  );
  final sampleHits = await orch3.search('测试', SourcePlatform.desktop);
  check('UI 示例文件导入后可真实搜索命中',
      sampleHits.any((e) => e.sourceId == kSampleSourceId));
  h3.close();
}

Future<void> main() async {
  final box = FileBox();
  await box.init();
  final site = FixtureSite('legacy');
  await site.start();
  try {
    _pathNormalize(box);
    await _readBoundaries(box);
    await _serviceCases(box, site.origin);
    await _liveChain(box, site);
  } finally {
    await site.close();
    await box.clean();
  }
  final total = _checkCount + _failCount;
  print('文件导入真实回归：$_checkCount/$total 断言通过');
  if (_failCount > 0) exitCode = 1;
}
