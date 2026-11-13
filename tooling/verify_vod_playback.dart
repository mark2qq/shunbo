// 1.0.5 第四次修回归：海报图 / 站点上限 100 / 外部代码开关 / 播放页控制 / 点播缓冲档。
//
// 五层：
//   ① 播放控制纯逻辑——快进快退夹取、相邻集、时钟、进度、按键映射；
//   ② 海报——相对路径补齐、非法地址拒绝、CMS 列表与详情都带上海报；
//   ③ 站点上限 100 + 允许执行外部代码（只跑 HTTP 接口，不运行 jar / JS）；
//   ④ 分批进度与「不按 32 截断」的真实行为；
//   ⑤ 静态护栏——播放页有返回 / 选集 / 暂停 / 快进快退 / 下一集，
//      内核有独立的点播缓冲档，片库按栏缓存。
//
// 运行：dart run tooling/verify_vod_playback.dart
import 'dart:convert';
import 'dart:io';

import 'package:shunbo/core/scheduler/source_catalog.dart';
import 'package:shunbo/core/source/source_registry.dart';
import 'package:shunbo/data/onboarding/source_config_url.dart';
import 'package:shunbo/data/onboarding/third_party_vod_service.dart';
import 'package:shunbo/data/onboarding/vod_library_store.dart';
import 'package:shunbo/data/onboarding/vod_source_address.dart';
import 'package:shunbo/features/vod/third_party_vod.dart';
import 'package:shunbo/features/vod/vod_catalog.dart';
import 'package:shunbo/features/vod/vod_facets.dart';
import 'package:shunbo/features/vod/vod_library.dart';
import 'package:shunbo/features/vod/vod_pager.dart';
import 'package:shunbo/features/vod/vod_playback_controls.dart';
import 'package:shunbo/features/vod/vod_session.dart';

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

const String _api = 'https://cms.example.test/api.php/provide/vod/';
const String _host = 'https://cms.example.test';

// ── ① 播放控制纯逻辑 ────────────────────────────────────────────

void testControls() {
  check('A01 快进 10 秒', vodSeekTarget(100, 1000, 10) == 110);
  check('A02 快退夹在 0（不会变成负数）', vodSeekTarget(3, 1000, -10) == 0);
  check('A03 快进不越过片尾', vodSeekTarget(995, 1000, 10) == 1000);
  check('A04 未知时长只做非负夹取',
      vodSeekTarget(5, 0, 10) == 15 && vodSeekTarget(5, 0, -30) == 0);
  check('A05 非法位置按 0 处理', vodSeekTarget(double.nan, 100, 10) == 10);
  check('A06 步长常量为 10 秒', kVodSeekStepSeconds == 10);

  const eps = <int>[1, 2, 3, 5, 8];
  check('A07 下一集按有序集号取相邻项（跳号也能接上）',
      vodAdjacentEpisode(eps, 3, 1) == 5);
  check('A08 最后一集没有下一集', vodAdjacentEpisode(eps, 8, 1) == null);
  check('A09 上一集', vodAdjacentEpisode(eps, 5, -1) == 3);
  check('A10 第一集没有上一集', vodAdjacentEpisode(eps, 1, -1) == null);
  check('A11 当前集不在表里时也能给出下一集',
      vodAdjacentEpisode(eps, 4, 1) == 5);
  check('A12 空剧集表返回 null', vodAdjacentEpisode(const <int>[], 1, 1) == null);
  check('A13 集序号', vodEpisodeOrdinal(eps, 3) == 3 && vodEpisodeOrdinal(eps, 9) == 0);

  check('A14 时钟 mm:ss', vodClock(65) == '01:05');
  check('A15 时钟 h:mm:ss', vodClock(3725) == '1:02:05');
  check('A16 负数 / 非有限值显示 --:--（不是 00:00）',
      vodClock(-1) == '--:--' && vodClock(double.infinity) == '--:--');
  check('A17 进度比例', vodProgress(50, 100) == 0.5);
  check('A18 未知时长进度为 0（不是满格）', vodProgress(50, 0) == 0);
  check('A19 进度越界被夹住', vodProgress(500, 100) == 1.0);

  check('A20 空格 / OK 暂停播放',
      vodActionFor('Space') == VodControlAction.togglePlay &&
          vodActionFor('Enter') == VodControlAction.togglePlay &&
          vodActionFor('Select') == VodControlAction.togglePlay);
  check('A21 左右键快退快进',
      vodActionFor('Arrow Left') == VodControlAction.backward &&
          vodActionFor('arrowright') == VodControlAction.forward);
  check('A22 上下键音量',
      vodActionFor('Arrow Up') == VodControlAction.volumeUp &&
          vodActionFor('Arrow Down') == VodControlAction.volumeDown);
  check('A23 返回键关闭', vodActionFor('Escape') == VodControlAction.close);
  check('A24 媒体键接上下曲 / 快进快退',
      vodActionFor('Media Track Next') == VodControlAction.nextEpisode &&
          vodActionFor('Media Fast Forward') == VodControlAction.forward);
  check('A25 未识别键交回框架', vodActionFor('F7') == VodControlAction.none);
  check('A26 自动隐藏时长在主流区间（3–6 秒）',
      kVodControlsIdleTimeout.inSeconds >= 3 &&
          kVodControlsIdleTimeout.inSeconds <= 6);
}

// ── ② 海报 ──────────────────────────────────────────────────────

void testPoster() {
  check('B01 绝对地址原样保留',
      resolvePosterUrl('http://img.test/a.jpg') == 'http://img.test/a.jpg');
  check('B02 省协议地址补 http',
      resolvePosterUrl('//img.test/a.jpg') == 'http://img.test/a.jpg');
  check('B03 相对路径按站点 host 补齐',
      resolvePosterUrl('/upload/vod/1.jpg', base: '$_host/api.php/provide/vod/') ==
          'https://cms.example.test/upload/vod/1.jpg');
  check('B04 没有 base 时相对路径直接丢弃',
      resolvePosterUrl('/upload/vod/1.jpg') == '');
  check('B05 空串 / 超长丢弃',
      resolvePosterUrl('') == '' &&
          resolvePosterUrl('http://a.test/${'x' * 3000}') == '');
  check('B06 非 http(s) 协议丢弃',
      resolvePosterUrl('javascript:alert(1)') == '' &&
          resolvePosterUrl('file:///etc/passwd') == '');
  check('B07 中文 / 空格路径百分号编码',
      resolvePosterUrl('http://img.test/海报 01.jpg') ==
          'http://img.test/%E6%B5%B7%E6%8A%A5%2001.jpg');
  check('B08 HTML 实体残渣被清掉',
      resolvePosterUrl('http://img.test/a.jpg&amp;x=1') ==
          'http://img.test/a.jpg&x=1');

  final list = parseCmsList(
    jsonEncode(<String, dynamic>{
      'list': <dynamic>[
        <String, dynamic>{
          'vod_id': '7',
          'vod_name': '带海报',
          'vod_pic': '/upload/vod/7.jpg',
          'type_name': '动作片',
        },
        <String, dynamic>{
          'vod_id': '8',
          'vod_name': '无海报',
          'type_name': '动作片',
        },
      ],
    }),
    baseUrl: _api,
  );
  check('B09 列表解析出海报并补成绝对地址',
      list.first.pic == 'https://cms.example.test/upload/vod/7.jpg');
  check('B10 没给海报就是空串（卡片回落色块）', list.last.pic.isEmpty);

  final details = parseCmsDetails(
    jsonEncode(<String, dynamic>{
      'list': <dynamic>[
        <String, dynamic>{
          'vod_id': '7',
          'vod_pic': '//img.test/7.jpg',
          'vod_play_url': '正片\$https://cdn.test/7.m3u8',
        },
      ],
    }),
    baseUrl: _api,
  );
  check('B11 详情也带海报（列表没给时兜底）',
      details['7']?.poster == 'http://img.test/7.jpg');

  final item = buildCmsItems(
    entries: <CmsEntry>[
      CmsEntry(
        id: '7',
        title: '带海报',
        typeName: '动作片',
        remarks: '',
        year: '2026',
        area: '',
        pic: 'https://img.test/7.jpg',
      ),
    ],
    details: details,
    sourceId: 's',
  ).first;
  check('B12 条目带上海报地址', item.posterUrl == 'https://img.test/7.jpg');

  final contract = scanVodConfigText(
    jsonEncode(<String, dynamic>{
      'items': <dynamic>[
        <String, dynamic>{
          'id': 'c1',
          'title': '契约片',
          'poster': 'https://img.test/c1.jpg',
          'episodes': <dynamic>[
            <String, dynamic>{'url': 'https://cdn.test/c1.m3u8'},
          ],
        },
      ],
    }),
    sourceId: 's',
  );
  check('B13 契约 JSON 的 poster 字段被采用',
      contract.contractItems.first.posterUrl == 'https://img.test/c1.jpg');

  final page = _src('lib/ui/vod/vod_page.dart');
  check('B14 卡片真的渲染网络海报（Image.network）',
      page.contains('Image.network('));
  check('B15 海报按卡片宽度解码，不按原图（cacheWidth）',
      page.contains('cacheWidth:'));
  check('B16 加载失败回落色块并记住，不反复重试',
      page.contains('_markDead') && page.contains('errorBuilder'));
  check('B17 内置片库仍然没有海报（不硬凑假海报）',
      VodCatalog.all.every((i) => i.posterUrl.isEmpty));
}

// ── ③ 站点上限 100 / 允许执行外部代码 ───────────────────────────

String _config(int sites, {int type = 1, bool urlApi = true}) => jsonEncode(
      <String, dynamic>{
        'name': '压测',
        'sites': <dynamic>[
          for (var i = 0; i < sites; i++)
            <String, dynamic>{
              'key': 'k$i',
              'name': '站$i',
              'type': type,
              'api': urlApi ? 'https://s$i.test/api.php/provide/vod/' : 'csp_$i',
            },
        ],
      },
    );

void testSiteLimits() {
  check('C01 站点上限常量是 100', kMaxThirdPartySites == 100);
  check('C02 条目上限是进程内安全天花板（分页之后不再是「一次导入多少」）',
      kMaxThirdPartyItems == 20000 && kVodCacheMaxItems == 10000);
  check('C03 每站取 20 部（与 1.0.5 上一版一致，不再压缩片量）',
      kMaxThirdPartyItemsPerSite == 20);

  final service = _src('lib/data/onboarding/third_party_vod_service.dart');
  check('C04 import 的默认上限直接引用常量（不是写死 32）',
      service.contains('int maxSites = kMaxThirdPartySites'));

  // type:3 + api 是 http(s)：开 / 关开关两种结论。
  final off = scanVodConfigText(_config(3, type: 3),
      sourceId: 's', allowExternalCode: false);
  check('C05 关闭开关时 type:3 站点全部跳过',
      off.kind == VodConfigKind.pluginOnly && off.pluginSites == 3);

  final on = scanVodConfigText(_config(3, type: 3),
      sourceId: 's', allowExternalCode: true);
  check('C06 打开开关后 type:3 站点进入探测池',
      on.kind == VodConfigKind.cmsSites &&
          on.sites.length == 3 &&
          on.externalCodeSites == 3,
      on.reason);
  check('C07 放行的站点被标记为 plugin（可观测）',
      on.sites.every((s) => s.plugin));

  final csp = scanVodConfigText(_config(3, type: 3, urlApi: false),
      sourceId: 's', allowExternalCode: true);
  check('C08 api 是 csp_ 脚本名的站点仍然跳过（真跑不了）',
      csp.kind == VodConfigKind.pluginOnly);

  final mixed = scanVodConfigText(_config(4),
      sourceId: 's', allowExternalCode: true);
  check('C09 type:1 站点的行为不受开关影响',
      mixed.kind == VodConfigKind.cmsSites && mixed.sites.length == 4);

  final settings = VodSourceAddressSettings.defaults;
  check('C10 默认允许执行外部代码（插件站点可用 HTTP 接口尝试）',
      settings.allowExternalCode);
  check('C11 开关可落盘并读回',
      VodSourceAddressSettings.fromJson(<String, dynamic>{
            'allowExternalCode': false,
          }).allowExternalCode ==
          false);
  check('C12 旧配置没有该键时默认为开（升级后片源不会变少）',
      VodSourceAddressSettings.fromJson(<String, dynamic>{'enabled': true})
          .allowExternalCode);
  check('C13 copyWith 能切换',
      settings.copyWith(allowExternalCode: false).allowExternalCode == false);
  check('C14 toJson 写成 allowExternalCode 键',
      settings.toJson().containsKey('allowExternalCode'));

  final section = _src('lib/ui/settings/vod_source_section.dart');
  // 第二十一次修：设置页按需求收敛成单输入框，三个开关从 UI 移除。
  // 能力本身没删 —— 既有设定仍透传给生成 / 更新链路；解析层零代码执行
  // 的安全基线照旧锁死。断言按新口径改写，不是放宽。
  check('C15 设置页不再暴露外部代码开关，但既有设定仍透传到更新链路',
      !section.contains('允许执行外部代码') &&
          !section.contains('SwitchListTile(') &&
          _src('lib/main.dart').contains('allowExternalCode: s.allowExternalCode'));
  check('C16 解析层仍如实声明零代码执行（本机不运行 jar / 脚本）',
      _src('lib/features/vod/third_party_vod.dart').contains('零代码执行') &&
          !_src('lib/features/vod/third_party_vod.dart').contains('Process.run'));
  check('C17 解析层仍是零代码执行（无子进程 / 无反射）',
      !_src('lib/features/vod/third_party_vod.dart').contains('Process.run'));
}

// ── ④ 分批进度与「不按 32 截断」 ────────────────────────────────

Map<String, String> _cmsPages(List<String> hosts, {int sites = 1}) {
  final pages = <String, String>{};
  for (final host in hosts) {
    final site = CmsSite(key: host, name: host, api: host);
    pages[site.listUrl] = jsonEncode(<String, dynamic>{
      'list': <dynamic>[
        <String, dynamic>{
          'vod_id': '1',
          'vod_name': '$host 的片',
          'type_name': '动作片',
          'vod_pic': '/p.jpg',
        },
      ],
    });
    pages[site.detailUrl(<String>['1'])] = jsonEncode(<String, dynamic>{
      'list': <dynamic>[
        <String, dynamic>{
          'vod_id': '1',
          'vod_pic': '/p.jpg',
          'vod_play_url': '正片\$https://cdn.test/$sites.m3u8',
        },
      ],
    });
    // 1.0.5 第三次修：分页走 `?ac=detail&pg=N` 合并接口（一次请求给全 20 部），
    // 夹具必须同时提供这一页，否则测的就变成「站不可达」而不是「分页行为」。
    pages[site.detailPageUrl(1)] = jsonEncode(<String, dynamic>{
      'page': 1,
      'pagecount': 1,
      'limit': '20',
      'total': 1,
      'list': <dynamic>[
        <String, dynamic>{
          'vod_id': '1',
          'vod_name': '$host 的片',
          'type_name': '动作片',
          'vod_pic': '/p.jpg',
          'vod_play_url': '正片\$https://cdn.test/$sites.m3u8',
        },
      ],
    });
  }
  return pages;
}

Future<void> testProgressAndBudget() async {
  // 40 个站点，只有第 35 个能出片：maxSites=32 时它会从未被请求。
  final hosts = <String>[
    for (var i = 1; i <= 40; i++) 'https://s$i.test/api.php/provide/vod/',
  ];
  final pages = _cmsPages(hosts, sites: 40);
  final config = jsonEncode(<String, dynamic>{
    'name': '四十站',
    'sites': <dynamic>[
      for (var i = 0; i < hosts.length; i++)
        <String, dynamic>{
          'key': 'k$i',
          'name': '站$i',
          'type': 1,
          'api': hosts[i],
        },
    ],
  });

  final requested = <String>[];
  final svc = ThirdPartyVodService(fetcher: (url, {allowInsecureHttp = false}) async {
    requested.add(url);
    if (url == 'https://cfg.test/config.json') {
      return SourceConfigUrlResult.ok(
          text: config, originLabel: 'cfg.test', bytes: config.length);
    }
    final body = pages[url];
    if (body == null) {
      return const SourceConfigUrlResult.fail(
          SourceConfigUrlFailure.timeout, '超时');
    }
    return SourceConfigUrlResult.ok(
        text: body, originLabel: 's', bytes: body.length);
  });

  final partials = <int>[];
  final report = await svc.import(
    url: 'https://cfg.test/config.json',
    allowInsecureHttp: false,
    itemsPerSite: 1,
    onProgress: (p) => partials.add(p.items.length),
  );
  check('D01 第 35 个站点也被请求了（不再按 32 截断）',
      requested.any((u) => u.startsWith(hosts[34])));
  check('D02 40 个站点全部探测过', report.loadedSites == 40, report.message);
  // 40 个站 / 每批 5 个 = 8 批，每批回传一次进度。
  check('D03 分批进度回调确实按批触发', partials.length == 8, '${partials.length}');
  check('D04 进度条目数单调递增',
      partials.every((n) => n > 0) &&
          List<int>.generate(partials.length, (i) => i)
              .every((i) => i == 0 || partials[i] >= partials[i - 1]));
  check('D05 海报跟着条目一起入库（每个站点都补了绝对地址）',
      report.items.every((i) => i.posterUrl == 'https://s1.test/p.jpg' ||
          i.posterUrl.startsWith('https://s') && i.posterUrl.endsWith('/p.jpg')));

  // 预算：全部失败时必须在预算内收工，不能转圈。
  final slowStarted = DateTime.now();
  final slow = ThirdPartyVodService(fetcher: (url, {allowInsecureHttp = false}) async {
    if (url == 'https://cfg2.test/config.json') {
      return SourceConfigUrlResult.ok(text: config, originLabel: 'x', bytes: 1);
    }
    return const SourceConfigUrlResult.fail(
        SourceConfigUrlFailure.timeout, '超时');
  });
  final failed = await slow.import(
    url: 'https://cfg2.test/config.json',
    allowInsecureHttp: false,
    budget: const Duration(milliseconds: 1),
  );
  check('D06 预算到点收工并如实报失败', !failed.ok, failed.message);
  check('D07 预算生效（没有把所有站点都试一遍）',
      DateTime.now().difference(slowStarted).inSeconds < 30);
}

// ── ⑤ 静态护栏：播放页 / 内核档 / 缓存 ──────────────────────────

void testStaticRails() {
  final page = _src('lib/ui/vod/vod_page.dart');
  final bar = _src('lib/ui/vod/player_control_bar.dart');
  final tuner = _src('lib/core/player/media_kit_player_controller.dart');
  final controller = _src('lib/core/player/player_controller.dart');
  final library = _src('lib/features/vod/vod_library.dart');

  check('E01 播放页接管返回键（页内切换必须自己接 PopScope）',
      page.contains('PopScope(') && page.contains('canPop: _view == _VodView.browse'));
  // 第二十次修（用户红标）：顶栏「返回」箭头与「选集」一起去掉，改成右上角
  // 唯一的「关闭」出口；Esc / 物理返回键仍走 _back 的分层返回。
  check('E02 播放页去顶栏返回箭头，改单出口「关闭」',
      !page.contains("tooltip: '返回（Esc / 返回键）'") &&
          !page.contains("label: const Text('选集'") &&
          page.contains('onPressed: _closePlayback') &&
          page.contains("label: const Text('关闭'") &&
          page.contains('case VodControlAction.close:'));
  check('E03 有暂停 / 播放', page.contains('_togglePause'));
  // 1.0.5 第九次修：控制栏整体搬进 player_control_bar.dart，
  // 按钮图标与文案随之搬家。断言改成「页面提供回调 + 控制栏画出按钮」两头对齐，
  // 而不是继续在页面里找一个已经搬走的图标字面量（那样会变成假绿）。
  check('E04 有快进 / 快退 10 秒（控制栏出按钮、页面出回调）',
      bar.contains('Icons.replay_10_rounded') &&
          bar.contains('Icons.forward_10_rounded') &&
          bar.contains('widget.onSkip(-kVodSeekStepSeconds)') &&
          page.contains('onSkip: (delta) => unawaited(_seekBy(delta))'));
  check('E05 有上一集 / 下一集',
      bar.contains('Icons.skip_previous_rounded') &&
          bar.contains('Icons.skip_next_rounded') &&
          page.contains('onPrevious: () => unawaited(_playAdjacent(-1))') &&
          page.contains('onNext: () => unawaited(_playAdjacent(1))'));
  check('E06 有选集面板（当前集高亮 + 点选即播）',
      page.contains('_episodePanel') &&
          page.contains('autofocus: active') &&
          page.contains('选集（\${episodes.length}）'));
  // 1.0.5 第九次修：Material `Slider` 换成自绘进度轨（要画缓冲段 + 指针跟随气泡，
  // Slider 两样都给不了）。断言改成锁「拖动中只预览、松手才 seek」这一行为契约，
  // 这才是 E07 原本想守的东西，不是「必须用 Slider」这个实现细节。
  check('E07 进度条可拖动（拖动中预览、松手才 seek）',
      bar.contains('onHorizontalDragUpdate') &&
          bar.contains('widget.onScrub(') &&
          bar.contains('widget.onSeek(') &&
          !bar.contains('Slider('));
  check('E08 控制条自动隐藏 + 点画面切换',
      page.contains('kVodControlsIdleTimeout') &&
          page.contains('_toggleControls'));
  check('E09 遥控器 / 键盘按键接到纯逻辑',
      page.contains('vodActionFor(') && page.contains('onKeyEvent: _onKey'));
  check('E10 退出播放页会停播并回到列表（详情页已删除）',
      page.contains('unawaited(_pauseForLeave());') &&
          page.contains('_view = _VodView.browse;') &&
          !page.contains('_VodView.detail'));

  check('E11 内核声明点播 / 直播两档缓冲',
      controller.contains('abstract interface class PlaybackTuner') &&
          controller.contains('applyVodProfile') &&
          controller.contains('applyLiveProfile'));
  check('E12 内核实现两档', tuner.contains('PlaybackTuner') &&
      tuner.contains('Future<void> applyVodProfile()'));
  // 1.0.5 第八次修：预读 15 → 6、攒 2 秒 → 1 秒。抗抖靠的是 cache-secs 30 +
  // demuxer-max-bytes（24MB），不是起手预读量；15 秒预读在弱源上会与首帧
  // 解码抢同一条连接，反而把「出画面」推后。
  check('E13 点播档：30 秒缓存 + 6 秒预读（起播不抢首帧带宽）',
      tuner.contains("'cache-secs': '30'") &&
          tuner.contains("'demuxer-readahead-secs': '6'"));
  check('E14 点播档：起播先攒 1 秒（既挡抖动又不白等）',
      tuner.contains("'cache-pause': 'yes'") &&
          tuner.contains("'cache-pause-wait': '1'"));
  check('E15 点播档：断线自动重连（源站掐连接不再当成 EOF）',
      tuner.contains('reconnect=1') && tuner.contains('reconnect_delay_max=5'));
  check('E16 直播档保持原值并把重连参数撤掉',
      tuner.contains("'cache-secs': '6'") &&
          tuner.contains("'demuxer-readahead-secs': '4'") &&
          tuner.contains("'demuxer-lavf-o': ''"));
  // 1.0.5 第八次修：mpv 默认网络超时 60 秒，弱源挂死时画面冻一分钟才报错，
  // 用户感知是「卡死」。10 秒把控制权更早交回上层重连 / 换源。
  check('E17 点播档：网络超时收到 10 秒（挂死不再冻一分钟）',
      tuner.contains("'network-timeout': '10'"));
  // 属性并发打进去：5 次串行 IPC 每次都叠在「点开视频」这段等待上。
  check('E18 内核属性并发下发（不再逐个 await）',
      tuner.contains('Future.wait<void>([') &&
          !tuner.contains('for (final entry in entries.entries) {'));
  // 幂等：连播下一集不该重复设同一批属性。
  check('E19 点播档幂等（已在档内直接返回）',
      tuner.contains('if (_vodProfile) return;'));
  check('E17 播放前切点播档、离开切回直播档',
      page.contains('await _applyVodProfile();') &&
          page.contains('await _applyLiveProfile();'));

  check('E18 片库按栏缓存（切栏目不再每次重算）',
      library.contains('_sectionCache') && library.contains('_invalidateCache'));
  check('E19 片库暴露 revision 供 UI 判断真的变了',
      library.contains('int get revision'));

  final registry = SourceRegistry();
  final catalog = SourceCatalog();
  final lib = VodLibrary(registry: registry, catalog: catalog);
  final first = lib.inSection(VodSection.movies);
  final second = lib.inSection(VodSection.movies);
  check('E20 同一栏连续取两次是同一个列表实例', identical(first, second));
  final rev = lib.revision;
  lib.install(
    sourceId: '外部点播·t',
    incoming: <VodItem>[
      VodItem(
        id: '外部点播·t:1',
        title: '外部片',
        subtitle: '',
        description: '',
        license: '',
        section: VodSection.movies,
        episodes: const <VodEpisode>[
          VodEpisode(number: 1, title: '正片', url: 'https://cdn.test/x.m3u8'),
        ],
        sourceId: '外部点播·t',
        // 1.0.5 第十一次修：电影栏目只收有电影类目证据的条目。
        // 夹具要反映真实数据（接口会带 type_name），不能再用「空类目」冒充电影。
        typeName: '动作片',
      ),
    ],
    sourceName: 't',
  );
  check('E21 装库后缓存失效并刷新出外部条目',
      lib.revision > rev && lib.inSection(VodSection.movies).length ==
          first.length + 1);

  check('E22 大响应解析走 isolate（不阻塞主线程）',
      _src('lib/features/vod/third_party_vod.dart').contains('Isolate.run'));
}

// ── ⑤b 底部控制栏（1.0.5 第九次修）────────────────────────────
//
// 分成两半：
//   · K01–K14 跑**纯函数**（档位文案 / 画质标签 / 缓冲夹取 / F 键映射），
//     这些是「算错了用户立刻能看出来」的地方，必须能裸跑；
//   · K15–K23 锁**结构契约**（三段轨道、悬停预览、状态色、三档密度、
//     拖动不重建整页、全屏归属外壳）。这类断言只能查源码，但它们锁的是行为
//     而不是实现细节 —— 例如 K15 不强求某个控件，只要求「缓冲段真的参与了绘制」。
void testControlBar() {
  print('\n== K. 底部控制栏 ==');
  final bar = _src('lib/ui/vod/player_control_bar.dart');
  final page = _src('lib/ui/vod/vod_page.dart');
  final shell = _src('lib/app/app_shell.dart');
  final controller = _src('lib/core/player/player_controller.dart');
  final tuner = _src('lib/core/player/media_kit_player_controller.dart');

  // ① 纯函数：档位文案
  check('K01 倍速文案整数档补一位小数（1.0x 而不是 1x）',
      vodRateLabel(1.0) == '1.0x' && vodRateLabel(2.0) == '2.0x',
      vodRateLabel(1.0));
  check('K02 倍速文案半档保留两位（0.75x / 1.25x）',
      vodRateLabel(0.75) == '0.75x' && vodRateLabel(1.25) == '1.25x');
  check('K03 倍速文案对非法值回落到 1.0x',
      vodRateLabel(0) == '1.0x' && vodRateLabel(double.nan) == '1.0x');
  check('K04 档位表覆盖 0.5–2.0 且含 1.0',
      kVodRateOptions.first == 0.5 &&
          kVodRateOptions.last == 2.0 &&
          kVodRateOptions.contains(1.0),
      kVodRateOptions.join(','));

  // ② 纯函数：画质标签（采集源没有档位，只能报实测分辨率）
  check('K05 实测 1920×1080 → 1080P',
      vodResolutionLabel(1920, 1080) == '1080P');
  check('K06 letterbox（1920×800）按长边判 → 仍是 1080P',
      vodResolutionLabel(1920, 800) == '1080P');
  check('K07 4K / 2K / 720P / 480P / 360P 分档正确',
      vodResolutionLabel(3840, 2160) == '4K' &&
          vodResolutionLabel(2560, 1440) == '2K' &&
          vodResolutionLabel(1280, 720) == '720P' &&
          vodResolutionLabel(854, 480) == '480P' &&
          vodResolutionLabel(640, 360) == '360P');
  check('K08 未出画（0×0）返回空串，不编一个假档名',
      vodResolutionLabel(0, 0) == '' && vodResolutionLabel(1920, 0) == '');

  // ③ 纯函数：音量与缓冲
  check('K09 音量文案四舍五入并夹取',
      vodVolumeLabel(72.4) == '72%' &&
          vodVolumeLabel(-5) == '0%' &&
          vodVolumeLabel(140) == '100%');
  check('K10 缓冲比例不小于已播比例（弱源抖动时不画倒缩的缓冲段）',
      vodBufferedProgress(10, 30, 100) == 0.3);
  check('K11 未知时长时缓冲与进度都是 0',
      vodBufferedProgress(20, 10, 0) == 0 && vodBufferedProgress(0, 0, -1) == 0);

  // ④ 纯函数：全屏键
  check('K12 F 键映射为全屏',
      vodActionFor('f') == VodControlAction.toggleFullscreen &&
          vodActionFor('F') == VodControlAction.toggleFullscreen);
  check('K13 M 键仍是选集（没有被 F 抢走）',
      vodActionFor('m') == VodControlAction.toggleEpisodes);

  // ⑤ 结构：进度轨三段 + 悬停预览
  check('K14 进度轨画三段（未缓冲 / 已缓冲 / 已播）',
      bar.contains('widget.secondary') &&
          bar.contains('Colors.white.withValues(alpha: 0.34)') &&
          bar.contains('Paint()..color = AppTheme.accent'));
  check('K15 悬停气泡贴着指针走，且两端做夹取（不半截跑到栏外）',
      bar.contains('Widget _bubble(double fraction, double width)') &&
          bar.contains('.clamp(0.0, (width - bubbleWidth)'));
  check('K16 拖动中显示拖动值、松手才 seek',
      bar.contains('widget.onScrub(f)') &&
          bar.contains('onHorizontalDragEnd') &&
          bar.contains('_commit(f)'));

  // ⑥ 结构：状态反馈与统一命中区
  check('K17 悬停 / 激活 / 禁用三态都有明确色值',
      bar.contains('Colors.white.withValues(alpha: 0.12)') &&
          bar.contains('AppTheme.accent.withValues(alpha: 0.24)') &&
          bar.contains('Colors.white.withValues(alpha: 0.26)'));
  check('K18 不用 IconButton / InkWell（水波纹画在 Material 上，会被视频盖住）',
      !bar.contains('IconButton(') && !bar.contains('InkWell('));
  check('K19 按钮统一 9 圆角、统一 38 命中区',
      bar.contains('BorderRadius.circular(9)') &&
          bar.contains('this.size = 38'));

  // ⑦ 结构：音量 / 清晰度 / 倍速 / 全屏
  check('K20 音量悬浮展开 + 数值预览',
      bar.contains('width: _open ? 88 : 0') &&
          bar.contains('formatter: (r) => vodVolumeLabel(r * 100)'));
  check('K21 清晰度 / 倍速 / 全屏都在控制栏里',
      bar.contains('Widget _buildPanel(double available)') &&
          bar.contains("tooltip: '清晰度'") &&
          bar.contains("tooltip: '播放倍速'") &&
          bar.contains('Icons.fullscreen_rounded') &&
          bar.contains('Icons.fullscreen_exit_rounded'));
  check('K22 清晰度选项由页面算、且**只有自动一档**（采集源没有画质档位）',
      page.contains('List<PlayerQualityOption> _qualityOptions()') &&
          page.contains("id: 'auto'") &&
          page.contains('实测 \$res') &&
          page.contains('_qualityNote'));

  // ⑧ 结构：三档密度与拖动性能契约
  check('K23 三档密度按内容宽度倒推（900 / 560 / compact）',
      bar.contains('if (width >= 900) return _Density.full;') &&
          bar.contains('if (width >= 560) return _Density.medium;') &&
          bar.contains('return _Density.compact;'));
  check('K24 拖动预览留在控制栏内部（页面不为拖动重建整页）',
      bar.contains('_scrubPreview') &&
          page.contains('position: position,') &&
          !page.contains('double? _dragValue;'));

  check('K30 音量也走 notifier（拖音量滑块不为每个像素重建整页）',
      page.contains('final ValueNotifier<double> _volumeN') &&
          page.contains('_resolution, _volumeN])') &&
          !page.contains('setState(() => _volume = v)'));

  // ⑨ 结构：全屏归属外壳 + 返回键先退全屏
  // 直播页本来就有一个入口，加上四个点播页（电影/电视剧/纪录片/短视频）
  // 共 5 处 —— 全都指向外壳的同一个 `_toggleFullscreen`，
  // 不存在「各页各存一份全屏状态」的分裂。
  // 全屏状态由外壳统一透传。
  //
  // 断言口径（1.0.5 第十二次修改正）：原来写死「直播 1 处 + 点播 4 处 = 5」，
  // 第 3 项新增「动漫」栏目后变成 6 处，写死的数字会把「加栏目」误判成回归。
  // 现在改成「点播页实例数 + 1（直播页）= 透传处数」，而点播页实例数直接从
  // `VodSection.values` 数出来 —— 加栏目不会破门禁，少给某一个页面透传才会。
  final vodSectionCount =
      RegExp(r'VodSection\.\w+,').allMatches(shell).length;
  final vodPageCount = RegExp(r'VodPage\(').allMatches(shell).length;
  final fullscreenPass =
      RegExp(r'onToggleFullscreen: _toggleFullscreen,').allMatches(shell).length;
  final fullscreenProp =
      RegExp(r'fullscreen: _fullscreen,').allMatches(shell).length;
  check(
      'K25 全屏状态由外壳统一透传（直播 1 处 + 点播 ${vodPageCount} 处）',
      vodPageCount == vodSectionCount &&
          fullscreenPass == vodPageCount + 1 &&
          fullscreenProp == vodPageCount + 1,
      'VodPage=$vodPageCount section=$vodSectionCount '
          '透传=$fullscreenPass/$fullscreenProp');
  check('K26 播放页返回键先退全屏，再退播放',
      page.contains('if (widget.fullscreen) {') &&
          page.contains('widget.onToggleFullscreen();') &&
          page.contains('case VodControlAction.toggleFullscreen:'));

  // ⑩ 结构：内核能力真的接上了（不是 UI 自己编的读数）
  check('K27 内核声明缓冲 / 变速 / 实测分辨率三个能力',
      controller.contains('abstract interface class BufferProbe') &&
          controller.contains('abstract interface class PlaybackRateControl') &&
          controller.contains('int get pictureWidth'));
  check('K28 media_kit 内核真的实现了它们',
      tuner.contains('BufferProbe') &&
          tuner.contains('PlaybackRateControl') &&
          tuner.contains('Future<void> setRate(double rate)') &&
          tuner.contains('double get bufferedSeconds'));
  check('K29 页面按能力探测取读数（内核不支持就不假装有）',
      page.contains('probe is BufferProbe ? probe.bufferedSeconds : 0') &&
          page.contains('if (p is! PlaybackRateControl) return;'));
}


// ── ⑧ 播放页右栏详情（1.0.5 第二十二次修）───────────────────────────
//
// 用户四条要求落成的样子：点卡片直接进播放、详情搬进右栏、右栏 8 秒无操作
// 自动收缩、交互重新展开并重置计时。这里把「时长、宽度、状态机、接线」逐条锁死。
void testDetailPanel() {
  final page = _src('lib/ui/vod/vod_page.dart');
  final controls = _src('lib/features/vod/vod_playback_controls.dart');

  check('T01 右栏收缩超时 8 秒，与控制条 4 秒各自独立',
      kVodDetailIdleTimeout.inSeconds == 8 &&
          kVodControlsIdleTimeout.inSeconds == 4 &&
          kVodDetailIdleTimeout != kVodControlsIdleTimeout);
  check('T02 8 秒写成常量而不是散落在 UI 里',
      controls.contains(
          'const Duration kVodDetailIdleTimeout = Duration(seconds: 8);'));

  check('T03 右栏宽度按视口 32% 取，夹在 340–440',
      (vodDetailWidth(1280) - 409.6).abs() < 0.01 &&
          vodDetailWidth(3840) == kVodDetailMaxWidth &&
          vodDetailWidth(800) == kVodDetailMinWidth &&
          vodDetailWidth(0) == kVodDetailMinWidth &&
          vodDetailWidth(double.nan) == kVodDetailMinWidth);
  // 第二十四次修：原来的「收起后留 44 px 窄条」被用户红标点掉
  // （「隐藏后还会有详情条，要参考左栏完全隐藏」），改成整块滑出屏幕。
  final shell = _src('lib/app/app_shell.dart');
  check('T04 收起不是窄条而是整块滑出，滑出时长与左栏同为 240 ms',
      kVodDetailSlideDuration == const Duration(milliseconds: 240) &&
          shell.contains('duration: const Duration(milliseconds: 240)') &&
          page.contains('right: _detailExpanded ? 0 : -width') &&
          !page.contains('kVodDetailRailWidth') &&
          !page.contains('_detailRail('));

  check('T05 进播放页即展开（详情页没了，进来不能是空的）',
      vodDetailExpandedAfter(false, VodDetailInput.enterPlayback));
  check('T06 指针进面板 / 贴到右边缘热区都展开',
      vodDetailExpandedAfter(false, VodDetailInput.pointerOnPanel) &&
          vodDetailExpandedAfter(false, VodDetailInput.pointerOnEdge));
  check('T07 I / D 键是 toggle（按一次开、再按一次关）',
      vodDetailExpandedAfter(false, VodDetailInput.toggleKey) &&
          !vodDetailExpandedAfter(true, VodDetailInput.toggleKey));
  check('T08 8 秒到点收缩',
      !vodDetailExpandedAfter(true, VodDetailInput.idleTimeout));
  check('T09 点画面别处只刷新计时、不改展开状态',
      vodDetailExpandedAfter(true, VodDetailInput.pointerElsewhere) &&
          !vodDetailExpandedAfter(false, VodDetailInput.pointerElsewhere));
  check('T10 展开态才计时，收起态不在后台空转',
      vodDetailRestartsTimer(true) && !vodDetailRestartsTimer(false));

  check('T11 点卡片直连播放，列表不再有详情入口',
      page.contains('unawaited(_openAndPlay(items[i]))') &&
          !page.contains('_openDetail(') &&
          !page.contains('Widget _buildDetail()'));

  final bodyIdx = page.indexOf('Widget _detailBody(');
  final bodyEnd = page.indexOf('Widget _detailStatus(');
  final body = (bodyIdx >= 0 && bodyEnd > bodyIdx)
      ? page.substring(bodyIdx, bodyEnd)
      : '';
  check('T12 右栏内容：海报 + 标题 + 类型 + 简介 + 授权说明',
      body.contains('_Poster(') &&
          body.contains('AspectRatio(') &&
          body.contains('item.title') &&
          body.contains('item.subtitle') &&
          body.contains('item.description') &&
          body.contains('item.license'));

  final panelIdx = page.indexOf('..._detailLayer(item),');
  final barIdx = page.indexOf('_controlBar(item, hasPrev, hasNext)');
  check('T13 右栏在播放页 Stack 里，且排在控制层下面（进度条不被挡）',
      panelIdx > 0 && barIdx > panelIdx);
  check('T14 收起后屏幕上不留任何东西，靠右边缘热区重新呼出（同左栏）',
      page.contains('EdgeRevealHandle(') &&
          page.contains('side: EdgeSide.right') &&
          page.contains('VodDetailInput.pointerOnEdge') &&
          page.contains('if (!_detailExpanded)') &&
          !page.contains("ValueKey<String>('vod-detail-rail')") &&
          !page.contains('_detailRail(') &&
          // 左栏也是这么呼出的（同一个组件），口径必须一致。
          shell.contains('EdgeRevealHandle(side: EdgeSide.left'));
  check('T15 键盘 I / D / 信息键能唤出右栏',
      page.contains("rawKey == 'keyi'") &&
          page.contains("rawKey == 'keyd'") &&
          page.contains("rawKey == 'info'") &&
          page.contains('_toggleDetail();'));
  check('T16 离开播放页与销毁时取消右栏计时',
      page.contains('void _leavePlaying(') &&
          page.contains('_detailTimer?.cancel();'));
  check('T17 取地址中 / 取不到时不收缩（原因不能被藏起来）',
      page.contains('if (_resolving || _resolveError != null) return;'));

  // ── 第二十三次修：右栏改成「像左栏那样」按悬停伸缩 ────────────────
  check('T18 移出右栏 1.2 秒后收缩（与左栏离栏延迟同一档）',
      kVodDetailHoverExitDelay.inMilliseconds == 1200 &&
          !vodDetailExpandedAfter(true, VodDetailInput.pointerLeftPanel) &&
          controls.contains('const Duration kVodDetailHoverExitDelay'));
  check('T19 悬停用 onEnter / onExit 两个事件（不再靠 onHover 续命）',
      page.contains('onEnter: (_) => _pokeDetail(') &&
          page.contains(
              'onExit: (_) => _pokeDetail(VodDetailInput.pointerLeftPanel)') &&
          !page.contains('onHover: (_) => _pokeDetail('));
  check('T20 指针停在栏内不排收缩计时（停在上面就一直开着）',
      page.contains('_detailHovering = true;') &&
          page.contains('void _cancelDetailTimer()') &&
          page.contains('if (!_detailExpanded || _detailHovering) return;'));
  check('T21 右栏底色与左栏同一个出口（AppTheme.panelScrim，不再自调一档黑）',
      page.contains('color: AppTheme.panelScrim,') &&
          !page.contains('Colors.black.withValues(alpha: 0.84)') &&
          !page.contains('Colors.black.withValues(alpha: 0.55)'));
  check('T22 右上角「收起」箭头已删除（收起靠悬停 / 计时 / I·D 键）',
      !page.contains('Icons.chevron_right_rounded') &&
          !page.contains('tooltip: \'收起详情'));
  check('T23 收起只把同一块面板滑出去，不再换一套「窄条」UI（状态不重建）',
      page.contains('width: width,') &&
          !page.contains('AnimatedSwitcher(') &&
          page.contains('child: _detailBody(item, width),'));
  check('T24 右栏收起 / 展开两个方向都受同一个 setState 驱动',
      page.contains('setState(() => _detailExpanded = false);') &&
          page.contains('setState(() => _detailExpanded = next);'));

  // ── 第二十八次修：选集右栏 6 秒无响应自动收起 ────────────────────
  //
  // 用户红标：「播放页面，选集弹出的右边栏…当无响应 6 秒需要自动隐藏」。
  // 原来这个抽屉只能靠右上角 X 或再按一次 M 关掉 —— 点开之后去干别的，
  // 它就一直在画面右侧杵着。现在套一层 PanelIdleHider，无响应 6 秒自己收。
  final hider = _src('lib/ui/vod/panel_idle_hider.dart');
  check('T25 选集抽屉套上「无响应自动收起」外壳，闲置时长 6 秒',
      kVodEpisodeIdleHide.inSeconds == 6 &&
          kVodEpisodeIdleHide.inMilliseconds == 6000 &&
          controls
              .contains('const Duration kVodEpisodeIdleHide = Duration(seconds: 6);') &&
          page.contains('child: PanelIdleHider(') &&
          page.contains('idle: kVodEpisodeIdleHide,'));
  check('T26 收起动作走既有开合状态，且到点前先复核抽屉还在',
      page.contains('if (!mounted || !_showEpisodes) return;') &&
          page.contains('setState(() => _showEpisodes = false);') &&
          // 收完要让控制条亮回来（用户下一步多半是拖进度或换集）
          page.contains('_pokeControls();'));
  check('T27 「有响应」六类信号都重置计时器（指针 / 点击 / 滚轮 / 滚动 / 焦点 / 按键）',
      hider.contains('onHover: (_) => _restart()') &&
          hider.contains('onPointerDown: (_) => _restart()') &&
          hider.contains('onPointerMove: (_) => _restart()') &&
          hider.contains('onPointerSignal: (_) => _restart()') &&
          hider.contains('NotificationListener<ScrollNotification>') &&
          hider.contains('onKeyEvent:') &&
          hider.contains('return KeyEventResult.ignored;') &&
          hider.contains('onFocusChange: (hasFocus)'));
  check('T28 计时器跟着抽屉生命周期：打开即起、销毁即取消（不留悬挂 timer）',
      hider.contains('void initState()') &&
          hider.contains('_restart();') &&
          hider.contains('void dispose()') &&
          hider.contains('_timer?.cancel();') &&
          // 回调后再挂一次计时只会让抽屉反复触发 onIdle
          !hider.contains('widget.onIdle();\n    _restart();'));
}

// ── ⑥ 分页：为什么原来只有 180 部 ────────────────────────────────
//
// 真实数据（2026-11-11 实测默认源）：
//   dyttzy  ?ac=list&pg=1 → pagecount=4255 total=85082
//   bfzy    ?ac=list&pg=1 → pagecount=8573 total=171459
// 旧实现只请求 `?ac=list`（等价 pg=1）再取 20 部，20 个站合计 180 部，
// 与接口自报的百万级差三个数量级 —— 不是取数失败，是**从来没翻过第 2 页**。

Map<String, String> _pagedPages() {
  final pages = <String, String>{};
  for (var site = 0; site < 2; site++) {
    final api = 'https://p$site.test/api.php/provide/vod/';
    final s = CmsSite(key: 'k$site', name: '站$site', api: api);
    for (var page = 1; page <= 2; page++) {
      pages[s.detailPageUrl(page)] = jsonEncode(<String, dynamic>{
        'page': page,
        'pagecount': 2,
        'limit': '20',
        'total': 40,
        'list': <dynamic>[
          for (var i = 0; i < 2; i++)
            <String, dynamic>{
              'vod_id': '${site * 100 + page * 10 + i}',
              'vod_name': '站$site第$page页片$i',
              'type_name': '动作片',
              'vod_year': '2026',
              'vod_pic': '/p.jpg',
              'vod_play_url': '正片\$https://cdn.test/$site-$page-$i.m3u8',
            },
        ],
      });
    }
  }
  return pages;
}

Future<void> testPaging() async {
  final site = CmsSite(key: 'k', name: 'n', api: 'https://p.test/api.php/provide/vod/');
  check('P01 第 1 页不带 pg 参数（保持 1.0.5 前两版口径）',
      !site.listUrlAt(1).contains('pg='));
  check('P02 第 3 页带 pg=3', site.listUrlAt(3).contains('pg=3'));
  check('P03 详情合并页带 ac=detail + pg=2',
      site.detailPageUrl(2).contains('ac=detail') &&
          site.detailPageUrl(2).contains('pg=2'));

  final listing = parseCmsListing(jsonEncode(<String, dynamic>{
    'page': '2',
    'pagecount': 4255,
    'limit': '20',
    'total': 85082,
    'list': <dynamic>[
      <String, dynamic>{'vod_id': 1, 'vod_name': '甲', 'type_name': '动作片'},
    ],
  }));
  check('P04 读得出 page / pagecount / total / limit（原来全丢）',
      listing.page == 2 &&
          listing.pageCount == 4255 &&
          listing.total == 85082 &&
          listing.limit == 20);
  check('P05 一页之后仍有更多', listing.hasMore);

  final detailPage = parseCmsDetailPage(jsonEncode(<String, dynamic>{
    'page': 1,
    'pagecount': 3,
    'list': <dynamic>[
      <String, dynamic>{
        'vod_id': '7',
        'vod_name': '合并页片',
        'type_name': '国产剧',
        'vod_pic': '/p.jpg',
        'vod_play_url': '第1集\$https://cdn.test/a.m3u8#第2集\$https://cdn.test/b.m3u8',
      },
    ],
  }), baseUrl: 'https://p.test/');
  check('P06 合并页一次拿到元数据 + 剧集',
      detailPage.entries.length == 1 &&
          detailPage.details['7']!.episodes.length == 2 &&
          detailPage.entries.first.pic == 'https://p.test/p.jpg');
  check('P07 合并页带分页元信息',
      detailPage.pageCount == 3 && detailPage.total == 0);

  // 分页器真实行为：两个站各 2 页，每页 2 部。
  final pages = _pagedPages();
  final requested = <String>[];
  final pager = VodSourcePager(
    sites: <CmsSite>[
      CmsSite(key: 'k0', name: '站0', api: 'https://p0.test/api.php/provide/vod/'),
      CmsSite(key: 'k1', name: '站1', api: 'https://p1.test/api.php/provide/vod/'),
    ],
    sourceId: '外部点播·p',
    sitesPerBatch: 2,
    fetcher: (url, {allowInsecureHttp = false}) async {
      requested.add(url);
      final body = pages[url];
      if (body == null) {
        return const SourceConfigUrlResult.fail(
            SourceConfigUrlFailure.httpStatus, '未命中');
      }
      return SourceConfigUrlResult.ok(
          text: body, originLabel: 'p', bytes: body.length);
    },
  );
  final b1 = await pager.next();
  check('P08 第一批取两个站的第 1 页', b1.added == 4, '${b1.added}');
  check('P09 第一批就把接口统计总数报出来', b1.discoveredTotal == 80);
  final b2 = await pager.next();
  check('P10 第二批自动翻到第 2 页（pg 真的在推进）',
      b2.added == 4 && requested.any((u) => u.contains('pg=2')));
  final b3 = await pager.next();
  check('P11 翻完 pagecount 后判定到底',
      b3.done && pager.done, 'done=${b3.done}');
  check('P12 累计条目数正确（2 站 × 2 页 × 2 部）', b3.loadedTotal == 8);

  // 跨站同名去重：九个镜像站常带同一部片子。
  final dupPages = <String, String>{};
  for (final api in <String>['https://d0.test/api.php/provide/vod/']) {
    final s = CmsSite(key: 'd', name: 'd', api: api);
    dupPages[s.detailPageUrl(1)] = jsonEncode(<String, dynamic>{
      'page': 1,
      'pagecount': 1,
      'list': <dynamic>[
        <String, dynamic>{
          'vod_id': '1',
          'vod_name': '同一部',
          'type_name': '动作片',
          'vod_year': '2026',
          'vod_play_url': '正片\$https://cdn.test/dup.m3u8',
        },
      ],
    });
  }
  final dupPager = VodSourcePager(
    sites: <CmsSite>[
      CmsSite(key: 'a', name: 'a', api: 'https://d0.test/api.php/provide/vod/'),
      CmsSite(key: 'b', name: 'b', api: 'https://d0.test/api.php/provide/vod/'),
    ],
    sourceId: '外部点播·d',
    sitesPerBatch: 2,
    fetcher: (url, {allowInsecureHttp = false}) async {
      final body = dupPages[url];
      if (body == null) {
        return const SourceConfigUrlResult.fail(
            SourceConfigUrlFailure.httpStatus, '未命中');
      }
      return SourceConfigUrlResult.ok(
          text: body, originLabel: 'd', bytes: body.length);
    },
  );
  final dupBatch = await dupPager.next();
  check('P13 跨站同名片只留一条（不去重会整屏重复）', dupBatch.added == 1,
      '${dupBatch.added}');

  // 站不认 pg：每页都回同一批 → 立即判到底，不空转请求。
  final stubborn = CmsSite(key: 's', name: 's', api: 'https://s.test/api.php/provide/vod/');
  final stubbornPage = jsonEncode(<String, dynamic>{
    'page': 1,
    'pagecount': 99,
    'list': <dynamic>[
      <String, dynamic>{
        'vod_id': '1',
        'vod_name': '固定页',
        'type_name': '动作片',
        'vod_play_url': '正片\$https://cdn.test/s.m3u8',
      },
    ],
  });
  // 每站第一页会并行取一次 `?ac=list` 拿类目表（用于短视频归类）。
  // 这两个用例断言的是「翻页请求不会空转」，因此把类目探测单独计数，
  // 并额外钉住「每站只探一次」，不是把断言数字直接放大放行。
  var stubbornHits = 0;
  var stubbornCategoryHits = 0;
  final stubbornPager = VodSourcePager(
    sites: <CmsSite>[stubborn],
    sourceId: '外部点播·s',
    fetcher: (url, {allowInsecureHttp = false}) async {
      if (url.contains('ac=detail')) {
        stubbornHits++;
      } else {
        stubbornCategoryHits++;
      }
      return SourceConfigUrlResult.ok(
          text: stubbornPage, originLabel: 's', bytes: stubbornPage.length);
    },
  );
  await stubbornPager.next();
  await stubbornPager.next();
  check('P14 不认 pg 的站不会无限重拉同一页', stubbornHits <= 2 && stubbornPager.done,
      'hits=$stubbornHits done=${stubbornPager.done}');
  check('P14b 类目表每站只探一次（不随翻页重复请求）',
      stubbornCategoryHits == 1, 'hits=$stubbornCategoryHits');

  // 超时一次即判死（别让死站把每一批都拖满超时）。
  var deadHits = 0;
  var deadCategoryHits = 0;
  final deadPager = VodSourcePager(
    sites: <CmsSite>[
      CmsSite(key: 'x', name: 'x', api: 'https://x.test/api.php/provide/vod/'),
    ],
    sourceId: '外部点播·x',
    fetcher: (url, {allowInsecureHttp = false}) async {
      if (url.contains('ac=detail')) {
        deadHits++;
      } else {
        deadCategoryHits++;
      }
      return const SourceConfigUrlResult.fail(
          SourceConfigUrlFailure.timeout, '超时');
    },
  );
  await deadPager.next();
  await deadPager.next();
  check('P15 连接超时一次即判死（不重复等超时）', deadHits == 1 && deadPager.done,
      'hits=$deadHits');
  check('P15b 死站的类目探测也只发一次且不影响判死',
      deadCategoryHits == 1, 'hits=$deadCategoryHits');
}

// ── ⑦ 冷启动缓存 + 直播/点播隔离 ────────────────────────────────

Future<void> testCacheAndIsolation() async {
  final dir = await Directory.systemTemp.createTemp('shunbo-vod-cache');
  final file = File('${dir.path}/vod-library.json');
  final store = VodLibraryStore(file);
  final items = <VodItem>[
    for (var i = 0; i < 3; i++)
      VodItem(
        id: '外部点播·c:$i',
        title: '缓存片$i',
        subtitle: '2026 · 中国',
        description: '',
        license: 'x',
        section: VodSection.movies,
        episodes: <VodEpisode>[
          VodEpisode(number: 1, title: '正片', url: 'https://cdn.test/$i.m3u8'),
        ],
        sourceId: '外部点播·c',
        posterUrl: 'https://img.test/$i.jpg',
      ),
  ];
  await store.save(
    sourceId: '外部点播·c',
    sourceName: '缓存源',
    headers: const <String, String>{'Referer': 'https://own.test'},
    items: items,
  );
  final loaded = await store.load();
  check('C01 缓存能落盘并读回', loaded != null && loaded.items.length == 3);
  check('C02 缓存带着 Referer（否则恢复后一播 403）',
      loaded!.headers['Referer'] == 'https://own.test');
  check('C03 缓存保留海报与剧集地址',
      loaded.items.first.posterUrl == 'https://img.test/0.jpg' &&
          loaded.items.first.episodes.first.url == 'https://cdn.test/0.m3u8');

  final lib = VodLibrary(registry: SourceRegistry(), catalog: SourceCatalog());
  lib.restore(
    sourceId: loaded.sourceId,
    items: loaded.items,
    sourceName: loaded.sourceName,
    headers: loaded.headers,
    savedAt: loaded.savedAt,
  );
  check('C04 恢复后立即可见（不用等网络）', lib.externalCount == 3);
  check('C05 刚恢复的缓存算新鲜（不触发重新拉网）', lib.cacheFresh());
  final stale = VodLibrary(registry: SourceRegistry(), catalog: SourceCatalog());
  stale.restore(
    sourceId: loaded.sourceId,
    items: loaded.items,
    sourceName: loaded.sourceName,
    savedAt: DateTime.now().subtract(const Duration(hours: 20)),
  );
  check('C06 超过 12 小时的缓存判为过期（后台刷新）', !stale.cacheFresh());

  // 增量追加不重建适配器：分页每批只做 O(新增)。
  final lib2 = VodLibrary(registry: SourceRegistry(), catalog: SourceCatalog());
  lib2.append(
      sourceId: '外部点播·c',
      incoming: items.take(1).toList(),
      sourceName: 'c');
  final rev1 = lib2.revision;
  lib2.append(
      sourceId: '外部点播·c',
      incoming: items.skip(1).toList(),
      sourceName: 'c');
  check('C07 追加是增量（版本号只 +1，条目累加）',
      lib2.revision == rev1 + 1 && lib2.externalCount == 3);
  check('C08 重复追加同一批不会重复入库',
      lib2.append(
              sourceId: '外部点播·c',
              incoming: items,
              sourceName: 'c') ==
          0);

  // 直播 / 点播隔离：静态护栏
  final stage = _src('lib/ui/widgets/player_stage.dart');
  final live = _src('lib/ui/live/live_page.dart');
  final page = _src('lib/ui/vod/vod_page.dart');
  check('I01 舞台支持「不挂渲染面」（不绘制 ≠ 摘掉原生视图）',
      stage.contains('attachSurface') &&
          stage.contains('if (!attachSurface)'));
  check('I02 直播页在非激活时不挂渲染面',
      live.contains('attachSurface: widget.active'));
  check('I03 点播页在非激活时不挂渲染面',
      page.contains('attachSurface: widget.active'));
  check('I04 切走栏目必须退出播放态（不留在 playing）',
      page.contains('void _leavePlaying(') &&
          page.contains('_view = _VodView.browse;') &&
          // didUpdateWidget 里不能 setState（build 期间 markNeedsBuild 会抛断言）
          page.contains('_leavePlaying(rebuild: false);'));
  // 第二十八次修：`dart format` 把这条链拆成了
  //   `widget.services.live\n    .stop()\n    .timeout(...)`
  // 所以断言改成容忍换行的正则 —— 锁的还是「起播前先调 live.stop()」，没放宽。
  check('I05 点播起播前先停直播（共用同一个内核实例）',
      RegExp(r'services\.live\s*\.\s*stop\(\)').hasMatch(page));
  // 停直播必须**有超时**：LiveController.stop() 的后半段走 AsyncSerialGate，
  // 会排在正在进行的 tune 之后；弱源一次 tune 8–12 秒，没有超时就会把
  // 「点开视频」拖成十几秒的纯等待（1.0.5 第八次修的第二个问题）。
  check('I07 停直播带超时（不把起播拖在 tune 之后）',
      page.contains('.timeout(const Duration(milliseconds: 900))'));
  check('I06 摘掉渲染面时给纯黑而不是「演示内核」提示',
      stage.contains('const ColoredBox(color: Colors.black)'));

  // 会话层：三个栏目页共用一个分页会话，重复进入不该重开配置。
  var openHits = 0;
  final config = jsonEncode(<String, dynamic>{
    'name': '会话源',
    'sites': <dynamic>[
      <String, dynamic>{
        'key': 'k',
        'name': '站',
        'type': 1,
        'api': 'https://sess.test/api.php/provide/vod/',
      },
    ],
  });
  final svc = ThirdPartyVodService(
    fetcher: (url, {allowInsecureHttp = false}) async {
      openHits++;
      if (url.contains('config.json')) {
        return SourceConfigUrlResult.ok(
            text: config, originLabel: 's', bytes: config.length);
      }
      final page = jsonEncode(<String, dynamic>{
        'page': 1,
        'pagecount': 1,
        'total': 1,
        'list': <dynamic>[
          <String, dynamic>{
            'vod_id': '1',
            'vod_name': '会话片',
            'type_name': '动作片',
            'vod_play_url': '正片\$https://cdn.test/s.m3u8',
          },
        ],
      });
      return SourceConfigUrlResult.ok(
          text: page, originLabel: 's', bytes: page.length);
    },
  );
  final sessionLib =
      VodLibrary(registry: SourceRegistry(), catalog: SourceCatalog());
  final session = VodSession(service: svc, library: sessionLib);
  final r1 = await session.start(
      url: 'https://sess.test/config.json', allowInsecureHttp: false);
  final hitsAfterFirst = openHits;
  final r2 = await session.start(
      url: 'https://sess.test/config.json', allowInsecureHttp: false);
  check('S01 会话首次接入拿到条目', r1.ok && sessionLib.externalCount == 1,
      r1.message);
  check('S02 重复 start 复用分页器（不重新拉配置、不重复入库）',
      openHits == hitsAfterFirst && r2.loadedItems == 1);
  check('S03 会话把「接口统计总数」透出来', r1.totalAvailable == 1);
}

// ── ⑦ 顶部筛选（facet）：类型 / 地区 / 时间 ────────────────────────
//
// 1.0.5 第八次修。设计稿的「资费 / 奖项 / 推荐」三行**没有数据支撑**，
// 刻意不实现；这里只回归有真实字段的三个维度，以及「不编造维度」这条底线。

VodItem _facetItem(String title,
        {String type = '',
        String area = '',
        String year = '',
        String genre = ''}) =>
    VodItem(
      id: 't:$title',
      title: title,
      subtitle: '',
      description: '',
      license: 'test',
      section: VodSection.movies,
      episodes: const <VodEpisode>[],
      typeName: type,
      area: area,
      year: year,
      genre: genre,
    );

void testFacets() {
  print('\n== F. 顶部筛选 facet ==');

  // ① 拆词：采集站的 vod_class 普遍是多值串。
  final multi = _facetItem('多值', type: '喜剧,爱情');
  check('F01 类型按逗号拆词', vodTypesOf(multi).join('/') == '喜剧/爱情',
      vodTypesOf(multi).join('/'));
  check('F02 类型也认空格与斜杠分隔',
      vodTypesOf(_facetItem('x', type: '动作 科幻/悬疑')).join('/') ==
          '动作/科幻/悬疑');
  check('F03 空类型不产生词', vodTypesOf(_facetItem('x')).isEmpty);

  // ①.5 取词口径（1.0.5 第十五次修）：类型读 `vod_class`，而不是
  // `type_name`（采集站栏目类目）。后者带地区，会让「类型」行长成一排国家名。
  check('F03a 有 genre 时优先用 genre',
      vodTypesOf(_facetItem('x', type: '国产剧', genre: '喜剧,爱情')).join('/') ==
          '喜剧/爱情',
      vodTypesOf(_facetItem('x', type: '国产剧', genre: '喜剧,爱情')).join('/'));
  check('F03b genre 为空时回落 typeName',
      vodTypesOf(_facetItem('x', type: '动作片')).join('/') == '动作片');
  check('F03c 回落时剔掉地区类目（欧美剧 / 国产剧 / 日韩剧）',
      vodTypesOf(_facetItem('x', type: '欧美剧')).isEmpty &&
          vodTypesOf(_facetItem('x', type: '国产剧')).isEmpty &&
          vodTypesOf(_facetItem('x', type: '日韩剧')).isEmpty &&
          vodTypesOf(_facetItem('x', type: '港台剧')).isEmpty);
  check('F03d 回落时剔掉纯体裁词（电影 / 动漫 / 剧）',
      vodTypesOf(_facetItem('x', type: '电影')).isEmpty &&
          vodTypesOf(_facetItem('x', type: '动漫')).isEmpty &&
          vodTypesOf(_facetItem('x', type: '剧')).isEmpty);
  check('F03e 真题材词保留（动作片 / 纪录片 / 篮球）',
      vodTypesOf(_facetItem('x', type: '动作片')).join('/') == '动作片' &&
          vodTypesOf(_facetItem('x', type: '纪录片')).join('/') == '纪录片' &&
          vodTypesOf(_facetItem('x', type: '篮球')).join('/') == '篮球');

  // 真实场景：一万条缓存里 type 全是栏目类目、genre 七成为空。
  // 修完之后「类型」行必须只剩真题材，一个地区词都不许漏进来。
  final mixed = <VodItem>[
    _facetItem('a', type: '欧美剧', genre: '剧情', area: '美国'),
    _facetItem('b', type: '欧美剧', genre: '剧情', area: '美国'),
    _facetItem('c', type: '国产剧', area: '内地'),
    _facetItem('d', type: '国产剧', area: '内地'),
    _facetItem('e', type: '日本剧', area: '日本'),
    _facetItem('f', type: '日本剧', area: '日本'),
    _facetItem('g', type: '动作片', area: '内地'),
    _facetItem('h', type: '动作片', area: '内地'),
  ];
  final mixedFacets = VodFacets.fromItems(mixed);
  // 第二十三次修：类型行改为固定词表并归一（动作片 → 动作），顺序即词表顺序。
  check('F03f 类型行里没有地区词，且类目名已归一（动作片 → 动作）',
      mixedFacets.types.join('/') == '动作/剧情',
      mixedFacets.types.join('/'));
  check('F03g 地区词一个不少地留在地区行（内地 / 日本 / 美国）',
      mixedFacets.areas.length == 3 &&
          mixedFacets.areas.toSet().containsAll(<String>['内地', '日本', '美国']),
      mixedFacets.areas.join('/'));

  // 地区维度的脏数据：有些采集站把 `vod_area` 当更新状态用，
  // 「地区」行里会冒出「已完结」「全80集（合全集）」「正片」。
  check('F03h 非地区值不进地区行（已完结 / 全80集 / 正片 / HD）',
      !looksLikeVodArea('已完结') &&
          !looksLikeVodArea('全80集（合全集）') &&
          !looksLikeVodArea('正片') &&
          !looksLikeVodArea('HD') &&
          !looksLikeVodArea(''));
  check('F03i 真地区照常保留（内地 / 美国 / 中国大陆 / 其它）',
      looksLikeVodArea('内地') &&
          looksLikeVodArea('美国') &&
          looksLikeVodArea('中国大陆') &&
          looksLikeVodArea('其它'));

  // ② 时间分档：>=2020 用具体年份，更早按年代归并。
  check('F04 2025 → 2025', vodTimeBucket('2025') == '2025');
  check('F05 2015 → 10年代', vodTimeBucket('2015') == '10年代');
  check('F06 1995 → 90年代', vodTimeBucket('1995') == '90年代');
  check('F07 1975 → 更早', vodTimeBucket('1975') == '更早');
  check('F08 非数字年份不进档位', vodTimeBucket('未知') == '');

  // ③ 长尾过滤：只出现一次的维度词不进筛选条（否则一排死词占满屏幕）。
  final items = <VodItem>[
    _facetItem('A', type: '喜剧', area: '内地', year: '2024'),
    _facetItem('B', type: '喜剧', area: '内地', year: '2024'),
    _facetItem('C', type: '动作', area: '美国', year: '2015'),
    _facetItem('D', type: '动作', area: '美国', year: '2015'),
    _facetItem('E', type: '冷门', area: '泰国', year: '1995'),
  ];
  final facets = VodFacets.fromItems(items);
  check('F09 只保留出现 ≥2 次的维度词（只出现 1 次的「冷门」被丢掉）',
      facets.types.toSet().containsAll(<String>['喜剧', '动作']) &&
          facets.types.length == 2 &&
          !facets.types.contains('冷门'),
      facets.types.join('/'));
  check('F10 地区同样过滤长尾',
      facets.areas.join('/') == '内地/美国', facets.areas.join('/'));
  check('F11 时间档按真实时间**倒序**（不是按命中数）',
      facets.times.join('/') == '2024/10年代', facets.times.join('/'));

  // ④ 过滤是「与」关系；再点一次同一个值等于取消。
  final onlyComedy =
      applyVodFilter(items, const VodFilter(type: '喜剧'));
  check('F12 单维度过滤', onlyComedy.length == 2);
  final comedyCn =
      applyVodFilter(items, const VodFilter(type: '喜剧', area: '美国'));
  check('F13 两个维度是「与」关系（喜剧 + 美国 = 0 条）', comedyCn.isEmpty);
  final actionUs =
      applyVodFilter(items, const VodFilter(type: '动作', area: '美国'));
  check('F14 命中组合', actionUs.length == 2);
  final byTime =
      applyVodFilter(items, const VodFilter(time: '10年代'));
  check('F15 时间档过滤按桶比对', byTime.length == 2);
  check('F16 不限 = 原样返回全部',
      applyVodFilter(items, VodFilter.empty).length == items.length);

  // ⑤ 排序：年份倒序且**稳定**（同年份保持原顺序，卡片不乱跳）。
  final sorted = applyVodFilter(items, const VodFilter(sort: VodSort.yearDesc));
  check('F17 年份倒序', sorted.first.year == '2024' && sorted.last.year == '1995');
  final stable =
      applyVodFilter(items, const VodFilter(sort: VodSort.yearDesc));
  check('F18 同年份保持原顺序（稳定排序）',
      stable[0].title == 'A' && stable[1].title == 'B');

  // ⑥ 值相等：`_filteredFor` 的缓存键直接用它，不实现就永远命中不了。
  check('F19 VodFilter 值相等（缓存键可用）',
      const VodFilter(type: '喜剧') == const VodFilter(type: '喜剧') &&
          const VodFilter(type: '喜剧') != const VodFilter(type: '动作'));
  check('F20 activeCount 统计生效维度',
      const VodFilter(type: '喜剧', time: '2024').activeCount == 2);

  // ⑦ 静态：顶部结构按设计稿分区，且**没有**凭空造出资费/奖项/推荐三行。
  final page = _src('lib/ui/vod/vod_page.dart');
  check('F21 顶部有分类 tab 行', page.contains('Widget _typeTabs('));
  check('F22 筛选行是「深色标签 + 值词」结构',
      page.contains('Widget _filterRow(') && page.contains('Widget _filterValue('));
  check('F23 有展开 / 收起（长尾词）', page.contains('_filtersExpanded'));
  check('F24 检索框在标题行内右对齐（窄窗口落到第二行）',
      page.contains('Widget _searchBox()') &&
          page.contains('Expanded(child: heading),') &&
          page.contains('_searchBox(),') &&
          // 窄窗口分支：标题与检索框上下叠，避免 300 宽输入框把行挤爆。
          page.contains('if (c.maxWidth < 720)'));
  // 反面：不能为了「像设计稿」把没有数据的维度做出来（资费/奖项/推荐）。
  // 用「实际调用了哪几行」来查，而不是查关键词是否出现 —— 注释里提到设计稿
  // 有那三行是合法的，做出来才是错的。
  final labels = RegExp(r"_filterRow\(\s*'([^']+)'")
      .allMatches(page)
      .map((m) => m.group(1))
      .toList();
  // 第二十次修：新增「分类」行 = 站点原始类目名（国产剧 / 欧美剧 …）。
  // 它同样有整份目录的数据支撑，且点下去能筛到条目，不是死按钮。
  // 第二十三次修：「分类」行按用户红标整行删除，只剩四个维度 + 排序。
  check('F25 筛选行只有有数据支撑的四个维度（类型/地区/时间/排序）',
      labels.join('/') == '类型/地区/时间/排序', labels.join('/'));

  // 取词口径的静态护栏：类型必须读 `genre`（真题材），不能只读栏目类目。
  // 这一条对应真实红标「类型不对」——「类型」行排出来是一排国家名。
  final facetsSrc = _src('lib/features/vod/vod_facets.dart');
  check('F26 类型取词读 genre（不再只看 type_name）',
      facetsSrc.contains('_splitTypeWords(item.genre)'));
  check('F27 回落时剔除地区 / 纯体裁词',
      facetsSrc.contains('if (isNonGenreLabel(t)) continue;'));
  check('F28 「分类」维度整行删除，类型改由固定词表供水（不再有采集站方言）',
      !facetsSrc.contains('final List<String> categories;') &&
          facetsSrc
              .contains('const List<String> kVodGenreVocabulary = <String>[') &&
          !page.contains('_filter.category') &&
          !page.contains("'分类',"));
  check('F29 类型行不再拼采集站类目（日剧 / 韩剧 这类进不来词表）',
      facetsSrc.contains("'马泰',") &&
          facetsSrc.contains("'港澳',") &&
          _src('lib/features/vod/vod_facet_directory.dart')
              .contains('for (final t in vodGenreKeysOf(label))') &&
          !_src('lib/features/vod/vod_facet_directory.dart')
              .contains('categoryCounts'));
}

Future<void> main() async {
  testControls();
  testPoster();
  testSiteLimits();
  await testProgressAndBudget();
  testStaticRails();
  await testPaging();
  await testCacheAndIsolation();
  testFacets();
  testControlBar();
  testDetailPanel();
  print('');
  if (_fail == 0) {
    print('回归通过：$_pass/$_pass 断言通过');
    exit(0);
  }
  print('回归失败：$_pass/${_pass + _fail} 断言通过');
  exit(1);
}
