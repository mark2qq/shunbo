// 配置驱动的多源聚合 · 真实 HTTP 回归。
//
// 验证 E9 白名单里定义了很久、但此前没有消费方的字段（headers / searchPath /
// playPath / platforms / episodeOffset / adInterval / adDuration），现在能被
// `SourceConfigLoader` 真正转成可运行的多源适配器，并走真实网络完成
// 「搜索聚合 → 选源 → 取址 → 对齐 → 播放」与「单源故障 → 自动换源」。
//
// 运行：dart run tooling/verify_source_config.dart
import 'dart:convert';
import 'dart:io';

import 'package:shunbo/core/player/mock_player_controller.dart';
import 'package:shunbo/core/scheduler/playback_failure.dart';
import 'package:shunbo/core/scheduler/playback_orchestrator.dart';
import 'package:shunbo/core/scheduler/source_catalog.dart';
import 'package:shunbo/core/scheduler/source_failover.dart';
import 'package:shunbo/core/source/site_rule.dart';
import 'package:shunbo/core/source/source_adapter.dart';
import 'package:shunbo/core/source/source_profile.dart';
import 'package:shunbo/core/source/source_registry.dart';
import 'package:shunbo/data/memory_resume_store.dart';
import 'package:shunbo/data/onboarding/source_config_loader.dart';
import 'package:shunbo/data/onboarding/source_config_validator.dart';

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

Map<String, dynamic> sourceConfig({
  required String id,
  required String baseUrl,
  required SiteRule preset,
  Map<String, String> headers = const <String, String>{},
  String searchPath = 'search?q={keyword}',
  String playPath = 'detail/{mediaId}',
  List<String> platforms = const <String>['desktop', 'tv'],
  int episodeOffset = 0,
  double adInterval = 0,
  double adDuration = 0,
  bool enabled = true,
  String parser = 'regex',
  String? ruleBaseUrl,
}) =>
    <String, dynamic>{
      'id': id,
      'name': '站点-$id',
      'baseUrl': baseUrl,
      'parser': parser,
      'headers': headers,
      'searchPath': searchPath,
      'playPath': playPath,
      'platforms': platforms,
      'episodeOffset': episodeOffset,
      'adInterval': adInterval,
      'adDuration': adDuration,
      'enabled': enabled,
      'rules': <String, dynamic>{
        ...preset.toJson(),
        'baseUrl': ruleBaseUrl ?? baseUrl,
      },
    };

/// 播放地址必须真能取到 m3u8 内容。
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

Future<void> _happyMultiSource(
  FixtureSite legacy,
  FixtureSite vod,
  FixtureSite jsonSite,
) async {
  final cfg = <String, dynamic>{
    'name': '本地多源样本',
    'version': 1,
    'sources': <Object?>[
      sourceConfig(
        id: 'src-legacy',
        baseUrl: legacy.origin,
        preset: SiteRulePresets.legacy,
        headers: <String, String>{
          'User-Agent': 'shunbo/1.0',
          'Referer': '${legacy.origin}/',
        },
        searchPath: 'v1/find?kw={keyword}',
        playPath: 'v1/info/{mediaId}',
        episodeOffset: 1,
        adInterval: 600,
        adDuration: 30,
      ),
      sourceConfig(
        id: 'src-vod',
        baseUrl: vod.origin,
        preset: SiteRulePresets.vodHtml,
      ),
      sourceConfig(
        id: 'src-json',
        baseUrl: jsonSite.origin,
        preset: SiteRulePresets.jsonApi,
        platforms: const <String>['desktop', 'tv', 'android'],
      ),
    ],
  };

  check('多源容器通过 E9 白名单整体验证', validateSourceConfig(cfg).ok);

  final loaded = loadSourceConfig(cfg);
  check('三源全部加载成功', loaded.accepted == 3 && loaded.rejected == 0);
  check('生成的适配器数量与画像数量一致',
      loaded.adapters.length == 3 && loaded.hasSources);

  final registry = SourceRegistry();
  final catalog = SourceCatalog();
  loaded.registerInto(registry, catalog);
  check('适配器与画像都已注册进业务能力层',
      registry.ids.length == 3 && catalog.names.length == 3);
  check('平台裁剪生效（仅 android 的源不存在于本次配置）',
      registry.availableOn(SourcePlatform.desktop).length == 3);

  final player = MockPlayerController();
  final orch = PlaybackOrchestrator(
    registry: registry,
    catalog: catalog,
    player: player,
    resumeStore: MemoryResumeStore(),
  );

  final hits = await orch.search('测试', SourcePlatform.desktop);
  check('跨真实源聚合命中（legacy2 + vod1 + json1）', hits.length == 4);
  check('聚合结果来自三个不同源',
      hits.map((h) => h.sourceId).toSet().length == 3);
  check('HTML 实体在真实链路上被解码',
      hits.any((h) => h.result.title.contains('测试剧 & A')));

  check('自定义 searchPath 真实生效',
      legacy.hitCount('/v1/find') == 1 && legacy.hitCount('/search') == 0);
  check('配置请求头真实发出（UA）',
      legacy.lastHeaders['user-agent'] == 'shunbo/1.0');
  check('配置请求头真实发出（Referer）',
      legacy.lastHeaders['referer'] == '${legacy.origin}/');

  final legacyHit = hits.firstWhere((h) => h.sourceId == 'src-legacy');
  final adapter = registry.get('src-legacy')!;
  final eps = await adapter.getEpisodes(legacyHit.result.mediaId);
  check('自定义 playPath 真实生效',
      eps.length == 2 && legacy.hitCount('/v1/info/m1') == 1);

  final session = await orch.startPlayback(
    sourceId: 'src-legacy',
    mediaId: legacyHit.result.mediaId,
    mediaTitle: legacyHit.result.title,
    canonicalEpisode: 1,
    canonicalSeconds: 650.0,
  );
  check('配置里的集数偏移生效', session.rawEpisode == 2);
  check('广告画像下内容坐标仍守恒', session.contentSeconds == 650.0);
  check('播放器载入真实择优地址',
      (player.loadedUrl ?? '').startsWith(legacy.origin) &&
          (player.loadedUrl ?? '').contains('/media/1080.m3u8'));
  check('播放地址真实可取回 m3u8', await mediaReachable(player.loadedUrl!));
  // 会话携带的必须是**播放器实际载入的那个地址**：投屏要靠它把同一个资源交给电视，
  // 两边地址不一致就会出现「本机能播、投屏黑屏」或者「投的是另一个清晰度」。
  check('会话携带的播放地址与播放器载入的一致',
      session.playUrl == player.loadedUrl && session.playUrl.isNotEmpty);
  check('会话播放地址真实可取回', await mediaReachable(session.playUrl));
  // 取数与播放必须用同一份请求头：源站校验 Referer 时，播放少一份就 403。
  check('配置里的请求头到达播放层',
      player.loadedHeaders['Referer'] == '${legacy.origin}/' &&
          player.loadedHeaders['User-Agent'] == 'shunbo/1.0');
  check('catalog 中的画像与配置一致',
      catalog.get('src-legacy')?.episodeOffset == 1 &&
          catalog.get('src-legacy')?.adDuration == 30.0);

  loaded.close();
}

Future<void> _faultIsolationAndFailover(
  FixtureSite legacy,
  FixtureSite vod,
  FixtureSite jsonSite,
) async {
  // 坏源指向无人监听的端口：真实连接失败，而非 Mock 出来的假失败。
  const deadOrigin = 'http://127.0.0.1:1';
  final cfg = <String, dynamic>{
    'sources': <Object?>[
      sourceConfig(
          id: 'src-dead', baseUrl: deadOrigin, preset: SiteRulePresets.legacy),
      sourceConfig(
        id: 'src-legacy',
        baseUrl: legacy.origin,
        preset: SiteRulePresets.legacy,
        headers: <String, String>{
          'User-Agent': 'shunbo/1.0',
          'Referer': '${legacy.origin}/',
        },
        searchPath: 'v1/find?kw={keyword}',
        playPath: 'v1/info/{mediaId}',
      ),
      sourceConfig(
          id: 'src-vod', baseUrl: vod.origin, preset: SiteRulePresets.vodHtml),
      sourceConfig(
          id: 'src-json',
          baseUrl: jsonSite.origin,
          preset: SiteRulePresets.jsonApi),
    ],
  };
  final loaded = loadSourceConfig(cfg);
  check('坏源配置本身合法（失败发生在运行期）',
      loaded.accepted == 4 && loaded.rejected == 0);

  final registry = SourceRegistry();
  final catalog = SourceCatalog();
  loaded.registerInto(registry, catalog);
  final player = MockPlayerController();
  final orch = PlaybackOrchestrator(
    registry: registry,
    catalog: catalog,
    player: player,
    resumeStore: MemoryResumeStore(),
  );

  final hits = await orch.search('测试', SourcePlatform.desktop);
  check('单源真实连接失败不拖垮多源聚合', hits.length == 4);
  check('失败源未污染命中结果',
      hits.every((h) => h.sourceId != 'src-dead'));

  final failedSession = PlaybackSession.fromRaw(
    mediaId: 'm1',
    mediaTitle: '故障恢复测试',
    sourceId: 'src-dead',
    profile: const SourceProfile(name: 'src-dead'),
    rawEpisode: 1,
    rawSeconds: 650.0,
    playUrl: 'https://example.invalid/dead.m3u8',
  );
  final failover = SourceFailover(
    orchestrator: orch,
    registry: registry,
    catalog: catalog,
  );
  final result = await failover.recover(
    failedSession: failedSession,
    failure: const PlaybackFailureException(
      reason: PlaybackFailureReason.networkError,
      sourceId: 'src-dead',
      message: '连接失败',
    ),
    platform: SourcePlatform.desktop,
  );
  check('跨真实源自动换源恢复成功', result.recovered);
  check('恢复后会话落在可用真实源',
      result.session != null && result.session!.sourceId != 'src-dead');
  check('恢复后播放器载入真实地址',
      (player.loadedUrl ?? '').startsWith('http://127.0.0.1:'));
  check('恢复过程内容坐标守恒',
      result.session != null && result.session!.contentSeconds == 650.0);

  loaded.close();
}

Future<void> _rejectionIsolation(FixtureSite legacy) async {
  final good = sourceConfig(
      id: 'good', baseUrl: legacy.origin, preset: SiteRulePresets.legacy);

  final withScript = Map<String, dynamic>.from(good)
    ..['id'] = 'bad-script'
    ..['script'] = 'https://evil/x.js';
  final jarBackend = sourceConfig(
      id: 'bad-jar',
      baseUrl: legacy.origin,
      preset: SiteRulePresets.legacy,
      parser: 'jar');
  final hostMismatch = sourceConfig(
    id: 'bad-host',
    baseUrl: legacy.origin,
    preset: SiteRulePresets.legacy,
    ruleBaseUrl: 'https://evil.example.com',
  );
  final headerInjection = sourceConfig(
    id: 'bad-inject',
    baseUrl: legacy.origin,
    preset: SiteRulePresets.legacy,
    headers: <String, String>{'X-Evil': 'a\r\nX-Injected: 1'},
  );
  final forbiddenHeader = sourceConfig(
    id: 'bad-host-header',
    baseUrl: legacy.origin,
    preset: SiteRulePresets.legacy,
    headers: <String, String>{'Host': 'evil.example.com'},
  );
  final duplicated = sourceConfig(
      id: 'good', baseUrl: legacy.origin, preset: SiteRulePresets.legacy);
  final disabled = sourceConfig(
      id: 'disabled',
      baseUrl: legacy.origin,
      preset: SiteRulePresets.legacy,
      enabled: false);
  final badPath = sourceConfig(
      id: 'bad-path',
      baseUrl: legacy.origin,
      preset: SiteRulePresets.legacy,
      searchPath: 'search?q=fixed');
  final redos = sourceConfig(
      id: 'bad-redos',
      baseUrl: legacy.origin,
      preset: SiteRulePresets.legacy);
  (redos['rules'] as Map<String, dynamic>)['search'] =
      <String, dynamic>{'patterns': <String>[r'(\w+)+'], 'fields': <String, String>{}};

  final cfg = <String, dynamic>{
    'sources': <Object?>[
      withScript,
      jarBackend,
      hostMismatch,
      headerInjection,
      forbiddenHeader,
      duplicated,
      disabled,
      badPath,
      redos,
      good,
    ],
  };
  final loaded = loadSourceConfig(cfg);
  check('坏配置逐条隔离，仅好配置被接受',
      loaded.accepted == 1 && loaded.sources.first.id == 'good');
  check('8 条坏配置被拒绝、禁用项不算拒绝', loaded.rejected == 8);

  final all = loaded.rejections.map((r) => r.reasons.join('；')).join('\n');
  check('拒绝动态代码字段', all.contains('禁止字段'));
  check('拒绝未授权 jar 后端', all.contains('jar/QuickJS') || all.contains('不是 Dart 后端'));
  check('拒绝规则指向外部主机', all.contains('主机不一致'));
  check('拒绝请求头换行注入', all.contains('含换行'));
  check('拒绝覆盖 Host 头', all.contains('禁止由配置覆盖请求头'));
  check('拒绝重复 id', all.contains('重复'));
  check('拒绝缺占位符的路径模板', all.contains('缺少占位符'));
  check('拒绝嵌套量词正则', all.contains('ReDoS') || all.contains('嵌套量词'));

  final containerCheck = validateSourceConfig(cfg);
  check('容器校验汇总各条问题且带索引',
      !containerCheck.ok && containerCheck.reasons.any((r) => r.contains('sources[')));
  check('容器拒绝未知顶层字段',
      !validateSourceConfig(<String, dynamic>{
        'sources': <Object?>[good],
        'evil': 1,
      }).ok);
  check('容器拒绝非字符串键',
      !validateSourceConfig(<Object?, Object?>{'sources': <Object?>[good], 1: 'x'}).ok);

  final fromText = loadSourceConfigFromJson(jsonEncode(cfg));
  check('从 JSON 文本加载结果一致',
      fromText.accepted == 1 && fromText.rejected == 8);
  final brokenText = loadSourceConfigFromJson('{oops');
  check('坏 JSON 降级不抛异常',
      brokenText.accepted == 0 && brokenText.rejected == 1);

  loaded.close();
  fromText.close();
  brokenText.close();
}

Future<void> _limits(FixtureSite legacy) async {
  final many = <Object?>[
    for (var i = 0; i < kMaxSources + 1; i++)
      sourceConfig(
        id: 'bulk-$i',
        baseUrl: legacy.origin,
        preset: SiteRulePresets.legacy,
      ),
  ];
  final loaded = loadSourceConfig(<String, dynamic>{'sources': many});
  check('源数量上限生效', loaded.accepted == kMaxSources);
  check('超限给出可读拒绝记录',
      loaded.rejections.any((r) => r.reasons.any((x) => x.contains('超过上限'))));
  loaded.close();

  final platforms = sourceConfig(
    id: 'android-only',
    baseUrl: legacy.origin,
    preset: SiteRulePresets.legacy,
    platforms: const <String>['android'],
  );
  final loaded2 = loadSourceConfig(platforms);
  final registry = SourceRegistry();
  final catalog = SourceCatalog();
  loaded2.registerInto(registry, catalog);
  check('platforms 裁剪：桌面不可见',
      registry.availableOn(SourcePlatform.desktop).isEmpty);
  check('platforms 裁剪：Android 可见',
      registry.availableOn(SourcePlatform.android).length == 1);
  check('未知平台被拒绝',
      loadSourceConfig(sourceConfig(
        id: 'bad-platform',
        baseUrl: legacy.origin,
        preset: SiteRulePresets.legacy,
        platforms: const <String>['windows'],
      )).rejected == 1);
  loaded2.close();
}

Future<void> main() async {
  // legacy 站点开启请求头校验：配置里的 UA / Referer 没真发出就会 403。
  final legacy = FixtureSite(
    'legacy',
    headerGuard: true,
    requiredHeaders: const <String, String>{'user-agent': 'shunbo/1.0'},
  );
  final vod = FixtureSite('vod');
  final jsonSite = FixtureSite('json');
  await Future.wait(<Future<void>>[
    legacy.start(),
    vod.start(),
    jsonSite.start(),
  ]);

  try {
    for (final group in <(String, Future<void> Function())>[
      ('multi-source', () => _happyMultiSource(legacy, vod, jsonSite)),
      ('fault-isolation', () => _faultIsolationAndFailover(legacy, vod, jsonSite)),
      ('rejection', () => _rejectionIsolation(legacy)),
      ('limits', () => _limits(legacy)),
    ]) {
      try {
        await group.$2();
      } catch (e, st) {
        _failCount++;
        print('ERROR[${group.$1}]: $e\n$st');
      }
    }
  } finally {
    await Future.wait(<Future<void>>[
      legacy.close(),
      vod.close(),
      jsonSite.close(),
    ]);
  }
  final total = _checkCount + _failCount;
  print('配置驱动多源真实回归：$_checkCount/$total 断言通过');
  if (_failCount > 0) {
    print('未通过 $_failCount 项，退出码 1');
    exitCode = 1;
  }
}
