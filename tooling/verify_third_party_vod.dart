// 1.0.5 第三方点播数据接入回归（G1 真正出数据 / 能播放）。
//
// 四层：
//   ① 纯数据协议解析——契约 JSON、CMS 列表/详情/播放地址、安全过滤；
//   ② 离线端到端——注入 fetcher，走完整 import() → VodLibrary →
//      SourceRegistry.resolvePlayUrl()，证明「配置能变成可播放地址」；
//   ③ 安全护栏——不执行外部代码、不内置第三方地址、明文 http 默认拒绝；
//   ④ 1.0.4 行为不变——内置片库 6 条、默认 sourceId、空查询顺序。
//
// 运行：dart run tooling/verify_third_party_vod.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shunbo/core/scheduler/source_catalog.dart';
import 'package:shunbo/core/source/source_registry.dart';
import 'package:shunbo/data/onboarding/source_config_url.dart';
import 'package:shunbo/data/onboarding/third_party_vod_service.dart';
import 'package:shunbo/data/onboarding/vod_source_address.dart';
import 'package:shunbo/features/vod/third_party_vod.dart';
import 'package:shunbo/features/vod/vod_auto_source.dart';
import 'package:shunbo/features/vod/vod_catalog.dart';
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

String _src(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

const String _configUrl = 'https://vod.example.test/config.json';
const String _contractUrl = 'https://vod.example.test/contract.json';
const String _pluginUrl = 'https://vod.example.test/plugin.json';
const String _cmsApi = 'https://cms.example.test/api.php/provide/vod/?ac=list';
const String _media1 = 'https://cdn.example.test/a.m3u8';
const String _media2 = 'https://cdn.example.test/e1.m3u8';
const String _media3 = 'https://cdn.example.test/e2.m3u8';

String _cmsConfig() => jsonEncode(<String, dynamic>{
      'name': '测试采集配置',
      'sites': <dynamic>[
        <String, dynamic>{
          'key': 'cms1',
          'name': '采集一',
          'type': 1,
          'api': _cmsApi,
        },
        <String, dynamic>{
          'key': 'plug',
          'name': '插件站',
          'type': 3,
          'api': 'csp_AppRJ',
          'ext': 'https://gitee.com/x/starlink.jar',
        },
      ],
    });

String _contractConfig() => jsonEncode(<String, dynamic>{
      'name': '自有片库',
      'headers': <String, dynamic>{
        'Referer': 'https://own.example.test',
        'Cookie': 'secret=1',
        'Host': 'evil.example.test',
      },
      'items': <dynamic>[
        <String, dynamic>{
          'id': 'm1',
          'title': '合规影片',
          'subtitle': '2026',
          'description': '简介',
          'license': '自有授权',
          'section': 'movies',
          'episodes': <dynamic>[
            <String, dynamic>{
              'number': 1,
              'title': '正片',
              'url': _media1,
            },
          ],
        },
        <String, dynamic>{
          'id': 'bad',
          'title': '非法地址',
          'section': 'series',
          'episodes': <dynamic>[
            <String, dynamic>{
              'number': 1,
              'title': 'x',
              'url': 'file:///etc/passwd',
            },
            <String, dynamic>{
              'number': 2,
              'title': 'y',
              'url': 'javascript:alert(1)',
            },
          ],
        },
      ],
    });

Map<String, String> _pages() {
  final site = CmsSite(key: 'cms1', name: '采集一', api: _cmsApi);
  return <String, String>{
    _configUrl: _cmsConfig(),
    _contractUrl: _contractConfig(),
    _pluginUrl: jsonEncode(<String, dynamic>{
      'spider': 'https://gitee.com/x/starlink.jar',
      'sites': <dynamic>[
        <String, dynamic>{
          'key': 'p',
          'name': '插件站',
          'type': 3,
          'api': 'csp_X',
        },
      ],
    }),
    site.listUrl: jsonEncode(<String, dynamic>{
      'code': 1,
      'msg': '数据列表',
      'list': <dynamic>[
        <String, dynamic>{
          'vod_id': '1',
          'vod_name': '示例电影',
          'type_name': '动作片',
          'vod_year': '2025',
          'vod_area': '美国',
          'vod_remarks': 'HD',
        },
        <String, dynamic>{
          'vod_id': '2',
          'vod_name': '示例剧集',
          'type_name': '国产剧',
          'vod_year': '2024',
          'vod_area': '中国',
          'vod_remarks': '更新至2集',
        },
      ],
    }),
    site.detailPageUrl(1): jsonEncode(<String, dynamic>{
      'code': 1,
      'page': 1,
      'pagecount': 3,
      'limit': '20',
      'total': 60,
      'list': <dynamic>[
        <String, dynamic>{
          'vod_id': '1',
          'vod_name': '示例电影',
          'type_name': '动作片',
          'vod_year': '2025',
          'vod_area': '美国',
          'vod_remarks': 'HD',
          'vod_content': '<p>一段简介</p>',
          'vod_play_url': '正片\$$_media1',
        },
        <String, dynamic>{
          'vod_id': '2',
          'vod_name': '示例剧集',
          'type_name': '国产剧',
          'vod_year': '2024',
          'vod_area': '中国',
          'vod_remarks': '更新至2集',
          'vod_content': '剧情',
          'vod_play_url': '第1集\$$_media2#第2集\$$_media3',
        },
      ],
    }),
    site.detailUrl(<String>['1', '2']): jsonEncode(<String, dynamic>{
      'code': 1,
      'list': <dynamic>[
        <String, dynamic>{
          'vod_id': '1',
          'vod_content': '<p>一段简介</p>',
          'vod_play_url': '正片\$$_media1',
        },
        <String, dynamic>{
          'vod_id': '2',
          'vod_content': '剧情',
          'vod_play_url': '第1集\$$_media2#第2集\$$_media3\$\$\$备用源\$https://x/b.m3u8',
        },
      ],
    }),
  };
}

// ── ① 纯数据协议解析 ────────────────────────────────────────────

void testContractParsing() {
  final scan = scanVodConfigText(_contractConfig(), sourceId: '外部点播·test');
  check('A01 契约配置识别为 contract', scan.kind == VodConfigKind.contract);
  check('A02 契约可用', scan.usable);
  check('A03 只产出 1 部（非法协议地址整条丢弃）',
      scan.contractItems.length == 1, '实际 ${scan.contractItems.length}');
  final item = scan.contractItems.first;
  check('A04 条目 id 带源前缀', item.id == '外部点播·test:m1');
  check('A05 条目 sourceId 指向外部源', item.sourceId == '外部点播·test');
  check('A06 播放地址保留', item.episodes.first.url == _media1);
  check('A07 栏目映射 movies', item.section == VodSection.movies);
  check('A08 只保留 Referer（Cookie / Host 被丢弃）',
      scan.headers.length == 1 && scan.headers.containsKey('Referer'));
  check('A09 授权说明沿用配置值', item.license == '自有授权');

  final empty = scanVodConfigText(
      jsonEncode(<String, dynamic>{'items': <dynamic>[]}),
      sourceId: 'x');
  check('A10 空 items 报明确原因',
      empty.kind == VodConfigKind.malformed &&
          empty.reason.contains('没有一条带可播放地址'));

  final html = scanVodConfigText('<!DOCTYPE html><html>接口分发站</html>',
      sourceId: 'x');
  check('A11 HTML 页面不再被误报成超限',
      html.kind == VodConfigKind.malformed &&
          html.reason.contains('不是合法 JSON'));

  final plugin = scanVodConfigText(_pages()[_pluginUrl]!, sourceId: 'x');
  check('A12 纯插件配置判为 pluginOnly',
      plugin.kind == VodConfigKind.pluginOnly);
  check('A13 插件配置给出「不运行外部代码」原因',
      plugin.reason.contains('不运行外部代码'));
  check('A14 插件站点计数正确', plugin.totalSites == 1);

  final cms = scanVodConfigText(_cmsConfig(), sourceId: 'x');
  check('A15 TVBox 配置识别为 cmsSites', cms.kind == VodConfigKind.cmsSites);
  check('A16 只提取 1 个 type:1 采集站', cms.sites.length == 1);
  check('A17 插件站点被跳过并计数', cms.pluginSites == 1);
  check('A18 采集站 api 保留', cms.sites.first.api == _cmsApi);
  check('A19 采集站 key 保留', cms.sites.first.key == 'cms1');
  check('A20 listUrl 生成 ac=list', cms.sites.first.listUrl.contains('ac=list'));
  check('A21 detailUrl 生成 ac=detail 且 ids 用裸逗号',
      cms.sites.first.detailUrl(<String>['1', '2']).contains('ac=detail') &&
          cms.sites.first
              .detailUrl(<String>['1', '2'])
              .contains('ids=1,2'));
  check('A22 detailUrl 不含 %2C',
      !cms.sites.first.detailUrl(<String>['1', '2']).contains('%2C'));
}

void testPlayUrlParsing() {
  final eps = parseVodPlayUrl('第1集\$$_media2#第2集\$$_media3');
  check('B01 解析出 2 集', eps.length == 2);
  check('B02 第 1 集标题与地址',
      eps[0].title == '第1集' && eps[0].url == _media2);
  check('B03 第 2 集编号与地址',
      eps[1].number == 2 && eps[1].url == _media3);

  // 1.0.5 第三次修：`$$$` 分隔的是**多个播放源**，原来只取第一个，
  // 于是「首源是 /share 网页、次源才是真 m3u8」的站被整站判死（实测电影天堂）。
  // 现在逐源打分，取「直链最多」的那个源。
  final multi = parseVodPlayUrl(
      '第1集\$https://vip.test/share/abc\$\$\$第1集\$$_media2');
  check(r'B04 $$$ 取直链最多的播放源（不是盲取第一个）',
      multi.length == 1 && multi.first.url == _media2);

  final bare = parseVodPlayUrl(_media1);
  check('B05 裸 URL 单集电影可解析',
      bare.length == 1 && bare.first.url == _media1);
  check('B06 裸 URL 默认标题', bare.first.title == '第 1 集');

  final mixed = parseVodPlayUrl(
      '第1集\$file:///etc/passwd#第2集\$javascript:alert(1)#第3集\$$_media1');
  check('B07 非法协议被过滤', mixed.length == 1);
  check('B08 过滤后仍保留合法媒体',
      mixed.isNotEmpty && mixed.first.url == _media1);

  check('B09 空播放串返回空', parseVodPlayUrl('').isEmpty);
  check('B10 m3u8 判为直接媒体', looksLikeDirectMedia(_media1));
  check('B11 share 跳转页不判为直接媒体',
      !looksLikeDirectMedia('https://vip.example.test/share/abcdef'));
  check('B12 带 query 的 m3u8 仍判为直接媒体',
      looksLikeDirectMedia('$_media1?token=abc'));
  check('B13 media 判定先过安全校验',
      !looksLikeDirectMedia('file:///a.m3u8'));

  check('B14 纪录片归类',
      sectionFromName('纪录片') == VodSection.documentaries);
  check('B15 剧集归类', sectionFromName('国产剧') == VodSection.series);
  check('B16 英文枚举归类', sectionFromName('movies') == VodSection.movies);
  check('B17 电影归类', sectionFromName('动作片') == VodSection.movies);
}

void testCmsParsing() {
  final pages = _pages();
  final site = CmsSite(key: 'cms1', name: '采集一', api: _cmsApi);
  final entries = parseCmsList(pages[site.listUrl]!);
  check('C01 列表解析出 2 条', entries.length == 2);
  check('C02 列表字段正确',
      entries.first.id == '1' && entries.first.title == '示例电影');
  final details = parseCmsDetails(pages[site.detailUrl(<String>['1', '2'])]!);
  check('C03 详情解析出 2 条', details.length == 2);
  check('C04 详情正文去掉 HTML 标签',
      details['1']!.content == '一段简介');
  check('C05 详情剧集数', details['2']!.episodes.length == 2);
  final items = buildCmsItems(
      entries: entries,
      details: details,
      sourceId: '外部点播·test',
      idScope: 'cms1');
  check('C06 合并出 2 部', items.length == 2);
  check('C07 idScope 防止跨站撞 id',
      items.first.id == '外部点播·test:cms1:1');
  check('C08 剧集归类正确', items.last.section == VodSection.series);
  check('C09 授权说明标明第三方责任',
      items.first.license == kThirdPartyLicense);
  check('C10 空详情不会产出条目',
      buildCmsItems(
              entries: entries,
              details: const <String, CmsDetail>{},
              sourceId: 'x')
          .isEmpty);
  check('C11 上限常量存在且合理',
      // 分页接入后 360 不再是「一次导入多少」，而是进程内条目的安全天花板。
      kMaxThirdPartyItems == 20000 &&
          kMaxThirdPartyEpisodes == 200 &&
          // 需求：站点上限 100（原 32 会让第 33 名以后的可片站从未被请求）。
          kMaxThirdPartySites == 100 &&
          kMaxThirdPartyItemsPerSite == 20 &&
          kVodItemsPerSitePage == 20 &&
          // 落盘容量：按实测体积定档（2500 条 5.9 MB / 解码 29–46 ms ⇒
          // 10000 条约 24 MB / 解码 130–190 ms），不与内存天花板 20000 对齐。
          kVodCacheMaxItems == 10000 &&
          kVodCacheMaxItems < kMaxThirdPartyItems);
}

void testUrlSafety() {
  check('D01 https 媒体通过', safeMediaUrl(_media1));
  check('D02 http 媒体通过', safeMediaUrl('http://cdn.test/a.m3u8'));
  check('D03 file 协议拒绝', !safeMediaUrl('file:///etc/passwd'));
  check('D04 javascript 拒绝', !safeMediaUrl('javascript:alert(1)'));
  check('D05 内嵌账密拒绝', !safeMediaUrl('https://u:p@cdn.test/a.m3u8'));
  check('D06 控制字符拒绝', !safeMediaUrl('https://cdn.test/a\n.m3u8'));
  check('D07 空 host 拒绝', !safeMediaUrl('https:///a.m3u8'));
  check('D08 超长 URL 拒绝',
      !safeMediaUrl('https://cdn.test/${'a' * 3000}.m3u8'));
  final h = safePlaybackHeaders(<String, dynamic>{
    'Referer': 'https://own.test',
    'User-Agent': 'Mozilla/5.0',
    'Cookie': 'x=1',
    'Authorization': 'Bearer y',
    'Host': 'evil',
  });
  check('D09 只保留 2 个反盗链头', h.length == 2);
  check('D10 头名规范化',
      h.containsKey('Referer') && h.containsKey('User-Agent'));
  check('D11 Cookie / Authorization / Host 全丢弃',
      !h.containsKey('Cookie') &&
          !h.containsKey('Authorization') &&
          !h.containsKey('Host'));

  // 1.0.5 第三次修：一部分采集站在 vod_play_url 里给的是 /play/<id> 播放页。
  // 实测 xluuss / jisuzyv / huyall 三站 `<页>/index.m3u8` 均返回 200 + #EXTM3U，
  // 而 /share/<hash> 型（ukubf3 / dytt-tvs / lzcdn27）返回 404 或另一张网页。
  // 派生只是猜地址，调用方必须先验一条再整站采用（见 D15 的注释口径）。
  check('D12 /play/<id> 播放页可派生 index.m3u8',
      deriveDirectMediaUrl('https://play.xluuss.com/play/egJxDXYd') ==
          'https://play.xluuss.com/play/egJxDXYd/index.m3u8');
  check('D13 /share/<hash> 不派生（实测不成立）',
      deriveDirectMediaUrl('https://v.lzcdn27.com/share/fce1eab44') == null &&
          deriveDirectMediaUrl('https://vip.dytt-tvs.com/share/4a643e03') == null);
  check('D14 已是直链或非 /play/ 路径不派生',
      deriveDirectMediaUrl('https://cdn.test/a/index.m3u8') == null &&
          deriveDirectMediaUrl('https://cdn.test/vod/123') == null &&
          deriveDirectMediaUrl('file:///play/x') == null &&
          deriveDirectMediaUrl('') == null);
  check('D15 派生保留 query（拼在路径后而不是 query 后）',
      deriveDirectMediaUrl('https://p.test/play/abc?token=1') ==
          'https://p.test/play/abc/index.m3u8?token=1');
  check('D16 带扩展名的末段不当作播放页',
      deriveDirectMediaUrl('https://p.test/play/abc.html') == null &&
          deriveDirectMediaUrl('https://p.test/play/abc/') == null);
}

// ── ② 离线端到端 ────────────────────────────────────────────────

VodTextFetcher _fakeFetcher(Map<String, String> pages) =>
    (String url, {bool allowInsecureHttp = false}) async {
      final text = pages[url];
      if (text == null) {
        return SourceConfigUrlResult.fail(
            SourceConfigUrlFailure.httpStatus, '离线样本未命中：$url');
      }
      return SourceConfigUrlResult.ok(
          text: text, originLabel: 'example.test', bytes: text.length);
    };

Future<void> testEndToEnd() async {
  final pages = _pages();
  final svc = ThirdPartyVodService(fetcher: _fakeFetcher(pages));

  final cms = await svc.import(url: _configUrl, allowInsecureHttp: false);
  check('E01 CMS 配置导入成功', cms.ok, cms.message);
  check('E02 产出 2 部可播放条目', cms.items.length == 2);
  check('E03 第一部播放地址正确',
      cms.items.first.episodes.first.url == _media1);
  check('E04 源 id 由配置地址派生',
      cms.sourceId.contains('vod.example.test'));
  check('E05 成功提示含「已加入点播栏目」',
      cms.message.contains('已加入点播栏目'));
  check('E06 插件站点跳过数正确', cms.skippedSites == 1);
  check('E07 成功站点数正确', cms.loadedSites == 1);

  final contract =
      await svc.import(url: _contractUrl, allowInsecureHttp: false);
  check('E08 契约配置导入成功', contract.ok, contract.message);
  check('E09 契约产出 1 部', contract.items.length == 1);
  check('E10 契约 Referer 透传',
      contract.headers['Referer'] == 'https://own.example.test');

  final plugin = await svc.import(url: _pluginUrl, allowInsecureHttp: false);
  check('E11 纯插件配置明确失败', !plugin.ok);
  check('E12 失败原因点明「不运行外部代码」',
      plugin.message.contains('不运行外部代码'));
  check('E13 失败原因给出可操作建议',
      plugin.message.contains('type:1') || plugin.message.contains('契约'));

  final missing =
      await svc.import(url: 'https://missing.test/x.json', allowInsecureHttp: false);
  check('E14 不存在的地址给出失败原因',
      !missing.ok && missing.message.contains('链接导入失败'));

  // VodLibrary：条目真的进栏目、真的能解析出播放地址、清空后能回退。
  final registry = SourceRegistry();
  final catalog = SourceCatalog();
  final lib = VodLibrary(registry: registry, catalog: catalog);
  check('E15 初始只有内置 6 条', lib.items.length == 6);
  check('E16 内置源已注册', registry.get(VodCatalog.sourceId) != null);
  check('E17 内置 profile 已登记',
      catalog.contains(VodCatalog.sourceId));
  check('E18 默认没有外部源', lib.externalCount == 0);

  final installed = lib.install(
    sourceId: cms.sourceId,
    incoming: <VodItem>[
      ...cms.items,
      // 故意与内置片库撞 id：必须被丢弃，不能覆盖 1.0.4 素材。
      VodCatalog.all.first,
    ],
    sourceName: '测试采集接口',
    headers: cms.headers,
  );
  check('E19 撞 id 条目被丢弃，只入库 2 部', installed == 2);
  check('E20 栏目总数 8 条', lib.items.length == 8);
  check('E21 电影栏目含外部条目',
      lib.inSection(VodSection.movies).any((i) => i.sourceId == cms.sourceId));
  check('E22 外部源已注册', registry.get(cms.sourceId) != null);
  check('E23 外部 profile 已登记', catalog.contains(cms.sourceId));
  final adapter = registry.get(cms.sourceId)!;
  final urls = await adapter.resolvePlayUrl(cms.items.first.id, 1);
  check('E24 适配器能解析出播放地址（起播链路闭环）',
      urls.isNotEmpty && urls.first.url == _media1);
  check('E25 空查询顺序仍以 1.0.4 内置片库开头',
      lib.items.first.id == VodCatalog.all.first.id);
  check('E26 1.0.4 检索纯函数仍可用',
      filterVodItems(VodCatalog.inSection(VodSection.movies), '').length == 3);

  lib.clearExternal();
  check('E27 清空后回到 6 条', lib.items.length == 6);
  check('E28 外部源已注销', registry.get(cms.sourceId) == null);
  check('E29 外部 profile 已注销', !catalog.contains(cms.sourceId));
  check('E30 内置源仍在', registry.get(VodCatalog.sourceId) != null);

  // 明文 http：默认拒绝（不发请求，在 scheme 检查阶段就返回）。
  final blocked = await fetchSourceConfigUrl('http://example.test/x.json');
  check('E31 默认拒绝非 loopback 明文 http',
      !blocked.ok &&
          blocked.failure == SourceConfigUrlFailure.insecureTransport);
  check('E32 拒绝原因给出显式放行入口',
      blocked.message.contains('允许明文 http'));
}

// ── ③ 安全护栏 ──────────────────────────────────────────────────

void testSafetyRails() {
  final parser = _src('lib/features/vod/third_party_vod.dart');
  final service = _src('lib/data/onboarding/third_party_vod_service.dart');
  final url = _src('lib/data/onboarding/source_config_url.dart');
  final address = _src('lib/data/onboarding/vod_source_address.dart');
  final section = _src('lib/ui/settings/vod_source_section.dart');
  final page = _src('lib/ui/vod/vod_page.dart');
  final services = _src('lib/app/services.dart');
  final mainDart = _src('lib/main.dart');
  final catalog = _src('lib/features/vod/vod_catalog.dart');
  final mainActivity =
      _src('android/app/src/main/kotlin/com/shunbo/shunbo/MainActivity.kt');

  check('F01 解析层不加载类 / 脚本 / 命令',
      !parser.contains('Process.run') &&
          !parser.contains('Function.apply') &&
          !parser.contains('dart:mirrors'));
  check('F02 服务层不打开 unsafe 后端',
      !service.contains('allowUnsafeBackends: true'));
  check('F03 解析层明确声明零代码执行',
      parser.contains('零代码执行') || parser.contains('不加载任何类'));
  check('F04 jar 通道原生侧仍未注册',
      !mainActivity.contains('shunbo/source_jar'));
  check('F05 下载层明文放行默认 false',
      url.contains('bool allowInsecureHttp = false'));
  check('F06 设置层明文放行默认 false',
      address.contains('this.allowInsecureHttp = false'));
  check('F07 明文放行只作用于点播源链路（E9 默认不变）',
      url.contains('!allowInsecureHttp') &&
          address.contains('allowInsecureHttp: insecure'));
  check('F08 内置片库不混入任何第三方地址',
      !catalog.contains('124.223.214.31') &&
          !catalog.contains('starlink.fan') &&
          !catalog.contains('47.96.82.41'));
  check('F09 启动装配不主动拉取候选地址',
      !mainDart.contains('kVodSourceCandidates'));
  // 第二十一次修：设置页收敛成单输入框，候选列表与并列按钮已删除。
  // 以下断言按新口径改写，安全语义一条不减（不是放宽）。
  check('F10 设置页只有一个输入框，且不回填当前选中',
      section.contains('TextField(') &&
          !section.contains('_input.text = _settings') &&
          (RegExp(r'TextField\(').allMatches(section).length == 1));
  check('F11 设置页有实时输入校验',
      section.contains('_onInputChanged') && section.contains('输入地址校验'));
  check('F12 状态行如实显示当前生效地址（但不预填输入框）',
      section.contains('当前生效：') &&
          section.contains('_settings.effectiveUrl') &&
          section.contains('_input.clear();'));
  check('F13 已知不可用地址在提交前被拦下，不发请求',
      section.contains('if (isKnownUnusableSource(raw))') &&
          section.contains('unavailableReason'));
  check('F13b 明文 http 必须经显式确认才放行（取消则什么都不做）',
      section.contains('_confirmInsecure') &&
          section.contains('放行并获取') &&
          section.contains('if (agreed != true) return;'));
  check('F13c 候选列表 / 一键导入按钮已彻底移除（反向锁死）',
      !section.contains('_pickCandidate') &&
          !section.contains('_runImport(') &&
          !section.contains('for (final c in kVodSourceCandidates)') &&
          !section.contains('SwitchListTile('));
  check('F13d 风险声明未接受时不发请求',
      section.contains('if (!widget.services.onboarding.state.disclaimerAccepted)') &&
          section.contains('请先阅读并接受风险声明'));
  check('F13e 点播取数链路把网页当失败，不再拖到 256 KB 上限才报错',
      service.contains('rejectHtml: true') &&
          url.contains('bool rejectHtml = false') &&
          url.contains('SourceConfigUrlFailure.htmlPage'));
  check('F13f 网页判定可独立回归（纯函数，不发请求）',
      url.contains('bool isHtmlLikePayload('));
  // 1.0.5 第十六次修：播放列表改为「进入点播时校验通过的那一份索引」，
  // 来源唯一。旧断言锁的是 `vodLibrary.inSection`（可变片库），与新需求冲突；
  // 这里改成强度更高的四条：确实从索引池取数、绝不混 inSection、
  // 池子来源必须同时通过「枚举 + 接口地址」两道一致性守卫、状态离开 ready
  // 必须清空列表。不是删除或放宽断言，是把旧口径换成新口径并加护栏。
  check('F14 点播页从索引池取数（列表来源=最终采用的索引）',
      page.contains('final all = sameSource ? _indexPool') &&
          page.contains('_loadIndexPage(') &&
          page.contains('vodIndexGate.ready'));
  check('F14a 列表不再混用 VodLibrary.inSection（来源唯一）',
      !page.contains('vodLibrary.inSection('));
  check('F14b 来源守卫同时校验枚举与接口地址',
      page.contains('_poolOrigin == gate.activeOrigin') &&
          page.contains('_poolSourceUrl == gate.lastUrl'));
  check('F14c 状态离开 ready 即清空列表',
      page.contains('void _resetIndexPool()') &&
          page.contains('_poolSeq++;'));
  check('F15 点播页按条目 sourceId 起播',
      page.contains('item.sourceId'));
  check('F16 点播页监听片库变化',
      page.contains('addListener(_onLibraryChanged)'));
  check('F17 服务容器暴露片库与第三方服务',
      services.contains('final VodLibrary vodLibrary;') &&
          services.contains('final ThirdPartyVodService thirdPartyVod;'));
  check('F18 主程序装配两个新对象',
      mainDart.contains('VodLibrary(registry: registry, catalog: catalog)') &&
          mainDart.contains('ThirdPartyVodService()'));
  check('F19 1.0.4 内置片库仍是 6 条', VodCatalog.all.length == 6);
  check('F20 内置条目 sourceId 恒为内置片库',
      VodCatalog.all.every((i) => i.sourceId == VodCatalog.sourceId));
  check('F21 内置条目不带第三方请求头',
      VodCatalog.all.every((i) => i.headers.isEmpty));
  check('F22 内置适配器 playbackHeaders 默认空',
      VodCatalog.buildAdapter().playbackHeaders.isEmpty);
  check('F23 默认设置仍关闭外部地址与明文放行',
      VodSourceAddressSettings.defaults.enabled == false &&
          VodSourceAddressSettings.defaults.allowInsecureHttp == false);
  check('F24 明文放行后 http 才可接受',
      validateVodSourceAddress('http://example.test/x.json',
              allowInsecureHttp: true)
          .acceptable);
  check('F25 默认口径下 http 仍被拒',
      validateVodSourceAddress('http://example.test/x.json').verdict ==
          VodAddressVerdict.plainHttp);
  check('F26 损坏配置不会悄悄打开外部源',
      VodSourceAddressSettings.fromJson(<String, dynamic>{
        'enabled': 'true',
        'allowInsecureHttp': 'true',
        'selectedUrl': 'http://evil.test/x.json',
      }).enabled ==
          false);
  check('F27 兼容模式/unsafe 后端仍被校验器列为 unsafe',
      _src('lib/data/onboarding/source_config_validator.dart')
          .contains("_unsafeParsers = <String>{'jar', 'quickjs'}"));
}

/// 1.0.5 第三次修：默认加载源 + 输入框不预填。
///
/// 用户要求两件事：① 五条地址实测后把最优的设为默认加载源；
/// ② 设置页的接口地址输入框不要默认显示已填写的地址。
/// 这里锁的是「行为」：只对默认源自动加载、三个栏目页共用一个请求、
/// 输入框由空开始且没有任何回填代码。
Future<void> testDefaultSourceAndAutoLoad() async {
  const defaultUrl = kVodDefaultSourceUrl;

  // ── 单飞：三个栏目页同时进来只发一次请求 ──
  var calls = 0;
  String? expectUrl;
  final started = Completer<void>();
  final release = Completer<void>();
  final auto = VodAutoSource(
    runner: (url,
        {required bool allowInsecureHttp,
        required bool allowExternalCode,
        void Function(VodImportPartial partial)? onProgress}) async {
      calls++;
      expectUrl = url;
      started.complete();
      await release.future;
      return const VodImportReport(
          ok: true, message: 'ok', sourceId: 's', sourceName: 'n');
    },
  );
  final a = auto.ensureLoaded(
      enabled: true,
      selectedUrl: defaultUrl,
      allowInsecureHttp: true,
      alreadyHasItems: false);
  final b = auto.ensureLoaded(
      enabled: true,
      selectedUrl: defaultUrl,
      allowInsecureHttp: true,
      alreadyHasItems: false);
  final c = auto.ensureLoaded(
      enabled: true,
      selectedUrl: defaultUrl,
      allowInsecureHttp: true,
      alreadyHasItems: false);
  await started.future;
  release.complete();
  final results = await Future.wait<VodImportReport?>([a!, b!, c!]);
  check('G01 三个栏目页共用一次请求（单飞）', calls == 1, '实际 $calls 次');
  check('G02 三个 Future 拿到同一份结果',
      results.every((r) => identical(r, results.first)));
  check('G03 自动加载只打默认源', expectUrl == defaultUrl);
  check('G04 尝试过之后 attempted 为真', auto.attempted);

  // ── 不该加载的三种情况 ──
  var skipped = 0;
  final noop = VodAutoSource(runner: (url,
      {required bool allowInsecureHttp,
      required bool allowExternalCode,
      void Function(VodImportPartial partial)? onProgress}) async {
    skipped++;
    return const VodImportReport(ok: true, message: 'x');
  });
  final off = noop.ensureLoaded(
      enabled: false,
      selectedUrl: defaultUrl,
      allowInsecureHttp: true,
      alreadyHasItems: false);
  final other = noop.ensureLoaded(
      enabled: true,
      selectedUrl: 'https://example.test/my.json',
      allowInsecureHttp: true,
      alreadyHasItems: false);
  final hasItems = noop.ensureLoaded(
      enabled: true,
      selectedUrl: defaultUrl,
      allowInsecureHttp: true,
      alreadyHasItems: true);
  check('G05 开关关闭时不自动请求', off == null);
  check('G06 选中的不是默认源时不自动请求', other == null);
  check('G07 片库已有外部条目不重复请求', hasItems == null);
  check('G08 上述三种情况一次请求都没发', skipped == 0);

  // ── 失败不抛出、也不自动重试 ──
  var boomCalls = 0;
  final boom = VodAutoSource(
      runner: (url,
        {required bool allowInsecureHttp,
        required bool allowExternalCode,
        void Function(VodImportPartial partial)? onProgress}) async {
    boomCalls++;
    throw StateError('network down');
  });
  final r1 = await boom.ensureLoaded(
      enabled: true,
      selectedUrl: defaultUrl,
      allowInsecureHttp: true,
      alreadyHasItems: false);
  final r2 = await boom.ensureLoaded(
      enabled: true,
      selectedUrl: defaultUrl,
      allowInsecureHttp: true,
      alreadyHasItems: false);
  check('G09 取数异常不冒泡到栏目页', r1 == null && r2 == null);
  check('G10 失败后不自动重试（进程内只试一次）', boomCalls == 1,
      '实际 $boomCalls 次');

  // ── 设置页：输入框不预填，也不回填 ──
  final section = _src('lib/ui/settings/vod_source_section.dart');
  check('G11 输入框构造时不带初始值（没有 TextEditingController(text:…)）',
      !section.contains('TextEditingController(text:'));
  check('G12 载入设置时显式清空输入框',
      section.contains('_input.clear();') &&
          section.contains('不预填已保存的地址'));
  check('G13 没有任何把 selectedUrl / effectiveUrl 灌进输入框的代码',
      !section.contains('_input.text = _settings') &&
          !section.contains('_input.text = selected') &&
          !section.contains('_input.text = url'));
  // 第二十三次修（用户红标「去除」）：那行说明整个删掉了 —— 输入框下面
  // 紧跟状态行「当前生效：…」，再挂一行解释只是噪音。这里反过来锁死：
  // 说明行不许回来，输入框仍然不回填已有地址。
  check('G14 输入框不再挂说明行（用户红标：去除），且仍不回填已有地址',
      !section.contains('helperText') &&
          !section.contains('不回填当前地址') &&
          section.contains('labelText: \'第三方片源接口地址（输入完成后自动获取）\''));

  // ── 设置页：默认源不再靠开关预选，改由闸门的地址一致性判定复用 ──
  check('G15 设置页不再有开关，默认源由地址一致判定零网络复用',
      !section.contains('_enableWithDefaultSource') &&
          !section.contains('SwitchListTile(') &&
          section.contains('vodIndexGate.submit(') &&
          File('lib/features/vod/vod_index_gate.dart')
              .readAsStringSync()
              .contains('builtin.matches(url)'));
  check('G16 默认地址在生成链路上被双保险拦住（不取数、不写盘）',
      // 第二十六次修：守住的位置不变（`isIndependentSource` 为假就绝不取数），
      // 但不再是静默 `return null` —— 那样闸门会重新判 needAddress 再弹输入页，
      // 形成「对话框一直闪」的循环。现在提前返回一句明确理由。
      File('lib/main.dart').readAsStringSync().contains(
          'if (!vodIndexStore.isIndependentSource(url)) {') &&
          File('lib/main.dart')
              .readAsStringSync()
              .contains('随包默认索引目录不可用'));

  // ── 点播页：按需自动加载 ──
  final page = _src('lib/ui/vod/vod_page.dart');
  check('G17 点播页在进入栏目时触发默认源加载',
      page.contains('_ensureDefaultSource') &&
          page.contains('vodAutoSource.ensureLoaded'));
  check('G18 只在本页真正激活时触发，不在三页同时抢跑',
      page.contains('if (widget.active) {') &&
          page.contains('if (widget.active && !oldWidget.active) {'));
  check('G19 加载中给出可读状态，不当成卡死',
      // 1.0.5 第三次修：文案改成「已接入 N 部 / 接口统计 M 部」，
      // 因为分页后用户要看见进度，而不是一句笼统的「加载中」。
      page.contains('正在加载点播源') &&
          page.contains('已接入 ') &&
          page.contains('_totalHint'));
}

Future<void> main() async {
  testContractParsing();
  testPlayUrlParsing();
  testCmsParsing();
  testUrlSafety();
  await testEndToEnd();
  testSafetyRails();
  await testDefaultSourceAndAutoLoad();
  print('');
  if (_fail == 0) {
    print('回归通过：$_pass/$_pass 断言通过');
    exit(0);
  }
  print('回归失败：$_pass/${_pass + _fail} 断言通过');
  exit(1);
}
