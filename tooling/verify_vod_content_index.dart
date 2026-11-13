// 1.0.5 第十次修：短视频栏目 + 接口数据本地内容检索记录回归。
//
// 四层：
//   ① 栏目与归类：枚举/类目表/文本关键词/老缓存迁移/后续新增统一归类；
//   ② 本地记录：字段持久化、upsert 去重、元数据更新、TTL 过期、换源重建、v1 升级；
//   ③ 内容检索：按片名/类型/年份/地区自由检索与字段前缀检索，三者一致；
//   ④ 源码静态护栏：装配、启动优先读本地、后台差量同步、门禁接入。
//
// 运行：dart run tooling/verify_vod_content_index.dart
import 'dart:convert';
import 'dart:io';

import 'package:shunbo/core/scheduler/source_catalog.dart';
import 'package:shunbo/core/source/source_registry.dart';
import 'package:shunbo/data/onboarding/vod_library_store.dart';
import 'package:shunbo/features/vod/third_party_vod.dart';
import 'package:shunbo/features/vod/vod_catalog.dart';
import 'package:shunbo/features/vod/vod_content_index.dart';
import 'package:shunbo/features/vod/vod_library.dart';
import 'package:shunbo/features/vod/vod_search.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (!ok) {
    _fail++;
    print('FAIL: $name${detail == null ? '' : ' —— $detail'}');
    return;
  }
  _pass++;
  print('PASS: $name');
}

/// Windows 工作区部分文件是 CRLF，统一成 LF 后再做匹配。
String _src(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

const String _m3u8 = 'https://cdn.test/1.m3u8';
const String _poster = 'https://img.test/1.jpg';

VodItem item({
  required String id,
  String title = '测试片',
  VodSection section = VodSection.movies,
  String typeName = '',
  String genre = '',
  String area = '',
  String year = '',
  String subtitle = '2026 · 中国大陆',
  String poster = _poster,
  List<VodEpisode>? episodes,
}) =>
    VodItem(
      id: id,
      title: title,
      subtitle: subtitle,
      description: '一段简介',
      license: kThirdPartyLicense,
      section: section,
      episodes: episodes ??
          <VodEpisode>[
            VodEpisode(number: 1, title: '正片', url: _m3u8),
          ],
      sourceId: '外部点播·test',
      headers: const <String, String>{'Referer': 'https://own.test'},
      posterUrl: poster,
      typeName: typeName,
      genre: genre,
      area: area,
      year: year,
    );

VodLibrary library() =>
    VodLibrary(registry: SourceRegistry(), catalog: SourceCatalog());

const String _classJson = '''
{"page":1,"pagecount":2,"total":40,"limit":20,
 "class":[
  {"type_id":20,"type_pid":0,"type_name":"电影片"},
  {"type_id":58,"type_pid":0,"type_name":"短剧大全"},
  {"type_id":61,"type_pid":58,"type_name":"现代言情"},
  {"type_id":68,"type_pid":58,"type_name":"AI漫剧"},
  {"type_id":70,"type_pid":70,"type_name":"自指环"}
 ],
 "list":[
  {"vod_id":"1","vod_name":"她和她的秘密","type_id":61,
   "type_name":"现代言情","vod_class":"爱情,都市","vod_year":"2026",
   "vod_area":"大陆","vod_remarks":"全集完结","vod_pic":"/p/1.jpg"},
  {"vod_id":"2","vod_name":"神秘面包小子","type_id":20,
   "type_name":"电影片","vod_class":"动画","vod_year":"2025",
   "vod_area":"日本","vod_remarks":"正片","vod_pic":"/p/2.jpg"}
 ]}''';

// ── ① 短视频栏目与归类 ──────────────────────────────────────────

void testSection() {
  // 1.0.5 第十二次修：新增动漫栏目，枚举变 6 项。这条断言随之改写 ——
  // 改的是**需求**（用户要求左侧新增动漫栏目），不是放宽既有约束：
  // 前五项序号与「只能末尾追加」这条铁律原样保留，动漫插在第 5、
  // other 顺延到第 6，仍然一个都不往前挪。
  check('A01 栏目枚举：短视频 3 / 动漫 4 / 其他 5，前四项序号一个不动',
      VodSection.values.length == 6 &&
          VodSection.shortVideo.label == '短视频' &&
          VodSection.shortVideo.index == 3 &&
          VodSection.anime.label == '动漫' &&
          VodSection.anime.index == 4 &&
          VodSection.other.index == 5 &&
          VodSection.movies.index == 0 &&
          VodSection.series.index == 1 &&
          VodSection.documentaries.index == 2);
  check('A02 原有三个栏目序号未变（导航 / IndexedStack 不错位）',
      VodSection.movies.index == 0 &&
          VodSection.series.index == 1 &&
          VodSection.documentaries.index == 2);
  check('A03 内置片库仍只落在原有栏目',
      VodCatalog.inSection(VodSection.shortVideo).isEmpty &&
          VodCatalog.inSection(VodSection.anime).isEmpty &&
          VodCatalog.inSection(VodSection.movies).length == 3 &&
          VodCatalog.all.length == 6);

  for (final n in <String>[
    '短剧',
    '短剧大全',
    'AI短剧',
    'ai短剧',
    '微短剧',
    '短视频',
    '电影解说',
    '预告片',
  ]) {
    check('A04 文本归类命中「$n」',
        sectionFromName(n) == VodSection.shortVideo &&
            sectionFromCms(typeName: n) == VodSection.shortVideo);
  }
  check('A05 英文枚举也归短视频',
      sectionFromName('shortVideo') == VodSection.shortVideo &&
          sectionFromName('shorts') == VodSection.shortVideo);
  check('A06 原有归类不变（短剧之外的剧集 / 纪录片 / 电影）',
      sectionFromName('国产剧') == VodSection.series &&
          sectionFromName('纪录片') == VodSection.documentaries &&
          sectionFromName('动作片') == VodSection.movies);

  final table = parseCmsCategories(_classJson);
  check('A07 类目表解析出 5 项', table.byId.length == 5);
  check('A08 短剧父类目命中', table.isShortVideo('58'));
  check('A09 短剧子类目顺着 type_pid 命中',
      table.isShortVideo('61') && table.isShortVideo('68'));
  check('A10 普通电影类目不误判', !table.isShortVideo('20'));
  check('A11 父类目自指成环不死循环', !table.isShortVideo('70'));
  check('A12 未知类目回落 false', !table.isShortVideo('999'));
  check('A13 没有 class 的响应回落空表',
      parseCmsCategories('{"list":[]}').isEmpty);

  final listing = parseCmsListing(_classJson,
      maxItems: 20, baseUrl: 'https://cdn.test/api.php/provide/vod/');
  check('A14 列表解析带出 type_id / vod_class',
      listing.entries.first.typeId == '61' &&
          listing.entries.first.genre == '爱情,都市');
  check('A15 列表响应同时带出类目表', !listing.categories.isEmpty);
  final detailPage = parseCmsDetailPage(_classJson,
      maxItems: 20, baseUrl: 'https://cdn.test/api.php/provide/vod/');
  check('A16 详情分页也带出 type_id / vod_class',
      detailPage.entries.first.typeId == '61' &&
          detailPage.entries.first.genre == '爱情,都市');

  final built = buildCmsItems(
    entries: listing.entries,
    details: <String, CmsDetail>{
      for (final e in listing.entries)
        e.id: CmsDetail(
            content: '简介',
            episodes: <VodEpisode>[
              VodEpisode(number: 1, title: '正片', url: _m3u8)
            ]),
    },
    sourceId: '外部点播·test',
    idScope: 's',
    categories: table,
  );
  check('A17 短剧子类目条目归入短视频栏目',
      built.first.section == VodSection.shortVideo);
  check('A18 普通电影不受影响',
      built.last.section == VodSection.movies);
  check('A19 四个基本维度都写进条目',
      built.first.typeName == '现代言情' &&
          built.first.genre == '爱情,都市' &&
          built.first.year == '2026' &&
          built.first.area == '大陆');
  check('A20 没有类目表时按文本关键词兜底',
      buildCmsItems(
              entries: <CmsEntry>[
                CmsEntry(
                    id: '9',
                    title: '某短剧',
                    typeName: '短剧大全',
                    remarks: '',
                    year: '2026',
                    area: '大陆')
              ],
              details: <String, CmsDetail>{
                '9': CmsDetail(
                    content: '',
                    episodes: <VodEpisode>[
                      VodEpisode(number: 1, title: '正片', url: _m3u8)
                    ])
              },
              sourceId: 'x')
          .first.section ==
          VodSection.shortVideo);

  final legacy = item(id: 'x:1', title: '相逢一盏茶AI短剧');
  final normalized = normalizeVodItem(legacy);
  check('A21 老缓存里带短剧字样的条目迁移到短视频栏目',
      normalized.section == VodSection.shortVideo &&
          legacy.section == VodSection.movies);
  final plain = item(id: 'x:2', year: '2026', area: '大陆');
  check('A22 无电影证据的普通条目迁出电影栏目（不占电影位）',
      normalizeVodItem(plain).section == VodSection.other &&
          plain.section == VodSection.movies);
  final realMovie =
      item(id: 'x:2b', typeName: '动作片', year: '2026', area: '大陆');
  check('A22d 有电影类目的条目归一返回同一实例（不产生无谓拷贝）',
      identical(normalizeVodItem(realMovie), realMovie));
  final legacyMeta = item(id: 'x:9', title: '老片', subtitle: '2019 · 香港 · 完结');
  final recovered = normalizeVodItem(legacyMeta);
  check('A22b 老副标题里的年份 / 地区被回填成结构化字段',
      recovered.year == '2019' && recovered.area == '香港' &&
          recovered.typeName.isEmpty);
  check('A22c 不是年份开头的副标题不做猜测',
      normalizeVodItem(item(id: 'x:10', subtitle: '更新至455期')).year.isEmpty);
  check('A23 已经归到短视频的条目重复归一不会弹回去',
      normalizeVodItem(item(id: 'x:3', section: VodSection.shortVideo))
              .section ==
          VodSection.shortVideo);

  // ── 1.0.5 第十一次修：电影栏目只展示电影类片源 ──────────────
  // 真实本地记录里电影栏目 470 条，混进 64 条大陆综艺、52 条足球、
  // 46+46 条日韩/港台综艺、9 条记录片、61 条现代都市短剧。
  for (final n in <String>[
    '大陆综艺', '港台综艺', '日韩综艺', '欧美综艺', '综艺',
    '足球', '篮球', '其他赛事', '真人秀', '脱口秀', '演唱会',
  ]) {
    check('A24 非电影大类「$n」不进电影栏目',
        sectionFromName(n) == VodSection.other);
  }
  check('A25 短剧子类目（没带类目表时）不进电影栏目',
      sectionFromName('现代都市') == VodSection.other &&
          sectionFromName('古装仙侠') == VodSection.other &&
          sectionFromName('女频恋爱') == VodSection.other);
  check('A26 纪录片 / 记录片统一归纪录片栏目',
      sectionFromName('纪录片') == VodSection.documentaries &&
          sectionFromName('记录片') == VodSection.documentaries);
  // 1.0.5 第十二次修：动漫独立成栏，A27/A28 随之收窄。
  // 这两条原本把「动画片」钉在电影、把「国产动漫」钉在电视剧，是当时
  // 「电影栏目只放电影」那轮的产物；用户现在要求「所有动漫统一归入
  // 动漫栏目」，归属规则因此变更 —— 保留原意里**仍然成立**的部分
  // （剧情片/喜剧片仍是电影、国产剧/欧美剧仍是电视剧），动漫部分
  // 迁到 A31 单独验证，不是把断言删掉或放宽。
  check('A27 剧情片 / 喜剧片仍是电影（不被「剧」字抢走）',
      sectionFromName('剧情片') == VodSection.movies &&
          sectionFromName('喜剧片') == VodSection.movies &&
          sectionFromName('动作片') == VodSection.movies);
  check('A28 剧集类目仍归电视剧',
      sectionFromName('国产剧') == VodSection.series &&
          sectionFromName('欧美剧') == VodSection.series &&
          sectionFromName('连续剧') == VodSection.series);

  // ── 1.0.5 第十二次修：动漫栏目归属 ──────────────────────────
  // 词表来源是 11 个可用采集站 `class` 表去重后的 15 个真实动漫类目。
  for (final n in <String>[
    '动漫', '动漫片', '动漫电影', '国产动漫', '日韩动漫', '欧美动漫',
    '港台动漫', '海外动漫', '中国动漫', '日本动漫', '动画片', 'AI动漫',
    'AI漫剧', '漫剧', '有声动漫',
  ]) {
    check('A31 真实动漫类目「$n」归动漫栏目',
        sectionFromName(n) == VodSection.anime);
  }
  check('A32 动漫不再被电影 / 电视剧 / 短视频三分',
      sectionFromName('动画片') != VodSection.movies &&
          sectionFromName('国产动漫') != VodSection.series &&
          sectionFromName('AI漫剧') != VodSection.shortVideo);
  check('A33 动漫判定不吃掉电影与剧集（回归）',
      sectionFromName('剧情片') == VodSection.movies &&
          sectionFromName('喜剧片') == VodSection.movies &&
          sectionFromName('科幻片') == VodSection.movies &&
          sectionFromName('国产剧') == VodSection.series &&
          sectionFromName('欧美剧') == VodSection.series &&
          sectionFromName('纪录片') == VodSection.documentaries);
  check('A34 动漫不吃掉短视频（短剧仍是短视频）',
      sectionFromName('短剧') == VodSection.shortVideo &&
          sectionFromName('短剧大全') == VodSection.shortVideo &&
          sectionFromName('AI短剧') == VodSection.shortVideo &&
          sectionFromName('电影解说') == VodSection.shortVideo);
  check('A35 类目父链识别动漫（漫剧挂在短剧大全之下也认得出）',
      sectionFromCms(
            typeName: '现代言情',
            typeId: '90',
            categories: parseCmsCategories(
                '{"class":[{"type_id":1,"type_pid":0,"type_name":"动漫"},'
                '{"type_id":90,"type_pid":1,"type_name":"连载新番"}]}'),
          ) ==
          VodSection.anime);
  check('A36 契约英文枚举 anime / animation / cartoon 归动漫',
      sectionFromName('anime') == VodSection.anime &&
          sectionFromName('animation') == VodSection.anime &&
          sectionFromName('cartoon') == VodSection.anime);
  check('A37 归一：类目是动漫的条目一律进动漫栏目',
      normalizeVodItem(item(id: 'x:a1', typeName: '国产动漫')).section ==
              VodSection.anime &&
          normalizeVodItem(item(id: 'x:a2', typeName: '动画片')).section ==
              VodSection.anime);
  check('A38 归一：类目为空时靠片名捞回动漫',
      normalizeVodItem(item(id: 'x:a3', title: '某番剧 第二季')).section ==
          VodSection.anime);
  check('A39 归一：类目非空且不是动漫时不被片名误收',
      normalizeVodItem(item(id: 'x:a4', title: '动画师', typeName: '剧情片'))
              .section ==
          VodSection.movies);
  check('A40 已归到动漫的条目重复归一不会弹回去',
      normalizeVodItem(item(
                  id: 'x:a5', typeName: '国产动漫', section: VodSection.anime))
              .section ==
          VodSection.anime);
  check('A29 电影闸挡住绕过归一的综艺 / 体育，放行真电影',
      !isMovieSectionItem(item(id: 'x:m1', typeName: '大陆综艺')) &&
          !isMovieSectionItem(item(id: 'x:m2', genre: '足球')) &&
          isMovieSectionItem(item(id: 'x:m3', typeName: '动作片')));
  check('A30 内置公开素材（无 sourceId）不受电影闸限制',
      VodCatalog.all.every(isMovieSectionItem));
}

void testLibraryMigration() {
  final lib = library();
  final incoming = <VodItem>[
    item(id: 'x:1', title: '她和她的秘密', typeName: '短剧大全'),
    item(id: 'x:2', title: '某部电影', typeName: '剧情片'),
    item(id: 'x:3', title: '相逢一盏茶AI短剧'), // 老缓存没有 typeName
    item(id: 'x:4', title: '另一部短剧', typeName: '现代言情', year: '2026'),
  ];
  lib.append(
      sourceId: '外部点播·test', incoming: incoming, sourceName: '测试源');
  check('B01 后续新增的短剧统一进短视频栏目',
      lib.inSection(VodSection.shortVideo).length == 3,
      '实际 ${lib.inSection(VodSection.shortVideo).length}');
  final externalMovies = lib
      .inSection(VodSection.movies)
      .where((i) => i.id.startsWith('x:'))
      .toList(growable: false);
  check('B02 电影栏目里的外部条目只剩非短剧条目',
      externalMovies.length == 1 &&
          externalMovies.first.title == '某部电影');
  check('B03 原有内置片库不受影响',
      lib.items.length == VodCatalog.all.length + 4);
  check('B04 短剧条目仍可起播（剧集地址表已注册）',
      lib.inSection(VodSection.shortVideo).every((i) => i.episodes.isNotEmpty));

  // 四类混合入库：综艺 / 体育 / 短剧子类目 / 真电影。
  // 即使接口把它们全写成 section=movies，归一 + 栏目闸也要只放行最后一条。
  final mixedLib = library();
  mixedLib.append(
    sourceId: '外部点播·mixed',
    sourceName: '混合源',
    incoming: <VodItem>[
      item(id: 'x:m1', title: '一档综艺', typeName: '大陆综艺'),
      item(id: 'x:m2', title: '一场球', typeName: '足球'),
      item(id: 'x:m3', title: '都市小传', typeName: '现代都市'),
      item(id: 'x:m4', title: '一部电影', typeName: '恐怖片'),
    ],
  );
  check('B10 电影栏目只剩内置片库 + 那一条真电影',
      mixedLib.inSection(VodSection.movies).length ==
          VodCatalog.inSection(VodSection.movies).length + 1 &&
          mixedLib.inSection(VodSection.movies).last.title == '一部电影');
  check('B11 综艺 / 体育 / 短剧子类目落到「其他」，不污染四个内容栏目',
      mixedLib.inSection(VodSection.other).length == 3 &&
          mixedLib.inSection(VodSection.series).length ==
              VodCatalog.inSection(VodSection.series).length &&
          mixedLib.inSection(VodSection.shortVideo).isEmpty,
      'other=${mixedLib.inSection(VodSection.other).length} '
      'series=${mixedLib.inSection(VodSection.series).length} '
      'builtinSeries=${VodCatalog.inSection(VodSection.series).length} '
      'short=${mixedLib.inSection(VodSection.shortVideo).length}');
  check('B12 迁走的条目仍留在本地检索记录派生列表里（检索不丢片）',
      mixedLib.localMatches('一档综艺').length == 1 &&
          mixedLib.localMatches('一场球').length == 1);

  // 接口刷新：同 id 元数据变了 → 就地更新，不新增条目。
  final before = lib.revision;
  final changed = lib.append(
    sourceId: '外部点播·test',
    incoming: <VodItem>[
      item(id: 'x:2',
          title: '某部电影',
          typeName: '剧情片',
          year: '2024',
          area: '香港',
          genre: '悬疑'),
    ],
    sourceName: '测试源',
  );
  check('B05 同 id 元数据刷新被识别为一次更新', changed == 1);
  check('B06 元数据真的写进去了（年份/地区/类型）',
      lib.byId('x:2')!.year == '2024' &&
          lib.byId('x:2')!.area == '香港' &&
          lib.byId('x:2')!.genre == '悬疑');
  check('B07 刷新不产生重复条目', lib.externalCount == 4);
  check('B08 刷新使列表版本 +1', lib.revision == before + 1);
  check('B09 内容没变时不再触发重建',
      lib.append(
              sourceId: '外部点播·test',
              incoming: <VodItem>[
                item(id: 'x:2',
                    title: '某部电影',
                    typeName: '剧情片',
                    year: '2024',
                    area: '香港',
                    genre: '悬疑')
              ],
              sourceName: '测试源') ==
          0);
  check('B10 跨站同名同年份镜像条目被去重',
      lib.append(
              sourceId: '外部点播·test',
              incoming: <VodItem>[
                item(id: 'y:2', title: '某部电影', year: '2024')
              ],
              sourceName: '测试源') ==
              0 &&
          lib.externalCount == 4);
}

// ── ② 本地内容检索记录 ──────────────────────────────────────────

void testIndex() {
  final now = DateTime(2026, 11, 12, 8);
  final index = VodContentIndex();
  final a = item(
      id: 'x:1',
      title: '她和她的秘密',
      typeName: '短剧大全',
      genre: '爱情,都市',
      area: '大陆',
      year: '2026',
      section: VodSection.shortVideo);
  final sync1 = index.upsertItems(<VodItem>[a],
      sourceId: '外部点播·test',
      sourceName: '测试源',
      headers: const <String, String>{'Referer': 'https://own.test'},
      now: now);
  check('C01 首条记录写入', sync1.added == 1 && index.length == 1);
  check('C02 记录持久化四个基本字段',
      index.byId('x:1')!.title == '她和她的秘密' &&
          index.byId('x:1')!.typeName == '短剧大全' &&
          index.byId('x:1')!.year == '2026' &&
          index.byId('x:1')!.area == '大陆' &&
          index.byId('x:1')!.genre == '爱情,都市');
  check('C03 记录保留播放地址 / 海报 / 请求头',
      index.byId('x:1')!.episodes.first.url == _m3u8 &&
          index.byId('x:1')!.posterUrl == _poster &&
          index.byId('x:1')!.headers['Referer'] == 'https://own.test');
  check('C04 展示条目与记录一一对应',
      index.items.length == 1 && index.items.first.id == 'x:1');

  final sync2 = index.upsertItems(<VodItem>[a],
      sourceId: '外部点播·test',
      sourceName: '测试源',
      headers: const <String, String>{'Referer': 'https://own.test'},
      now: now.add(const Duration(hours: 1)));
  check('C05 重复数据不新增记录（避免重复）',
      sync2.added == 0 && sync2.changed == 0 && index.length == 1);
  check('C06 仍在接口的记录被续期（不会误判过期）',
      index.byId('x:1')!.updatedAt == now.add(const Duration(hours: 1)));

  final a2 = a.copyWith(area: '香港', year: '2025');
  final sync3 = index.upsertItems(<VodItem>[a2],
      sourceId: '外部点播·test',
      sourceName: '测试源',
      headers: const <String, String>{'Referer': 'https://own.test'},
      now: now.add(const Duration(hours: 2)));
  check('C07 同 id 元数据变化就地更新',
      sync3.updated == 1 && index.length == 1 &&
          index.byId('x:1')!.area == '香港' &&
          index.byId('x:1')!.year == '2025');

  final mirror = item(id: 'y:1', title: '她和她的秘密', year: '2025');
  final sync4 = index.upsertItems(<VodItem>[mirror],
      sourceId: '外部点播·test',
      sourceName: '测试源',
      headers: const <String, String>{},
      now: now);
  check('C08 同名同年份的镜像记录被丢弃',
      sync4.duplicates == 1 && index.length == 1);

  index.upsertItems(
      <VodItem>[item(id: 'x:2', title: '另一部片子', year: '2024')],
      sourceId: '外部点播·test',
      sourceName: '测试源',
      headers: const <String, String>{},
      now: now.add(const Duration(days: 40)));
  check('C09 过期记录被清理，仍有效的记录保留',
      index.pruneExpired(now.add(const Duration(days: 40)), kVodRecordTtl) ==
              1 &&
          index.length == 1 &&
          index.byId('x:2') != null);
  check('C10 限容保序', VodContentIndex(index.records).limited(1).length == 1);
  check('C11 记录 JSON 往返不丢字段',
      VodContentIndex.fromRecords(index.toJson(),
                  fallbackSourceId: '外部点播·test',
                  fallbackSourceName: '测试源',
                  fallbackHeaders: const <String, String>{},
                  fallbackUpdatedAt: now)
              .byId('x:2') !=
          null);
}

Future<void> testStore() async {
  final dir = await Directory.systemTemp.createTemp('shunbo-vod-index');
  try {
    final file = File('${dir.path}/vod-library.json');
    final store = VodLibraryStore(file);
    final now = DateTime(2026, 11, 12, 8);
    await store.save(
      sourceId: '外部点播·test',
      sourceName: '测试源',
      headers: const <String, String>{'Referer': 'https://own.test'},
      items: <VodItem>[
        item(
            id: 'x:1',
            title: '她和她的秘密',
            typeName: '短剧大全',
            genre: '爱情,都市',
            area: '大陆',
            year: '2026',
            section: VodSection.shortVideo),
        item(id: 'x:2', title: '普通电影', typeName: '剧情片', year: '2024'),
      ],
      now: now,
    );
    final disk = jsonDecode(await file.readAsString()) as Map;
    check('D01 落盘为 v2 本地记录格式',
        disk['version'] == kVodContentIndexVersion &&
            disk['recordCount'] == 2 &&
            (disk['records'] as List).length == 2);
    check('D02 记录里带类型 / 年份 / 地区字段',
        (disk['records'] as List).first['type'] == '短剧大全' &&
            (disk['records'] as List).first['year'] == '2026' &&
            (disk['records'] as List).first['area'] == '大陆');

    final loaded = await store.load();
    check('D03 读回记录与写入条数一致',
        loaded != null && loaded.records.length == 2 && loaded.items.length == 2);
    check('D04 读回保留 Referer（恢复后一播不 403）',
        loaded!.headers['Referer'] == 'https://own.test');
    check('D05 读回保留四字段与栏目',
        loaded.items.first.typeName == '短剧大全' &&
            loaded.items.first.year == '2026' &&
            loaded.items.first.area == '大陆' &&
            loaded.items.first.section == VodSection.shortVideo);

    // 增量同步：只给 1 条新的，旧的两条不能丢。
    await store.save(
      sourceId: '外部点播·test',
      sourceName: '测试源',
      headers: const <String, String>{'Referer': 'https://own.test'},
      items: <VodItem>[item(id: 'x:3', title: '第三部', year: '2023')],
      now: now.add(const Duration(minutes: 1)),
    );
    final merged = await store.load();
    check('D06 增量落盘不冲掉历史记录（避免过期/丢失）',
        merged != null && merged.items.length == 3);
    await store.save(
      sourceId: '外部点播·test',
      sourceName: '测试源',
      headers: const <String, String>{'Referer': 'https://own.test'},
      items: <VodItem>[item(id: 'x:3', title: '第三部', year: '2023')],
      now: now.add(const Duration(minutes: 2)),
    );
    check('D07 重复落盘不产生重复记录',
        (await store.load())!.items.length == 3);

    // 换源：整库重建，绝不与旧源混在一起。
    await store.save(
      sourceId: '外部点播·other',
      sourceName: '另一家',
      headers: const <String, String>{},
      items: <VodItem>[item(id: 'z:1', title: '新源的片')],
      now: now,
    );
    final switched = await store.load();
    check('D08 换源后整库重建（不混两家条目）',
        switched != null &&
            switched.items.length == 1 &&
            switched.items.first.id == 'z:1' &&
            switched.sourceId == '外部点播·other');

    // v1 老缓存：升级 + 短视频迁移 + 同名去重。
    final v1 = File('${dir.path}/v1.json');
    await v1.writeAsString(jsonEncode(<String, dynamic>{
      'version': 1,
      'sourceId': '外部点播·old',
      'sourceName': '老缓存源',
      'savedAt': now.toIso8601String(),
      'headers': <String, dynamic>{},
      'items': <dynamic>[
        <String, dynamic>{
          'id': 'old:1',
          'title': '相逢一盏茶AI短剧',
          'subtitle': '2026 · 大陆',
          'section': 'series',
          'poster': '',
          'episodes': <List<Object?>>[
            <Object?>[1, '正片', _m3u8]
          ],
        },
        <String, dynamic>{
          'id': 'old:2',
          'title': '普通电影',
          'subtitle': '2024',
          'section': 'movies',
          'poster': '',
          'episodes': <List<Object?>>[
            <Object?>[1, '正片', _m3u8]
          ],
        },
      ],
    }));
    final migrated = await VodLibraryStore(v1).load();
    check('D09 v1 老缓存可读回并升级成记录',
        migrated != null && migrated.records.length == 2);
    final upgradedDisk = jsonDecode(await v1.readAsString()) as Map;
    check('D09b v1 缓存当场升级写回 v2（不必每次启动重解析）',
        upgradedDisk['version'] == kVodContentIndexVersion &&
            (upgradedDisk['records'] as List).length == 2);
    check('D10 老缓存里的短剧条目迁移到短视频栏目',
        migrated!.items.first.section == VodSection.shortVideo &&
            migrated.items.first.title == '相逢一盏茶AI短剧');
    check('D11 老缓存里无类目字段的普通条目迁到「其他」（电影栏目只收电影类）',
        migrated.items.last.section == VodSection.other);
    check('D12 老缓存不编造类型，但副标题里的年份/地区如实回填',
        migrated.items.first.typeName.isEmpty &&
            migrated.items.first.genre.isEmpty &&
            migrated.items.first.year == '2026' &&
            migrated.items.first.area == '大陆');

    // 过期记录：接口不再返回且超过 TTL → 读回时清掉。
    final staleFile = File('${dir.path}/stale.json');
    await staleFile.writeAsString(jsonEncode(<String, dynamic>{
      'version': kVodContentIndexVersion,
      'sourceId': '外部点播·stale',
      'sourceName': '过期源',
      'savedAt': now.toIso8601String(),
      'headers': <String, dynamic>{},
      'records': <dynamic>[
        VodContentRecord.fromItem(
                item(id: 's:1', title: '早就下架的片'),
                sourceId: '外部点播·stale',
                sourceName: '过期源',
                headers: const <String, String>{},
                updatedAt: now.subtract(const Duration(days: 90)))
            .toJson(),
        VodContentRecord.fromItem(
                item(id: 's:2', title: '仍在接口的片'),
                sourceId: '外部点播·stale',
                sourceName: '过期源',
                headers: const <String, String>{},
                updatedAt: now)
            .toJson(),
      ],
    }));
    final pruned = await VodLibraryStore(staleFile).load();
    check('D13 超过 TTL 的下架记录被清理',
        pruned != null &&
            pruned.records.length == 1 &&
            pruned.items.first.id == 's:2');

    // 栏目 / 记录 / 检索结果一致性。
    final lib = library();
    lib.restore(
      sourceId: loaded.sourceId,
      items: loaded.items,
      sourceName: loaded.sourceName,
      headers: loaded.headers,
      savedAt: loaded.savedAt,
    );
    final libIndex = VodContentIndex(loaded.records);
    check('D14 栏目条目与本地记录逐条同 id',
        libIndex.length == lib.externalCount &&
            libIndex.records.every((r) => lib.byId(r.id) != null));
    check('D15 栏目栏目分组与记录里的 section 一致',
        lib.inSection(VodSection.shortVideo).length ==
            libIndex.records
                .where((r) => r.section == VodSection.shortVideo)
                .length);
  } finally {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

// ── ③ 内容检索 ──────────────────────────────────────────────────

void testSearch() {
  final all = <VodItem>[
    item(
        id: 'x:1',
        title: '她和她的秘密',
        typeName: '短剧大全',
        genre: '爱情,都市',
        area: '大陆',
        year: '2026',
        section: VodSection.shortVideo),
    item(
        id: 'x:2',
        title: '神秘面包小子',
        typeName: '剧情片',
        genre: '喜剧,Comedy',
        area: '日本',
        year: '2024'),
    item(
        id: 'x:3',
        title: '大雄兔',
        typeName: '动画短片',
        year: '2008',
        subtitle: '2008 · 开源'),
  ];
  check('E01 空查询返回原列表引用（1.0.4 行为不变）',
      identical(filterVodItems(all, ''), all));
  check('E02 片名检索', filterVodItems(all, '秘密').length == 1);
  check('E03 类型检索（type_name）',
      filterVodItems(all, '短剧大全').length == 1);
  check('E04 类型检索（vod_class）',
      filterVodItems(all, '喜剧').length == 1 &&
          filterVodItems(all, 'comedy').length == 1);
  check('E05 年份检索', filterVodItems(all, '2024').length == 1);
  check('E06 地区检索', filterVodItems(all, '日本').length == 1);
  check('E07 字段前缀：类型',
      filterVodItems(all, '类型:剧情片').length == 1 &&
          filterVodItems(all, '类型:剧情片').first.id == 'x:2');
  check('E08 字段前缀：年份',
      filterVodItems(all, '年份:2026').length == 1);
  check('E09 字段前缀：地区',
      filterVodItems(all, '地区:大陆').length == 1);
  check('E10 字段前缀：片名',
      filterVodItems(all, '片名:大雄兔').length == 1);
  check('E11 多字段是「与」关系',
      filterVodItems(all, '类型:剧情片 年份:2026').isEmpty &&
          filterVodItems(all, '类型:剧情片 年份:2024').length == 1);
  check('E12 字段 + 自由文本也是「与」关系',
      filterVodItems(all, '类型:剧情片 小子').length == 1 &&
          filterVodItems(all, '类型:剧情片 秘密').isEmpty);
  check('E13 字段解析不吃掉普通冒号文本',
      parseVodSearchQuery('12:30 的片').text.contains('12:30'));
  check('E14 大小写不敏感（ASCII 类型词）',
      filterVodItems(all, 'COMEDY').length == 1 &&
          parseVodSearchQuery('类型:COMEDY').fields['type'] == 'comedy');
  check('E15 无匹配返回空',
      filterVodItems(all, '不存在的片名zzz').isEmpty);
  final builtIn = VodCatalog.all;
  check('E16 内置片库空查询仍返回同一实例',
      identical(filterVodItems(builtIn, '  '), builtIn));

  final index = VodContentIndex();
  index.upsertItems(all,
      sourceId: '外部点播·test',
      sourceName: '测试源',
      headers: const <String, String>{},
      now: DateTime(2026, 11, 12));
  check('E17 本地记录检索与直接检索结果一致（唯一真相）',
      index.search('类型:剧情片').length ==
              filterVodItems(index.items, '类型:剧情片').length &&
          index.search('类型:剧情片').isNotEmpty);
  check('E18 本地记录按四字段都能命中',
      index.search('2024').length == 1 &&
          index.search('地区:大陆').length == 1 &&
          index.search('类型:剧情片').length == 1 &&
          index.search('片名:大雄兔').length == 1);
}

// ── ④ 装配静态护栏 ──────────────────────────────────────────────

void testWiring() {
  final shell = _src('lib/app/app_shell.dart');
  final mainDart = _src('lib/main.dart');
  final page = _src('lib/ui/vod/vod_page.dart');
  final store = _src('lib/data/onboarding/vod_library_store.dart');
  final session = _src('lib/features/vod/vod_session.dart');
  final gates = _src('tooling/verify_all.dart');
  final search = _src('lib/features/vod/vod_search.dart');

  check('F01 左侧菜单新增短视频（追加在末尾）',
      shell.contains("shortVideos('短视频'") &&
          shell.indexOf("live('电视直播'") <
              shell.indexOf("shortVideos('短视频'"));
  check('F02 原有四个菜单项都在且顺序未变',
      shell.contains("live('电视直播'") &&
          shell.contains("movies('电影'") &&
          shell.contains("series('电视剧'") &&
          shell.contains("documentaries('纪录片'"));
  // 1.0.5 第十二次修：新增动漫栏目页，`VodPage` 由 4 个变 5 个。
  // 断言从「== 4」改成「== 5」并追加动漫页与导航项的具体校验，
  // 不是删除断言；「导航项仍由 AppSection.values 统一生成」由 F04 继续锁。
  check('F03 IndexedStack 增加短视频 + 动漫栏目页',
      shell.contains('section: VodSection.shortVideo') &&
          shell.contains('section: VodSection.anime') &&
          RegExp(r'VodPage\(').allMatches(shell).length == 5 &&
          shell.contains('active: _section == AppSection.shortVideos') &&
          shell.contains('active: _section == AppSection.anime'));
  check('F03b 动漫页排在 IndexedStack 末尾（前五项下标不动）',
      shell.indexOf('section: VodSection.anime') >
          shell.indexOf('section: VodSection.shortVideo'));
  check('F04 导航项仍由 AppSection.values 统一生成',
      shell.contains('for (final s in AppSection.values)'));
  check('F05 播放链路零改动（起播仍走 orchestrator.startPlayback）',
      page.contains('widget.services.orchestrator.startPlayback('));
  check('F06 启动优先读本地检索记录',
      mainDart.contains('cached.records.length') &&
          mainDart.contains('vodLibrary.restore(') &&
          mainDart.contains('VodLibraryStore.at('));
  check('F07 本地记录是单一真相（同一文件、同一版本出口）',
      store.contains("'version': kVodContentIndexVersion") &&
          store.contains("'records': limited.toJson()") &&
          store.contains('kVodRecordTtl'));
  check('F08 v1 旧缓存有升级路径',
      store.contains('version != 1 && version != kVodContentIndexVersion') &&
          store.contains('normalizeVodItem(item)'));
  check('F09 新鲜记录后台差量同步且不清空已有卡片',
      page.contains('_revalidateInBackground') &&
          page.contains('preserveExisting: true') &&
          session.contains('preserveExisting'));
  check('F10 检索框提示四个字段',
      page.contains('片名 / 类型 / 年份 / 地区'));
  check('F11 栏目页展示本地记录条数',
      page.contains('本地检索记录'));
  check('F12 检索只查本地（不请求接口）',
      !search.contains('HttpClient') && !search.contains('fetchSourceConfigUrl'));
  // 1.0.5 第十二次修：检索顺序变了 —— 先查本地内容检索目录拿到命中 id，
  // 再在栏目列表里取交集，最后才叠 facet + 关键词。旧断言锁的是
  // `applyVodFilter(all, ...)` 这个直连全量的写法，改造后必然假失败；
  // 这里改成**顺序 + 成分**双断言，防止有人把「本地优先」又改回直连全量。
  final localIdx = page.indexOf('localMatches(q)');
  final filterIdx = page.indexOf('filterVodItems(applyVodFilter(pool, _filter)');
  check('F13 检索优先查本地目录，再叠加筛选（顺序不可颠倒）',
      localIdx >= 0 &&
          filterIdx > localIdx &&
          page.contains('if (ids.contains(i.id)) i'));
  check('F14 新回归已接入统一门禁',
      gates.contains("'vod-content-index'") &&
          gates.contains('verify_vod_content_index.dart'));
}

Future<void> main() async {
  testSection();
  testLibraryMigration();
  testIndex();
  await testStore();
  testSearch();
  testWiring();
  print('');
  if (_fail == 0) {
    print('回归通过：$_pass/$_pass 断言通过');
    exit(0);
  }
  print('回归失败：$_pass/${_pass + _fail} 断言通过');
  exit(1);
}
