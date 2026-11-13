// 1.0.5 点播源地址配置（G1 开放接口 / G2+G3 默认组合）回归。
//
// 三层：
//   ① 纯 Dart 状态机——默认关闭、候选清单、地址校验、设置持久化；
//   ② 片库检索——空查询必须返回原列表，保证 1.0.4 浏览行为不变；
//   ③ 源码静态护栏——装配/UI/安全基线/版本与回退基线，防止后续改动悄悄回退。
//
// 运行：dart run tooling/verify_vod_source_address.dart
import 'dart:io';

import 'package:shunbo/data/file_config_store.dart';
import 'package:shunbo/data/onboarding/source_config_url.dart';
import 'package:shunbo/data/onboarding/vod_source_address.dart';
import 'package:shunbo/data/onboarding/vod_source_address_store.dart';
import 'package:shunbo/data/onboarding/vod_update_cadence.dart';
import 'package:shunbo/features/vod/vod_catalog.dart';
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

const String _https = 'https://example.com/sources.json';

// ── ① 默认状态：1.0.4 行为不变的第一道护栏 ──────────────────────

void testDefaults() {
  final d = VodSourceAddressSettings.defaults;
  check('A01 默认关闭外部地址', d.enabled == false);
  check('A02 默认选中内置片库（空串）', d.selectedUrl == kVodBuiltInSourceUrl);
  check('A03 默认无自定义地址', d.customUrls.isEmpty);
  check('A04 默认 usesBuiltIn 为真', d.usesBuiltIn);
  check('A05 默认 effectiveUrl 为空（不请求外网）', d.effectiveUrl.isEmpty);
  check('A06 默认策略标识为 G2+G3', kVodDefaultPolicy == 'G2+G3');
  check('A07 fromJson(null) 回落默认', VodSourceAddressSettings.fromJson(null).enabled == false);
  check('A08 fromJson(空对象) 回落默认', VodSourceAddressSettings.fromJson(<String, dynamic>{}).enabled == false);
  check('A09 enabled 只认字面 true（字符串不生效）',
      VodSourceAddressSettings.fromJson(<String, dynamic>{'enabled': 'true'}).enabled == false);
  check('A10 坏地址配置整体回落默认（不会悄悄打开外部源）',
      VodSourceAddressSettings.fromJson(<String, dynamic>{
        'enabled': true,
        'selectedUrl': 'javascript:alert(1)',
      }).enabled == false);
}

// ── ② 候选地址清单 ──────────────────────────────────────────────

void testCandidates() {
  final c = kVodSourceCandidates;
  check('B01 候选列表非空', c.isNotEmpty);
  check('B02 含内置片库项', c.any((x) => x.id == 'built-in'));
  final builtIn = c.firstWhere((x) => x.id == 'built-in');
  check('B03 内置片库项 url 为空且非第三方',
      builtIn.url.isEmpty && builtIn.thirdParty == false);
  check('B04 候选 id 唯一',
      c.map((x) => x.id).toSet().length == c.length);
  check('B05 第三方候选均带地址',
      c.where((x) => x.thirdParty).every((x) => x.url.isNotEmpty));
  check('B06 候选地址不含内嵌账密',
      c.every((x) =>
          x.url.isEmpty ||
          (Uri.tryParse(x.url)?.userInfo.isEmpty ?? false)));

  // 候选必须覆盖《播放接口.txt》的点播侧条目（行首有「1. 」序号，两个直播
  // M3U 不属于点播源配置）。用正则从原文抽 URL，避免依赖行格式。
  //
  // 字符集必须限死在 URL 合法字符内：原文有些行在地址后面直接跟中文注释
  // （如「…pps.bmp（82.4 万）」），用 `[^\s]+` 会把「（82.4」一起吞进去，
  // 于是 B08 会误报「地址不在候选中」—— 那是抽取规则的问题，不是候选缺失。
  final found = RegExp(r"https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+")
      .allMatches(_src('../播放接口.txt'))
      .map((m) => m.group(0)!)
      .where((u) => !u.contains('zb.7778.uk'))
      .toSet();
  final urls = c.map((x) => x.url).toSet();
  check('B07 《播放接口.txt》点播条目共 6 条', found.length == 6,
      '实际 ${found.length}');
  check('B08 6 条点播地址全部出现在候选中',
      found.every((u) => urls.contains(u)));

  final httpOnes = c.where((x) => x.url.startsWith('http://')).toList();
  check('B09 明文 http 候选共 5 条', httpOnes.length == 5,
      '实际 ${httpOnes.length}');
  check('B10 5 条明文 http 候选一律被当前策略拒绝',
      httpOnes.every((x) =>
          validateVodSourceAddress(x.url).verdict ==
          VodAddressVerdict.plainHttp));
  check('B11 官方入口 https 可进入 E9 校验（不代表内容可导入）',
      validateVodSourceAddress('https://api.starlink.fan/index.php').acceptable);

  // 1.0.5 第二次修：格式合规 ≠ 能出片。上一版只按格式决定能否选中，
  // 结果唯一 https 合规的候选是实测必然失败的网页，能出片的全被锁成灰的。
  check('B12 影视仓官方入口标记为「返回网页」，不再冒充可用候选',
      c.firstWhere((x) => x.id == 'starlink-official').availability ==
          VodAvailability.htmlPage);
  check('B13 :16/8888 标记为纯插件型（放行明文也出不来片）',
      c.firstWhere((x) => x.id == 'tvbox-8888').availability ==
          VodAvailability.pluginOnly);
  check('B14 实测可出片的采集接口在可选项中，网页 / 插件型被排除',
      () {
    final usable = c.where((x) => x.canProduceItems).map((x) => x.id).toSet();
    return usable.contains('tvbox-config') &&
        !usable.contains('starlink-official') &&
        !usable.contains('tvbox-8888');
  }());
  check('B15 每个不可用候选都带可读原因',
      c.where((x) => !x.canProduceItems)
          .every((x) => (x.unavailableReason ?? '').isNotEmpty));
  check('B16 isKnownUnusableSource 只对清单内的不可用地址为真',
      isKnownUnusableSource('https://api.starlink.fan/index.php') &&
          !isKnownUnusableSource('http://47.96.82.41:5188/config.json') &&
          !isKnownUnusableSource('https://example.com/my.json') &&
          !isKnownUnusableSource(''));

  // 1.0.5 第三次修：五条第三方地址逐个实测（2026-11-11 19:20）后的结论。
  // 这一组断言锁的是「实测事实」而不是偏好：哪条能出片、哪条根本出不来。
  check('B17 默认源就是实测最优的那一条，且标记为可用',
      kVodDefaultSourceUrl == 'http://47.96.82.41:5188/config.json' &&
          kVodDefaultSourceCandidate.canProduceItems &&
          kVodDefaultSourceCandidate.isDefaultSource);
  check('B18 默认源排在候选第二位（内置片库之后）',
      c[0].id == 'built-in' && c[1].url == kVodDefaultSourceUrl);
  check('B19 :55316/9981 的 117 个站点全是插件型',
      c.firstWhere((x) => x.id == 'tvbox-9981').availability ==
          VodAvailability.pluginOnly);
  check('B20 :924/924 的采集站导不出可播条目（有采集站 ≠ 能播）',
      c.firstWhere((x) => x.id == 'tvbox-924').availability ==
          VodAvailability.noPlayable);
  check('B21 :20271/pps.bmp 实测可用（6 个采集站有直链）',
      c.firstWhere((x) => x.id == 'tvbox-pps').canProduceItems);
  check('B22 可用候选恰好是「默认源 + pps + 内置片库」',
      c.where((x) => x.canProduceItems).map((x) => x.id).toSet().length == 3 &&
          c
              .where((x) => x.canProduceItems)
              .map((x) => x.id)
              .toSet()
              .containsAll(<String>{'built-in', 'tvbox-config', 'tvbox-pps'}));
  check('B23 每个候选的 note 都写清了实测结论（不再有「未实测」）',
      c.where((x) => x.thirdParty).every((x) => !x.note.contains('未实测')));
}

// ── ③ 地址校验 ──────────────────────────────────────────────────

void testValidate() {
  check('C01 空串 = 内置片库',
      validateVodSourceAddress('').verdict == VodAddressVerdict.builtIn);
  check('C02 纯空白 = 内置片库',
      validateVodSourceAddress('   ').verdict == VodAddressVerdict.builtIn);
  check('C03 https 正常地址可接受',
      validateVodSourceAddress(_https).acceptable);
  check('C04 http 裸 IP 被判明文拒绝',
      validateVodSourceAddress('http://124.223.214.31:16/8888').verdict ==
          VodAddressVerdict.plainHttp);
  check('C05 loopback http 可接受',
      validateVodSourceAddress('http://127.0.0.1:8080/sources.json').acceptable);
  check('C06 localhost http 可接受',
      validateVodSourceAddress('http://localhost/sources.json').acceptable);
  check('C07 file:// 被拒',
      validateVodSourceAddress('file:///etc/passwd').verdict ==
          VodAddressVerdict.malformed);
  check('C08 javascript: 被拒',
      validateVodSourceAddress('javascript:alert(1)').verdict ==
          VodAddressVerdict.malformed);
  check('C09 内嵌账密被拒',
      validateVodSourceAddress('https://u:p@example.com/x.json').verdict ==
          VodAddressVerdict.malformed);
  check('C10 缺主机名被拒',
      validateVodSourceAddress('https://').verdict ==
          VodAddressVerdict.malformed);
  check('C11 控制字符被拒',
      validateVodSourceAddress('https://example.com/a\n.json').verdict ==
          VodAddressVerdict.malformed);
  check('C12 超长地址被拒',
      validateVodSourceAddress('https://example.com/${'a' * 2100}').verdict ==
          VodAddressVerdict.malformed);
  check('C13 与传输层 loopback 判定同口径（127 段）',
      isLoopbackHost('127.0.0.2') &&
          validateVodSourceAddress('http://127.0.0.2/x.json').acceptable);
  check('C14 与传输层 loopback 判定同口径（外部主机）',
      !isLoopbackHost('example.com'));

  // 1.0.5 第二次修：网页不是接口。原来的路径会先撞 256 KB 上限，
  // 报「配置超过 256 KB」，把「这条根本不是接口」说成「换个大点的地址」。
  check('C15 text/html 判定为网页', isHtmlLikePayload(contentType: 'text/html; charset=utf-8'));
  check('C16 application/xhtml+xml 判定为网页',
      isHtmlLikePayload(contentType: 'application/xhtml+xml'));
  check('C17 正文以 < 开头判定为网页（Content-Type 撒谎时兜底）',
      isHtmlLikePayload(bodyPrefix: '  <!DOCTYPE html><html>'));
  check('C18 JSON 正文不误判',
      !isHtmlLikePayload(contentType: 'application/json', bodyPrefix: '{"code":1}'));
  check('C19 数组 JSON 不误判',
      !isHtmlLikePayload(bodyPrefix: '[{"vod_id":1}]'));
  check('C20 application/octet-stream + JSON 正文不误判',
      !isHtmlLikePayload(
          contentType: 'application/octet-stream', bodyPrefix: '{"sites":[]}'));
  check('C21 空输入不误判',
      !isHtmlLikePayload() &&
          !isHtmlLikePayload(contentType: '', bodyPrefix: ''));
  check('C22 网页判定的失败原因可与超限区分开',
      SourceConfigUrlFailure.values.contains(SourceConfigUrlFailure.htmlPage) &&
          SourceConfigUrlFailure.htmlPage != SourceConfigUrlFailure.tooLarge);

  // 1.0.5 第三次修：只看 Content-Type 会把 12 个可用采集站全判成网页。
  // 实测苹果 CMS 采集站大量返回 `Content-Type: text/html;charset=utf-8`，
  // 正文却是合法 JSON（老 PHP 站点的默认头）—— 正文才是判据。
  check('C23 采集站实测：text/html 头 + JSON 正文不误判（曾误杀 12 个站）',
      !isHtmlLikePayload(
          contentType: 'text/html;charset=utf-8',
          bodyPrefix: '{"code":1,"msg":"数据列表","page":1,"pagecount":3692}'));
  check('C24 数组 JSON + text/html 头不误判',
      !isHtmlLikePayload(
          contentType: 'text/html; charset=utf-8', bodyPrefix: '[{"vod_id":1}]'));
  check('C25 带 BOM 的 JSON 不误判',
      !isHtmlLikePayload(
          contentType: 'text/html', bodyPrefix: '\uFEFF{"code":1}'));
  check('C26 真网页（text/html + <!DOCTYPE）仍然拦下',
      isHtmlLikePayload(
          contentType: 'text/html; charset=utf-8',
          bodyPrefix: '<!-- x --><!DOCTYPE html><html lang="en">'));
  check('C27 流式首字节判定：跳过 BOM 与空白取第一个有效字节',
      firstSignificantByte(<int>[
            0xEF, 0xBB, 0xBF, 0x20, 0x0A, 0x3C, 0x21
          ]) ==
          0x3C &&
          firstSignificantByte(<int>[0xEF, 0xBB, 0xBF, 0x7B]) == 0x7B &&
          firstSignificantByte(<int>[0x20, 0x09]) == null);
}

// ── ④ 设置对象变更 ──────────────────────────────────────────────

void testSettings() {
  final d = VodSourceAddressSettings.defaults;
  check('D01 copyWith 打开开关', d.copyWith(enabled: true).enabled);
  final onlySwitch = d.copyWith(enabled: true);
  check('D02 只开开关未选地址仍走内置片库', onlySwitch.usesBuiltIn);
  check('D03 只开开关不产生外部 effectiveUrl', onlySwitch.effectiveUrl.isEmpty);

  final added = d.addCustom(_https);
  check('D04 添加 https 地址后自动启用', added.enabled);
  check('D05 添加后选中该地址', added.selectedUrl == _https);
  check('D06 添加后自定义列表含该地址', added.customUrls.contains(_https));
  check('D07 明文 http 地址不被添加',
      identical(added.addCustom('http://124.223.214.31:16/8888'), added));
  check('D08 重复添加不产生重复项',
      added.addCustom(_https).customUrls.length == 1);
  check('D09 前后空白被 trim',
      added.addCustom('  $_https  ').customUrls.length == 1);

  var many = d;
  for (var i = 0; i < 15; i++) {
    many = many.addCustom('https://example.com/s$i.json');
  }
  check('D10 自定义地址上限生效', many.customUrls.length == kMaxVodCustomUrls);
  check('D11 超限后保留最新一条',
      many.selectedUrl == 'https://example.com/s14.json');

  final removed = added.removeCustom(_https);
  check('D12 移除后选中项回落内置片库', removed.selectedUrl.isEmpty);
  check('D13 移除后 usesBuiltIn 为真', removed.usesBuiltIn);

  final roundTrip = VodSourceAddressSettings.fromJson(added.toJson());
  check('D14 toJson/fromJson 往返 enabled 一致',
      roundTrip.enabled == added.enabled);
  check('D15 toJson/fromJson 往返选中地址一致',
      roundTrip.selectedUrl == added.selectedUrl);
  check('D16 toJson/fromJson 往返自定义列表一致',
      roundTrip.customUrls.length == added.customUrls.length);
  check('D17 自定义列表非法项被过滤',
      VodSourceAddressSettings.fromJson(<String, dynamic>{
        'customUrls': <dynamic>[_https, 123, '', 'file:///x']
      }).customUrls.length == 1);

  // 1.0.5 第二次修：已知不可用的候选（返回网页 / 纯插件型）不能成为
  // 重启后的选中项 —— 否则用户每次进设置都停在一个「点了必然失败」的地址上。
  check('D18 选中「返回网页」的候选时回落内置片库，但保留 enabled',
      () {
    final s = VodSourceAddressSettings.fromJson(<String, dynamic>{
      'enabled': true,
      'selectedUrl': 'https://api.starlink.fan/index.php',
    });
    return s.enabled && s.selectedUrl.isEmpty && s.usesBuiltIn;
  }());
  // 1.0.5 第四次修：插件型候选**不再**强制回落。
  // 理由：新增「允许执行外部代码」后，这类站点的 HTTP 接口会被真正试一次，
  // 把选中的地址钉回内置片库等于连试都不给试（用户会以为设置没生效）。
  check('D19 插件型候选不再被强制回落（允许外部代码后可重试）',
      VodSourceAddressSettings.fromJson(<String, dynamic>{
            'enabled': true,
            'selectedUrl': 'http://124.223.214.31:16/8888',
            'allowInsecureHttp': true,
          }).selectedUrl ==
          'http://124.223.214.31:16/8888');
  check('D19b 「只给分享页」的候选仍然回落（真的取不到）',
      VodSourceAddressSettings.fromJson(<String, dynamic>{
            'enabled': true,
            'selectedUrl': 'http://124.223.214.31:924/924',
            'allowInsecureHttp': true,
          }).selectedUrl.isEmpty);
  check('D20 可用候选（采集接口）正常保留',
      VodSourceAddressSettings.fromJson(<String, dynamic>{
        'enabled': true,
        'selectedUrl': 'http://47.96.82.41:5188/config.json',
        'allowInsecureHttp': true,
      }).selectedUrl == 'http://47.96.82.41:5188/config.json');

  // 1.0.5 第二十四次修：自动更新间隔改为用户可选七档，落在这里的是天数。
  check('D21 间隔缺省一天', VodSourceAddressSettings.defaults.updateIntervalDays == 1);
  check('D22 间隔往返一致（一季度）',
      VodSourceAddressSettings.fromJson(
                  VodSourceAddressSettings.defaults
                      .copyWith(updateIntervalDays: 90)
                      .toJson())
              .updateIntervalDays ==
          90);
  check('D23 间隔坏值回落一天（不在七档 / 非整数 / 负数）',
      VodSourceAddressSettings.fromJson(<String, dynamic>{
            'vodUpdateIntervalDays': 5
          }).updateIntervalDays ==
          1 &&
          VodSourceAddressSettings.fromJson(<String, dynamic>{
                'vodUpdateIntervalDays': '7'
              }).updateIntervalDays ==
              1 &&
          VodSourceAddressSettings.fromJson(<String, dynamic>{
                'vodUpdateIntervalDays': -3
              }).updateIntervalDays ==
              1);
  check('D24 坏地址回默认时也不丢间隔',
      VodSourceAddressSettings.fromJson(<String, dynamic>{
            'enabled': true,
            'selectedUrl': 'file:///etc/passwd',
            'vodUpdateIntervalDays': 180,
          }).updateIntervalDays ==
          180);
  check('D25 七档表：顺序 / 天数 / 文案全对',
      VodUpdateCadence.values.length == 7 &&
          VodUpdateCadence.values.map((c) => c.days).join(',') ==
              '1,3,7,30,90,180,365' &&
          VodUpdateCadence.values.map((c) => c.label).join(',') ==
              '一天,三天,一周,一月,一季度,半年,一年' &&
          VodUpdateCadence.quarter.duration == const Duration(days: 90));
  check('D26 档位容错：fromDays 兜底一天，tryParse 区分没配过',
      VodUpdateCadence.fromDays(999) == VodUpdateCadence.day &&
          VodUpdateCadence.fromDays(0) == VodUpdateCadence.day &&
          VodUpdateCadence.tryParse(null) == null &&
          VodUpdateCadence.tryParse('7') == null &&
          VodUpdateCadence.tryParse(365) == VodUpdateCadence.year);
}

// ── ⑤ 落盘 ──────────────────────────────────────────────────────

Future<void> testStore() async {
  final dir = Directory.systemTemp.createTempSync('shunbo_vod_addr_');
  final path = '${dir.path}${Platform.pathSeparator}config.json';
  try {
    final store = VodSourceAddressStore(FileConfigStore.at(path));
    final first = await store.load();
    check('E01 全新安装读出「关闭」默认', first.enabled == false);
    check('E02 全新安装读出内置片库', first.usesBuiltIn);
    final target = VodSourceAddressSettings.defaults.addCustom(_https);
    await store.save(target);
    final second = await store.load();
    check('E03 保存后可复现 enabled', second.enabled == target.enabled);
    check('E04 保存后可复现选中地址', second.selectedUrl == target.selectedUrl);
    await store.reset();
    final third = await store.load();
    check('E05 reset 回到关闭状态', third.enabled == false);
    check('E06 reset 清空选中地址', third.selectedUrl.isEmpty);
  } finally {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // 临时目录清理失败不影响回归结论
    }
  }
}

// ── ⑥ G3 片库检索 ───────────────────────────────────────────────

void testSearch() {
  final all = VodCatalog.all;
  check('F01 内置片库非空（1.0.4 片库未被删改）', all.isNotEmpty);
  check('F02 空查询返回原列表引用',
      identical(filterVodItems(all, ''), all));
  check('F03 纯空白查询返回原列表引用',
      identical(filterVodItems(all, '   '), all));
  check('F04 空查询计数文案与 1.0.4 逐字相同',
      vodCountLabel(all.length, all.length) ==
          '${all.length} 部 · 公开授权示例片库');
  check('F05 筛选后计数文案标注已筛选',
      vodCountLabel(2, all.length).contains('已筛选'));
  final hit = filterVodItems(all, '大雄兔');
  check('F06 按片名筛选有结果', hit.isNotEmpty);
  check('F07 筛选结果是原列表子集',
      hit.every((x) => all.any((y) => y.id == x.id)));
  check('F08 筛选结果全部命中关键字',
      hit.every((x) => vodMatches(x, '大雄兔')));
  check('F09 无匹配返回空列表', filterVodItems(all, '不存在的片名zzz').isEmpty);
  check('F10 大小写不敏感',
      filterVodItems(all, 'OCEANS').length ==
          filterVodItems(all, 'oceans').length);
}

// ── ⑦ 装配与安全基线静态护栏 ────────────────────────────────────

void testWiring() {
  final services = _src('lib/app/services.dart');
  final mainDart = _src('lib/main.dart');
  final settings = _src('lib/ui/settings/settings_page.dart');
  final section = _src('lib/ui/settings/vod_source_section.dart');
  final vodPage = _src('lib/ui/vod/vod_page.dart');
  final loader = _src('lib/data/onboarding/source_config_loader.dart');
  final validator = _src('lib/data/onboarding/source_config_validator.dart');
  final mainActivity =
      _src('android/app/src/main/kotlin/com/shunbo/shunbo/MainActivity.kt');
  final liveController = _src('lib/features/live/live_controller.dart');

  check('G01 services 持有 vodSourceStore',
      services.contains('final VodSourceAddressStore vodSourceStore;'));
  check('G02 main 装配 store 且复用同一 configStore',
      mainDart.contains('VodSourceAddressStore(configStore)') &&
          mainDart.contains('vodSourceStore: vodSourceStore'));
  check('G03 设置页挂上点播源区块，标题不带版本号（第二十四次修红标）',
      settings.contains('VodSourceAddressSection(services: s)') &&
          settings.contains("title: '点播源',") &&
          !settings.contains('点播源（1.0.5）'));
  // 第二十一次修：设置页按需求收敛成「一个输入框 + 一个手动入口」。
  // 下面五条旧断言锁的是被删掉的候选列表 / 三按钮结构，按项目惯例
  // 改写成等价或更强的新约束（不是放宽）。
  check('G04 区块不再渲染候选列表 / 开关（候选只用于已知不可用校验）',
      !section.contains('for (final c in kVodSourceCandidates)') &&
          !section.contains('SwitchListTile(') &&
          section.contains('isKnownUnusableSource(raw)'));
  check('G05 区块只有一个第三方片源接口地址输入框',
      section.contains('TextField(') &&
          section.contains('第三方片源接口地址') &&
          (RegExp(r'TextField\(').allMatches(section).length == 1));
  check('G06 输入完成自动提交既有闸门（回车 + 失焦，判断逻辑不改）',
      section.contains('onSubmitted:') &&
          section.contains('_onFocusLost') &&
          section.contains('vodIndexGate.submit(') &&
          mainDart.contains('rebuild: (url, insecure, externalCode) async'));
  check('G06b 同一地址不重复提交，文本变化或失败允许重试',
      section.contains('if (raw == _lastSubmitted) return;') &&
          section.contains("if (!verdict.ready) _lastSubmitted = '';") &&
          section.contains("if (_input.text.trim() != _lastSubmitted)"));
  check('G06c 输入框实时校验；明文 http 仍需显式确认（界面无开关）',
      section.contains('_onInputChanged') &&
          section.contains('_confirmInsecure') &&
          section.contains('输入地址校验') &&
          section.contains('disclaimerAccepted'));
  check('G07 区块未打开 unsafe 后端',
      !section.contains('allowUnsafeBackends: true'));
  check('G08 加载器仍只接受 Dart 纯数据后端',
      loader.contains('_dartParsers') &&
          loader.contains('!_dartParsers.contains(parser)'));
  check('G09 校验器仍把 jar/QuickJS 列为 unsafe',
      validator.contains('_unsafeParsers') &&
          validator.contains('allowUnsafeBackends') &&
          validator.contains("'quickjs'"));
  check('G10 jar 通道在原生侧仍未注册（不执行远端代码）',
      !mainActivity.contains('shunbo/source_jar'));
  // 1.0.5 第八次修：筛选多了 facet 一层（类型/地区/时间），但仍在**点播页内
  // 用纯 Dart 完成**——不依赖远端接口的 `?ac=detail&t=..&area=..` 之类参数，
  // 也因此能被 `dart run` 直接回归。
  // 1.0.5 第十二次修：检索入口先查本地内容检索目录再叠 facet，不再是
  // `applyVodFilter(all, ...)` 直连全量。
  // 1.0.5 第十七次修：**条件的来源**从「当前已加载的那 120 条」改为整份
  // 索引目录。旧断言锁 `_facetsCache.of(`（按当前页统计）与新口径冲突，
  // 按项目惯例改写成等价强度的新断言：纯 Dart 过滤 + 本地优先不变，
  // 另加「条件必须来自目录服务、两种来源都有加载实现」两条。不是放宽。
  check('G11 点播页使用可回归的纯 Dart 筛选（条件改由索引目录加载）',
      vodPage.contains('filterVodItems(applyVodFilter(pool, _filter)') &&
          vodPage.contains('localMatches(q)') &&
          vodPage.contains('vodFacetDirectory.catalogFor(') &&
          vodPage.contains('facetOptionsFromItems(') &&
          vodPage.contains('facetOptionsFromShard(') &&
          !vodPage.contains('_facetsCache.of('));
  check('G12 点播页仍以内置片库为播放源',
      vodPage.contains('VodCatalog.sourceId'));
  check('G13 G1 不进直播控制器（直播链路零改动）',
      !liveController.contains('VodSourceAddress'));
  check('G14 启动装配不主动拉取候选地址',
      !mainDart.contains('kVodSourceCandidates'));

  // ── 第二十一次修：设置-点播源模块的四条需求逐条反向锁死 ──────────
  final storeSrc = File('lib/data/onboarding/vod_index_directory_store.dart')
      .readAsStringSync();
  final updaterSrc = File('lib/data/onboarding/vod_index_updater.dart')
      .readAsStringSync();
  final gateSrc =
      File('lib/features/vod/vod_index_gate.dart').readAsStringSync();
  check('G15 保留原有获取判断：地址与默认索引一致就直接复用默认记录',
      gateSrc.contains('decideVodIndexSubmit(') &&
          gateSrc.contains('builtin.matches(url)') &&
          gateSrc.contains('VodIndexSubmitAction.loadExisting') &&
          // 第二十六次修：默认地址走到 rebuild 说明随包索引不可用，
          // 此时必须回一句理由（原来静默 return null ⇒ 又弹输入页 ⇒ 死循环）。
          mainDart.contains('随包默认索引目录不可用'));
  check('G16 新接口索引按地址独立存放，默认地址永不生成文件',
      storeSrc.contains('String vodIndexFileForUrl(String raw,') &&
          storeSrc.contains('Future<void> saveFor(') &&
          storeSrc.contains('默认片源索引是随包只读资产') &&
          mainDart.contains('vodIndexStore.saveFor('));
  check('G17 追加合并按片源 id 去重，旧条目不删、只写自己的文件',
      storeSrc.contains('VodIndexMergeResult mergeVodIndexItems(') &&
          storeSrc.contains('seen.add(item.id)') &&
          storeSrc.contains('Future<VodIndexAppendResult> appendFor(') &&
          storeSrc.contains('await _writeTo(target, doc);'));
  // 第二十四次修：周期不再是写死的 24 小时，改成七档可选 + 每小时 tick。
  check('G18 自动更新周期改为用户可选七档，定时器按 1 小时 tick 问一次',
      updaterSrc.contains('const Duration kVodIndexUpdateInterval = Duration(days: 1);') &&
          updaterSrc.contains('const Duration kVodIndexUpdateTick = Duration(hours: 1);') &&
          updaterSrc.contains('Timer.periodic(kVodIndexUpdateTick') &&
          updaterSrc.contains('shouldUpdate(last, now(), settings.interval)') &&
          mainDart.contains('vodIndexUpdater.start();') &&
          mainDart.contains('updateIntervalDays: s.updateIntervalDays'));
  check('G19 手动获取入口与定时更新共用同一条追加链路',
      section.contains('立即获取最新片源') &&
          section.contains('vodIndexUpdater.runOnce(force: true)') &&
          updaterSrc.contains('final result = await append(settings.url, items);'));
  check('G20 定时更新让位播放链路、默认地址跳过、不重取全量',
      mainDart.contains('await vodBoot.settled;') &&
          mainDart.contains('await vodIndexGate.settled;') &&
          updaterSrc.contains('final batch = await pager.next();') &&
          updaterSrc.contains('kMaxVodUpdateRounds') &&
          updaterSrc.contains('没有**定时自动更新'));

  // ── 第二十四次修：三条红标的静态护栏 ──────────────────────────
  check('G21 输入框下改挂免责版权说明（原技术说明不再出现）',
      section.contains('不提供、不存储、不传播任何影音内容') &&
          section.contains('片源与版权归各来源站点所有') &&
          !section.contains('默认留空，不回填当前地址') &&
          !section.contains('每 24 小时自动更新一次片源'));
  check('G22 七档间隔由用户点选，选完只落盘不触发取数',
      section.contains('自动更新间隔') &&
          section.contains('VodUpdateCadence.values') &&
          section.contains('_selectCadence') &&
          section.contains('copyWith(updateIntervalDays: cadence.days)') &&
          !section.contains('runOnce(force: true) ;') &&
          // 档位切换不该顺手取数：`_selectCadence` 里只有落盘。
          !RegExp(r'_selectCadence[\s\S]{0,400}runOnce\(')
              .hasMatch(section));
  check('G23 档位落盘键固定，UI 与调度器读同一份设置',
      section.contains('_settings.updateIntervalDays') &&
          updaterSrc.contains('this.updateIntervalDays = 1') &&
          updaterSrc.contains('VodUpdateCadence.fromDays(updateIntervalDays)'));

  // ── 第二十六次修：获取过程要有进度条，且一定会收场 ──────────────
  check('G24 设置页获取时显示进度条 + 已用秒数（不再只有一行不动的字）',
      section.contains('LinearProgressIndicator(') &&
          section.contains('p?.fraction') &&
          section.contains('_startTicker') &&
          section.contains(r'已用 $_elapsedSec 秒') &&
          // 输入框改用 readOnly：置灰会让它丢焦点，焦点一丢又触发一次
          // 失焦提交（虽被 `_busy` 挡住，但光标会闪一下）。
          section.contains('readOnly: _busy || _updating') &&
          !section.contains('enabled: !_busy && !_updating'));
  check('G25 获取一定会有结论：异常也清 busy，失败用告警色',
      section.contains('_stopTicker()') &&
          section.contains('_noteIsError') &&
          section.contains(r"_note = '获取失败：$e，可改地址或稍后重试'") &&
          section.contains('_noteIsError ? AppTheme.warn'));
  // 第二十七次修：走 builtin 分支时那句「与默认片源索引地址一致…」——
  // 用户红标「把『默认』文字改成『当前』」，两处必须一起换，留一个就还是混口径。
  check('G26 复用内置记录的状态句按「当前」口径措辞（不再出现「默认」）',
      section.contains('与当前片源索引地址一致，已直接复用当前记录（未发起网络请求）') &&
          !section.contains('与默认片源索引地址一致'));
}

// ── ⑧ 版本与 1.0.4 回退基线 ────────────────────────────────────

void testVersionAndIsolation() {
  final pub = _src('pubspec.yaml');
  final sys = _src('lib/platform/system_channel.dart');
  final iss = _src('tooling/windows_installer.iss');
  final gates = _src('tooling/verify_all.dart');
  final buildPy = _src('legacy/build_legacy.py');
  final releaseIss = _src('tooling/windows_release.iss');
  final catalog = _src('lib/features/vod/vod_catalog.dart');

  check('H01 pubspec 版本为 1.0.6+7', pub.contains('version: 1.0.6+7'));
  check('H02 平台通道兜底版本同步',
      sys.contains("kAppVersionName = '1.0.6'") &&
          RegExp(r'kAppVersionCode\s*=\s*7\s*;').hasMatch(sys));
  check('H03 通用安装脚本版本同步',
      iss.contains('#define AppVersion "1.0.6"'));
  check('H04 新回归已接入统一门禁',
      gates.contains("'vod-source-address'") &&
          gates.contains('verify_vod_source_address.dart'));
  check('H05 1.0.4 legacy 产物脚本保留作回退基线',
      buildPy.contains('OUT_NAME = "Shunbo-Legacy-1.0.4-armv7a.apk"'));
  check('H06 1.0.4 Windows 实测出包脚本保留作回退基线',
      releaseIss.contains('#define MyAppVersion "1.0.4"'));
  check('H07 内置片库仍是默认合规片源',
      catalog.contains("sourceId = '内置片库'") &&
          catalog.contains('Blender 基金会开源影片'));
  check('H08 内置片库未混入任何第三方候选地址',
      !catalog.contains('124.223.214.31') &&
          !catalog.contains('starlink.fan'));
  check('H09 内置片库仍包装成标准源适配器（复用 1.0.4 播放链路）',
      catalog.contains('MemorySourceAdapter') &&
          catalog.contains('buildAdapter()'));
}

Future<void> main() async {
  testDefaults();
  testCandidates();
  testValidate();
  testSettings();
  await testStore();
  testSearch();
  testWiring();
  testVersionAndIsolation();
  print('');
  if (_fail == 0) {
    print('回归通过：$_pass/$_pass 断言通过');
    exit(0);
  }
  print('回归失败：$_pass/${_pass + _fail} 断言通过');
  exit(1);
}
