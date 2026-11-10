// 直播「分类切换 + 地方频道按城市 + 购物台剔除 + 卫视归一」回归。
//
// 这一轮改动横跨目录层、纯逻辑层与 UI 状态，全部在这套脚本里用裸 dart run 钉住：
//   ① 购物频道必须从频道表里消失（不是仅隐藏）
//   ② 英文卫视台名归一，与中文索引合并成多线路
//   ③ 中文 group-title 正确归类（卫视 / 地方）
//   ④ 分类固定顺序 + 左右导航到头不越界，少儿 / 其它常驻可达
//   ⑤ 城市推断（中文 / 拼音 / 行政区划代码）、过滤、默认城市优先级
//   ⑥ IP 定位响应解析（含 GBK 字节、JSONP、脏数据）与失败静默兜底
//   ⑦ 城市偏好落盘的原子性与损坏容错
//   ⑧ 城市台补充索引：只留城市台、放宽扫描上限、失败静默降级
//
// 运行：dart run tooling/verify_live_regions.dart
import 'dart:convert';
import 'dart:io';

import 'package:shunbo/data/live_region_store.dart';
import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';
import 'package:shunbo/features/live/live_geo_ip.dart';
import 'package:shunbo/features/live/live_region.dart';
import 'package:shunbo/features/live/live_source_descriptor.dart';

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

LiveChannel _ch(String name, {String group = '地方频道', String? tvgId}) =>
    LiveChannel(
      id: LiveCatalogService.channelIdFor(name, group),
      name: name,
      group: group,
      badge: name,
      streams: const <LiveStream>[LiveStream(url: 'http://a.com/x.m3u8')],
      tvgId: tvgId,
    );

Future<void> main() async {
  testShoppingRemoval();
  testSatelliteNormalization();
  testChineseGroups();
  testCatalogEndToEnd();
  testGroupNavigation();
  testCityDirectory();
  testCityFiltering();
  await testIpLocator();
  await testRegionStore();
  testCitySupplementParse();
  await testCitySupplementLoad();
  testIndexConstants();

  print('');
  // 汇总串格式与其余回归保持一致：门禁靠 "N/M 断言通过" 解析断言数。
  if (_fail == 0) {
    print('回归通过：$_pass/$_pass 断言通过');
    exit(0);
  }
  print('回归失败：$_pass/${_pass + _fail} 断言通过');
  exit(1);
}

// ── ① 购物频道移除 ────────────────────────────────────────

void testShoppingRemoval() {
  check(
    'Shop 分组 + Shopping 台名被识别',
    LiveCatalogService.isShoppingChannel(
        'Fengshang Shopping Channel (1080p)', 'Shop'),
  );
  check(
    '中文购物台被识别',
    LiveCatalogService.isShoppingChannel('家有购物', null),
  );
  check(
    '电视购物被识别',
    LiveCatalogService.isShoppingChannel('风尚购物频道高清', null),
  );
  check(
    '购物分组多标签被识别',
    LiveCatalogService.isShoppingChannel('某频道', 'Kids;Shop'),
  );
  check(
    'Workshop 不被误伤（英文词边界）',
    !LiveCatalogService.isShoppingChannel('Workshop Channel', null),
  );
  check(
    'CCTV-1 不被误伤',
    !LiveCatalogService.isShoppingChannel('CCTV-1 综合', null),
  );
  check(
    '湖南卫视不被误伤',
    !LiveCatalogService.isShoppingChannel('湖南卫视', '卫视频道'),
  );

  final withShop = <LiveChannel>[
    _ch('CCTV-1', group: '央视频道'),
    _ch('购物频道', group: '购物'),
    _ch('Fengshang Shopping Channel', group: '其它频道'),
  ];
  final cleaned = LiveCatalogService.withoutShopping(withShop);
  check('withoutShopping 只留非购物台', cleaned.length == 1, '${cleaned.length}');
  check(
    'group=购物 被剔除',
    cleaned.every((c) => !LiveCatalogService.isBlockedChannel(c)),
  );
  check('购物台不占频道表位置', cleaned.first.name == 'CCTV-1');
}

// ── ② 卫视归一 ────────────────────────────────────────────

void testSatelliteNormalization() {
  check(
    'Hunan TV → 湖南卫视',
    LiveCatalogService.satelliteNameOf('Hunan TV') == '湖南卫视',
    LiveCatalogService.satelliteNameOf('Hunan TV'),
  );
  check(
    'Jiangsu Satellite TV → 江苏卫视',
    LiveCatalogService.satelliteNameOf('Jiangsu Satellite TV') == '江苏卫视',
  );
  check(
    'Shandong Satellite TV → 山东卫视',
    LiveCatalogService.satelliteNameOf('Shandong Satellite TV') == '山东卫视',
  );
  check(
    'Shandong TV 与 Satellite 版归一到同一台',
    LiveCatalogService.satelliteNameOf('Shandong TV') ==
        LiveCatalogService.satelliteNameOf('Shandong Satellite TV'),
  );
  check(
    'Dragon TV International → 东方卫视',
    LiveCatalogService.satelliteNameOf('Dragon TV International') == '东方卫视',
  );
  check(
    'Zhejiang Satellite TV → 浙江卫视',
    LiveCatalogService.satelliteNameOf('Zhejiang Satellite TV') == '浙江卫视',
  );
  check(
    'Hunan News Channel 不误判为卫视主台',
    LiveCatalogService.satelliteNameOf('Hunan News Channel') == null,
  );
  check(
    'Some TV 不误判',
    LiveCatalogService.satelliteNameOf('Some TV') == null,
  );
  check(
    '已是中文卫视名则不再改写',
    LiveCatalogService.satelliteNameOf('湖南卫视') == null,
  );
  check(
    '归一键忽略大小写与标点',
    LiveCatalogService.satelliteKey('Hunan-TV') ==
        LiveCatalogService.satelliteKey('HUNAN TV'),
  );

  final parsed = LiveCatalogService.parseM3U('''
#EXTM3U
#EXTINF:-1 group-title="General",Hunan TV (2160p)
http://a.com/h1.m3u8
''');
  check('英文卫视解析成中文台名', parsed.first.name == '湖南卫视', parsed.first.name);
  check('英文卫视归入卫视频道', parsed.first.group == '卫视频道', parsed.first.group);
}

// ── ③ 中文 group-title ────────────────────────────────────

void testChineseGroups() {
  check(
    '卫视频道分组被采用',
    LiveCatalogService.inferGroup('江苏卫视', '卫视频道') == '卫视频道',
  );
  check(
    '央视频道分组被采用',
    LiveCatalogService.inferGroup('综合频道', '央视频道') == '央视频道',
  );
  check(
    '浙江频道归地方频道',
    LiveCatalogService.inferGroup('浙江新闻', '浙江频道') == '地方频道',
    LiveCatalogService.inferGroup('浙江新闻', '浙江频道'),
  );
  check(
    '内蒙频道归地方频道',
    LiveCatalogService.inferGroup('包头新闻综合', '内蒙频道') == '地方频道',
  );
  // 内容分类是**叠加**的：主分类按来源（地方），「少儿」另算一份。
  check(
    '中文少儿分组被采用',
    LiveCatalogService.categoriesOf('卡通频道', '少儿').contains('少儿'),
    LiveCatalogService.categoriesOf('卡通频道', '少儿').join(','),
  );
  check(
    '中文购物分组仍被发现（供目录层剔除）',
    LiveCatalogService.inferGroup('某台', '购物频道') == '购物',
  );
  // 原有语义不能破：这些断言与 verify_live_catalog 的分组推断一致。
  check(
    'General 仍归地方频道',
    LiveCatalogService.inferGroup('QTV-1', 'General', tvgId: 'QTV1.cn') ==
        '地方频道',
  );
  check(
    'News 仍归新闻',
    LiveCatalogService.categoriesOf('Harbin News', 'News',
            tvgId: 'HarbinNews.cn')
        .contains('新闻'),
    LiveCatalogService.categoriesOf('Harbin News', 'News', tvgId: 'HarbinNews.cn')
        .join(','),
  );
  check(
    'Religious 仍归其它频道',
    LiveCatalogService.inferGroup('Some TV', 'Religious') == '其它频道',
  );
  check(
    'CCTV 台名优先于内容分组',
    LiveCatalogService.inferGroup('CCTV-7', 'Education') == '央视频道',
  );
}

// ── ④ 目录层端到端（不联网） ──────────────────────────────

void testCatalogEndToEnd() {
  const m3u = '''
#EXTM3U
#EXTINF:-1 group-title="央视频道",CCTV-1 综合
http://a.com/cctv1.m3u8
#EXTINF:-1 group-title="General",Hunan TV (2160p)
http://a.com/hn-en.m3u8
#EXTINF:-1 group-title="卫视频道",湖南卫视
http://a.com/hn-cn.m3u8
#EXTINF:-1 group-title="Shop",Fengshang Shopping Channel (1080p)
http://a.com/shop.m3u8
#EXTINF:-1 group-title="浙江频道",呼市新闻综合
http://a.com/hu.m3u8
''';
  final parsed = LiveCatalogService.parseM3U(m3u);
  check('购物台在解析阶段就被剔除', parsed.length == 4, '实际 ${parsed.length}');
  check(
    '解析结果里没有购物台',
    parsed.every((c) => !LiveCatalogService.isBlockedChannel(c)),
  );
  check(
    '卫视频道有两条待合并条目',
    parsed.where((c) => c.group == '卫视频道').length == 2,
  );
  check('呼市台归地方频道',
      parsed.any((c) => c.name == '呼市新闻综合' && c.group == '地方频道'));

  final merged = LiveCatalogService.mergeChannels(
      builtIn: const <LiveChannel>[], remote: parsed);
  check('合并后 3 个台', merged.length == 3, '实际 ${merged.length}');
  final hunan = merged.where((c) => c.name == '湖南卫视').toList();
  check('中英卫视归一成同一个台', hunan.length == 1, '实际 ${hunan.length}');
  check('该台合并出 2 条线路', hunan.first.streams.length == 2,
      '实际 ${hunan.first.streams.length}');

  final sorted = LiveCatalogService.sortChannels(merged);
  check('央视频道排在最前', sorted.first.group == '央视频道', sorted.first.group);
  check('地方频道排在卫视之后',
      sorted.last.group == '地方频道', sorted.last.group);

  // `load()` 的三条返回路径都统一走 withoutShopping，
  // 这里钉住该函数本身（内置清单或配置导入里混入购物台也要被剔除）。
  final builtIn = <LiveChannel>[
    _ch('CCTV-1', group: '央视频道'),
    _ch('家有购物', group: '购物'),
  ];
  check(
    '服务层的内置清单同样可过滤',
    LiveCatalogService.withoutShopping(builtIn).length == 1,
  );
}

// ── ⑤ 分类固定顺序与左右导航 ──────────────────────────────

void testGroupNavigation() {
  final g = LiveRegion.groups;
  check('第一个是全部', g[0] == '全部');
  check('第二个是央视频道', g[1] == '央视频道');
  check('第三个是卫视频道', g[2] == '卫视频道');
  check('第四个是地方频道', g[3] == '地方频道');
  check('购物频道不在分类里', !g.contains('购物'));
  check('少儿分类常驻可达', g.contains('少儿'));
  check('其它频道分类常驻可达', g.contains('其它频道'));
  check('体育分类常驻可达', g.contains('体育'));
  check('分类顺序与 groupRank 一致（央视 < 卫视 < 地方）',
      LiveChannel.groupRank('央视频道') < LiveChannel.groupRank('卫视频道') &&
          LiveChannel.groupRank('卫视频道') <
              LiveChannel.groupRank('地方频道'));
  check('少儿排在其它频道之前', g.indexOf('少儿') < g.indexOf('其它频道'));

  check('在第一个分类再往左不动', LiveRegion.moveGroup(0, -1) == 0);
  check('从地方频道往右到新闻', LiveRegion.moveGroup(3, 1) == 4);
  check('在最后一个分类再往右不动',
      LiveRegion.moveGroup(g.length - 1, 1) == g.length - 1);
  check(
    '越界下标也落在合法范围',
    LiveRegion.moveGroup(-5, 1) >= 0 &&
        LiveRegion.moveGroup(-5, 1) < g.length,
    '${LiveRegion.moveGroup(-5, 1)}',
  );
  check('超大下标被安全钳制',
      LiveRegion.moveGroup(999, -1) == g.length - 2);
  check('groupAt 越界返回最后一项', LiveRegion.groupAt(999) == g.last);
  check('null 分组映射到全部', LiveRegion.indexOfGroup(null) == 0);
  check('少儿分组有合法下标', LiveRegion.indexOfGroup('少儿') > 3);
  check('未知分组回落到全部', LiveRegion.indexOfGroup('购物') == 0);
}

// ── ⑥ 城市目录 ────────────────────────────────────────────

void testCityDirectory() {
  check('320500 → 苏州', CityDirectory.cityOfCode('320500') == '苏州');
  check('320505 区县码归苏州', CityDirectory.cityOfCode('320505') == '苏州');
  check('110100 → 北京', CityDirectory.cityOfCode('110100') == '北京');
  check('330400 → 嘉兴', CityDirectory.cityOfCode('330400') == '嘉兴');
  check('未知区划码返回 null', CityDirectory.cityOfCode('999999') == null);
  check('非数字区划码返回 null', CityDirectory.cityOfCode('abcdef') == null);
  check('长度不对的码返回 null', CityDirectory.cityOfCode('3205') == null);

  check('江苏省苏州市 → 苏州', CityDirectory.cityOfName('江苏省苏州市') == '苏州');
  check('苏州市 → 苏州', CityDirectory.cityOfName('苏州市') == '苏州');
  check('苏州 → 苏州', CityDirectory.cityOfName('苏州') == '苏州');
  check('Suzhou → 苏州', CityDirectory.cityOfName('Suzhou') == '苏州');
  check('Jiaxing → 嘉兴', CityDirectory.cityOfName('Jiaxing') == '嘉兴');
  check('上海市 → 上海', CityDirectory.cityOfName('上海市') == '上海');
  check('嘉兴市 → 嘉兴', CityDirectory.cityOfName('嘉兴市') == '嘉兴');
  check('未知 → null', CityDirectory.cityOfName('未知') == null);
  check('省份名不当城市', CityDirectory.cityOfName('Zhejiang') == null);
  check('脏数据不当城市',
      CityDirectory.cityOfName('<script>alert(1)</script>') == null);
  check('空串不当城市', CityDirectory.cityOfName('') == null);

  check('Suzhou News Channel → 苏州',
      CityDirectory.inferCity('Suzhou News Channel') == '苏州');
  check('苏州新闻综合 → 苏州',
      CityDirectory.inferCity('苏州新闻综合') == '苏州');
  check('Chuxiong News Channel → 楚雄',
      CityDirectory.inferCity('Chuxiong News Channel') == '楚雄');
  check('Harbin Comprehensive News Channel → 哈尔滨',
      CityDirectory.inferCity('Harbin Comprehensive News Channel') == '哈尔滨');
  check('呼市新闻综合 → 呼和浩特',
      CityDirectory.inferCity('呼市新闻综合') == '呼和浩特');
  check('包头新闻综合 → 包头',
      CityDirectory.inferCity('包头新闻综合') == '包头');
  check('QTV-1 → 青岛', CityDirectory.inferCity('QTV-1') == '青岛');
  check('Xiangyang TV 不被 Xian 吃掉 → 襄阳',
      CityDirectory.inferCity('Xiangyang TV') == '襄阳',
      CityDirectory.inferCity('Xiangyang TV'));
  check("Xi'an Business Channel → 西安",
      CityDirectory.inferCity("Xi'an Business Information Channel") == '西安');
  check('省级台 Jiangsu City Channel 不产生城市',
      CityDirectory.inferCity('Jiangsu City Channel') == null);
  check('Hunan News Channel 不产生城市',
      CityDirectory.inferCity('Hunan News Channel') == null);
  check('DaAi 1 不产生城市', CityDirectory.inferCity('DaAi 1') == null);
  check('Channel 8 不产生城市', CityDirectory.inferCity('Channel 8') == null);
  check('tvg-id 也能推断城市',
      CityDirectory.inferCity('综合频道', tvgId: 'SuzhouTV.cn') == '苏州');

  check('isKnown 苏州', CityDirectory.isKnown('苏州'));
  check('isKnown 火星为假', !CityDirectory.isKnown('火星'));
  check('全部城市是合法选择',
      CityDirectory.isValidSelection(CityDirectory.allCities));
  check('其它城市是合法选择',
      CityDirectory.isValidSelection(CityDirectory.otherCities));
  check('任意脚本串不是合法选择',
      !CityDirectory.isValidSelection('<script>'));
  check('null 不是合法选择', !CityDirectory.isValidSelection(null));
}

// ── ⑦ 城市过滤与默认城市 ──────────────────────────────────

void testCityFiltering() {
  final local = <LiveChannel>[
    _ch('苏州新闻综合'),
    _ch('Suzhou News Channel'),
    _ch('Jiaxing TV'),
    _ch('DaAi 1'),
    _ch('Channel 8'),
    _ch('Harbin Comprehensive News Channel'),
    _ch('QTV-1'),
  ];
  final options = CityDirectory.citiesOf(local);
  check('识别出 4 个城市', options.length == 4, '实际 ${options.length}');
  check('苏州台数最多排第一', options.first.name == '苏州', options.first.name);
  check('苏州有 2 台', options.first.count == 2, '${options.first.count}');
  check('未识别台不进城市列表',
      options.every((o) => o.name != 'DaAi 1' && o.name != 'Channel 8'));

  check('全部城市返回所有台',
      CityDirectory.filter(local, CityDirectory.allCities).length == local.length);
  check('null 也返回所有台', CityDirectory.filter(local, null).length == 7);
  check('按苏州过滤得 2 台',
      CityDirectory.filter(local, '苏州').length == 2,
      '${CityDirectory.filter(local, '苏州').length}');
  check('按苏州过滤不含嘉兴台',
      CityDirectory.filter(local, '苏州').every((c) => !c.name.contains('Jiaxing')));
  check('其它城市收留未识别台',
      CityDirectory.filter(local, CityDirectory.otherCities).length == 2,
      '${CityDirectory.filter(local, CityDirectory.otherCities).length}');
  check('未知城市返回空而不是全部',
      CityDirectory.filter(local, '火星').isEmpty);

  check('IP 定位到有收录的苏州则默认苏州',
      CityDirectory.defaultCity(local, located: '苏州') == '苏州');
  check('用户上次选择优先于 IP',
      CityDirectory.defaultCity(local, saved: '嘉兴', located: '苏州') == '嘉兴');
  check('保存的「全部城市」可直接生效',
      CityDirectory.defaultCity(local, saved: CityDirectory.allCities,
              located: '苏州') ==
          CityDirectory.allCities);
  check('定位城市无收录则退回全部城市',
      CityDirectory.defaultCity(local, located: '火星') ==
          CityDirectory.allCities);
  check('地方频道为空时也退回全部城市',
      CityDirectory.defaultCity(const <LiveChannel>[], located: '苏州') ==
          CityDirectory.allCities);
  check('保存的城市若已不在目录里则忽略',
      CityDirectory.defaultCity(local, saved: '火星', located: '苏州') == '苏州');
}

// ── ⑧ IP 定位 ─────────────────────────────────────────────

Future<void> testIpLocator() async {
  check(
    'cityCode 解析 → 苏州',
    IpCityLocator.parseCityText(
            '{"ip":"1.2.3.4","pro":"<gbk>","city":"<gbk>","cityCode":"320500"}') ==
        '苏州',
  );
  check(
    'ipinfo 英文市名 → 嘉兴',
    IpCityLocator.parseCityText('{"city":"Jiaxing","region":"Zhejiang"}') ==
        '嘉兴',
  );
  check(
    'JSONP cname → 苏州',
    IpCityLocator.parseCityText(
            'var returnCitySN = {"cname":"江苏省苏州市"};') ==
        '苏州',
  );
  check('未知城市返回 null',
      IpCityLocator.parseCityText('{"cname":"未知"}') == null);
  check('非 JSON 返回 null', IpCityLocator.parseCityText('hello') == null);
  check('空响应返回 null', IpCityLocator.parseCityText('') == null);
  check('数组响应返回 null', IpCityLocator.parseCityText('[1,2,3]') == null);
  check('字段超长被忽略',
      IpCityLocator.parseCityText('{"city":"${'x' * 100}"}') == null);
  check('脏数据不会被采纳',
      IpCityLocator.parseCityText('{"city":"<script>alert(1)</script>"}') ==
          null);
  check('超限响应被拒',
      IpCityLocator.parseCityText('x' * (IpCityLocator.maxResponseBytes + 1)) ==
          null);
  check(
    'UTF-8 字节也能解析',
    IpCityLocator.parseCityBytes(utf8.encode('{"city":"Suzhou"}')) == '苏州',
  );
  check('空字节返回 null',
      IpCityLocator.parseCityBytes(const <int>[]) == null);
  check(
    '超限字节返回 null',
    IpCityLocator.parseCityBytes(
            List<int>.filled(IpCityLocator.maxResponseBytes + 1, 32)) ==
        null,
  );

  // GBK 响应的中文字段里可能含 0x5C（反斜杠），会让 JSON 解析整体失败；
  // cityCode 走 Latin-1 字节视图提取，必须仍能定位成功。
  final gbkBytes = <int>[
    ...utf8.encode('{"city":"'),
    0xBD,
    0x5C,
    0xAA,
    ...utf8.encode('","cityCode":"320500","err":""}'),
  ];
  check(
    'GBK 字节含 0x5C 仍靠 cityCode 定位',
    IpCityLocator.parseCityBytes(gbkBytes) == '苏州',
    IpCityLocator.parseCityBytes(gbkBytes),
  );

  // 真实 socket：注入本机 HttpServer 的客户端，验证 _fetch / 关闭 / 降级。
  HttpServer? server;
  try {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final okPort = server.port;
    server.listen((request) async {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
          '{"pro":"<gbk>","city":"<gbk>","cityCode":"320500","err":""}');
      await request.response.close();
    });
    final good = IpCityLocator(
      endpoints: <String>['http://127.0.0.1:$okPort/ip'],
      timeout: const Duration(seconds: 3),
      // 本机回环必须 DIRECT：系统代理会把 127.0.0.1 接管成 502。
      httpClientFactory: () =>
          HttpClient()..findProxy = ((_) => 'DIRECT'),
    );
    final city = await good.locate();
    check('locate 走注入客户端拿到苏州', city == '苏州', city);
  } finally {
    await server?.close(force: true);
  }

  HttpServer? bad;
  try {
    bad = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final badPort = bad.port;
    bad.listen((request) async {
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    });
    final failing = IpCityLocator(
      endpoints: <String>['http://127.0.0.1:$badPort/ip'],
      timeout: const Duration(seconds: 2),
      httpClientFactory: () =>
          HttpClient()..findProxy = ((_) => 'DIRECT'),
    );
    check('HTTP 500 时静默返回 null', await failing.locate() == null);
  } finally {
    await bad?.close(force: true);
  }

  final unreachable = IpCityLocator(
    endpoints: const <String>['http://127.0.0.1:1/ip'],
    timeout: const Duration(milliseconds: 400),
    httpClientFactory: () => HttpClient()..findProxy = ((_) => 'DIRECT'),
  );
  check('不可达端点静默返回 null', await unreachable.locate() == null);
}

// ── ⑨ 城市偏好落盘 ────────────────────────────────────────

Future<void> testRegionStore() async {
  final dir = await Directory.systemTemp.createTemp('shunbo_region_');
  try {
    final path = '${dir.path}${Platform.pathSeparator}city.txt';
    final store = LiveRegionStore.at(path);
    check('文件不存在读回 null', await store.load() == null);
    await store.save('苏州');
    check('保存后读回苏州', await store.load() == '苏州');
    await store.save('嘉兴');
    check('覆盖保存生效', await store.load() == '嘉兴');
    await store.save('<script>alert(1)</script>');
    check('非法城市被拒且旧值不变', await store.load() == '嘉兴');
    await store.save('全部城市');
    check('虚拟城市项可持久化', await store.load() == '全部城市');
    await File(path).writeAsString('火星');
    check('损坏内容读回 null', await store.load() == null);
    await File(path).writeAsString('x' * 200);
    check('超长内容读回 null', await store.load() == null);
    check('读坏文件不抛异常也不影响后续', await store.load() == null);
    await store.save('苏州');
    check('损坏后仍可重新写入', await store.load() == '苏州');
  } finally {
    dir.deleteSync(recursive: true);
  }
}

// ── ⑩ 城市台补充索引 ──────────────────────────────────────

/// 形态照抄真实补充表：中文 group-title 带 emoji 前缀、央视/卫视重复线路、
/// 省级台（无城市）、地市台（苏州 / 青岛）与购物台混在一起。
const String _citySupplementM3U = '''
#EXTM3U
#EXTINF:-1 tvg-id="CCTV-1" group-title="📺央视频道",CCTV-1
http://a.com/cctv1.m3u8
#EXTINF:-1 group-title="☘️江苏频道",苏州新闻综合
http://a.com/sz1.m3u8
#EXTINF:-1 group-title="☘️江苏频道",苏州社会经济
http://a.com/sz2.m3u8
#EXTINF:-1 group-title="☘️浙江频道",浙江新闻
http://a.com/zj.m3u8
#EXTINF:-1 group-title="☘️山东频道",QTV-4
http://a.com/qd.m3u8
#EXTINF:-1 group-title="Shop",风尚购物
http://a.com/shop.m3u8
''';

void testCitySupplementParse() {
  final all = LiveCatalogService.parseM3U(_citySupplementM3U);
  check('普通解析保留 5 条（购物台已剔除）', all.length == 5, '实际 ${all.length}');

  final cities = LiveCatalogService.parseM3U(_citySupplementM3U, cityOnly: true);
  check('cityOnly 只留 3 个城市台', cities.length == 3, '实际 ${cities.length}');
  check(
    'cityOnly 丢掉央视重复线路与省级台',
    cities.every((c) => c.name.contains('苏州') || c.name == 'QTV-4'),
    cities.map((c) => c.name).join(','),
  );
  check(
    '带 emoji 的省级 group-title 仍归地方频道',
    cities.every((c) => c.group == LiveRegion.localGroup),
    cities.map((c) => c.group).join(','),
  );
  check(
    '苏州台被识别为 2 台',
    CityDirectory.citiesOf(cities).any((o) => o.name == '苏州' && o.count == 2),
  );
  check(
    'QTV-4 被识别为青岛',
    CityDirectory.inferCity('QTV-4') == '青岛',
  );
  check(
    '有了苏州台，IP 定位不再回退全部城市',
    CityDirectory.defaultCity(cities, located: '苏州') == '苏州',
  );
  check(
    '苏州过滤出 2 台',
    CityDirectory.filter(cities, '苏州').length == 2,
  );
  check(
    '全部城市返回 3 台',
    CityDirectory.filter(cities, CityDirectory.allCities).length == 3,
  );
  check(
    '其它城市为空（cityOnly 后没有无归属台）',
    CityDirectory.filter(cities, CityDirectory.otherCities).isEmpty,
  );
  check(
    '没有苏州台时仍按老规矩回退全部城市',
    CityDirectory.defaultCity(
            cities.where((c) => c.name != '苏州新闻综合' &&
                c.name != '苏州社会经济'),
            located: '苏州') ==
        CityDirectory.allCities,
  );

  // 真实补充表里苏州在第 1448 行（第 600 条 EXTINF 之后）。
  // 钉住这个坑：默认上限会把城市台全截掉；放宽上限 + cityOnly 才能拿到它，
  // 且被过滤掉的 650 条不占额度（channelLimit=1 仍能扫到末尾那条苏州台）。
  final buf = StringBuffer('#EXTM3U\n');
  for (var i = 0; i < 650; i++) {
    buf.writeln('#EXTINF:-1 group-title="📺央视频道",CCTV-1 综合 $i');
    buf.writeln('http://a.com/cctv$i.m3u8');
  }
  buf.writeln('#EXTINF:-1 group-title="☘️江苏频道",苏州新闻综合');
  buf.writeln('http://a.com/suzhou.m3u8');
  final long = buf.toString();
  final capped = LiveCatalogService.parseM3U(long);
  check('默认解析被 600 条上界截断', capped.length == 600, '实际 ${capped.length}');
  check(
    '默认上限会把排在第 651 条的苏州台丢掉',
    capped.every((c) => !c.name.contains('苏州')),
  );
  final supplement = LiveCatalogService.parseM3U(
    long,
    channelLimit: LiveCatalogService.maxLines,
    cityOnly: true,
  );
  check('补充解析只得到苏州 1 台', supplement.length == 1,
      '实际 ${supplement.length}');
  check('补充解析拿到的是苏州台',
      supplement.isNotEmpty && supplement.first.name == '苏州新闻综合');
  final tinyLimit = LiveCatalogService.parseM3U(
    long,
    channelLimit: 1,
    cityOnly: true,
  );
  check(
    '被过滤的条目不占额度（上限 1 仍能扫到末尾城市台）',
    tinyLimit.length == 1 && tinyLimit.first.name == '苏州新闻综合',
    '实际 ${tinyLimit.length}',
  );
}

/// 端到端：主索引 + 补充索引一起走 `load()`，以及补充源 404 时静默降级。
Future<void> testCitySupplementLoad() async {
  const mainM3U = '''
#EXTM3U
#EXTINF:-1 group-title="央视频道",CCTV-1
http://a.com/cctv1.m3u8
''';
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final base = 'http://127.0.0.1:${server.port}';
  server.listen((HttpRequest req) async {
    switch (req.uri.path) {
      case '/main.m3u':
        req.response.headers.contentType = ContentType.text;
        req.response.write(mainM3U);
      case '/city.m3u':
        req.response.headers.contentType = ContentType.text;
        req.response.write(_citySupplementM3U);
      default:
        req.response.statusCode = HttpStatus.notFound;
    }
    await req.response.close();
  });

  // 本机回环必须 DIRECT，否则会被系统代理转成 502（项目已踩过）。
  HttpClient directClient() => HttpClient()..findProxy = ((_) => 'DIRECT');

  final svc = LiveCatalogService(
    builtIn: const <LiveChannel>[],
    remotePlaylistUrls: <String>['$base/main.m3u'],
    citySupplementUrls: <String>['$base/city.m3u'],
    streamIndexUrl: null,
    httpClientFactory: directClient,
  );
  final snap = await svc.load();
  check('补充索引并入不写告警', snap.warnings.isEmpty, snap.warnings.join(';'));
  check(
    '苏州台进入合并频道表',
    snap.channels.any((c) => c.name == '苏州新闻综合'),
  );
  check(
    '苏州台归地方频道',
    snap.channels
        .where((c) => c.name == '苏州新闻综合')
        .every((c) => c.group == LiveRegion.localGroup),
  );
  check(
    '补充表里的央视重复线路被 cityOnly 挡掉',
    snap.channels.where((c) => c.name == 'CCTV-1').length == 1,
  );
  final local = snap.channels
      .where((c) => c.group == LiveRegion.localGroup)
      .toList(growable: false);
  check(
    '端到端默认城市落在苏州',
    CityDirectory.defaultCity(local, located: '苏州') == '苏州',
  );
  check(
    '端到端苏州过滤出 2 台',
    CityDirectory.filter(local, '苏州').length == 2,
  );

  final broken = LiveCatalogService(
    builtIn: const <LiveChannel>[],
    remotePlaylistUrls: <String>['$base/main.m3u'],
    citySupplementUrls: <String>['$base/missing.m3u'],
    streamIndexUrl: null,
    httpClientFactory: directClient,
  );
  final fallenBack = await broken.load();
  check('补充源 404 不写告警（静默降级）', fallenBack.warnings.isEmpty,
      fallenBack.warnings.join(';'));
  check(
    '补充源 404 不影响主频道表',
    fallenBack.channelCount == 1 &&
        !fallenBack.channels.any((c) => c.name == '苏州新闻综合'),
    '实际 ${fallenBack.channelCount}',
  );

  await server.close(force: true);
}

// ── ⑪ 默认索引常量 ────────────────────────────────────────

void testIndexConstants() {
  // 主链路只保留 iptv-org 两份官方目录（小、快、直连）；国内 IPv6 直连表已从主链路
  // 移入增强源（见 live_catalog.dart 的 kDefaultDiscoverySources），不再阻塞/告警首屏。
  check('主索引只有 iptv-org 两份目录', kDefaultLiveIndexUrls.length == 2,
      '${kDefaultLiveIndexUrls.length}');
  check('第一份是 iptv-org cn.m3u',
      kDefaultLiveIndexUrls[0].contains('iptv-org.github.io') &&
          kDefaultLiveIndexUrls[0].contains('cn.m3u'));
  check('第二份是 iptv-org zho.m3u',
      kDefaultLiveIndexUrls[1].contains('zho.m3u'));
  check('主索引均为 https 且仅 iptv-org 直连（不含代理镜像）',
      kDefaultLiveIndexUrls.every((u) =>
          u.startsWith('https://') && u.contains('iptv-org.github.io')),
      kDefaultLiveIndexUrls.join(' | '));
  check('IPv6 直连表已移入增强源',
      kDefaultDiscoverySources.any((d) => d.label.startsWith('IPv6 直连表')),
      '${kDefaultDiscoverySources.map((d) => d.label).join(',')}');
  check('所有索引都是 https',
      kDefaultLiveIndexUrls.every((u) => u.startsWith('https://')));
  check('备用源索引仍指向 streams.json',
      kDefaultStreamIndexUrl.contains('streams.json'));
  // 苏州台要求「稳定检索」：同一份数据走两个不同镜像，任一挂掉仍有苏州台。
  check('城市台补充索引至少两份镜像', kDefaultCitySupplementUrls.length >= 2,
      '${kDefaultCitySupplementUrls.length}');
  check('城市台补充索引全是 https',
      kDefaultCitySupplementUrls.every((u) => u.startsWith('https://')));
  check('城市台补充索引都指向 result.m3u',
      kDefaultCitySupplementUrls.every((u) => u.contains('result.m3u')));
  check('两条镜像落在不同主机（真冗余）',
      kDefaultCitySupplementUrls
              .map((u) => Uri.parse(u).host)
              .toSet()
              .length >=
          2,
      kDefaultCitySupplementUrls.map((u) => Uri.parse(u).host).join(','));
  check('城市台补充索引与主索引分开装配',
      kDefaultCitySupplementUrls.every(
          (u) => !kDefaultLiveIndexUrls.contains(u)));

  // 全网检索：格式、收窄范围、体积上限都必须显式建模。
  check('全网发现源至少 4 份', kDefaultDiscoverySources.length >= 4,
      '${kDefaultDiscoverySources.length}');
  check('所有发现源地址合法（https / 无凭据）',
      kDefaultDiscoverySources.every((s) => s.isWellFormed));
  check('发现源含 nameUrl 格式（苏州第二份独立来源）',
      kDefaultDiscoverySources.any((s) =>
          s.format == LiveSourceFormat.nameUrl &&
          s.scope == LiveSourceScope.cityOnly));
  check('发现源含 iptv-org 中国全线路表',
      kDefaultDiscoverySources.any(
          (s) => s.label.contains('中国全线路') && s.url.contains('streams/cn.m3u')));
  check('发现源含全球总索引且做了中国收窄',
      kDefaultDiscoverySources.any((s) =>
          s.url.contains('index.m3u') &&
          s.scope == LiveSourceScope.chinaOnly));
  check('全球总索引放大了体积与扫描行数上限',
      kDefaultDiscoverySources
          .where((s) => s.url.contains('index.m3u'))
          .every((s) =>
              (s.maxBytes ?? 0) > LiveCatalogService.maxPlaylistBytes &&
              (s.scanLines ?? 0) > LiveCatalogService.maxLines));
  check('备用源镜像清单非空且指向 streams.json',
      kDefaultStreamIndexUrls.isNotEmpty &&
          kDefaultStreamIndexUrls.every((u) => u.contains('streams.json')));
}
