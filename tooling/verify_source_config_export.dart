// 源配置「导出 / 备份」端到端回归。
//
// 导出的价值不在「写个文件」本身，而在两件事必须成立：
// 1. **不覆盖用户已有文件**（默认拒绝，覆盖时先备份再换名，失败回滚）；
// 2. **导出 → 导入往返一致** —— 备份出来的配置必须能被自己重新导入并真实可播，
//    否则这就是一份看着像备份、恢复时才炸的假产物。
//
// 文件是真实临时文件，链路末尾走真实本地 HTTP（FixtureSite）。
// 运行：dart run tooling/verify_source_config_export.dart
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
import 'package:shunbo/data/onboarding/source_config_file.dart';
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

class MemorySaved {
  String? text;
  Map<String, dynamic>? onboarding;
  bool failWrites = false;
  int writes = 0;
}

class Harness {
  final SourceRegistry registry = SourceRegistry();
  final SourceCatalog catalog = SourceCatalog();
  final MemorySaved saved;
  late final OnboardingFlow flow;
  late final SourceImportService svc;

  int fileWrites = 0;

  Harness(this.saved, {SourceConfigFileWriter? writer}) {
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
      writeFile: (path, text, {bool overwrite = false}) async {
        fileWrites++;
        return writer != null
            ? writer(path, text, overwrite: overwrite)
            : writeSourceConfigFile(path, text, overwrite: overwrite);
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
      'name': '导出样本',
      'version': 1,
      'sources': sources,
    });

class FileBox {
  late final Directory dir;

  Future<void> init() async {
    dir = await Directory.systemTemp.createTemp('shunbo-file-export-');
  }

  String path(String name) => '${dir.path}/$name';

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
// A. 写入边界（直接调用写模块）
// ---------------------------------------------------------------------------
Future<void> _writeBoundaries(FileBox box) async {
  final body = multi(<Object?>[cfg('src-x', 'http://127.0.0.1:1')]);
  final target = box.path('export.json');

  final first = await writeSourceConfigFile(target, body);
  check('导出到新文件成功', first.ok);
  check('返回真实写入字节数',
      first.bytes == utf8.encode(body).length && first.fileName == 'export.json');
  check('文件内容与输入完全一致', await File(target).readAsString() == body);
  check('导出文件可直接 jsonDecode',
      jsonDecode(await File(target).readAsString()) is Map);

  final before = await File(target).readAsString();
  final blocked = await writeSourceConfigFile(target, '{"sources":[]}');
  check('默认不覆盖已有文件', !blocked.ok &&
      blocked.failure == SourceConfigFileWriteFailure.alreadyExists);
  check('被拒覆盖时原文件未被改动', await File(target).readAsString() == before);

  final over = await writeSourceConfigFile(target, body, overwrite: true);
  check('显式授权后可覆盖', over.ok);
  check('覆盖后内容已替换', await File(target).readAsString() == body);
  check('覆盖后无临时/备份文件残留',
      !await File('$target.shunbo-tmp').exists() &&
          !await File('$target.shunbo-bak').exists());

  // 覆盖成更短内容：不能残留旧文件尾巴。
  final short = '{"name":"s","version":1,"sources":[]}';
  final shortWrite = await writeSourceConfigFile(target, short, overwrite: true);
  check('覆盖为更短内容后无旧内容残留',
      shortWrite.ok && await File(target).readAsString() == short);

  final dirFail = await writeSourceConfigFile(box.dir.path, body);
  check('目标为目录被拒绝',
      dirFail.failure == SourceConfigFileWriteFailure.notAFile);

  final missingParent =
      await writeSourceConfigFile('${box.dir.path}/no-such-dir/a.json', body);
  check('父目录不存在被拒绝且不自动创建',
      missingParent.failure == SourceConfigFileWriteFailure.parentMissing &&
          !await Directory('${box.dir.path}/no-such-dir').exists());

  check('空路径被拒绝',
      (await writeSourceConfigFile('  ', body)).failure ==
          SourceConfigFileWriteFailure.emptyPath);
  check('远程 file://host 被拒绝',
      (await writeSourceConfigFile('file://evil.example/share/a.json', body))
              .failure ==
          SourceConfigFileWriteFailure.remotePath);
  check('UNC 网络路径被拒绝',
      (await writeSourceConfigFile(r'\\evil.example\share\a.json', body))
              .failure ==
          SourceConfigFileWriteFailure.remotePath);
  check('超长路径被拒绝',
      (await writeSourceConfigFile('C:/${'a' * 9000}.json', body)).failure ==
          SourceConfigFileWriteFailure.tooLongPath);
  check('空内容被拒绝',
      (await writeSourceConfigFile(box.path('empty.json'), '   ')).failure ==
          SourceConfigFileWriteFailure.noContent);
  check('超过体积上限被拒绝',
      (await writeSourceConfigFile(box.path('big.json'), body, maxBytes: 8))
              .failure ==
          SourceConfigFileWriteFailure.tooLarge);

  // 路径形态：带引号、file:// URI 都要落到同一个真实文件。
  final quotedTarget = box.path('quoted.json');
  final quoted = await writeSourceConfigFile('"$quotedTarget"', body);
  check('带引号路径可真实写入',
      quoted.ok && await File(quotedTarget).exists());
  final uriTarget = box.path('uri.json');
  final viaUri =
      await writeSourceConfigFile(Uri.file(uriTarget).toString(), body);
  check('file:// URI 可真实写入',
      viaUri.ok && await File(uriTarget).readAsString() == body);

  // 符号链接：拒绝写入链接（否则会写到链接目标，绕过用户的路径预期）。
  Link? link;
  try {
    link = Link(box.path('link.json'));
    await link.create(target);
  } catch (_) {
    link = null;
  }
  if (link != null) {
    final linkWrite = await writeSourceConfigFile(link.path, body);
    check('符号链接目标被拒绝写入',
        linkWrite.failure == SourceConfigFileWriteFailure.symlink);
  } else {
    check('平台不允许创建符号链接，改由目录用例覆盖类型拒绝',
        (await writeSourceConfigFile(box.dir.path, body)).failure ==
            SourceConfigFileWriteFailure.notAFile);
  }
}

// ---------------------------------------------------------------------------
// B. 服务层导出
// ---------------------------------------------------------------------------
Future<void> _serviceExport(FileBox box, String origin) async {
  final saved = MemorySaved();
  final h = Harness(saved);

  final noSource = await h.svc.exportToFile(box.path('none.json'));
  check('没有生效配置时导出返回明确原因',
      noSource.failure == SourceConfigFileWriteFailure.noContent &&
          noSource.message.contains('没有可导出'));
  check('没有生效配置时不会产生空文件',
      !await File(box.path('none.json')).exists());
  check('没有生效配置时不触发写入 IO', h.fileWrites == 0);

  await h.flow.acceptDisclaimer();
  final imported = await h.svc.importFromText(
      multi(<Object?>[cfg('src-export', origin)]));
  check('导入成功', imported.ok && imported.accepted == 1);

  final out = box.path('backup.json');
  final exported = await h.svc.exportToFile(out);
  check('导入后可导出', exported.ok && await File(out).exists());
  check('导出内容等于当前生效配置',
      await File(out).readAsString() == h.svc.currentConfigText);
  check('导出内容是净化配置（无 BOM、可解析）',
      !(await File(out).readAsString()).startsWith('\uFEFF') &&
          jsonDecode(await File(out).readAsString()) is Map);
  check('导出后生效配置文本未被改动',
      h.svc.currentConfigText != null &&
          (jsonDecode(h.svc.currentConfigText!)['sources'] as List).length == 1);

  final second = await h.svc.exportToFile(out);
  check('重复导出同一路径默认被拒（不静默覆盖备份）',
      !second.ok && second.failure == SourceConfigFileWriteFailure.alreadyExists);
  final secondOver = await h.svc.exportToFile(out, overwrite: true);
  check('允许覆盖后可重复导出', secondOver.ok);

  // 坏条隔离：导出内容只含被接受的源。
  final mixedImport = await h.svc.importFromText(multi(<Object?>[
    <String, dynamic>{
      'id': 'evil',
      'baseUrl': origin,
      'script': 'doBadThings()',
    },
    cfg('src-export-2', origin),
  ]));
  check('含坏条的配置导入成功且坏条被隔离',
      mixedImport.ok && mixedImport.accepted == 1);
  final purified = box.path('purified.json');
  await h.svc.exportToFile(purified);
  final purifiedText = await File(purified).readAsString();
  check('导出的是净化配置，坏条不进入备份',
      !purifiedText.contains('doBadThings') &&
          (jsonDecode(purifiedText)['sources'] as List).length == 1);

  // 写入器抛异常：服务必须收敛为 writeError。
  final throwing = Harness(MemorySaved(),
      writer: (p, t, {bool overwrite = false}) async =>
          throw const FileSystemException('disk ejected'));
  await throwing.flow.acceptDisclaimer();
  await throwing.svc.importFromText(multi(<Object?>[cfg('src-throw', origin)]));
  final thrown = await throwing.svc.exportToFile(box.path('throw.json'));
  check('写入器异常被收敛为 writeError',
      thrown.failure == SourceConfigFileWriteFailure.writeError &&
          thrown.message.contains('异常'));
  throwing.close();

  h.close();
}

// ---------------------------------------------------------------------------
// C. 导出 → 导入往返（含真实 HTTP 链路）
// ---------------------------------------------------------------------------
Future<void> _roundTrip(FileBox box, FixtureSite site) async {
  final saved = MemorySaved();
  final h = Harness(saved);
  await h.flow.acceptDisclaimer();
  final imported = await h.svc.importFromText(multi(<Object?>[
    <String, dynamic>{
      ...cfg('src-trip', site.origin),
      'qualityRank': 80,
    },
  ]));
  check('往返用例：源导入成功', imported.ok && imported.accepted == 1);

  final backup = box.path('trip.json');
  final exported = await h.svc.exportToFile(backup);
  check('往返用例：导出成功', exported.ok);

  // 读回：走与 UI「从文件导入」相同的读取器。
  final readBack = await readSourceConfigFile(backup);
  check('导出的文件可被读取器读回', readBack.ok);
  check('读回文本与导出内容一致', readBack.text == await File(backup).readAsString());

  // 另一台「设备」：全新注册表，从备份文件恢复。
  final saved2 = MemorySaved();
  final h2 = Harness(saved2);
  await h2.flow.acceptDisclaimer();
  final restored = await h2.svc.importFromFile(backup);
  check('备份文件可在全新环境导入成功', restored.ok && restored.accepted == 1);
  check('往返后源 id 一致', restored.sourceIds.contains('src-trip'));
  check('往返保留 qualityRank 等配置字段',
      h2.svc.currentConfigText != null &&
          (jsonDecode(h2.svc.currentConfigText!)['sources'] as List)
              .any((s) => (s as Map)['qualityRank'] == 80));

  // 真实链路：备份恢复后的源必须真能搜到并播出来。
  final player = MockPlayerController();
  final orch = PlaybackOrchestrator(
    registry: h2.registry,
    catalog: h2.catalog,
    player: player,
    resumeStore: MemoryResumeStore(),
  );
  final hits = await orch.search('测试', SourcePlatform.desktop);
  check('备份恢复的源在真实搜索中命中',
      hits.any((e) => e.sourceId == 'src-trip'));
  final hit = hits.firstWhere((e) => e.sourceId == 'src-trip');
  final session = await orch.startPlayback(
    sourceId: hit.sourceId,
    mediaId: hit.result.mediaId,
    mediaTitle: hit.result.title,
    canonicalEpisode: 1,
    canonicalSeconds: 650.0,
  );
  check('备份恢复的源走通对齐并载入播放器',
      session.contentSeconds == 650.0 &&
          (player.loadedUrl ?? '').startsWith(site.origin));
  check('备份恢复的播放地址真实可取回 m3u8',
      await mediaReachable(player.loadedUrl!));

  // 重启恢复后仍可再次导出（备份能力不依赖本次会话的导入动作）。
  final h3 = Harness(saved2);
  final restoredOnBoot = await h3.svc.restore();
  check('重启后可恢复上次导出所对应的配置',
      restoredOnBoot.ok && restoredOnBoot.kind == ImportOutcomeKind.restored);
  final again = await h3.svc.exportToFile(box.path('again.json'));
  check('重启恢复后仍可再次导出备份', again.ok);
  h3.close();
  h2.close();
  h.close();
}

Future<void> main() async {
  final box = FileBox();
  await box.init();
  final site = FixtureSite('legacy');
  await site.start();
  try {
    await _writeBoundaries(box);
    await _serviceExport(box, site.origin);
    await _roundTrip(box, site);
  } finally {
    await site.close();
    await box.clean();
  }
  final total = _checkCount + _failCount;
  print('配置文件导出真实回归：$_checkCount/$total 断言通过');
  if (_failCount > 0) exitCode = 1;
}
