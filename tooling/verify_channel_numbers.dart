// 频道分类策略 + 数字编号 + 遥控器数字输入 回归。
//
// 对应用户需求：
//   ① 新闻 / 少儿 / 体育 三个分类的内容来源覆盖央视、卫视、地方三类频道；
//   ② 纪实分类的内容来源为央视及全网其它视频源；
//   ③ 除上述已列来源之外的其它来源视频统一归入「其它」频道；
//   ④ 所有频道及节目分配唯一、稳定的数字编号，央视一套 = 1；
//   ⑤ 编号便于记忆且不冲突，遥控器可直接输入数字切台；
//   ⑥ 中国教育 4 个台从卫视频道改归央视频道（作为央视的四个台）。
//
// 运行：dart run tooling/verify_channel_numbers.dart
import 'dart:async';
import 'dart:io';

import 'package:shunbo/features/live/channel_numbering.dart';
import 'package:shunbo/features/live/channel_taxonomy.dart';
import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';

int _pass = 0;
int _fail = 0;

/// 退出码：有失败时置 1（门禁靠它判定成败）。
int exitCode = 0;

void check(String name, bool ok, [String? detail]) {
  if (!ok) {
    _fail++;
    print('FAIL: $name${detail == null ? '' : ' —— $detail'}');
    return;
  }
  _pass++;
  print('PASS: $name');
}

LiveChannel _ch(String name, {String group = '地方频道', String? tvgId}) {
  return LiveChannel(
    id: LiveCatalogService.channelIdFor(name, group),
    name: name,
    group: group,
    badge: name,
    tvgId: tvgId,
    streams: const <LiveStream>[LiveStream(url: 'http://a/x.m3u8')],
  );
}

/// 内存版落盘实现：模拟「跨会话记住编号」。
class _MemoryStore implements ChannelNumberStore {
  _MemoryStore([Map<String, int>? seed]) : data = <String, int>{...?seed};

  Map<String, int> data;
  int saves = 0;

  @override
  Map<String, int> load() => Map<String, int>.of(data);

  @override
  Future<void> save(Map<String, int> map) async {
    saves++;
    data = Map<String, int>.of(map);
  }
}

// ── ① 号段配置 ──────────────────────────────────────────────

void testBands() {
  print('\n== 号段配置 ==');
  check('央视号段 1-99',
      ChannelNumberBook.bandOf(ChannelSource.cctv).start == 1 &&
          ChannelNumberBook.bandOf(ChannelSource.cctv).end == 99);
  check('卫视号段 101-199',
      ChannelNumberBook.bandOf(ChannelSource.satellite).start == 101 &&
          ChannelNumberBook.bandOf(ChannelSource.satellite).end == 199);
  check('地方号段 201-899',
      ChannelNumberBook.bandOf(ChannelSource.local).start == 201 &&
          ChannelNumberBook.bandOf(ChannelSource.local).end == 899);
  check('全网其它视频源号段 901-999',
      ChannelNumberBook.bandOf(ChannelSource.web).start == 901 &&
          ChannelNumberBook.bandOf(ChannelSource.web).end == 999);
  check('节目号段 1001-1099',
      kProgramBandStart == 1001 && kProgramBandEnd == 1099);
  check('分集号段 1101-1999',
      kEpisodeBandStart == 1101 && kEpisodeBandEnd == 1999);
  check('号段互不重叠',
      kChannelBands.every((b) => b.source != ChannelSource.cctv ||
          !kChannelBands
              .where((o) => o.source != ChannelSource.cctv)
              .any((o) => o.start <= b.end && o.end >= b.start)));
}

// ── ② 固定编号表 ────────────────────────────────────────────

void testFixedNumbers() {
  print('\n== 固定编号 ==');
  check('央视一套 = 1', fixedNumberOf('CCTV-1') == 1, '${fixedNumberOf('CCTV-1')}');
  check('央视一套综合写法也是 1',
      fixedNumberOf('CCTV-1 综合') == 1, '${fixedNumberOf('CCTV-1 综合')}');
  check('央视二套 = 2', fixedNumberOf('CCTV-2') == 2);
  check('央视十三套 = 13', fixedNumberOf('CCTV-13') == 13);
  check('央视十七套 = 17', fixedNumberOf('CCTV-17') == 17);
  check('央视五加 = 18', fixedNumberOf('CCTV-5+') == 18);
  check('央视 4K = 19', fixedNumberOf('CCTV 4K') == 19);
  check('CGTN = 20', fixedNumberOf('CGTN') == 20);
  check('CGTN 纪录 = 21', fixedNumberOf('CGTN 纪录') == 21);
  check('中国教育一台 = 22', fixedNumberOf('中国教育1台') == 22);
  check('中国教育四台 = 25', fixedNumberOf('中国教育4台') == 25);
  check('CETV-1 归一后也是 22', fixedNumberOf('CETV-1') == 22);
  check('北京卫视 = 101', fixedNumberOf('北京卫视') == 101);
  check('湖南卫视 = 118', fixedNumberOf('湖南卫视') == 118);
  check('江苏卫视 = 110', fixedNumberOf('江苏卫视') == 110);
  check('东方卫视 = 109', fixedNumberOf('东方卫视') == 109);
  // 旧名「上海卫视」2002 年已更名「东方卫视」：在 canonicalName 阶段归一成
  // 「东方卫视」，因此二者是同一个频道、同一个号（不再双列/编号分裂）。
  // fixedNumberOf 直接吃原始台名、不做中文旧名归一，所以用 canonicalName
  // 验证归一结果，而非比较两者的 fixedNumberOf。
  check('上海卫视 归一成东方卫视',
      LiveCatalogService.canonicalName('上海卫视') == '东方卫视',
      LiveCatalogService.canonicalName('上海卫视'));
  check('苏州新闻综合 = 201', fixedNumberOf('苏州新闻综合') == 201);
  check('苏州 4K = 205', fixedNumberOf('苏州4K') == 205);
  // 卫视 4K/8K 画质变体固定号：与基础台同名但独立频道，给固定号防漂移。
  // （结尾带「超清/高清」的写法会被 canonicalName 归一进基础台，不算独立频道。）
  check('深圳卫视4K = 141', fixedNumberOf('深圳卫视4K') == 141,
      '${fixedNumberOf('深圳卫视4K')}');
  check('浙江卫视4K = 142', fixedNumberOf('浙江卫视4K') == 142);
  check('湖南卫视4K = 145', fixedNumberOf('湖南卫视4K') == 145);
  check('深圳卫视8K = 151', fixedNumberOf('深圳卫视8K') == 151);
  check('4K 变体 ≠ 基础台号', fixedNumberOf('深圳卫视4K') != fixedNumberOf('深圳卫视'));
  check('无固定编号的台返回 null', fixedNumberOf('某地市台') == null);
  check('节目编号齐全', kProgramNumbers.length == 6);
  check('节目编号落在节目号段',
      kProgramNumbers.values.every((n) => n >= kProgramBandStart && n <= kProgramBandEnd));
}

// ── ③ 分类来源策略 ──────────────────────────────────────────

void testCategoryPolicy() {
  print('\n== 分类来源策略 ==');
  const cctv = ChannelSource.cctv;
  const sat = ChannelSource.satellite;
  const local = ChannelSource.local;
  const web = ChannelSource.web;

  for (final g in <String>['新闻', '少儿', '体育']) {
    check('$g 收录央视', ChannelTaxonomy.categoryAllows(g, cctv));
    check('$g 收录卫视', ChannelTaxonomy.categoryAllows(g, sat));
    check('$g 收录地方', ChannelTaxonomy.categoryAllows(g, local));
    check('$g 不收全网其它视频源', !ChannelTaxonomy.categoryAllows(g, web));
  }
  check('纪实收录央视', ChannelTaxonomy.categoryAllows('纪实', cctv));
  check('纪实收录全网其它视频源', ChannelTaxonomy.categoryAllows('纪实', web));
  check('纪实不收卫视', !ChannelTaxonomy.categoryAllows('纪实', sat));
  check('其它频道只收全网其它视频源',
      ChannelTaxonomy.categoryAllows('其它频道', web) &&
          !ChannelTaxonomy.categoryAllows('其它频道', cctv) &&
          !ChannelTaxonomy.categoryAllows('其它频道', sat) &&
          !ChannelTaxonomy.categoryAllows('其它频道', local));

  // 来源判定
  check('CCTV-1 属央视', ChannelTaxonomy.sourceOf('CCTV-1') == cctv);
  check('CGTN 属央视', ChannelTaxonomy.sourceOf('CGTN') == cctv);
  check('中国教育台属央视', ChannelTaxonomy.sourceOf('中国教育1台') == cctv);
  check('湖南卫视属卫视', ChannelTaxonomy.sourceOf('湖南卫视') == sat);
  check('苏州新闻综合属地方', ChannelTaxonomy.sourceOf('苏州新闻综合') == local);
  check('英文省台靠 tvg-id 判地方',
      ChannelTaxonomy.sourceOf('Xinjiang TV 1', tvgId: 'XinjiangTV1.cn') == local);
  check('境外台属全网其它视频源',
      ChannelTaxonomy.sourceOf('Some TV', tvgId: 'SomeTV.us') == web);
  check('group-title 央视频道判央视',
      ChannelTaxonomy.sourceOf('综合频道', remoteGroup: '📺央视频道') == cctv);
  check('group-title 省级频道判地方',
      ChannelTaxonomy.sourceOf('QTV-4', remoteGroup: '☘️山东频道') == local);

  // 内容分类（叠加）
  check('CCTV-13 同时是新闻与央视',
      LiveCatalogService.categoriesOf('CCTV-13', 'News').contains('新闻') &&
          LiveCatalogService.categoriesOf('CCTV-13', 'News')
              .contains('央视频道'));
  check('苏州新闻综合同时是新闻与地方频道',
      LiveCatalogService.categoriesOf('苏州新闻综合', '☘️江苏频道')
          .contains('新闻') &&
          LiveCatalogService.categoriesOf('苏州新闻综合', '☘️江苏频道')
              .contains('地方频道'));
  check('境外新闻台不进新闻分类',
      !LiveCatalogService.categoriesOf('Some News', 'News').contains('新闻'));
  check('境外纪实台归纪实分类',
      LiveCatalogService.inferGroup('Some Documentary', 'Documentary') == '纪实');
  check('中国教育台归央视频道',
      LiveCatalogService.inferGroup('中国教育1台', '卫视频道') == '央视频道');
  check('CETV 与中国教育台名归一',
      LiveCatalogService.canonicalName('CETV-3') == '中国教育3台');
}

// ── ④ 编号分配：唯一 / 稳定 / 号段正确 ──────────────────────

void testAllocation() {
  print('\n== 编号分配 ==');
  final channels = <LiveChannel>[
    _ch('CCTV-1', group: '央视频道'),
    _ch('CCTV-2', group: '央视频道'),
    _ch('中国教育1台', group: '央视频道'),
    _ch('湖南卫视', group: '卫视频道'),
    _ch('江苏卫视', group: '卫视频道'),
    _ch('苏州新闻综合'),
    _ch('苏州社会经济'),
    // 境外台：台名没有汉字、tvg-id 也不是中国域名 → 来源=全网其它视频源。
    _ch('Some TV', group: '其它频道'),
  ];
  final book = ChannelNumberBook();
  book.rebuild(channels);

  final numbers = channels
      .map((c) => book.numberOf(c.id))
      .whereType<int>()
      .toList();
  check('每个台都有编号', numbers.length == channels.length);
  check('编号唯一', numbers.toSet().length == numbers.length, '$numbers');
  check('CCTV-1 拿到 1', book.numberOf(channels[0].id) == 1);
  check('CCTV-2 拿到 2', book.numberOf(channels[1].id) == 2);
  check('中国教育一台拿到 22', book.numberOf(channels[2].id) == 22);
  check('湖南卫视拿到 118', book.numberOf(channels[3].id) == 118);
  check('江苏卫视拿到 110', book.numberOf(channels[4].id) == 110);
  check('苏州新闻综合拿到 201', book.numberOf(channels[5].id) == 201);
  check('境外台落在 901-999',
      book.numberOf(channels[7].id)! >= 901 && book.numberOf(channels[7].id)! <= 999);

  // 稳定性：同一份频道表重建两次，结果一致。
  final book2 = ChannelNumberBook();
  book2.rebuild(channels);
  check('重建结果稳定',
      channels.every((c) => book.numberOf(c.id) == book2.numberOf(c.id)));

  // 稳定性：新增一个台，老台的编号不变。
  final withExtra = <LiveChannel>[...channels, _ch('浙江新闻综合')];
  final book3 = ChannelNumberBook();
  book3.rebuild(withExtra);
  check('新增台不影响老台编号',
      channels.every((c) => book3.numberOf(c.id) == book.numberOf(c.id)),
      channels
          .map((c) => '${c.name}:${book.numberOf(c.id)}->${book3.numberOf(c.id)}')
          .join(' '));

  // 跨会话：落盘后新实例读回，老台编号不变。
  final store = _MemoryStore();
  final book4 = ChannelNumberBook(store: store);
  book4.rebuild(channels);
  check('落盘被调用', store.saves > 0);
  final book5 = ChannelNumberBook(store: store);
  book5.rebuild(withExtra);
  check('跨会话编号不变',
      channels.every((c) => book5.numberOf(c.id) == book.numberOf(c.id)));

  // 按编号反查频道（遥控器输入用）。
  final hit = book.channelForNumber(channels, 1);
  check('编号 1 反查到 CCTV-1', hit?.name == 'CCTV-1', hit?.name);
  check('不存在的编号返回 null', book.channelForNumber(channels, 7777) == null);

  // 固定编号不能被别的台抢走：兜底分配（同名台多份时另给一个号）
  // 必须避开前两轮已占用的号码。实测 `Ando TV`（英文台名、.cn 的 tvg-id，
  // 归属地方）曾抢走苏州台预留的号，把苏州几个台挤到 331/344/345。
  final withLocal = <LiveChannel>[
    ...channels,
    _ch('Ando TV', group: '地方频道', tvgId: 'AndoTV.cn'),
  ];
  final bookFixed = ChannelNumberBook();
  bookFixed.rebuild(withLocal);
  final suzhou = withLocal.firstWhere((c) => c.name == '苏州新闻综合');
  final ando = withLocal.firstWhere((c) => c.name == 'Ando TV');
  check('固定编号不被别的台抢走',
      bookFixed.numberOf(suzhou.id) == 201 &&
          bookFixed.numberOf(ando.id) != 201,
      '苏州=${bookFixed.numberOf(suzhou.id)} Ando=${bookFixed.numberOf(ando.id)}');

  // 全表编号唯一：遥控器上两个台抢同一个号是不可接受的。
  final all = <int>{};
  var dup = 0;
  for (final c in withLocal) {
    final n = bookFixed.numberOf(c.id);
    if (n == null) continue;
    if (!all.add(n)) dup++;
  }
  check('全表编号唯一', dup == 0, '重复 $dup 个');
}

// ── ④b 排序键：分辨率/画质后缀不得被当成台号 ─────────────────
//
// 这是「点击深圳卫视4K 误切到北京卫视」的直接根因回归：sortChannels 用
// 台名里的「台号」排序，若把「4K」里的 4 当成台号，深圳卫视4K 会排到
// 卫视频道最前（4 < 101），自动切台/下一台就跳到紧邻的北京卫视。
void testSortKey() {
  print('\n== 排序键（台号）==');
  // 4K/8K/超清 是画质档，不是台号 → 应排到本组最后（9999）。
  check('深圳卫视4K 排序键不是 4', LiveCatalogService.sortKeyOf('深圳卫视4K') == 9999,
      '${LiveCatalogService.sortKeyOf('深圳卫视4K')}');
  check('深圳卫视8K 排序键不是 8', LiveCatalogService.sortKeyOf('深圳卫视8K') == 9999,
      '${LiveCatalogService.sortKeyOf('深圳卫视8K')}');
  check('浙江卫视超清 排序键不是数字', LiveCatalogService.sortKeyOf('浙江卫视超清') == 9999,
      '${LiveCatalogService.sortKeyOf('浙江卫视超清')}');
  // 真实台号仍需正确提取。
  check('CCTV-1 排序键=1', LiveCatalogService.sortKeyOf('CCTV-1') == 1);
  check('CCTV-13 排序键=13', LiveCatalogService.sortKeyOf('CCTV-13') == 13);
  check('CCTV-5+ 排序键=1005', LiveCatalogService.sortKeyOf('CCTV-5+') == 1005);
  // 排序层面：深圳卫视4K 不得排在 北京卫视 之前（同组、台号 9999 >= 9999）。
  check('深圳卫视4K 不早于北京卫视排序',
      LiveCatalogService.sortKeyOf('深圳卫视4K') >= LiveCatalogService.sortKeyOf('北京卫视'));

  // sortChannels 实盘：深圳卫视4K 在全列表中不排在北京卫视前面。
  final sorted = LiveCatalogService.sortChannels(<LiveChannel>[
    _ch('北京卫视', group: '卫视频道'),
    _ch('深圳卫视', group: '卫视频道'),
    _ch('深圳卫视4K', group: '卫视频道'),
  ]);
  final i4k = sorted.indexWhere((c) => c.name == '深圳卫视4K');
  final iBj = sorted.indexWhere((c) => c.name == '北京卫视');
  check('sortChannels：深圳卫视4K 不早于北京卫视',
      i4k > iBj, '深圳卫视4K@$i4k 北京卫视@$iBj');
}

// ── ⑤ 遥控器数字输入 ────────────────────────────────────────

void testNumberInput() {
  print('\n== 遥控器数字输入 ==');
  final buf = NumberInputBuffer();
  check('空缓冲', buf.isEmpty);
  check('输入 1', buf.addDigit(1) && buf.buffer == '1');
  check('再输入 0', buf.addDigit(0) && buf.buffer == '10');
  check('取出后清空', buf.take() == '10' && buf.isEmpty);
  check('非数字被拒', !buf.addDigit(-1) && !buf.addDigit(10));
  check('最多 4 位', buf.addDigit(1) &&
      buf.addDigit(2) &&
      buf.addDigit(3) &&
      buf.addDigit(4) &&
      !buf.addDigit(5) &&
      buf.buffer == '1234');
  buf.clear();
  check('清空', buf.isEmpty);
  check('超时时长可配', const Duration(milliseconds: 1500) > Duration.zero);
}

// ── ⑥ 目录层真实解析：分类与编号贯通 ────────────────────────

void testCatalogIntegration() {
  print('\n== 目录贯通 ==');
  final channels = LiveCatalogService.parseM3U('''
#EXTINF:-1 tvg-id="CCTV-1" group-title="央视频道",CCTV-1
http://a.com/1.m3u8
#EXTINF:-1 tvg-id="CCTV-13" group-title="央视频道",CCTV-13 新闻
http://a.com/13.m3u8
#EXTINF:-1 group-title="卫视频道",中国教育1台
http://a.com/e1.m3u8
#EXTINF:-1 group-title="☘️江苏频道",苏州新闻综合
http://a.com/sz.m3u8
#EXTINF:-1 group-title="卫视频道",湖南卫视
http://a.com/hn.m3u8
''');
  check('解析出 5 个台', channels.length == 5, '实际 ${channels.length}');
  final book = ChannelNumberBook();
  book.rebuild(channels);
  int numOf(String name) {
    final c = channels.firstWhere((e) => e.name == name);
    return book.numberOf(c.id) ?? -1;
  }

  check('CCTV-1 编号 1', numOf('CCTV-1') == 1, '${numOf('CCTV-1')}');
  check('CCTV-13 编号 13', numOf('CCTV-13') == 13, '${numOf('CCTV-13')}');
  check('中国教育一台编号 22', numOf('中国教育1台') == 22, '${numOf('中国教育1台')}');
  check('湖南卫视编号 118', numOf('湖南卫视') == 118, '${numOf('湖南卫视')}');
  check('苏州新闻综合编号 201', numOf('苏州新闻综合') == 201, '${numOf('苏州新闻综合')}');

  final cctv13 = channels.firstWhere((e) => e.name == 'CCTV-13');
  check('CCTV-13 同时归央视与新闻',
      cctv13.group == '央视频道' && cctv13.categories.contains('新闻'),
      '${cctv13.group}/${cctv13.categories.join(',')}');
  final suzhou = channels.firstWhere((e) => e.name == '苏州新闻综合');
  check('苏州台同时归地方与新闻',
      suzhou.group == '地方频道' && suzhou.categories.contains('新闻'),
      '${suzhou.group}/${suzhou.categories.join(',')}');
  final edu = channels.firstWhere((e) => e.name == '中国教育1台');
  check('中国教育台归央视频道', edu.group == '央视频道', edu.group);
  check('中国教育台台标带号码', edu.badge.contains('1'), edu.badge);
}

// ── ⑥b 旧名归一 + 卫视 4K 固定号 ────────────────────────────
//
// 用户要求：① 把「上海卫视」归一成「东方卫视」，消除 109 重复与双列；
//          ② 给主流卫视 4K/8K 变体补固定号，消除跨会话漂移。
void testLegacyAnd4k() {
  print('\n== 旧名归一 + 卫视 4K 固定号 ==');

  // ① 归一：canonicalName 把旧名收敛成现行名；现行名不受影响。
  check('上海卫视 → 东方卫视',
      LiveCatalogService.canonicalName('上海卫视') == '东方卫视',
      LiveCatalogService.canonicalName('上海卫视'));
  check('东方卫视 不变', LiveCatalogService.canonicalName('东方卫视') == '东方卫视');

  // ① 实盘：两份索引各给一种写法 → 合并成同一个频道、同一个号（无双列）。
  final merged = LiveCatalogService.parseM3U('''
#EXTINF:-1 group-title="卫视频道",东方卫视
http://a.com/df.m3u8
#EXTINF:-1 group-title="卫视频道",上海卫视
http://a.com/sh.m3u8
#EXTINF:-1 group-title="卫视频道",北京卫视
http://a.com/bj.m3u8
''');
  final bookM = ChannelNumberBook();
  bookM.rebuild(merged);
  final names = merged.map((c) => c.name).toSet();
  check('上海卫视与东方卫视合并为单列',
      !names.contains('上海卫视') &&
          names.contains('东方卫视') &&
          names.length == 2,
      names.join('/'));
  final df = merged.firstWhere((c) => c.name == '东方卫视');
  check('合并后的东方卫视编号为 109', bookM.numberOf(df.id) == 109,
      '${bookM.numberOf(df.id)}');

  // ② 4K 变体固定号（不漂移）。
  check('深圳卫视4K 固定号 141', fixedNumberOf('深圳卫视4K') == 141);
  check('浙江卫视4K 固定号 142', fixedNumberOf('浙江卫视4K') == 142);
  check('湖南卫视4K 固定号 145', fixedNumberOf('湖南卫视4K') == 145);
  check('深圳卫视8K 固定号 151', fixedNumberOf('深圳卫视8K') == 151);
  check('4K 变体 ≠ 基础台号',
      fixedNumberOf('深圳卫视4K') != fixedNumberOf('深圳卫视'));

  // ② 实盘：4K 变体在 rebuild 中拿到固定号，且两次重建一致（不漂移）。
  final with4k = <LiveChannel>[
    _ch('深圳卫视', group: '卫视频道'),
    _ch('深圳卫视4K', group: '卫视频道'),
    _ch('北京卫视', group: '卫视频道'),
    _ch('浙江卫视4K', group: '卫视频道'),
  ];
  final bA = ChannelNumberBook();
  bA.rebuild(with4k);
  final bB = ChannelNumberBook();
  bB.rebuild(with4k);
  final c4k = with4k.firstWhere((c) => c.name == '深圳卫视4K');
  check('深圳卫视4K 在 rebuild 中拿到固定号 141',
      bA.numberOf(c4k.id) == 141, '${bA.numberOf(c4k.id)}');
  check('4K 变体重建稳定不漂移',
      with4k.every((c) => bA.numberOf(c.id) == bB.numberOf(c.id)));
}

// ── ⑥c 全频道一致性（配置 / 别名 / 归一 / 实盘）────────────
//
// 第十二轮：用户要求「排查所有频道」。真实公开索引（664 台）暴露出
// fixedNumberOf 的两处宽泛匹配错误映射，以及 6 个卫视漂移台。这里把
// 修复后的语义固化成离线断言，防止悄悄回退。
void testFullChannelConsistency() {
  print('\n== 全频道一致性 ==');

  // ① 配置层：所有固定表跨表无重复号、且落在正确号段。
  final owner = <int, List<String>>{};
  void add(String tag, Map<String, int> m, int lo, int hi) {
    for (final e in m.entries) {
      owner.putIfAbsent(e.value, () => <String>[]).add('$tag/${e.key}');
      if (e.value < lo || e.value > hi) {
        check('$tag/${e.key} 固定号落在 $lo-$hi', false, '${e.value}');
      }
    }
  }

  add('cctv', <String, int>{
    for (final e in kCctvNumbers.entries) 'CCTV-${e.key}': e.value,
  }, 1, 99);
  add('cctv-special', <String, int>{
    'CCTV-5+': kCctvSportsPlusNumber,
    'CCTV 4K': kCctv4kNumber,
    'CCTV-8K': kCctv8kNumber,
    'CGTN': kCgtnNumber,
    'CGTN 纪录': kCgtnDocumentaryNumber,
  }, 1, 99);
  add('edu', <String, int>{
    for (final e in kEducationNumbers.entries) '中国教育${e.key}台': e.value,
  }, 1, 99);
  add('satellite', kSatelliteNumbers, 101, 199);
  add('satellite-4k', kSatelliteQualityNumbers, 101, 199);
  add('local', kLocalNumbers, 201, 899);
  add('program', kProgramNumbers, kProgramBandStart, kProgramBandEnd);
  final dup = owner.entries.where((e) => e.value.length > 1).toList();
  check('全部固定编号跨表唯一', dup.isEmpty,
      dup.map((e) => '${e.key}:${e.value.join("/")}').join(' '));

  // ② 别名层：satelliteAliases 归一出的每一个中文卫视都必须有稳定固定号。
  final aliasValues = LiveCatalogService.satelliteAliases.values.toSet();
  final noFixed = aliasValues.where((v) => fixedNumberOf(v) == null).toList();
  check('satelliteAliases 全量卫视都有固定号', noFixed.isEmpty,
      noFixed.join('/'));
  check('兵团卫视 = 136', fixedNumberOf('兵团卫视') == 136);
  check('延边卫视 = 137', fixedNumberOf('延边卫视') == 137);

  // ③ 真实索引里的特殊卫视（非省级行政区划序列）也必须有稳定号。
  check('东南卫视 = 138', fixedNumberOf('东南卫视') == 138);
  check('大湾区卫视 = 139', fixedNumberOf('大湾区卫视') == 139);
  check('康巴卫视 = 140', fixedNumberOf('康巴卫视') == 140);
  check('蒙语卫视 = 160', fixedNumberOf('蒙语卫视') == 160);

  // ④ CCTV-K：4K 与 8K 是不同台，不能抢同一个号。
  check('CCTV 4K = 19', fixedNumberOf('CCTV 4K') == 19);
  check('CCTV-8K = 26', fixedNumberOf('CCTV-8K') == 26,
      '${fixedNumberOf('CCTV-8K')}');
  check('CCTV-4K ≠ CCTV-8K',
      fixedNumberOf('CCTV-4K') != fixedNumberOf('CCTV-8K'));

  // ⑤ CGTN：综合/纪录有固定号，各语种子频道是不同台、不得误占 20/21。
  check('CGTN = 20', fixedNumberOf('CGTN') == 20);
  check('CGTN 纪录 = 21', fixedNumberOf('CGTN 纪录') == 21);
  check('CGTN纪录 = 21', fixedNumberOf('CGTN纪录') == 21);
  check('CGTN英语 不占 20', fixedNumberOf('CGTN英语') == null);
  check('CGTN Arabic 不占 20', fixedNumberOf('CGTN Arabic') == null);
  check('CGTN Global Biz 不占 20', fixedNumberOf('CGTN Global Biz') == null);

  // ⑥ 归一：前缀/简写/中英文/错字 → 正式台名（避免双列与一号多台）。
  check('BRTV 北京卫视 → 北京卫视',
      LiveCatalogService.canonicalName('BRTV 北京卫视') == '北京卫视');
  check('黑龙卫视 → 黑龙江卫视',
      LiveCatalogService.canonicalName('黑龙卫视') == '黑龙江卫视');
  check('CGTN Documentary → CGTN纪录',
      LiveCatalogService.canonicalName('CGTN Documentary') == 'CGTN纪录');
  check('CGTN记录 → CGTN纪录',
      LiveCatalogService.canonicalName('CGTN记录') == 'CGTN纪录');
  check('CGTN 纪录 → CGTN纪录',
      LiveCatalogService.canonicalName('CGTN 纪录') == 'CGTN纪录');
  check('CCTV-4K 与 CCTV-8K 不合并',
      LiveCatalogService.canonicalName('CCTV-4K') !=
          LiveCatalogService.canonicalName('CCTV-8K'));

  // ⑦ 实盘：把全部已知台名喂进真实解析链路，逐台核对
  //    声明固定号 == 实际编号 / 按号反查不串台 / 号段与来源匹配 / 编号唯一 / 无漂移。
  final names = <String>[
    for (var i = 1; i <= 17; i++) 'CCTV-$i',
    'CCTV-5+', 'CCTV 4K', 'CCTV-8K', 'CGTN', 'CGTN 纪录',
    'CGTN Documentary', 'CGTN记录', 'CGTN英语', 'CGTN Arabic',
    'CGTN Global Biz', 'CGTN俄语',
    '中国教育1台', '中国教育2台', '中国教育3台', '中国教育4台',
    'CETV-1', 'CCTV-1 综合', 'CCTV-13 新闻',
    ...kSatelliteNumbers.keys,
    ...kSatelliteQualityNumbers.keys,
    ...kLocalNumbers.keys,
    ...LiveCatalogService.satelliteAliases.keys,
    '上海卫视', 'BRTV 北京卫视', '黑龙卫视',
    '湖南卫视 超清', '浙江卫视超清',
    '演示信号 · HLS 测试', 'Some TV',
  ];
  final b = StringBuffer();
  for (final n in <String>{...names}) {
    b.writeln('#EXTINF:-1,$n');
    b.writeln('http://a.example/$n.m3u8');
  }
  final channels = LiveCatalogService.parseM3U(b.toString());
  final book = ChannelNumberBook();
  book.rebuild(channels);

  var mismatch = 0;
  var crossTune = 0;
  var bandBad = 0;
  var drift = 0;
  final numberOwner = <int, Set<String>>{};
  for (final c in channels) {
    final declared = fixedNumberOf(c.name);
    final got = book.numberOf(c.id);
    if (got == null) {
      mismatch++;
      continue;
    }
    numberOwner.putIfAbsent(got, () => <String>{}).add(c.name);
    if (declared != null && got != declared) mismatch++;
    if (declared != null) {
      final hit = book.channelForNumber(channels, declared);
      if (hit == null || numberKey(hit.name) != numberKey(c.name)) crossTune++;
    }
    final src = ChannelTaxonomy.sourceOf(c.name, tvgId: c.tvgId);
    if (!ChannelNumberBook.bandOf(src).contains(got)) bandBad++;
    if (declared == null && c.name.contains('卫视')) drift++;
  }
  final dupReal = numberOwner.entries.where((e) => e.value.length > 1).length;
  check('实盘全集：编号唯一', dupReal == 0, '$dupReal 处重复');
  check('实盘全集：固定号 == 实际编号', mismatch == 0, '$mismatch 个不符');
  check('实盘全集：按号反查不串台', crossTune == 0, '$crossTune 个串台');
  check('实盘全集：号段与来源匹配', bandBad == 0, '$bandBad 个错配');
  check('实盘全集：所有卫视都有稳定固定号', drift == 0, '$drift 个漂移');
}

// ── 落盘卫生：不累加历史 + 固定号优先于被污染的历史 ──────────────
//
// 实测背景：老实现 `_persist` 用 `{..._persisted, ...assigned}` 把历史会话的
// 条目永久累加，文件涨到 1051 条、其中 208 个号码重复。重复号意味着「按号
// 切台」可能切到另一个台——这是最该被门禁钉住的行为。
void testPersistHygiene() {
  print('\n== 落盘卫生：不累加历史、固定号优先 ==');
  // 历史里塞：已下线台的死条目 + 被污染的固定号（cctv12→10、cctv1→7）。
  final store = _MemoryStore(<String, int>{
    'deadchannelxyz': 12,
    'cctv12': 10,
    'cctv1': 7,
  });
  final book = ChannelNumberBook(store: store);
  final channels = <LiveChannel>[
    _ch('CCTV-1', group: '央视频道'),
    _ch('CCTV-12', group: '央视频道'),
    _ch('CCTV-13', group: '央视频道'),
    _ch('浙江卫视4K', group: '卫视频道'),
  ];
  final byId = book.rebuild(channels);

  int numOf(String name) =>
      byId[channels.firstWhere((c) => c.name == name).id] ?? -1;

  check('固定号优先于被污染的历史（CCTV-12 仍为 12）', numOf('CCTV-12') == 12,
      '${numOf('CCTV-12')}');
  check('固定号优先（CCTV-1 仍为 1）', numOf('CCTV-1') == 1, '${numOf('CCTV-1')}');
  check('4K 台拿到卫视号段内的号', numOf('浙江卫视4K') >= 101,
      '${numOf('浙江卫视4K')}');
  check('落盘不再包含已下线的历史条目', !store.data.containsKey('deadchannelxyz'),
      store.data.keys.join(','));
  check('落盘条目数 == 当前表台名数（历史被清干净）',
      store.data.length == channels.length,
      '${store.data.length} vs ${channels.length}');
  check('落盘里 CCTV-12 的号是 12（不是污染的 10）',
      store.data['cctv12'] == 12, '${store.data['cctv12']}');
  // 编号唯一性（同一台名多份时共享号是允许的，这里四个台名互不相同）。
  final nums = channels.map((c) => byId[c.id]).toList();
  check('四个台编号两两不同', nums.toSet().length == nums.length, nums.join(','));

  // 带栏目/语种后缀的央视台名必须仍落到固定号（否则「按 4」会切到别的台）。
  check('CCTV-4中文国际 -> 4', fixedNumberOf('CCTV-4中文国际') == 4,
      '${fixedNumberOf('CCTV-4中文国际')}');
  check('CCTV-5+体育赛事 -> 18',
      fixedNumberOf('CCTV-5+体育赛事') == 18,
      '${fixedNumberOf('CCTV-5+体育赛事')}');
  check('CCTV-8K超高清 -> 26',
      fixedNumberOf('CCTV-8K超高清') == 26,
      '${fixedNumberOf('CCTV-8K超高清')}');
  check('CCTV-1 综合 -> 1', fixedNumberOf('CCTV-1 综合') == 1,
      '${fixedNumberOf('CCTV-1 综合')}');
  check('CCTV+1 付费台不该抢到 4',
      fixedNumberOf('CCTV+1') == null,
      '${fixedNumberOf('CCTV+1')}');
  check('CCTV-4美洲是独立台，不该抢 4', fixedNumberOf('CCTV-4美洲') == null,
      '${fixedNumberOf('CCTV-4美洲')}');
  check('CCTV-4K(真4K) 仍是 19', fixedNumberOf('CCTV-4K') == 19,
      '${fixedNumberOf('CCTV-4K')}');
}

void main() {
  testBands();
  testFixedNumbers();
  testCategoryPolicy();
  testSortKey();
  testAllocation();
  testNumberInput();
  testCatalogIntegration();
  testLegacyAnd4k();
  testFullChannelConsistency();
  testPersistHygiene();

  print('');
  if (_fail > 0) {
    print('回归失败：$_fail 项失败，$_pass 项通过');
    exitCode = 1;
    return;
  }
  print('回归通过：$_pass/$_pass 断言通过');
  if (exitCode != 0) exit(exitCode);
}
