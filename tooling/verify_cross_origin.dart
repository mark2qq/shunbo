// 配置驱动的多主机（CDN）取数 + 源级优先级 · 真实 HTTP 回归。
//
// 真实站点几乎不会把所有页面放在同一个主机：搜索 API / 详情页 / 播放页常分属
// 不同域名。此前 `DartHttpFetcher` 虽有 allowedOrigins 参数，但加载器从不传，
// 运行期只认 baseUrl 自身；而配置里的 `qualityRank` 白名单放行却无人消费。
//
// 更关键的安全点：一旦允许跨主机，`Cookie` / `Authorization` / `X-Api-Key`
// 若随请求原样发出，站点被劫持后把取址页指向攻击者 origin 就会直接泄漏凭据。
//
// 三个独立端口的样本站点模拟「主站 / CDN / 未授权外部站」，全部走真实 socket。
// 运行：dart run tooling/verify_cross_origin.dart
import 'dart:convert';
import 'dart:io';

import 'package:shunbo/core/player/mock_player_controller.dart';
import 'package:shunbo/core/scheduler/playback_orchestrator.dart';
import 'package:shunbo/core/scheduler/source_catalog.dart';
import 'package:shunbo/core/source/dart_backend.dart';
import 'package:shunbo/core/source/site_rule.dart';
import 'package:shunbo/core/source/source_adapter.dart';
import 'package:shunbo/core/source/source_fetcher.dart';
import 'package:shunbo/core/source/source_registry.dart';
import 'package:shunbo/data/memory_resume_store.dart';
import 'package:shunbo/data/onboarding/onboarding_flow.dart';
import 'package:shunbo/data/onboarding/source_config_loader.dart';
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

Map<String, dynamic> cfg({
  required String id,
  required String baseUrl,
  List<String>? allowedOrigins,
  int? qualityRank,
  String playPath = 'detail/{mediaId}',
  Map<String, String> headers = const <String, String>{},
}) =>
    <String, dynamic>{
      'id': id,
      'name': '站点-$id',
      'baseUrl': baseUrl,
      'parser': 'regex',
      'searchPath': 'search?q={keyword}',
      'playPath': playPath,
      'platforms': const <String>['desktop', 'tv'],
      if (qualityRank != null) 'qualityRank': qualityRank,
      if (allowedOrigins != null) 'allowedOrigins': allowedOrigins,
      if (headers.isNotEmpty) 'headers': headers,
      'rules': <String, dynamic>{
        ...SiteRulePresets.legacy.toJson(),
        'baseUrl': baseUrl,
      },
    };

String multi(List<Object?> sources) =>
    jsonEncode(<String, dynamic>{'name': '多主机样本', 'version': 1, 'sources': sources});

const Map<String, String> sensitiveHeaders = <String, String>{
  'User-Agent': 'shunbo/1.0',
  'Cookie': 'session=SECRET',
  'Authorization': 'Bearer TOKEN',
  'X-Api-Key': 'KEY-123',
  'Referer': 'https://private.example/',
};

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
// A. 配置字段校验：allowedOrigins 按整个 origin 授权，不接受模糊匹配
// ---------------------------------------------------------------------------
void _validationCases() {
  const base = 'http://127.0.0.1:50001';
  const cdn = 'http://127.0.0.1:50002';

  check('合法 allowedOrigins 通过校验',
      validateSourceConfig(cfg(id: 'a', baseUrl: base,
          allowedOrigins: <String>[cdn])).ok);
  check('normalizeAllowedOrigins 归一化为 origin（去尾斜杠、保留端口）',
      normalizeAllowedOrigins(<String>['$cdn/'], baseUrl: base).origins
          .contains(cdn));

  for (final entry in <(String, Object)>[
    ('通配符', <String>['http://*.example.com']),
    ('携带路径', <String>['$cdn/play']),
    ('查询串', <String>['$cdn/?x=1']),
    ('userinfo', <String>['http://user:pass@127.0.0.1:50002']),
    ('非 http scheme', <String>['javascript:alert(1)']),
    ('含空白', <String>[' $cdn']),
    ('非数组', 'http://127.0.0.1:50002'),
  ]) {
    check('${entry.$1} 的 allowedOrigins 被拒绝',
        !validateSourceConfig(cfg(id: 'a', baseUrl: base)..['allowedOrigins'] = entry.$2).ok);
  }

  final tooMany = List<String>.generate(
      kMaxAllowedOrigins + 1, (i) => 'http://127.0.0.1:${51000 + i}');
  check('数量超过上限被拒绝',
      !validateSourceConfig(cfg(id: 'a', baseUrl: base,
          allowedOrigins: tooMany)).ok);

  check('https 主站授权 http 源站被拒绝（协议降级）',
      !validateSourceConfig(cfg(id: 'a', baseUrl: 'https://example.com',
          allowedOrigins: <String>['http://cdn.example.com'])).ok);
  check('https 主站授权 https 源站允许',
      validateSourceConfig(cfg(id: 'a', baseUrl: 'https://example.com',
          allowedOrigins: <String>['https://cdn.example.com'])).ok);

  for (final bad in <Object?>['high', -1, 101, 5.5]) {
    check('qualityRank=$bad 被拒绝',
        !validateSourceConfig(cfg(id: 'a', baseUrl: base)..['qualityRank'] = bad).ok);
  }
  check('qualityRank 0..100 整数通过',
      validateSourceConfig(cfg(id: 'a', baseUrl: base, qualityRank: 100)).ok);
}

// ---------------------------------------------------------------------------
// B. 真实跨主机链路：声明才放行，且凭据头不泄漏
// ---------------------------------------------------------------------------
Future<void> _crossOriginChain(
    FixtureSite primary, FixtureSite cdn, FixtureSite outside) async {
  // 未声明：运行期详情页给出的跨主机取址页必须被拒，且请求根本不发出。
  final narrowCfg = cfg(
    id: 'src-narrow',
    baseUrl: primary.origin,
    playPath: 'detail-cdn/{mediaId}',
  );
  final narrow = loadSourceConfig(narrowCfg);
  check('未声明跨主机时配置本身合法（失败发生在运行期）',
      narrow.accepted == 1 && narrow.rejected == 0);
  final reg1 = SourceRegistry();
  final cat1 = SourceCatalog();
  narrow.registerInto(reg1, cat1);
  final narrowAdapter = reg1.get('src-narrow')!;
  final narrowEps = await narrowAdapter.getEpisodes('m1');
  check('未声明时详情页仍可正常解析出剧集', narrowEps.length == 1);
  final before = cdn.hitCount('/play-abs');
  Object? err;
  try {
    await narrowAdapter.resolvePlayUrl('m1', 1);
  } catch (e) {
    err = e;
  }
  check('未声明 allowedOrigins 的跨主机取址被拒绝',
      err is SourceAdapterException &&
          err.reason == SourceFetchFailure.invalidUrl);
  check('被拒时未向跨主机发出任何请求', cdn.hitCount('/play-abs') == before);
  narrow.close();

  // 声明后：真实取到跨主机播放页 → 择优地址 → 播放器载入 → 真实 GET m3u8。
  final crossCfg = cfg(
    id: 'src-cross',
    baseUrl: primary.origin,
    playPath: 'detail-cdn/{mediaId}',
    allowedOrigins: <String>[cdn.origin],
    headers: sensitiveHeaders,
    qualityRank: 80,
  );
  final loaded = loadSourceConfig(crossCfg);
  check('声明 CDN 后配置通过校验', loaded.accepted == 1 && loaded.rejected == 0);
  check('配置里的源级优先级被消费',
      loaded.adapters.first.qualityRank == 80 &&
          loaded.sources.first.qualityRank == 80);
  final fetcher = loaded.adapters.first.fetcher;
  check('allowedOrigins 真的传进取数层（主站 + CDN，无外部站）',
      fetcher is DartHttpFetcher &&
          fetcher.allowedOrigins.contains(primary.origin) &&
          fetcher.allowedOrigins.contains(cdn.origin) &&
          !fetcher.allowedOrigins.contains(outside.origin));

  final reg = SourceRegistry();
  final cat = SourceCatalog();
  loaded.registerInto(reg, cat);
  final adapter = reg.get('src-cross')!;
  await adapter.search('测试');
  check('主站请求确实带上了凭据头（排除「配置没生效」的假通过）',
      primary.headersFor('/search')['cookie'] == 'session=SECRET' &&
          primary.headersFor('/search')['authorization'] == 'Bearer TOKEN' &&
          primary.headersFor('/search')['x-api-key'] == 'KEY-123');
  check('主站请求带上 Referer',
      primary.headersFor('/search')['referer'] == 'https://private.example/');

  final eps = await adapter.getEpisodes('m1');
  check('跨主机详情页真实解析出剧集', eps.length == 1);
  final urls = await adapter.resolvePlayUrl('m1', 1);
  check('跨主机取址页真实取回播放地址',
      urls.isNotEmpty && urls.first.url.startsWith(cdn.origin));
  check('跨主机播放地址按清晰度择优（1080 在前）',
      urls.first.url.contains('1080.m3u8'));
  check('跨主机播放地址真实可取回 m3u8', await mediaReachable(urls.first.url));

  final seen = cdn.headersFor('/play-abs');
  check('跨 origin 请求未携带 Cookie',
      seen['cookie'] == null || seen['cookie']!.isEmpty);
  check('跨 origin 请求未携带 Authorization',
      seen['authorization'] == null || seen['authorization']!.isEmpty);
  check('跨 origin 请求未携带自定义凭据头 X-Api-Key',
      seen['x-api-key'] == null || seen['x-api-key']!.isEmpty);
  check('跨 origin 请求未携带主站 Referer',
      seen['referer'] == null || seen['referer']!.isEmpty);
  check('跨 origin 请求仍带 User-Agent（安全头白名单生效）',
      seen['user-agent'] == 'shunbo/1.0');

  final player = MockPlayerController();
  final orch = PlaybackOrchestrator(
    registry: reg,
    catalog: cat,
    player: player,
    resumeStore: MemoryResumeStore(),
  );
  final session = await orch.startPlayback(
    sourceId: 'src-cross',
    mediaId: 'm1',
    mediaTitle: '跨主机测试',
    canonicalEpisode: 1,
    canonicalSeconds: 650.0,
  );
  check('编排层跨主机链路走通且内容坐标守恒', session.contentSeconds == 650.0);
  check('播放器载入的是 CDN 主机的地址',
      (player.loadedUrl ?? '').startsWith(cdn.origin));
  loaded.close();

  // 未列入白名单的第三台主机：即使站点响应给出了地址也必须拒绝。
  primary.outsideOrigin = outside.origin;
  final evilCfg = cfg(
    id: 'src-evil',
    baseUrl: primary.origin,
    playPath: 'fault/evil-detail?x={mediaId}',
    allowedOrigins: <String>[cdn.origin],
  );
  final evil = loadSourceConfig(evilCfg);
  check('只授权 CDN 的配置合法', evil.accepted == 1);
  final reg2 = SourceRegistry();
  final cat2 = SourceCatalog();
  evil.registerInto(reg2, cat2);
  await reg2.get('src-evil')!.getEpisodes('m1');
  final outsideBefore = outside.hitCount('/play/1');
  Object? evilErr;
  try {
    await reg2.get('src-evil')!.resolvePlayUrl('m1', 1);
  } catch (e) {
    evilErr = e;
  }
  check('运行期指向未授权主机被拒绝（授权列表不是摆设）',
      evilErr is SourceAdapterException &&
          evilErr.reason == SourceFetchFailure.invalidUrl);
  check('未向未授权主机发出任何请求',
      outside.hitCount('/play/1') == outsideBefore);
  evil.close();
}

// ---------------------------------------------------------------------------
// C. 重定向：每一跳独立过白名单，且跨跳剥离凭据
// ---------------------------------------------------------------------------
Future<void> _redirectCases(FixtureSite primary, FixtureSite cdn) async {
  primary.redirectOrigin = cdn.origin;
  final allowed = DartHttpFetcher(
    primary.origin,
    allowedOrigins: <String>{primary.origin, cdn.origin},
    headers: sensitiveHeaders,
    useSystemProxy: false,
  );
  final before = cdn.hitCount('/play-abs');
  final body = await allowed.fetchPlayPage('m1', 'fault/redirect-cross/m1');
  check('302 跳到已声明 CDN 时取数成功', body.contains('m3u8'));
  check('跨主机重定向确实请求了 CDN', cdn.hitCount('/play-abs') == before + 1);
  final seen = cdn.headersFor('/play-abs');
  check('重定向后的跨 origin 请求也已剥离凭据',
      seen['authorization'] == null && seen['cookie'] == null);
  allowed.close();

  final blocked = DartHttpFetcher(
    primary.origin,
    headers: sensitiveHeaders,
    useSystemProxy: false,
  );
  final before2 = cdn.hitCount('/play-abs');
  Object? err;
  try {
    await blocked.fetchPlayPage('m1', 'fault/redirect-cross/m1');
  } catch (e) {
    err = e;
  }
  check('未声明时跨主机重定向被拒绝（自动跟随不能绕过白名单）',
      err is SourceFetchException &&
          err.reason == SourceFetchFailure.invalidUrl);
  check('被拒重定向未向 CDN 发出请求', cdn.hitCount('/play-abs') == before2);
  blocked.close();

  final sameOrigin = DartHttpFetcher(primary.origin, useSystemProxy: false);
  final same = await sameOrigin.fetchPlayPage('m1', 'fault/redirect?q=x');
  check('同源相对重定向仍可用（加固不回退）', same.contains('data-id'));
  sameOrigin.close();
}

// ---------------------------------------------------------------------------
// D. 导入 → 净化落盘 → 重启恢复：allowedOrigins 不能重启就丢
// ---------------------------------------------------------------------------
Future<void> _importRestore(FixtureSite primary, FixtureSite cdn) async {
  String? saved;
  final reg1 = SourceRegistry();
  final cat1 = SourceCatalog();
  final flow1 = OnboardingFlow(
    initial: const OnboardingState(
        step: OnboardingStep.done, disclaimerAccepted: true),
  );
  final svc1 = SourceImportService(
    registry: reg1,
    catalog: cat1,
    flow: flow1,
    readSaved: () async => saved,
    writeSaved: (t) async => saved = t,
  );
  final text = multi(<Object?>[
    cfg(
      id: 'src-persist',
      baseUrl: primary.origin,
      playPath: 'detail-cdn/{mediaId}',
      allowedOrigins: <String>[cdn.origin],
      qualityRank: 60,
    ),
  ]);
  final imported = await svc1.importFromText(text);
  check('带 allowedOrigins 的配置可经引导服务导入', imported.ok);
  check('净化配置保留 allowedOrigins 与 qualityRank',
      saved != null &&
          saved!.contains('allowedOrigins') &&
          saved!.contains('qualityRank'));
  final stored = jsonDecode(saved!) as Map<String, dynamic>;
  final storedSource = (stored['sources'] as List).first as Map;
  check('净化配置里的白名单值未被篡改',
      (storedSource['allowedOrigins'] as List).contains(cdn.origin));
  svc1.close();

  // 模拟重启：全新注册表，只从磁盘恢复。
  final reg2 = SourceRegistry();
  final cat2 = SourceCatalog();
  final flow2 = OnboardingFlow(
    initial: const OnboardingState(
        step: OnboardingStep.done, disclaimerAccepted: true),
  );
  final svc2 = SourceImportService(
    registry: reg2,
    catalog: cat2,
    flow: flow2,
    readSaved: () async => saved,
    writeSaved: (t) async => saved = t,
  );
  final restored = await svc2.restore();
  check('重启恢复成功', restored.ok && restored.kind == ImportOutcomeKind.restored);
  final adapter = reg2.get('src-persist');
  check('恢复后适配器与画像都在', adapter != null && cat2.get('src-persist') != null);
  check('恢复后源级优先级仍在', adapter!.qualityRank == 60);
  await adapter.getEpisodes('m1');
  final urls = await adapter.resolvePlayUrl('m1', 1);
  check('重启后跨主机取址仍真实可用',
      urls.isNotEmpty && urls.first.url.startsWith(cdn.origin));
  check('重启后播放地址仍真实可取', await mediaReachable(urls.first.url));
  svc2.close();

  // 多源容器：坏 allowedOrigins 逐条隔离，不影响好源。
  final mixed = multi(<Object?>[
    cfg(id: 'src-good', baseUrl: primary.origin,
        allowedOrigins: <String>[cdn.origin]),
    cfg(id: 'src-bad', baseUrl: primary.origin,
        allowedOrigins: <String>['http://*.evil.example']),
  ]);
  final isolated = loadSourceConfigFromJson(mixed);
  check('坏 allowedOrigins 被逐条隔离',
      isolated.accepted == 1 && isolated.rejected == 1);
  check('隔离后净化配置只含好源',
      isolated.validatedConfig != null &&
          !jsonEncode(isolated.validatedConfig).contains('evil.example'));
  isolated.close();
}

// ---------------------------------------------------------------------------
// E. qualityRank：源级优先级排序必须稳定
// ---------------------------------------------------------------------------
Future<void> _qualityRankCases(
    FixtureSite a, FixtureSite b, FixtureSite c) async {
  final ranked = loadSourceConfigFromJson(multi(<Object?>[
    cfg(id: 'rank-low', baseUrl: a.origin, qualityRank: 0),
    cfg(id: 'rank-mid', baseUrl: b.origin, qualityRank: 50),
    cfg(id: 'rank-high', baseUrl: c.origin, qualityRank: 100),
  ]));
  check('三个源全部加载', ranked.accepted == 3);
  final reg = SourceRegistry();
  final cat = SourceCatalog();
  ranked.registerInto(reg, cat);
  final orch = PlaybackOrchestrator(
    registry: reg,
    catalog: cat,
    player: MockPlayerController(),
    resumeStore: MemoryResumeStore(),
  );
  final hits = await orch.search('测试', SourcePlatform.desktop);
  check('多源聚合命中数不变', hits.length == 6);
  check('命中按源级优先级降序',
      hits.map((h) => h.qualityRank).toList().join(',') == '100,100,50,50,0,0');
  check('最高优先级源排在最前', hits.first.sourceId == 'rank-high');
  check('SearchHit 带出 qualityRank 供 UI 展示', hits.first.qualityRank == 100);
  ranked.close();

  final plain = loadSourceConfigFromJson(multi(<Object?>[
    cfg(id: 'first', baseUrl: a.origin),
    cfg(id: 'second', baseUrl: b.origin),
    cfg(id: 'third', baseUrl: c.origin),
  ]));
  check('未配置 qualityRank 时默认 0',
      plain.adapters.every((e) => e.qualityRank == 0));
  final reg2 = SourceRegistry();
  final cat2 = SourceCatalog();
  plain.registerInto(reg2, cat2);
  final orch2 = PlaybackOrchestrator(
    registry: reg2,
    catalog: cat2,
    player: MockPlayerController(),
    resumeStore: MemoryResumeStore(),
  );
  final plainHits = await orch2.search('测试', SourcePlatform.desktop);
  check('相同 rank 保持注册顺序（稳定排序，无随机漂移）',
      plainHits.first.sourceId == 'first' &&
          plainHits[2].sourceId == 'second' &&
          plainHits[4].sourceId == 'third');
  plain.close();
}

Future<void> main() async {
  final primary = FixtureSite('legacy');
  final cdn = FixtureSite('legacy');
  final outside = FixtureSite('legacy');
  for (final s in <FixtureSite>[primary, cdn, outside]) {
    await s.start();
  }
  primary.cdnOrigin = cdn.origin;
  try {
    _validationCases();
    await _crossOriginChain(primary, cdn, outside);
    await _redirectCases(primary, cdn);
    await _importRestore(primary, cdn);
    await _qualityRankCases(primary, cdn, outside);
  } finally {
    await Future.wait(<Future<void>>[
      primary.close(),
      cdn.close(),
      outside.close(),
    ]);
  }
  final total = _checkCount + _failCount;
  print('跨主机取数 / 源级优先级回归：$_checkCount/$total 断言通过');
  if (_failCount > 0) exitCode = 1;
}
