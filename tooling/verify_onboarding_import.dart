// 源配置「导入 → 生效 → 落盘 → 重启恢复」端到端回归。
//
// 重点不是再测一遍正则解析，而是测编排层的**状态一致性**，这里最容易出
// 假成功：零可用源却推进引导、坏条被落盘后重启复活、外部配置用同名 id
// 顶掉内置源画像、重复导入留下孤儿源、失败导入破坏已有配置。
//
// 取数全部走真实本地 HTTP 服务（FixtureSite），不是 MockFetcher。
// 运行：dart run tooling/verify_onboarding_import.dart
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

/// 模拟持久层：保存净化配置文本 + 引导状态，可注入写失败。
class MemorySaved {
  String? text;
  Map<String, dynamic>? onboarding;
  bool failWrites = false;
  int writes = 0;
}

/// 一次「启动」：全新注册表 / 编排层，但从同一份磁盘状态回读。
class Harness {
  final SourceRegistry registry = SourceRegistry();
  final SourceCatalog catalog = SourceCatalog();
  final MemorySaved saved;
  late final OnboardingFlow flow;
  late final SourceImportService svc;

  Harness(this.saved) {
    // 内置源：外部配置不得用同名 id 覆盖它（会篡改换源决策画像）。
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
      persist: (s) async {
        saved.onboarding = Map<String, dynamic>.from(s);
      },
    );
    svc = SourceImportService(
      registry: registry,
      catalog: catalog,
      flow: flow,
      readSaved: () async => saved.text,
      writeSaved: (t) async {
        if (failWrites) throw StateError('simulated disk full');
        saved.text = t;
        saved.writes++;
      },
    );
  }

  bool get failWrites => saved.failWrites;
  set failWrites(bool v) => saved.failWrites = v;

  void close() => svc.close();
}

Map<String, dynamic> cfg(String id, String baseUrl, SiteRule preset) =>
    <String, dynamic>{
      'id': id,
      'name': '站点-$id',
      'baseUrl': baseUrl,
      'parser': 'regex',
      'searchPath': 'search?q={keyword}',
      'playPath': 'detail/{mediaId}',
      'platforms': const <String>['desktop', 'tv'],
      'rules': <String, dynamic>{
        ...preset.toJson(),
        'baseUrl': baseUrl,
      },
    };

String multi(List<Object?> sources, {String name = '本地样本'}) =>
    jsonEncode(<String, dynamic>{
      'name': name,
      'version': 1,
      'sources': sources,
    });

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
// A. 安全门禁
// ---------------------------------------------------------------------------
Future<void> _gates(FixtureSite site) async {
  final saved = MemorySaved();
  final h = Harness(saved);
  final good = multi(<Object?>[cfg('src-a', site.origin, SiteRulePresets.legacy)]);

  final before = await h.svc.importFromText(good);
  check('未接受免责声明时导入被拒绝',
      before.kind == ImportOutcomeKind.blockedByDisclaimer && !before.ok);
  check('被拒导入没有注册任何源', h.registry.ids.length == 1);
  check('被拒导入没有落盘', saved.text == null && saved.writes == 0);
  check('被拒导入没有推进引导',
      h.flow.state.step == OnboardingStep.welcome && saved.onboarding == null);

  await h.flow.acceptDisclaimer();
  check('接受免责声明后进入导入步骤',
      h.flow.state.step == OnboardingStep.sourceImport &&
          h.flow.state.disclaimerAccepted);

  check('空文本被拒绝',
      (await h.svc.importFromText('   ')).kind == ImportOutcomeKind.rejected);
  check('超长文本被拒绝',
      (await h.svc.importFromText(
              List.filled(kMaxImportTextLength + 1, 'a').join()))
          .kind ==
          ImportOutcomeKind.rejected);
  check('坏 JSON 被拒绝且不影响引导步骤',
      (await h.svc.importFromText('{not json')).kind ==
              ImportOutcomeKind.rejected &&
          h.flow.state.step == OnboardingStep.sourceImport);

  final evil = <String, dynamic>{
    ...cfg('evil', site.origin, SiteRulePresets.legacy),
    'script': 'https://evil.example/x.js',
  };
  final evilResult = await h.svc.importFromText(multi(<Object?>[evil]));
  check('带代码加载字段的配置被拒绝',
      evilResult.kind == ImportOutcomeKind.rejected &&
          evilResult.rejections.isNotEmpty);
  check('危险配置未注册 / 未落盘 / 未推进',
      h.registry.ids.length == 1 &&
          saved.text == null &&
          h.flow.state.step == OnboardingStep.sourceImport);

  final qjs = <String, dynamic>{
    ...cfg('qjs', site.origin, SiteRulePresets.legacy),
    'parser': 'quickjs',
  };
  check('未授权的 QuickJS 后端被拒绝',
      (await h.svc.importFromText(multi(<Object?>[qjs]))).kind ==
          ImportOutcomeKind.rejected);
  check('拒绝原因可读（供 UI 展示）',
      (h.svc.lastOutcome!.message).contains('导入失败'));

  // 跳过引导不能成为绕过免责声明的捷径。
  final saved2 = MemorySaved();
  final h2 = Harness(saved2);
  await h2.flow.skipAll();
  check('跳过引导后状态为 completed 但未接受免责',
      h2.flow.state.completed && !h2.flow.state.disclaimerAccepted);
  check('跳过引导的用户导入被拒绝',
      (await h2.svc.importFromText(good)).kind ==
          ImportOutcomeKind.blockedByDisclaimer);
  await h2.flow.acceptDisclaimerLater();
  final late = await h2.svc.importFromText(good);
  check('补签免责声明后可以导入，且不回退引导步骤',
      late.ok && h2.flow.state.completed && h2.flow.state.importCount == 1);

  h.close();
  h2.close();
}

// ---------------------------------------------------------------------------
// B. 状态一致性：坏条隔离 / 零源不推进 / id 冲突 / 重复导入 / 写失败
// ---------------------------------------------------------------------------
Future<void> _stateConsistency(FixtureSite a, FixtureSite b) async {
  final saved = MemorySaved();
  final h = Harness(saved);
  await h.flow.acceptDisclaimer();

  final bad = <String, dynamic>{
    ...cfg('bad', a.origin, SiteRulePresets.legacy),
    'eval': 'process()',
  };
  final disabled = cfg('disabled', a.origin, SiteRulePresets.legacy);
  disabled['enabled'] = false;
  final text = multi(<Object?>[
    cfg('src-a', a.origin, SiteRulePresets.legacy),
    bad,
    disabled,
  ]);

  final r = await h.svc.importFromText(text);
  check('部分坏条时好源仍导入成功', r.ok && r.accepted == 1);
  check('坏条被逐条隔离并带索引/原因',
      r.rejections.length == 1 && r.rejections.first.index == 1);
  check('禁用的源既不加载也不算拒绝',
      r.rejections.every((e) => !e.id.contains('disabled')));
  check('引导推进到平台确认且记录导入次数',
      h.flow.state.step == OnboardingStep.platformConfirm &&
          h.flow.state.sourceImported &&
          h.flow.state.importCount == 1);
  check('落盘的是净化配置（坏条不会重启复活）',
      saved.text != null &&
          !saved.text!.contains('eval') &&
          !saved.text!.contains('disabled'));
  final stored = jsonDecode(saved.text!) as Map<String, dynamic>;
  check('净化配置只含被接受的 1 个源',
      (stored['sources'] as List).length == 1 &&
          (stored['sources'] as List).first['id'] == 'src-a');
  check('服务可回填当前配置文本供编辑', h.svc.currentConfigText == saved.text);

  // 同名 id 会顶掉内置源画像，必须整条拒绝；且失败导入不能破坏已有配置。
  final collide = await h.svc.importFromText(
      multi(<Object?>[cfg('builtin', a.origin, SiteRulePresets.legacy)]));
  check('与内置源同 id 的配置被拒绝',
      collide.kind == ImportOutcomeKind.rejected &&
          collide.rejections.any((e) => e.toString().contains('冲突')));
  check('内置源画像未被外部配置篡改',
      h.registry.get('builtin') is MemorySourceAdapter &&
          h.catalog.get('builtin')?.episodeOffset == 0);
  check('失败导入不破坏已生效的源',
      h.svc.hasImportedSources &&
          h.registry.ids.contains('src-a') &&
          saved.text!.contains('src-a'));

  // 重新导入（此时引导停在 platformConfirm，不应被「步骤不正确」挡住）。
  final replaced = await h.svc.importFromText(
      multi(<Object?>[cfg('src-b', b.origin, SiteRulePresets.vodHtml)]));
  check('引导中途也能重新导入配置', replaced.ok && replaced.accepted == 1);
  check('重复导入注销了旧源，无孤儿',
      !h.registry.ids.contains('src-a') &&
          !h.catalog.names.contains('src-a') &&
          h.svc.activeSourceIds.length == 1);
  check('重复导入注册了新源与画像',
      h.registry.ids.contains('src-b') && h.catalog.get('src-b') != null);
  check('重新导入累计次数且步骤不回退',
      h.flow.state.importCount == 2 &&
          h.flow.state.step == OnboardingStep.platformConfirm);
  check('落盘已替换为新配置',
      saved.text!.contains('src-b') && !saved.text!.contains('src-a'));

  // 写失败：源仍可用，但必须如实告知重启会丢失。
  h.failWrites = true;
  final writeFail = await h.svc.importFromText(
      multi(<Object?>[cfg('src-c', a.origin, SiteRulePresets.legacy)]));
  check('写盘失败时源仍然生效', writeFail.ok && h.registry.ids.contains('src-c'));
  check('写盘失败被如实标记在结果与文案中',
      !writeFail.persisted && writeFail.message.contains('保存失败'));
  h.failWrites = false;

  h.close();
  check('close 注销外部源并保留内置源',
      !h.registry.ids.contains('src-c') &&
          h.registry.ids.contains('builtin') &&
          !h.svc.hasImportedSources);
}

// ---------------------------------------------------------------------------
// C. 真实链路：导入后立刻能搜到、能取址、能播放
// ---------------------------------------------------------------------------
Future<void> _liveChain(FixtureSite site, MemorySaved saved, Harness h) async {
  final player = MockPlayerController();
  final orch = PlaybackOrchestrator(
    registry: h.registry,
    catalog: h.catalog,
    player: player,
    resumeStore: MemoryResumeStore(),
  );
  final hits = await orch.search('测试', SourcePlatform.desktop);
  check('导入的源在真实搜索中命中', hits.any((e) => e.sourceId == 'src-live'));
  final hit = hits.firstWhere((e) => e.sourceId == 'src-live');
  final session = await orch.startPlayback(
    sourceId: hit.sourceId,
    mediaId: hit.result.mediaId,
    mediaTitle: hit.result.title,
    canonicalEpisode: 1,
    canonicalSeconds: 650.0,
  );
  check('导入源走通对齐并载入播放器',
      session.contentSeconds == 650.0 &&
          (player.loadedUrl ?? '').startsWith(site.origin));
  check('播放地址真实可取回 m3u8', await mediaReachable(player.loadedUrl!));
  check('导入配置落盘且引导状态已持久化',
      saved.text != null && saved.onboarding != null);
}

// ---------------------------------------------------------------------------
// D. 重启恢复与磁盘防护
// ---------------------------------------------------------------------------
Future<void> _restoreCases(FixtureSite site) async {
  final saved = MemorySaved();
  final h1 = Harness(saved);
  await h1.flow.acceptDisclaimer();
  final first = await h1.svc.importFromText(
      multi(<Object?>[cfg('src-live', site.origin, SiteRulePresets.legacy)]));
  check('导入成功并持久化', first.ok && first.persisted && saved.writes == 1);
  await _liveChain(site, saved, h1);
  await h1.flow.confirmPlatform('desktop');
  check('引导完成后状态已落盘', saved.onboarding!['step'] == 'done');
  h1.close();

  // 模拟重启：同一份磁盘、全新的注册表与引导实例。
  final h2 = Harness(saved);
  check('重启后引导不需要重来', h2.flow.state.completed);
  final restored = await h2.svc.restore();
  check('重启恢复成功', restored.kind == ImportOutcomeKind.restored && restored.ok);
  check('恢复后画像与适配器都在',
      h2.registry.ids.contains('src-live') &&
          h2.catalog.get('src-live') != null &&
          h2.svc.activeSourceIds.length == 1);
  check('恢复不重复写盘、不推进引导',
      saved.writes == 1 && h2.flow.state.importCount == 1);
  await _liveChain(site, saved, h2);
  h2.close();

  // 磁盘有配置但免责声明未接受：保留文本，不加载。
  final saved3 = MemorySaved()
    ..text = multi(<Object?>[cfg('src-x', site.origin, SiteRulePresets.legacy)])
    ..onboarding = const OnboardingState().toJson();
  final h3 = Harness(saved3);
  final blocked = await h3.svc.restore();
  check('未接受免责声明时拒绝从磁盘加载',
      blocked.kind == ImportOutcomeKind.blockedByDisclaimer && !blocked.ok);
  check('被拒恢复保留磁盘文本且不注册源',
      saved3.text != null && !h3.registry.ids.contains('src-x'));

  // 损坏 / 超长 / 冲突的磁盘内容一律按「不注册」处理。
  for (final entry in <(String, String)>[
    ('损坏配置', '{broken'),
    ('超长配置', List.filled(kMaxImportTextLength + 1, 'x').join()),
    (
      '撞内置源的配置',
      multi(<Object?>[cfg('builtin', site.origin, SiteRulePresets.legacy)])
    ),
  ]) {
    final s = MemorySaved()
      ..text = entry.$2
      ..onboarding = const OnboardingState(
        step: OnboardingStep.done,
        disclaimerAccepted: true,
      ).toJson();
    final hh = Harness(s);
    final out = await hh.svc.restore();
    check('${entry.$1}：恢复被拒绝且不注册外部源',
        out.kind == ImportOutcomeKind.rejected &&
            !hh.svc.hasImportedSources);
    hh.close();
  }

  // 空磁盘不是错误。
  final h4 = Harness(MemorySaved());
  check('无保存配置时恢复为 nothingToRestore',
      (await h4.svc.restore()).kind == ImportOutcomeKind.nothingToRestore);
  h4.close();
}

// ---------------------------------------------------------------------------
// E. UI「填入本地示例」按钮产出的配置，必须真的能导入并播起来
// ---------------------------------------------------------------------------
Future<void> _sampleConfigChain(FixtureSite site) async {
  final text = sampleSourceConfigJson(baseUrl: site.origin, ruleName: 'legacy');
  check('UI 示例配置通过 E9 白名单整体验证',
      validateSourceConfig(jsonDecode(text)).ok);
  final fallback = sampleSourceConfig();
  final first = (fallback['sources'] as List).first as Map;
  check('未指定地址时示例指向演示服务默认端口',
      first['baseUrl'] == 'http://127.0.0.1:$kDefaultFixturePort');

  final saved = MemorySaved();
  final h = Harness(saved);
  await h.flow.acceptDisclaimer();
  final imported = await h.svc.importFromText(text);
  check('UI 一键示例可真实导入且无拒绝项',
      imported.ok && imported.accepted == 1 && imported.rejections.isEmpty);
  check('示例源已注册进业务能力层',
      h.svc.activeSourceIds.contains(kSampleSourceId) &&
          h.catalog.get(kSampleSourceId) != null);

  final player = MockPlayerController();
  final orch = PlaybackOrchestrator(
    registry: h.registry,
    catalog: h.catalog,
    player: player,
    resumeStore: MemoryResumeStore(),
  );
  final hits = await orch.search('测试', SourcePlatform.desktop);
  check('示例源在真实搜索中命中',
      hits.any((e) => e.sourceId == kSampleSourceId));
  final hit = hits.firstWhere((e) => e.sourceId == kSampleSourceId);
  final session = await orch.startPlayback(
    sourceId: hit.sourceId,
    mediaId: hit.result.mediaId,
    mediaTitle: hit.result.title,
    canonicalEpisode: 1,
    canonicalSeconds: 650.0,
  );
  check('示例源走通对齐与载入',
      session.contentSeconds == 650.0 &&
          (player.loadedUrl ?? '').startsWith(site.origin));
  check('示例源播放地址真实可取回 m3u8', await mediaReachable(player.loadedUrl!));
  h.close();
}

Future<void> main() async {
  final legacy = FixtureSite('legacy');
  final vod = FixtureSite('vod-html');
  await legacy.start();
  await vod.start();
  try {
    await _gates(legacy);
    await _stateConsistency(legacy, vod);
    await _restoreCases(legacy);
    await _sampleConfigChain(legacy);
  } finally {
    await Future.wait(<Future<void>>[legacy.close(), vod.close()]);
  }
  final total = _checkCount + _failCount;
  print('引导导入全流程回归：$_checkCount/$total 断言通过');
  if (_failCount > 0) exitCode = 1;
}
