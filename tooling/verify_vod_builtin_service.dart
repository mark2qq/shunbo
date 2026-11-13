// 内置索引**运行期服务**回归：检索 → 命中 → 转条目 → 回源 → 挂进播放链路。
//
// 与 `verify_vod_builtin_index.dart` 的分工：
//  * 那份测「打包产物是否自洽、Dart 解析器与 Python 打包器是否同口径」；
//  * 这份测「把索引接进 App 之后，搜索能不能搜到、点开能不能播」。
//
// 为什么必须单独测：`BuiltinIndexService` 与 `VodLibrary.adoptResolved` 是
// 第 1 项里**唯一会碰播放链路**的一段。这里一旦把 sourceId 搞错，
// `VodLibrary.append` 会把用户已经同步的几万条外部目录整批清空 —— 这种
// 事故不会崩、不会报错，只是「升级后片库突然空了」，极难从现象反推。
//
// 运行：dart run tooling/verify_vod_builtin_service.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shunbo/core/scheduler/source_catalog.dart';
import 'package:shunbo/core/source/source_adapter.dart';
import 'package:shunbo/core/source/source_registry.dart';
import 'package:shunbo/features/vod/vod_boot_index.dart';
import 'package:shunbo/features/vod/vod_builtin_index.dart';
import 'package:shunbo/features/vod/vod_builtin_service.dart';
import 'package:shunbo/features/vod/vod_catalog.dart';
import 'package:shunbo/features/vod/vod_library.dart';

int _pass = 0;
int _fail = 0;
final List<String> _failures = <String>[];

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
    _failures.add(detail.isEmpty ? name : '$name —— $detail');
    stdout.writeln('  FAIL $name${detail.isEmpty ? '' : ' —— $detail'}');
  }
}

const String kDir = 'assets/vod_index';

/// 从真实打包产物读 manifest 与分片（不造样本：造样本测不出「打包侧口径」）。
Future<BuiltinIndexManifest?> realManifest() async {
  final f = File('$kDir/manifest.json');
  if (!f.existsSync()) return null;
  return BuiltinIndexManifest.decode(f.readAsStringSync());
}

Future<Uint8List?> realShard(String file) async {
  final f = File('$kDir/$file');
  if (!f.existsSync()) return null;
  return f.readAsBytes();
}

/// 一个可控的回源替身：记录被请求的命中，返回可播条目。
class _Fetcher {
  final List<String> requests = <String>[];
  bool fail = false;

  /// 只让某些站点下标失败（测「同名备选来源」的换源路径）。
  final Set<int> failSites = <int>{};

  Future<VodItem?> call(BuiltinIndexHit hit) async {
    requests.add('${hit.siteIndex}|${hit.vodId}');
    if (fail || failSites.contains(hit.siteIndex)) return null;
    return VodItem(
      id: 'test:$hit vodId',
      title: hit.name,
      subtitle: 'test',
      description: 'test',
      license: 'test',
      section: vodSectionFromKey(hit.section),
      episodes: <VodEpisode>[
        VodEpisode(number: 1, title: '第1集', url: 'https://cdn.test/1.m3u8'),
      ],
      sourceId: '测试回源源',
    );
  }
}

Future<void> main() async {
  final manifest = await realManifest();
  if (manifest == null) {
    stdout.writeln('缺 $kDir/manifest.json —— 先跑 python tooling/pack_vod_index.py');
    exit(2);
  }

  // ── A. manifest 读取与 ready 语义 ──
  {
    final svc = BuiltinIndexService(
      loadManifest: realManifest,
      loadShardBytes: realShard,
      fetchDetail: (hit) async => null,
    );
    check('A01 未 ensureManifest 前 ready=false（不偷读磁盘）', !svc.ready);
    final m = await svc.ensureManifest();
    check('A02 ensureManifest 成功', m != null);
    check('A03 读完后 ready=true', svc.ready);
    check('A04 ensureManifest 幂等（第二次不再读）', identical(await svc.ensureManifest(), m));
    check('A05 初始未解压任何分片', svc.loadedShards == 0 && svc.loadedChars == 0);
  }

  // ── B. manifest 读不到 → ready=false，且所有检索返回空而不抛 ──
  {
    final svc = BuiltinIndexService(
      loadManifest: () async => null,
      loadShardBytes: realShard,
      fetchDetail: (hit) async => null,
    );
    check('B01 manifest 缺失 ready=false', !(await svc.ensureManifest() != null && svc.ready));
    final hits = await svc.search('movies', '战狼');
    check('B02 没 manifest 时检索返回空而不是抛异常', hits.isEmpty);
    check('B03 没 manifest 时 searchAll 返回空', (await svc.searchAll('战狼')).isEmpty);
  }

  // ── C. manifest 读取抛异常 → 吞掉，当作没有 ──
  {
    final svc = BuiltinIndexService(
      loadManifest: () async => throw StateError('磁盘坏了'),
      loadShardBytes: realShard,
      fetchDetail: (hit) async => null,
    );
    BuiltinIndexManifest? got;
    try {
      got = await svc.ensureManifest();
    } catch (e) {
      got = null;
      check('C01 ensureManifest 不该把异常抛给调用方', false, '$e');
    }
    check('C02 异常被吞，返回 null', got == null);
  }

  // ── D. 空查询 / 空分片 → 返回空（浏览不走索引）──
  {
    final svc = BuiltinIndexService(
      loadManifest: realManifest,
      loadShardBytes: realShard,
      fetchDetail: (hit) async => null,
    );
    await svc.ensureManifest();
    check('D01 空查询返回空（索引只负责「搜得到」，不负责浏览）',
        (await svc.search('movies', '')).isEmpty);
    check('D02 纯空格查询返回空', (await svc.search('movies', '   ')).isEmpty);
    check('D03 空查询不触发分片解压', svc.loadedShards == 0);
    check('D04 未知栏目键返回空而不是抛',
        (await svc.search('not_a_section', '战狼')).isEmpty);
  }

  // ── E. 真实分片检索 + 按栏目隔离 ──
  {
    final svc = BuiltinIndexService(
      loadManifest: realManifest,
      loadShardBytes: realShard,
      fetchDetail: (hit) async => null,
    );
    final m = await svc.ensureManifest();
    // 从分片里取一条真实片名当查询词，保证一定有命中。
    final shard = m!.shards.first;
    final text = decodeShardBody((await realShard(shard.file))!);
    final firstLine = BuiltinIndexLine.parse(text.split('\n').first);
    check('E00 能解出首行（前置条件）', firstLine != null);
    final probe = firstLine!.suffix.isEmpty ? '' : firstLine.suffix;
    if (probe.isEmpty) {
      check('E01 首行后缀为空，跳过（数据形态异常）', false, '首行=${text.split('\n').first}');
    } else {
      final hits = await svc.search(shard.key, probe, limit: 20);
      check('E01 真实片名前缀能搜到', hits.isNotEmpty, 'probe=$probe key=${shard.key}');
      check('E02 命中条目全部落在请求的栏目', hits.every((h) => h.section == shard.key));
      check('E03 命中条数不超过 limit', hits.length <= 20, '${hits.length}');
      check('E04 只解压了被查的那一片', svc.loadedShards == 1, '${svc.loadedShards}');
      check('E05 片名非空', hits.every((h) => h.name.trim().isNotEmpty));
      check('E06 vod_id 非空', hits.every((h) => h.vodId.trim().isNotEmpty));
      check('E07 站点下标在 manifest 范围内',
          hits.every((h) => h.siteIndex >= 0 && h.siteIndex < m.sites.length));

      // 缓存：同查询第二次不再解压
      final before = svc.loadedChars;
      final again = await svc.search(shard.key, probe, limit: 20);
      check('E08 同查询命中缓存（结果一致）', again.length == hits.length);
      check('E09 同查询不再重新解压', svc.loadedChars == before);
    }
  }

  // ── F. limit 生效 + 大 limit 不炸 ──
  {
    final svc = BuiltinIndexService(
      loadManifest: realManifest,
      loadShardBytes: realShard,
      fetchDetail: (hit) async => null,
    );
    final m = await svc.ensureManifest();
    // 用一个极常见的单字，保证命中数量远超 limit。
    final shard = m!.shards.first;
    final text = decodeShardBody((await realShard(shard.file))!);
    String candidate = '';
    for (final ch in '的一是国我中大电影人'.split('')) {
      final n = text.split('\n').where((l) => l.contains(ch)).length;
      if (n > 30) {
        candidate = ch;
        break;
      }
    }
    if (candidate.isEmpty) {
      check('F01 找不到高频字样本，跳过', true);
    } else {
      final a = await svc.search(shard.key, candidate, limit: 5);
      final b = await svc.search(shard.key, candidate, limit: 50);
      check('F01 limit=5 生效', a.length <= 5, '${a.length}');
      check('F02 limit=50 能拿到更多', b.length >= a.length, '${a.length} vs ${b.length}');
    }
  }

  // ── G. 分片读不到 → 检索返回空（不抛）──
  {
    final svc = BuiltinIndexService(
      loadManifest: realManifest,
      loadShardBytes: (file) async => throw StateError('读不到'),
      fetchDetail: (hit) async => null,
    );
    await svc.ensureManifest();
    final hits = await svc.search('movies', '战狼');
    check('G01 分片读取抛异常时检索返回空', hits.isEmpty);
  }

  // ── H. 命中 → 条目：id 前缀 / 栏目 / 空剧集 ──
  {
    final svc = BuiltinIndexService(
      loadManifest: realManifest,
      loadShardBytes: realShard,
      fetchDetail: (hit) async => null,
    );
    await svc.ensureManifest();
    const hit = BuiltinIndexHit(
        siteIndex: 0, vodId: '12345', typeId: '25', name: '测试片', section: 'movies');
    final item = svc.toItem(hit);
    check('H01 toItem 的 id 带 builtin: 前缀', isBuiltinHitId(item.id), item.id);
    check('H02 hit.id 与 item.id 一致（回源要靠它反查）', item.id == hit.id);
    check('H03 剧集刻意为空（回源前不可播）', item.episodes.isEmpty);
    check('H04 sourceId 用内置索引专用 id', item.sourceId == kVodBuiltinIndexSourceId);
    check('H05 栏目按命中落位', item.section == VodSection.movies);
    check('H06 副标题含站点名', item.subtitle.isNotEmpty);
    check('H07 描述明示「播放地址在打开时获取」', item.description.contains('播放地址'));
    check('H08 非内置 id 不被判成内置命中', !isBuiltinHitId('外部点播·x:dyttzy:1'));

    // 类目 id → 中文名（1.0.5 第十五次修）：界面不许出现「25」这种数字类型。
    final unknown = svc.toItem(const BuiltinIndexHit(
      siteIndex: 0,
      vodId: '12345',
      typeId: 'zz-not-a-type',
      name: '测试片',
      section: 'movies',
    ));
    check('H09 查不到类目名时留空，不回退成数字 id',
        unknown.typeName.isEmpty &&
            !unknown.subtitle.contains('zz-not-a-type'),
        'typeName=${unknown.typeName} / sub=${unknown.subtitle}');

    final m = await realManifest();
    var probed = false;
    if (m != null) {
      for (var i = 0; i < m.types.length; i++) {
        final label = m.typeNameOf(m.typeSites[i], m.types[i]);
        if (label.isEmpty) continue;
        final realItem = svc.toItem(BuiltinIndexHit(
          siteIndex: m.typeSites[i],
          vodId: '1',
          typeId: m.types[i],
          name: '测试片',
          section: 'movies',
        ));
        check('H10 真实类目回填成中文名（$label）',
            realItem.typeName == label &&
                int.tryParse(realItem.typeName) == null,
            realItem.typeName);
        check('H11 副标题用中文类目名，不含裸 id', realItem.subtitle.contains(label),
            realItem.subtitle);
        probed = true;
        break;
      }
    }
    check('H12 至少有一个可命名的类目（否则 H10 无意义）', probed);
  }

  // ── I. 栏目键 → 枚举：六项全覆盖 + 未知回落 other ──
  {
    for (final s in VodSection.values) {
      check('I01[${s.name}] 栏目键往返一致', vodSectionFromKey(s.name) == s);
    }
    check('I02 未知键回落 other（绝不污染电影栏目）',
        vodSectionFromKey('weird') == VodSection.other);
    check('I03 空字符串回落 other', vodSectionFromKey('') == VodSection.other);
  }

  // ── J. hitById：转条目后能反查（回源路径的前提）──
  {
    final fetcher = _Fetcher();
    final svc = BuiltinIndexService(
      loadManifest: realManifest,
      loadShardBytes: realShard,
      fetchDetail: fetcher.call,
    );
    final m = await svc.ensureManifest();
    final shard = m!.shards.first;
    final text = decodeShardBody((await realShard(shard.file))!);
    final first = BuiltinIndexLine.parse(text.split('\n').first)!;
    final hits = await svc.search(shard.key, first.suffix, limit: 5);
    check('J00 前置：搜到了命中', hits.isNotEmpty);
    if (hits.isNotEmpty) {
      final item = svc.toItem(hits.first);
      final back = svc.hitById(item.id);
      check('J01 toItem 后能按 id 反查回命中', back != null);
      check('J02 反查到的站点下标一致', back?.siteIndex == hits.first.siteIndex);
      check('J03 反查到的 vod_id 一致', back?.vodId == hits.first.vodId);
      check('J04 反查到的片名一致', back?.name == hits.first.name);
      check('J05 未转成条目的 id 查不到', svc.hitById('builtin:999:999') == null);
      check('J06 非内置 id 查不到', svc.hitById('whatever') == null);
    }
  }

  // ── J2. 第二十四次修：命中表会清，id 结构不会 ──
  //
  // 用户看到「这条索引记录已失效，请重新检索」，可过一会再点又能播。
  // 真凶不是索引坏了，而是 `hitById` 只查一个会话级缓存（上限 4000，
  // 老实现到顶整表 clear），屏幕上的卡片却还在。这里把「按 id 重建」
  // 这条路逐条锁死：只要 id 结构完好、站点下标没越界，就必须能回源。
  {
    check(
        'J07 id 结构可拆：站点下标 + vod_id',
        parseBuiltinHitId('builtin:12:8848')?.siteIndex == 12 &&
            parseBuiltinHitId('builtin:12:8848')?.vodId == '8848');
    check('J08 vod_id 里带冒号也整段保留（截断会回源到另一部片）',
        parseBuiltinHitId('builtin:3:a:b:c')?.vodId == 'a:b:c');
    check(
        'J09 畸形 id 一律 null（非内置前缀 / 缺分隔符 / 负下标 / 空 vod_id）',
        parseBuiltinHitId('whatever') == null &&
            parseBuiltinHitId('builtin:') == null &&
            parseBuiltinHitId('builtin:12') == null &&
            parseBuiltinHitId('builtin:-1:9') == null &&
            parseBuiltinHitId('builtin:12:') == null &&
            parseBuiltinHitId('builtin:x:9') == null);
  }
  {
    final fetcher = _Fetcher();
    final svc = BuiltinIndexService(
      loadManifest: realManifest,
      loadShardBytes: realShard,
      fetchDetail: fetcher.call,
    );
    final m = await svc.ensureManifest();
    check('J10 前置：真实 manifest 有站点表', (m?.sites.isNotEmpty ?? false));
    // 故意不经过 toItem ⇒ `_byId` 里没有这条。
    final rebuilt = await svc.hitByIdOrRebuild(
      'builtin:0:xyz',
      name: '随便一部片',
      section: 'movies',
    );
    check('J11 命中表里没有，也能按 id 结构重建命中', rebuilt != null);
    check('J12 重建的命中年份 / 片名取自调用方给的条目',
        rebuilt?.name == '随便一部片' && rebuilt?.section == 'movies');
    final played = rebuilt == null ? null : await svc.resolve(rebuilt);
    check('J13 重建的命中能直接回源（不再误报「已失效」）',
        (played?.episodes.isNotEmpty ?? false) &&
            fetcher.requests.single == '0|xyz',
        fetcher.requests.join(','));
    check('J14 站点下标越界时仍返回 null（这份索引确实对不上）',
        (await svc.hitByIdOrRebuild('builtin:9999:xyz')) == null);
    check('J15 非内置 id 不重建',
        (await svc.hitByIdOrRebuild('whatever')) == null);
    final svcSrc =
        File('lib/features/vod/vod_builtin_service.dart').readAsStringSync();
    check('J16 命中表到顶不再整表清空（淘汰最早的 1/4）',
        !svcSrc.contains('if (_byId.length >= kHitIndexCap) _byId.clear();') &&
            svcSrc.contains('final drop = kHitIndexCap ~/ 4;'));
  }

  {
    final fetcher = _Fetcher();
    final svc = BuiltinIndexService(
      loadManifest: realManifest,
      loadShardBytes: realShard,
      fetchDetail: fetcher.call,
    );
    await svc.ensureManifest();
    const hit = BuiltinIndexHit(
        siteIndex: 3, vodId: 'abc', typeId: '1', name: '片名', section: 'series');
    final item = await svc.resolve(hit);
    check('K01 resolve 成功返回条目', item != null);
    check('K02 回源器收到正确的站点下标与 vod_id',
        fetcher.requests.single == '3|abc', fetcher.requests.join(','));
    check('K03 回源条目带剧集（可播）', (item?.episodes.isNotEmpty ?? false));
    fetcher.fail = true;
    check('K04 回源失败返回 null 而不是抛', (await svc.resolve(hit)) == null);
  }

  // ── L. searchAll：六片顺序固定 ──
  {
    final svc = BuiltinIndexService(
      loadManifest: realManifest,
      loadShardBytes: realShard,
      fetchDetail: (hit) async => null,
    );
    final m = await svc.ensureManifest();
    // 用「一」这种高频字保证多片都有命中。
    final hits = await svc.searchAll('一', limitPerSection: 3);
    check('L01 searchAll 有命中', hits.isNotEmpty);
    // 命中顺序必须按 manifest.shards 的顺序（分组可预期）
    final order = <String>[];
    for (final h in hits) {
      if (order.isEmpty || order.last != h.section) order.add(h.section);
    }
    final shardOrder = m!.shards.map((s) => s.key).toList();
    var cursor = 0;
    var inOrder = true;
    for (final k in order) {
      final at = shardOrder.indexOf(k);
      if (at < cursor) {
        inOrder = false;
        break;
      }
      cursor = at;
    }
    check('L02 searchAll 结果按 manifest 分片顺序分组', inOrder, order.join('>'));
    check('L03 searchAll 空查询返回空', (await svc.searchAll('')).isEmpty);
  }

  // ── M. clearCache：下一次检索重新解压 ──
  {
    final svc = BuiltinIndexService(
      loadManifest: realManifest,
      loadShardBytes: realShard,
      fetchDetail: (hit) async => null,
    );
    final m = await svc.ensureManifest();
    final shard = m!.shards.first;
    final text = decodeShardBody((await realShard(shard.file))!);
    final probe = BuiltinIndexLine.parse(text.split('\n').first)!.suffix;
    await svc.search(shard.key, probe);
    check('M01 解压后 loadedShards>0', svc.loadedShards > 0);
    svc.clearCache();
    check('M02 clearCache 后 loadedShards 归零', svc.loadedShards == 0);
    check('M03 clearCache 后 ready=false（要重新读 manifest）', !svc.ready);
    await svc.ensureManifest();
    final again = await svc.search(shard.key, probe);
    check('M04 clearCache 后仍能重新检索到', again.isNotEmpty);
  }

  // ── N. VodLibrary.adoptResolved：绝不能清掉外部目录 ──
  {
    final registry = SourceRegistry();
    final catalog = SourceCatalog();
    final lib = VodLibrary(registry: registry, catalog: catalog);

    // 先接入一个「外部采集源」，模拟用户已经同步了几百条。
    //
    // 注意 `typeName` 必须给：电影栏目额外过 `isMovieSectionItem`，
    // 空 typeName 会被判成「不是电影」而整条滤掉 —— 那时 N03 失败的原因是
    // **样本不真实**，不是 adoptResolved 清空了目录，很容易看错方向。
    final external = <VodItem>[
      for (var i = 1; i <= 3; i++)
        VodItem(
          id: '外部点播·test:site1:$i',
          title: '外部片$i',
          subtitle: 'site1',
          description: 'd',
          license: 'l',
          section: VodSection.movies,
          typeName: '动作片',
          episodes: <VodEpisode>[
            VodEpisode(number: 1, title: '第1集', url: 'https://cdn.ext/$i.m3u8'),
          ],
          sourceId: '外部点播·test',
        ),
    ];
    final added = lib.append(
      sourceId: '外部点播·test',
      incoming: external,
      sourceName: '外部测试源',
    );
    check('N01 外部源已接入 3 条', added == 3 && lib.externalCount == 3, '$added');

    // 再挂一条「内置索引回源」条目（sourceId 不同）。
    final resolved = VodItem(
      id: '内置索引回源:site9:777',
      title: '回源片',
      subtitle: 'site9',
      description: 'd',
      license: 'l',
      section: VodSection.anime,
      episodes: <VodEpisode>[
        VodEpisode(number: 1, title: '正片', url: 'https://cdn.builtin/777.m3u8'),
      ],
      sourceId: kVodBuiltinIndexSourceId,
    );
    lib.adoptResolved(resolved);

    check('N02 回源条目**没有**清掉外部目录（这是最关键的断言）',
        lib.externalCount == 3, '${lib.externalCount}');
    check('N03 外部条目仍在栏目里',
        lib.inSection(VodSection.movies).any((i) => i.id == external.first.id));
    check('N04 回源条目**没有**混进栏目列表（索引只负责搜得到）',
        !lib.inSection(VodSection.anime).any((i) => i.id == resolved.id));
    check('N05 外部来源名未被回源覆盖', lib.activeSourceName == '外部测试源',
        '${lib.activeSourceName}');

    // 回源条目的适配器必须真的能取到地址，否则点开就是黑屏。
    final adapter = registry.get(kVodBuiltinIndexSourceId);
    check('N06 回源 sourceId 注册了适配器', adapter != null);
    final urls = await adapter?.resolvePlayUrl(resolved.id, 1) ??
        const <PlayUrl>[];
    check('N07 适配器能取到回源条目的地址', urls.isNotEmpty, '${urls.length}');
    check('N08 地址与详情里的一致',
        urls.isNotEmpty && urls.first.url == 'https://cdn.builtin/777.m3u8');
    final eps = await adapter?.getEpisodes(resolved.id) ?? const <EpisodeInfo>[];
    check('N09 适配器能取到剧集表', eps.length == 1);

    // 外部源的适配器不受影响
    final extAdapter = registry.get('外部点播·test');
    check('N10 外部源适配器仍在', extAdapter != null);
    check(
        'N11 外部条目地址仍可取',
        (await extAdapter?.resolvePlayUrl(external.first.id, 1) ??
                const <PlayUrl>[])
            .isNotEmpty);

    // 幂等：同一条回源两次不重复注册、不抛
    lib.adoptResolved(resolved);
    check('N12 重复 adoptResolved 不抛且不改外部计数', lib.externalCount == 3);
    check(
        'N13 重复 adoptResolved 后地址仍在',
        (await registry
                    .get(kVodBuiltinIndexSourceId)
                    ?.resolvePlayUrl(resolved.id, 1) ??
                const <PlayUrl>[])
            .isNotEmpty);

    // 无剧集的条目不该挂进链路（挂了也播不了，只会留下一条空记录）
    lib.adoptResolved(VodItem(
      id: '内置索引回源:empty',
      title: '空条目',
      subtitle: '',
      description: '',
      license: '',
      section: VodSection.other,
      episodes: const <VodEpisode>[],
      sourceId: kVodBuiltinIndexSourceId,
    ));
    check(
        'N14 无剧集条目被忽略（适配器里查不到）',
        (await registry
                    .get(kVodBuiltinIndexSourceId)
                    ?.getEpisodes('内置索引回源:empty') ??
                const <EpisodeInfo>[])
            .isEmpty);
  }

  // ── O. 源码静态护栏：接入点必须真的存在 ──
  {
    final page = File('lib/ui/vod/vod_page.dart').readAsStringSync();
    final mainSrc = File('lib/main.dart').readAsStringSync();
    final service = File('lib/features/vod/vod_builtin_service.dart')
        .readAsStringSync();

    check('O01 vod_page 用内置索引检索', page.contains('.vodBuiltin.'));
    check('O02 vod_page 合并索引命中', page.contains('_mergeIndexHits('));
    check('O03 vod_page 只合并本栏目的命中', page.contains('hit.section != widget.section'));
    check('O04 vod_page 点开前先回源', page.contains('vodBuiltin.resolve('));
    check('O05 vod_page 回源失败有提示', page.contains('暂时取不到播放地址'));
    check('O06 vod_page 监听启动状态', page.contains('vodBoot.addListener('));
    check('O07 vod_page dispose 对称移除', page.contains('vodBoot.removeListener('));
    check('O08 vod_page 显示启动状态文案', page.contains('boot.note'));
    check('O09 检索有 debounce（不给每个字符解一次 gzip）',
        page.contains('_scheduleIndexSearch(') && page.contains('_indexTimer'));
    check('O10 检索有结果序号（先回来的旧结果不许覆盖新结果）',
        page.contains('_indexSeq'));
    check('O11 main 回源时放行明文 http（内置站点是打包固化的，不是用户输入）',
        mainSrc.contains('allowInsecureHttp: true'));
    check('O12 main 回源后挂进播放链路', mainSrc.contains('adoptResolved('));
    check('O13 回源栏目取索引已定的 section（不重猜）',
        mainSrc.contains('section: vodSectionFromKey(hit.section)'));
    check('O14 服务层不含 dart:io（可裸 dart run 回归）',
        !service.contains("import 'dart:io'"));
    check('O15 服务层不含 flutter 依赖', !service.contains('package:flutter/'));
    // 启动校验完成前用户就打字的那次检索会落空（svc.ready 还是 false），
    // 必须在状态通知里补跑一次，否则表现为「刚打开搜不到、重进才有」。
    check('O16 状态变化时补跑落空的检索',
        page.contains('hasLocalIndex && _indexHits.isEmpty'));
    check('O17 检索前检查索引已就绪', page.contains('if (!svc.ready) return;'));
  }

  // ── P. 真实产物端到端：boot() → 检索，主路径不许有假绿灯 ──
  //
  // 前面的分组各自测一层；这一段把它们串起来跑一遍真实链路：
  // 用真实 manifest + 真实分片 + 真实状态机，断言「一致 ⇒ 零网络 ⇒ 真能搜到」。
  // 少了这段，每层都能过、合起来却不工作（比如 manifest 的 sourceUrl 与
  // 用户默认接口不一致，就会变成「每次启动都判不一致、永远走网络」）。
  {
    final m = await realManifest();
    var syncCalls = 0;
    final boot = VodBootController(
      loadManifest: realManifest,
      loadShard: (file) => realShard(file),
      syncNetwork: () async {
        syncCalls++;
        return '端到端测试不该联网';
      },
      now: () => DateTime.parse('${m!.generatedAt.toIso8601String()}'),
    );
    final phase = await boot.boot(
      selectedUrl: m!.sourceUrl,
      builtinSourceUrl: '',
      allowSync: true,
    );
    check('P01 真实产物 + 地址一致 ⇒ readyBuiltin', phase == VodBootPhase.readyBuiltin,
        '${phase.name} / ${boot.note}');
    check('P02 一致时零网络请求', syncCalls == 0, '$syncCalls');
    check('P03 note 里有条数（用户要知道装了多少）', boot.note.contains('条'), boot.note);
    check('P04 hasLocalIndex=true', boot.hasLocalIndex);
    check('P05 busy=false（启动校验已结束）', !boot.busy);
    check('P06 verdict 可读且为一致', boot.verdict?.match == true,
        boot.verdict?.reason ?? 'null');

    // 用同一个 manifest 建检索服务，跑一次真实查询。
    final svc = BuiltinIndexService(
      loadManifest: realManifest,
      loadShardBytes: realShard,
      fetchDetail: (hit) async => null,
    );
    await svc.ensureManifest();
    final shard = m.shards.first;
    final text = decodeShardBody((await realShard(shard.file))!);
    final probe = BuiltinIndexLine.parse(text.split('\n').first)!.suffix;
    final hits = await svc.search(shard.key, probe, limit: 10);
    check('P07 启动校验通过后，真实分片能搜到东西', hits.isNotEmpty, probe);
    check('P08 命中条目的 section 与分片一致',
        hits.every((h) => h.section == shard.key));

    // 反方向：地址改一个字就必须判不一致（这是「换了接口还能用旧索引」的闸）。
    var sync2 = 0;
    final boot2 = VodBootController(
      loadManifest: realManifest,
      loadShard: (file) => realShard(file),
      syncNetwork: () async {
        sync2++;
        return '故意失败';
      },
      now: () => m.generatedAt,
    );
    final phase2 = await boot2.boot(
      selectedUrl: '${m.sourceUrl}x',
      builtinSourceUrl: '',
      allowSync: true,
    );
    check('P09 地址改一个字符 ⇒ 触发同步', sync2 == 1);
    check('P10 同步失败 ⇒ 回退内置索引', phase2 == VodBootPhase.fallbackBuiltin,
        phase2.name);
    check('P11 回退文案明示「可能不是最新」', boot2.note.contains('可能不是最新'),
        boot2.note);
  }

  // ── Q. 同名两条：检索归并 + 回源换源 ──
  //
  // 打包侧 `--keep-per-title 2` 会给同一个片名留两条（来自不同站），
  // 目的只有一个：主记录那个站的详情接口抽风时还能换源。
  // 这条链路有两个必然会踩的坑，都在这里钉住：
  //   1. 不归并 ⇒ 同一部片两张卡片（用户以为片库里有两部《斗罗大陆》）；
  //   2. 不换源 ⇒ 保留两条纯占体积，主站一挂这部片就点不开。
  {
    // 前端编码的三行样本：两条同名（不同站）+ 一条前缀共享
    final body = <String>[
      '0\t101\t0\t0\t斗罗大陆',
      '1\t202\t0\t4\t',
      '0\t103\t0\t0\t雪中悍刀行',
    ].join('\n');
    final gz = Uint8List.fromList(gzip.encode(utf8.encode(body)));
    final manifestJson = jsonEncode(<String, Object?>{
      'format': 'shunbo-vod-index',
      'version': 1,
      'generatedAt': '2026-11-12T04:00:00+00:00',
      'sourceUrl': 'http://example.invalid/config.json',
      'sites': <Object?>[
        {'key': 'a', 'name': 'A站', 'api': 'http://a/api.php/provide/vod/', 'total': 2},
        {'key': 'b', 'name': 'B站', 'api': 'http://b/api.php/provide/vod/', 'total': 1},
      ],
      'types': <Object?>['1'],
      'sections': <Object?>[
        {
          'key': 'movies',
          'label': '电影',
          'file': 'movies.tsv.gz',
          'records': 3,
          'gzBytes': gz.length,
          'sha256': '',
        },
      ],
      'total': 3,
      'titleCount': 2,
      'keepPerTitle': 2,
      'rawTotal': 9,
      'dedupDropped': 6,
    });
    Future<BuiltinIndexManifest?> loadM() async =>
        BuiltinIndexManifest.decode(manifestJson);
    Future<Uint8List?> loadS(String file) async =>
        file == 'movies.tsv.gz' ? gz : null;

    final fetcher = _Fetcher();
    final svc = BuiltinIndexService(
      loadManifest: loadM,
      loadShardBytes: loadS,
      fetchDetail: fetcher.call,
    );
    await svc.ensureManifest();
    final hits = await svc.search('movies', '斗罗');
    check('Q01 同名两条只出一张卡片', hits.length == 1, '${hits.length} 条');
    check('Q02 同名的第二条进了备选',
        hits.isNotEmpty && svc.altCountFor(hits.first.id) == 1,
        'alts=${hits.isEmpty ? '-' : svc.altCountFor(hits.first.id)}');
    check('Q03 第三个片名仍在结果里，未被误并',
        (await svc.search('movies', '雪中')).length == 1);

    // 主记录正常 ⇒ 只用主记录，不该白跑一次备选
    final okItem = hits.isEmpty ? null : await svc.resolve(hits.first);
    check('Q04 主记录可用时回源成功', okItem != null && okItem.episodes.isNotEmpty);
    check('Q05 主记录可用时不打备选', fetcher.requests.length == 1,
        fetcher.requests.join(','));

    // 主记录那站挂了 ⇒ 自动换到备选站
    final fetcher2 = _Fetcher()..failSites.add(0);
    final svc2 = BuiltinIndexService(
      loadManifest: loadM,
      loadShardBytes: loadS,
      fetchDetail: fetcher2.call,
    );
    await svc2.ensureManifest();
    final hits2 = await svc2.search('movies', '斗罗');
    final altItem = hits2.isEmpty ? null : await svc2.resolve(hits2.first);
    check('Q06 主站回源失败 ⇒ 换源成功', altItem != null && altItem.episodes.isNotEmpty);
    check('Q07 确实先试主站再试备选',
        fetcher2.requests.length == 2 && fetcher2.requests.first.startsWith('0|') &&
            fetcher2.requests.last.startsWith('1|'),
        fetcher2.requests.join(','));

    // 两站都挂 ⇒ 老实返回 null（不许假装成功）
    final deadFetcher = _Fetcher()..fail = true;
    final svc3 = BuiltinIndexService(
      loadManifest: loadM,
      loadShardBytes: loadS,
      fetchDetail: deadFetcher.call,
    );
    await svc3.ensureManifest();
    final hits3 = await svc3.search('movies', '斗罗');
    check('Q08 全部来源失败 ⇒ 返回 null',
        hits3.isEmpty || await svc3.resolve(hits3.first) == null);

    // 片名归一必须与打包侧同口径
    check('Q09 片名归一忽略标点与空白',
        BuiltinIndexService.nameKey('斗罗·大陆') ==
            BuiltinIndexService.nameKey(' 斗罗大陆 '));
    check('Q10 片名归一不把不同片并成一个',
        BuiltinIndexService.nameKey('斗罗大陆') !=
            BuiltinIndexService.nameKey('雪中悍刀行'));

    // 源码护栏：这条能力不许被顺手删掉
    final pack = File('tooling/pack_vod_index.py').readAsStringSync();
    check('Q11 打包侧支持每名多条', pack.contains('--keep-per-title'));
    check('Q12 打包侧优先不同站（同站同名不重复占位）',
        pack.contains('if sidx in sites_of'));
    check('Q13 服务层走 _tryResolve（统一判「无剧集＝失败」）',
        File('lib/features/vod/vod_builtin_service.dart')
            .readAsStringSync()
            .contains('_tryResolve'));
  }

  final total = _pass + _fail;
  stdout.writeln('');
  if (_fail == 0) {
    stdout.writeln('回归通过：$_pass/$total 断言通过');
    exit(0);
  }
  stdout.writeln('回归失败：$_pass/$total 断言通过');
  for (final f in _failures) {
    stdout.writeln('  - $f');
  }
  exit(1);
}
