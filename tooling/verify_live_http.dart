// 真实 HTTP 端到端回归（E2 输入侧闭环）。
//
// 与 verify_logic.dart 的本质区别：这里 **不用 MockFetcher 注入响应**。
// 本机起真实 HttpServer，由 DartHttpFetcher 通过 socket 发 GET；三类站点结构的
// 搜索 → 剧集 → 取址 → 择优 → 对齐 → 播放载入全部走真实网络，最后把播放器
// 拿到的播放地址再真实 GET 一次，确认它是「真能取到内容」的地址。
//
// 同时覆盖只有真实网络才会暴露的边界：非 2xx、超时、超大响应、非 UTF-8、
// 重定向、运行期绝对地址越权（SSRF）、以及网络失败能否被翻译成 E7 可恢复失效。
//
// 运行：dart run tooling/verify_live_http.dart
import 'dart:convert';
import 'dart:io';

import 'package:shunbo/core/player/mock_player_controller.dart';
import 'package:shunbo/core/scheduler/playback_failure.dart';
import 'package:shunbo/core/scheduler/playback_orchestrator.dart';
import 'package:shunbo/core/scheduler/source_catalog.dart';
import 'package:shunbo/core/source/dart_backend.dart';
import 'package:shunbo/core/source/parsed_source_adapter.dart';
import 'package:shunbo/core/source/rule_source_parser.dart';
import 'package:shunbo/core/source/site_rule.dart';
import 'package:shunbo/core/source/source_adapter.dart';
import 'package:shunbo/core/source/source_fetcher.dart';
import 'package:shunbo/core/source/source_profile.dart';
import 'package:shunbo/core/source/source_registry.dart';
import 'package:shunbo/data/memory_resume_store.dart';
import 'fixture_site.dart';

int _checkCount = 0;
int _failCount = 0;

/// 收集式断言：一次跑完能看到全部缺口，而不是被第一个失败截断。
/// 末尾按失败数设置进程退出码，供 CI 门禁使用。
void check(String name, bool ok) {
  if (!ok) {
    _failCount++;
    print('FAIL: $name');
    return;
  }
  _checkCount++;
  print('PASS: $name');
}

/// 所有真实 fetcher 统一登记，收尾时关闭连接池，避免残留 socket 挂住进程。
final List<DartHttpFetcher> _openFetchers = <DartHttpFetcher>[];

DartHttpFetcher newFetcher(
  String origin, {
  Duration requestTimeout = const Duration(seconds: 8),
  int maxResponseBytes = 2 * 1024 * 1024,
}) {
  final f = DartHttpFetcher(
    origin,
    requestTimeout: requestTimeout,
    maxResponseBytes: maxResponseBytes,
    // 本地样本站点固定直连，避免机器上的系统代理把 localhost 请求改写成 502。
    useSystemProxy: false,
  );
  _openFetchers.add(f);
  return f;
}

/// 构造一条走真实 HTTP 的适配器 + 编排层。
({
  ParsedSourceAdapter adapter,
  PlaybackOrchestrator orchestrator,
  MockPlayerController player,
}) buildStack(String origin, SiteRule preset, String id) {
  final rule = SiteRule.fromJson(<String, dynamic>{
    ...preset.toJson(),
    'baseUrl': origin,
  });
  final adapter = ParsedSourceAdapter(
    id: id,
    profile: SourceProfile(name: id),
    parser: RuleSourceParser(rule),
    fetcher: newFetcher(origin),
    supportedPlatforms: const <SourcePlatform>{
      SourcePlatform.desktop,
      SourcePlatform.tv,
    },
  );
  final registry = SourceRegistry()..register(adapter);
  final catalog = SourceCatalog()..register(adapter.profile);
  final player = MockPlayerController();
  final orchestrator = PlaybackOrchestrator(
    registry: registry,
    catalog: catalog,
    player: player,
    resumeStore: MemoryResumeStore(),
  );
  return (adapter: adapter, orchestrator: orchestrator, player: player);
}

/// 播放地址必须是「真能取到内容」的地址，而不是只长得像 URL 的字符串。
Future<Probe> fetchMedia(String url) async {
  final client = HttpClient();
  try {
    return await probe(() async {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw HttpException('status ${resp.statusCode}', uri: Uri.parse(url));
      }
      return await resp.transform(utf8.decoder).join();
    });
  } finally {
    client.close();
  }
}

Future<void> _happyPath(String label, FixtureSite site, SiteRule preset) async {
  final rule = SiteRule.fromJson(<String, dynamic>{
    ...preset.toJson(),
    'baseUrl': site.origin,
  });
  check('$label 站点规则通过安全校验', validateSiteRule(rule).ok);

  final stack = buildStack(site.origin, preset, label);
  final hits = await stack.orchestrator.search('测试', SourcePlatform.desktop);
  check('$label 真实 GET 搜索命中', hits.isNotEmpty);
  final mediaId = hits.first.result.mediaId;

  final eps = await stack.adapter.getEpisodes(mediaId);
  check('$label 真实 GET 剧集去重升序',
      eps.length == 2 && eps[0].episode == 1 && eps[1].episode == 2);

  final urls = await stack.adapter.resolvePlayUrl(mediaId, 1);
  check('$label 真实 GET 播放地址择优',
      urls.isNotEmpty && urls.first.url.startsWith('http://127.0.0.1:'));

  final session = await stack.orchestrator.startPlayback(
    sourceId: label,
    mediaId: mediaId,
    mediaTitle: '真实链路测试',
    canonicalEpisode: 1,
    canonicalSeconds: 650.0,
  );
  check('$label 播放器载入的是真实择优地址',
      stack.player.loadedUrl == urls.first.url);
  check('$label 真实链路下内容坐标守恒', session.contentSeconds == 650.0);

  final media = await fetchMedia(stack.player.loadedUrl!);
  check('$label 播放地址真实可取且为 m3u8 内容',
      !media.threw && (media.value ?? '').contains('#EXTM3U'));
  check('$label 危险 scheme 被丢弃',
      urls.every((u) => !u.url.contains('javascript:') && !u.url.startsWith('file:')));
  check('$label 地址按清晰度降序且去重', () {
    final seen = <String>{};
    for (final u in urls) {
      if (!seen.add(u.url)) return false;
    }
    for (var i = 1; i < urls.length; i++) {
      if (urls[i - 1].qualityRank < urls[i].qualityRank) return false;
    }
    return true;
  }());
}

/// 把任意路径强行喂给 fetcher（fetchPlayPage 接受绝对/相对路径）。
Future<Probe> fetchFault(DartHttpFetcher f, String path) =>
    probe(() => f.fetchPlayPage('fault', path));

Future<void> _faultPaths(FixtureSite site, FixtureSite outside) async {
  // 用显式的小预算验证边界；生产默认值见 DartHttpFetcher 构造参数。
  final f = newFetcher(
    site.origin,
    requestTimeout: const Duration(milliseconds: 400),
    maxResponseBytes: 256 * 1024,
  );

  final p404 = await fetchFault(f, '/fault/404');
  check('非 2xx 不被当成正常页面（拒绝假成功）',
      p404.error is SourceFetchException &&
          (p404.error! as SourceFetchException).reason ==
              SourceFetchFailure.httpStatus);

  final pSlow = await fetchFault(f, '/fault/slow');
  check('慢响应在超时预算内失败',
      pSlow.error is SourceFetchException && pSlow.elapsedMs < 3000);

  final pBig = await fetchFault(f, '/fault/big');
  check('超大响应被拒绝（防内存放大）',
      pBig.error is SourceFetchException &&
          (pBig.error! as SourceFetchException).reason ==
              SourceFetchFailure.tooLarge);

  final pBad = await fetchFault(f, '/fault/badjson');
  check('坏 JSON 在取数层仍能取回文本（由解析层降级）',
      !pBad.threw && (pBad.value ?? '').contains('oops'));
  final jsonParser = RuleSourceParser(SiteRule.fromJson(<String, dynamic>{
    ...SiteRulePresets.jsonApi.toJson(),
    'baseUrl': site.origin,
  }));
  check('坏 JSON 解析降级为空集而非抛异常',
      (await jsonParser.parseSearch(pBad.value ?? '')).isEmpty);

  final pLatin = await fetchFault(f, '/fault/latin1');
  check('非 UTF-8 响应不使整条链路崩溃',
      !pLatin.threw && (pLatin.value ?? '').isNotEmpty);

  final pRedirect = await fetchFault(f, '/fault/redirect');
  check('同站重定向可跟随且结果正确',
      !pRedirect.threw && (pRedirect.value ?? '').contains('data-id'));

  final outsideBefore = outside.hitCount('/play/1');
  final evilDetail = await fetchFault(f, '/fault/evil-detail');
  check('越权详情页本身可取回', !evilDetail.threw);
  final evilParser = RuleSourceParser(SiteRule.fromJson(<String, dynamic>{
    ...SiteRulePresets.legacy.toJson(),
    'baseUrl': site.origin,
  }));
  final evilEps = await evilParser.parseEpisodes(evilDetail.value ?? '');
  check('解析层如实保留站点返回的跨源站路径',
      evilEps.isNotEmpty && evilEps.first.playPagePath.startsWith(outside.origin));
  final pOutside = await probe(() => f.fetchPlayPage('fault', evilEps.first.playPagePath));
  check('运行期绝对地址越权（跨 origin）被拒绝',
      pOutside.error is SourceFetchException &&
          (pOutside.error! as SourceFetchException).reason ==
              SourceFetchFailure.invalidUrl);
  check('未向越权主机发出任何请求', outside.hitCount('/play/1') == outsideBefore);

  final pDanger = await fetchFault(f, '/fault/danger');
  check('含危险 scheme 的播放页可取回', !pDanger.threw);
  final safeUrls = await evilParser.parsePlayUrls(pDanger.value ?? '');
  check('危险 scheme 地址被逐条隔离',
      safeUrls.length == 1 && safeUrls.first.url.contains('/media/720.m3u8'));
}

/// 网络失败必须被翻译成 E7 的一等失效，否则 UI 的
/// `on PlaybackFailureException` 抓不到，自动换源形同虚设。
Future<void> _failureMapping(FixtureSite goodSite) async {
  // 坏源：搜索正常，但取剧集/取址页真实返回 404。
  final broken = _BrokenFetcher(newFetcher(goodSite.origin));
  final badAdapter = ParsedSourceAdapter(
    id: 'bad',
    profile: const SourceProfile(name: 'bad'),
    parser: RuleSourceParser(SiteRule.fromJson(<String, dynamic>{
      ...SiteRulePresets.legacy.toJson(),
      'baseUrl': goodSite.origin,
    })),
    fetcher: broken,
    supportedPlatforms: const <SourcePlatform>{SourcePlatform.desktop},
  );
  final goodAdapter = buildStack(goodSite.origin, SiteRulePresets.legacy, 'good').adapter;
  final registry = SourceRegistry()
    ..register(badAdapter)
    ..register(goodAdapter);
  final catalog = SourceCatalog()
    ..register(badAdapter.profile)
    ..register(goodAdapter.profile);
  final orch = PlaybackOrchestrator(
    registry: registry,
    catalog: catalog,
    player: MockPlayerController(),
    resumeStore: MemoryResumeStore(),
  );

  Object? err;
  try {
    await orch.startPlayback(
      sourceId: 'bad',
      mediaId: 'm1',
      mediaTitle: '映射测试',
      canonicalEpisode: 1,
      canonicalSeconds: 100.0,
    );
  } catch (e) {
    err = e;
  }
  check('真实网络失败被翻译成可恢复失效',
      err is PlaybackFailureException && err.reason == PlaybackFailureReason.networkError);

  // 连接级失败（端口无人监听）同样不能裸奔到 UI。
  final deadAdapter = ParsedSourceAdapter(
    id: 'dead',
    profile: const SourceProfile(name: 'dead'),
    parser: RuleSourceParser(SiteRule.fromJson(<String, dynamic>{
      ...SiteRulePresets.legacy.toJson(),
      'baseUrl': 'http://127.0.0.1:1',
    })),
    fetcher: newFetcher('http://127.0.0.1:1'),
    supportedPlatforms: const <SourcePlatform>{SourcePlatform.desktop},
  );
  Object? deadErr;
  try {
    await deadAdapter.getEpisodes('m1');
  } catch (e) {
    deadErr = e;
  }
  check('连接级失败在适配器边界带上了 sourceId',
      deadErr is SourceAdapterException &&
          (deadErr.reason == SourceFetchFailure.connection ||
              deadErr.reason == SourceFetchFailure.timeout));

  final rawDead =
      await probe(() => newFetcher('http://127.0.0.1:1').fetchDetail('m1'));
  check('连接级失败在取数层归一为可识别异常',
      rawDead.error is SourceFetchException &&
          ((rawDead.error! as SourceFetchException).reason ==
                  SourceFetchFailure.connection ||
              (rawDead.error! as SourceFetchException).reason ==
                  SourceFetchFailure.timeout));
}

/// 只把「取址/详情」请求导向故障页，搜索仍走真实搜索页。
class _BrokenFetcher implements SourceFetcher {
  final DartHttpFetcher real;
  _BrokenFetcher(this.real);

  @override
  Future<String> fetchSearch(String keyword) => real.fetchSearch(keyword);

  @override
  Future<String> fetchDetail(String mediaId) =>
      real.fetchPlayPage(mediaId, '/fault/404');

  @override
  Future<String> fetchPlayPage(String mediaId, String playPagePath) =>
      real.fetchPlayPage(mediaId, '/fault/404');
}

Future<void> main() async {
  final legacy = FixtureSite('legacy');
  final vod = FixtureSite('vod');
  final jsonSite = FixtureSite('json');
  final outside = FixtureSite('outside');
  await Future.wait(<Future<void>>[
    legacy.start(),
    vod.start(),
    jsonSite.start(),
    outside.start(),
  ]);
  legacy.outsideOrigin = outside.origin;

  try {
    for (final group in <(String, Future<void> Function())>[
      ('legacy', () => _happyPath('legacy', legacy, SiteRulePresets.legacy)),
      ('vod-html', () => _happyPath('vod-html', vod, SiteRulePresets.vodHtml)),
      ('json-api', () => _happyPath('json-api', jsonSite, SiteRulePresets.jsonApi)),
      ('fault', () => _faultPaths(legacy, outside)),
      ('failure-mapping', () => _failureMapping(legacy)),
    ]) {
      try {
        await group.$2();
      } catch (e) {
        _failCount++;
        print('ERROR[${group.$1}]: $e');
      }
    }
  } finally {
    for (final f in _openFetchers) {
      f.close();
    }
    await Future.wait(<Future<void>>[
      legacy.close(),
      vod.close(),
      jsonSite.close(),
      outside.close(),
    ]);
  }
  final total = _checkCount + _failCount;
  print('真实 HTTP 端到端回归：$_checkCount/$total 断言通过');
  if (_failCount > 0) {
    print('未通过 $_failCount 项，退出码 1');
    exitCode = 1;
  }
}
