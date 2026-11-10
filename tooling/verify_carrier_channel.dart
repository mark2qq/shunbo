// 运营商电视通道回归（研发方案 N1–N6 / F1–F12）。
//
// 这一套要钉住的不是「能不能解析 m3u」，而是**不对的线路绝不能进候选**：
// 异网内网源被误启用会拖慢换台、产生无效请求甚至触发风控；组播默认开启
// 会让档位 C 用户每次换台先白等 3 秒。所以断言的重点是「剔除」而非「加入」，
// 以及识别失败时行为与接入前逐字节一致。
//
// 全部用注入的假归属服务 / 假网络状态 / 假时钟，不发一次真实外网请求。
//
// 运行：dart run tooling/verify_carrier_channel.dart
library;

import 'dart:async';
import 'dart:io';

import 'package:shunbo/core/player/player_controller.dart';
import 'package:shunbo/data/file_config_store.dart';
import 'package:shunbo/features/live/carrier_detector.dart';
import 'package:shunbo/features/live/carrier_playlist_importer.dart';
import 'package:shunbo/features/live/channel_settings.dart';
import 'package:shunbo/features/live/channel_settings_store.dart';
import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';
import 'package:shunbo/features/live/live_controller.dart';
import 'package:shunbo/features/live/live_selection.dart';
import 'package:shunbo/features/live/network_channel.dart';
import 'package:shunbo/features/live/network_event.dart';

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

class _Clock {
  DateTime now = DateTime(2026, 11, 7, 12);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

class _FakeLookup implements IpLookup {
  _FakeLookup(this.responses);
  final List<String?> responses;
  int calls = 0;

  @override
  Future<String?> lookup() async {
    calls++;
    return responses.isEmpty
        ? null
        : responses[(calls - 1).clamp(0, responses.length - 1)];
  }
}

class _FakeNetwork implements NetworkStateProvider {
  _FakeNetwork(this.state);
  NetworkState state;
  int calls = 0;

  @override
  Future<NetworkState> current() async {
    calls++;
    return state;
  }
}

const NetworkState _wifi = NetworkState(kind: NetworkKind.wifi, key: 'wifi-home');
const NetworkState _cellular =
    NetworkState(kind: NetworkKind.cellular, key: 'cellular');
const NetworkState _otherWifi =
    NetworkState(kind: NetworkKind.wifi, key: 'wifi-office');

CarrierDetector detectorOf(
  _FakeLookup lookup,
  _FakeNetwork network,
  _Clock clock, {
  Future<bool?> Function(Carrier carrier)? featureProbe,
  Duration ttl = const Duration(hours: 1),
}) =>
    CarrierDetector(
      lookup: lookup,
      networkProvider: network,
      featureProbe: featureProbe,
      ttl: ttl,
      clock: clock,
    );

LiveStream stream(
  String url, {
  LiveChannelType type = LiveChannelType.public,
  Carrier carrier = Carrier.unknown,
  String? rawAddr,
  int rank = 0,
}) =>
    LiveStream(
      url: url,
      qualityRank: rank,
      channelType: type,
      carrier: carrier,
      rawAddr: rawAddr,
    );

LiveChannel ch(String name, List<LiveStream> streams) => LiveChannel(
      id: LiveCatalogService.channelIdFor(name, '卫视频道'),
      name: name,
      group: '卫视频道',
      badge: '测',
      categories: const <String>['卫视频道'],
      streams: streams,
    );

// ── A. 模型与旧数据兼容 ────────────────────────────────────────────
void testModel() {
  print('\n== A. 线路模型与旧数据兼容 ==');
  final s = LiveStream(url: 'https://a.example/1.m3u8');
  check('老数据默认 public', s.channelType == LiveChannelType.public);
  check('老数据默认无运营商', s.carrier == Carrier.unknown);
  check('老数据无原始组播地址', s.rawAddr == null && s.transport == null);
  check('老数据仍可播', s.url.startsWith('https://'));

  final copy = s.withAddress('https://b.example/2.m3u8',
      rawAddr: 'udp://239.1.1.1:5000', transport: 'udp');
  check('withAddress 改地址', copy.url.contains('b.example'));
  check('withAddress 保留请求头等元数据', copy.headers.isEmpty && copy.qualityRank == 0);
  check('withAddress 带上原始组播地址', copy.rawAddr == 'udp://239.1.1.1:5000');
  check('withAddress 不改动原对象', s.rawAddr == null);

  final multi = <LiveStream>[
    stream('http://192.168.5.1:4022/udp/239.1.1.1:5000',
        type: LiveChannelType.multicast),
  ];
  final carrier = <LiveStream>[
    stream('http://10.0.0.9/cctv1.m3u8',
        type: LiveChannelType.carrierNet, carrier: Carrier.chinaMobile),
  ];
  check('hasMulticast 由线路汇总', ch('A', multi).hasMulticast);
  check('hasCarrierNet 由线路汇总', ch('B', carrier).hasCarrierNet);
  check('纯公网台标注公网', ch('C', [s]).channelLabel == '公网');
  check('仅专网台标注仅电视专网', ch('D', multi).channelLabel == '仅电视专网');
  check('仅内網台标注仅运营商内网', ch('E', carrier).channelLabel == '仅运营商内网');
  check('混合台标注两者兼有',
      ch('F', <LiveStream>[...multi, s]).channelLabel == '专网 + 公网');
  check('通道中文名齐全',
      LiveChannel.typeLabel(LiveChannelType.carrierNet) == '运营商内网' &&
          LiveChannel.typeLabel(LiveChannelType.multicast) == '电视专网');
}

// ── B. 设置与反序列化 ──────────────────────────────────────────────
void testSettings() {
  print('\n== B. 设置默认值与宽容反序列化 ==');
  const d = ChannelSettings();
  check('组播默认关闭', !d.multicastEnabled);
  check('默认未组播配置', !d.multicastConfigured);
  check('默认无 udpxy 主机', d.udpxyHost.isEmpty);
  check('默认端口 4022', d.udpxyPort == 4022);
  check('默认自动识别', d.carrierOverride == Carrier.unknown);
  check('默认无订阅地址', d.subscriptionUrl.isEmpty);
  check('默认省份江苏（仅展示用）', d.province == '江苏');

  check('空 JSON 回落默认', !ChannelSettings.fromJson(<String, dynamic>{}).multicastEnabled);
  final bad = ChannelSettings.fromJson(<String, dynamic>{
    'multicastEnabled': 'yes',
    'udpxyHost': '8.8.8.8',
    'udpxyPort': 99999,
    'carrierOverride': '不存在的运营商',
    'subscriptionUrl': 'ftp://user:pw@evil.example/x',
  });
  check('损坏字段不启用组播', !bad.multicastEnabled);
  check('公网主机被拒绝', bad.udpxyHost.isEmpty);
  check('越界端口回落默认', bad.udpxyPort == 4022);
  check('未知运营商回落 unknown', bad.carrierOverride == Carrier.unknown);
  check('非法订阅地址被清空', bad.subscriptionUrl.isEmpty);

  final good = ChannelSettings.fromJson(<String, dynamic>{
    'multicastEnabled': true,
    'udpxyHost': '192.168.5.1',
    'udpxyPort': 7088,
    'carrierOverride': 'mobile',
    'subscriptionUrl': 'https://example.com/jiangsu-mobile.m3u',
    'province': '江苏',
    'tableVersion': '2026-11-07',
  });
  check('合法配置可组播', good.multicastConfigured);
  check('合法端口被保留', good.udpxyPort == 7088);
  check('手动覆盖可解析', good.carrierOverride == Carrier.chinaMobile);
  check('合法订阅地址保留', good.subscriptionUrl.startsWith('https://'));

  final round = ChannelSettings.fromJson(
      Map<String, dynamic>.from(good.toJson()..remove('tableVersion')));
  check('toJson → fromJson 往返', round.udpxyHost == '192.168.5.1' &&
      round.multicastEnabled && round.carrierOverride == Carrier.chinaMobile);
  check('copyWith 只改指定字段',
      good.copyWith(udpxyPort: 4022).udpxyPort == 4022 &&
          good.copyWith(udpxyPort: 4022).udpxyHost == '192.168.5.1');
  check('运营商 key 三网互异', <String>{
        ChannelSettings.carrierKey(Carrier.chinaMobile),
        ChannelSettings.carrierKey(Carrier.chinaTelecom),
        ChannelSettings.carrierKey(Carrier.chinaUnicom),
      }.length ==
      3);
  check('运营商中文名齐全',
      ChannelSettings.carrierLabel(Carrier.chinaUnicom) == '中国联通' &&
          ChannelSettings.carrierLabel(Carrier.unknown) == '未知');
}

// ── C. udpxy 主机白名单 ────────────────────────────────────────────
void testHostWhitelist() {
  print('\n== C. udpxy 主机白名单（防把请求打向公网） ==');
  const ok = <String>[
    '192.168.5.1',
    '10.0.0.1',
    '172.16.0.1',
    '172.31.255.254',
    '127.0.0.1',
    '169.254.1.1',
    'localhost',
    'router.local',
  ];
  for (final h in ok) {
    check('放行 $h', ChannelSettings.isValidUdpxyHost(h));
  }
  const bad = <String>[
    '',
    '8.8.8.8',
    '1.2.3.4',
    '172.32.0.1',
    '192.169.1.1',
    'example.com',
    '192.168.5.1.evil.com',
    '192.168.5.1:4022',
    'http://192.168.5.1',
    '192.168.5.999',
    '192.168.5',
    '999.999.999.999',
  ];
  for (final h in bad) {
    check('拒绝 $h', !ChannelSettings.isValidUdpxyHost(h));
  }
  check('订阅地址允许为空', ChannelSettings.isValidSubscriptionUrl(''));
  check('订阅地址允许 https',
      ChannelSettings.isValidSubscriptionUrl('https://a.example/x.m3u'));
  check('订阅地址拒绝 javascript',
      !ChannelSettings.isValidSubscriptionUrl('javascript:alert(1)'));
  check('订阅地址拒绝 userinfo',
      !ChannelSettings.isValidSubscriptionUrl('https://u:p@a.example/x'));
  check('订阅地址拒绝换行注入',
      !ChannelSettings.isValidSubscriptionUrl('https://a.example/x\nHost: evil'));
  check('订阅地址拒绝超长',
      !ChannelSettings.isValidSubscriptionUrl('https://a.example/${'x' * 600}'));
}

// ── D. 组播地址解析与重写 ──────────────────────────────────────────
void testRewriter() {
  print('\n== D. 组播地址解析与 udpxy 重写 ==');
  final p1 = UdpxyRewriter.parseMulticast('udp://239.49.1.2:5000');
  check('udp:// 解析成功', p1 != null);
  check('udp transport 正确', p1?.$1 == 'udp');
  check('目标地址正确', p1?.$2 == '239.49.1.2:5000');
  check('rtp:// 解析成功',
      UdpxyRewriter.parseMulticast('rtp://239.49.1.2:5000')?.$1 == 'rtp');
  check('udp://@ 写法兼容',
      UdpxyRewriter.parseMulticast('udp://@239.49.1.2:5000')?.$2 ==
          '239.49.1.2:5000');
  check('裸 IP:端口 默认 udp',
      UdpxyRewriter.parseMulticast('239.49.1.2:5000')?.$1 == 'udp');
  for (final bad in <String>[
    'http://239.49.1.2:5000',
    'udp://192.168.5.1:5000',
    'udp://8.8.8.8:53',
    'udp://239.49.1.2:0',
    'udp://239.49.1.2:70000',
    'udp://239.49.1.2',
    'udp://239.49.1.2:5000/path',
    'udp://u:p@239.49.1.2:5000',
    'udp://239.49.1.2:5000\nX',
    '',
  ]) {
    check('拒绝 $bad', UdpxyRewriter.parseMulticast(bad) == null);
  }

  const r = UdpxyRewriter(host: '192.168.5.1', port: 4022);
  check('重写器合法', r.isValid);
  check('生成 /udp/ 单播地址',
      r.rewriteRaw('udp://239.49.1.2:5000') ==
          'http://192.168.5.1:4022/udp/239.49.1.2:5000');
  check('生成 /rtp/ 单播地址',
      r.rewriteRaw('rtp://239.49.1.2:5000') ==
          'http://192.168.5.1:4022/rtp/239.49.1.2:5000');
  check('非法网关不生成地址',
      const UdpxyRewriter(host: '8.8.8.8', port: 4022).rewriteRaw(
          'udp://239.49.1.2:5000') ==
          null);
  check('非法端口不生成地址',
      const UdpxyRewriter(host: '192.168.5.1', port: 0).rewriteRaw(
          'udp://239.49.1.2:5000') ==
          null);

  final s = stream('http://192.168.5.1:4022/udp/239.49.1.2:5000',
      type: LiveChannelType.multicast, rawAddr: 'udp://239.49.1.2:5000');
  final changed = const UdpxyRewriter(host: '192.168.5.1', port: 7088).rewrite(s);
  check('换端口后地址自动重写（验收 5）',
      changed.url == 'http://192.168.5.1:7088/udp/239.49.1.2:5000');
  check('重写后仍保留 raw_addr', changed.rawAddr == 'udp://239.49.1.2:5000');
  check('重写后通道类型不变', changed.channelType == LiveChannelType.multicast);
  check('无 raw_addr 的线路原样返回',
      identical(r.rewrite(stream('https://a/x.m3u8')).url, 'https://a/x.m3u8'));
}

// ── E. 运营商字段解析 ──────────────────────────────────────────────
void testCarrierText() {
  print('\n== E. 公网 IP 归属字段解析（三网通用） ==');
  final cases = <String, Carrier>{
    '{"addr":"江苏省苏州市 移动","cityCode":"320500"}': Carrier.chinaMobile,
    '{"isp":"中国移动"}': Carrier.chinaMobile,
    '{"org":"AS9808 China Mobile Communications Group Co., Ltd."}':
        Carrier.chinaMobile,
    '{"org":"AS4134 China Telecom"}': Carrier.chinaTelecom,
    '{"addr":"江苏省苏州市 电信"}': Carrier.chinaTelecom,
    '{"org":"AS4837 China Unicom"}': Carrier.chinaUnicom,
    '{"isp":"中国联通"}': Carrier.chinaUnicom,
    '{}': Carrier.unknown,
    '{"city":"苏州市"}': Carrier.unknown,
    '{"a":"中国移动","b":"中国联通"}': Carrier.unknown,
    'not a json but 移动': Carrier.chinaMobile,
    '': Carrier.unknown,
  };
  cases.forEach((raw, expected) {
    check('解析 ${raw.isEmpty ? '空串' : raw.substring(0, raw.length > 30 ? 30 : raw.length)}',
        CarrierDetector.parseCarrierText(raw) == expected,
        '期望 $expected');
  });
  check('三家同时命中按 unknown（宁可不识别）',
      CarrierDetector.parseCarrierText('移动 电信 联通') == Carrier.unknown);
}

// ── F. 识别器行为 ──────────────────────────────────────────────────
Future<void> testDetector() async {
  print('\n== F. 运营商自动识别（蜂窝零请求 / 失败兜底 / 缓存） ==');
  final clock = _Clock();
  final lookup = _FakeLookup(<String?>['{"addr":"江苏省苏州市 移动"}']);
  final network = _FakeNetwork(_wifi);
  final d = detectorOf(lookup, network, clock);
  final r1 = await d.detect(const ChannelSettings(), state: _wifi);
  check('Wi-Fi 下识别为移动', r1.carrier == Carrier.chinaMobile, r1.summary);
  check('识别来源为公网 IP 归属', r1.source == '公网 IP 归属');
  check('识别结论可用', r1.isUsable);
  check('未配置复核时不阻塞', !r1.verified);
  check('识别发起了一次归属请求', lookup.calls == 1);

  final r2 = await d.detect(const ChannelSettings(), state: _wifi);
  check('同网络缓存命中', r2.carrier == Carrier.chinaMobile);
  check('缓存命中不重复请求', lookup.calls == 1, '${lookup.calls}');

  clock.advance(const Duration(hours: 2));
  await d.detect(const ChannelSettings(), state: _wifi);
  check('超过 1 小时缓存失效', lookup.calls == 2, '${lookup.calls}');

  await d.detect(const ChannelSettings(), state: _otherWifi);
  check('换 Wi-Fi 立即重判', lookup.calls == 3, '${lookup.calls}');

  d.invalidate();
  await d.detect(const ChannelSettings(), state: _otherWifi);
  check('手动重新检测立即失效', lookup.calls == 4, '${lookup.calls}');

  final cellLookup = _FakeLookup(<String?>['{"isp":"中国移动"}']);
  final cellNet = _FakeNetwork(_cellular);
  final cellDetector = detectorOf(cellLookup, cellNet, clock);
  final cell = await cellDetector.detect(const ChannelSettings(), state: _cellular);
  check('蜂窝零网络请求', cellLookup.calls == 0, '${cellLookup.calls}');
  check('蜂窝按 public 兜底', !cell.isUsable);
  check('蜂窝给出可读原因', cell.reason.contains('蜂窝'));

  final cellHint = await cellDetector.detect(const ChannelSettings(),
      state: const NetworkState(
          kind: NetworkKind.cellular,
          key: 'cellular',
          carrierHint: Carrier.chinaMobile));
  check('系统运营商信息可用于蜂窝记录', cellHint.carrier == Carrier.chinaMobile);
  check('蜂窝即使识别也不启用内网源', cellHint.reason.contains('不启用'));

  final failLookup = _FakeLookup(<String?>[null]);
  final fail = await detectorOf(failLookup, _FakeNetwork(_wifi), clock)
      .detect(const ChannelSettings(), state: _wifi);
  check('归属服务不可用按 public 兜底', !fail.isUsable);
  check('兜底原因可读', fail.reason.contains('归属服务'));

  final conflictLookup = _FakeLookup(<String?>['{"a":"移动","b":"联通"}']);
  final conflict = await detectorOf(conflictLookup, _FakeNetwork(_wifi), clock)
      .detect(const ChannelSettings(), state: _wifi);
  check('归属字段矛盾按 public 兜底', !conflict.isUsable);

  final overrideLookup = _FakeLookup(<String?>['{"isp":"中国移动"}']);
  final overridden = await detectorOf(overrideLookup, _FakeNetwork(_wifi), clock)
      .detect(const ChannelSettings(carrierOverride: Carrier.chinaTelecom),
          state: _wifi);
  check('手动覆盖生效', overridden.carrier == Carrier.chinaTelecom);
  check('手动覆盖跳过归属请求', overrideLookup.calls == 0, '${overrideLookup.calls}');

  final verifyOk = _FakeLookup(<String?>['{"isp":"中国移动"}']);
  final verified = await detectorOf(verifyOk, _FakeNetwork(_wifi), clock,
          featureProbe: (c) async => c == Carrier.chinaMobile)
      .detect(const ChannelSettings(), state: _wifi);
  check('内网特征复核通过', verified.isUsable && verified.verified);

  final verifyBad = _FakeLookup(<String?>['{"isp":"中国移动"}']);
  final rejected = await detectorOf(verifyBad, _FakeNetwork(_wifi), clock,
          featureProbe: (c) async => false)
      .detect(const ChannelSettings(), state: _wifi);
  check('复核不一致一律回落 public', !rejected.isUsable);
  check('复核失败原因可读', rejected.reason.contains('复核'));

  final verifySkip = _FakeLookup(<String?>['{"isp":"中国移动"}']);
  final skipped = await detectorOf(verifySkip, _FakeNetwork(_wifi), clock,
          featureProbe: (c) async => null)
      .detect(const ChannelSettings(), state: _wifi);
  check('未配置特征地址时跳过而非否决', skipped.isUsable && !skipped.verified);

  final throwLookup = _FakeLookup(<String?>['{"isp":"中国移动"}']);
  final thrown = await detectorOf(throwLookup, _FakeNetwork(_wifi), clock,
          featureProbe: (c) async => throw StateError('probe down'))
      .detect(const ChannelSettings(), state: _wifi);
  check('复核抛异常不冒泡、按 public', !thrown.isUsable);

  final diag = CarrierDetection.unknown(_wifi, '测试原因');
  check('诊断摘要含运营商与原因', diag.summary.contains('未知') &&
      diag.summary.contains('测试原因'));
}

// ── G. 策略准入与冷却 ──────────────────────────────────────────────
Future<void> testPolicy() async {
  print('\n== G. 候选准入 / 异网剔除 / 失败冷却 ==');
  final clock = _Clock();
  final public = stream('https://public.example/1.m3u8');
  final mobile = stream('http://10.0.0.9/1.m3u8',
      type: LiveChannelType.carrierNet, carrier: Carrier.chinaMobile);
  final telecom = stream('http://10.0.0.8/1.m3u8',
      type: LiveChannelType.carrierNet, carrier: Carrier.chinaTelecom);
  final multi = stream('http://192.168.5.1:4022/udp/239.1.1.1:5000',
      type: LiveChannelType.multicast);

  final noNet = NetworkChannelPolicy(
    detector: detectorOf(_FakeLookup(<String?>[null]), _FakeNetwork(_wifi), clock),
    clock: clock,
  );
  await noNet.refresh(state: _wifi);
  check('默认组播状态未配置', noNet.multicastState == ChannelUsable.unconfigured);
  check('公网源恒可用', noNet.isEligible(public));
  check('未识别时移动内网源剔除', !noNet.isEligible(mobile));
  check('未识别时电信内网源剔除', !noNet.isEligible(telecom));
  check('未配置时组播源剔除', !noNet.isEligible(multi));
  check('候选集合仍只剩公网',
      noNet.eligible(<LiveStream>[mobile, multi, public]).length == 1);

  final mobilePolicy = NetworkChannelPolicy(
    detector: detectorOf(
        _FakeLookup(<String?>['{"addr":"江苏省苏州市 移动"}']),
        _FakeNetwork(_wifi),
        clock),
    clock: clock,
  );
  await mobilePolicy.refresh(state: _wifi);
  check('识别为移动后本家内网源进候选', mobilePolicy.isEligible(mobile));
  check('识别为移动后异网电信源仍剔除', !mobilePolicy.isEligible(telecom));
  check('公网源仍在候选（不劣于现状）', mobilePolicy.isEligible(public));

  // N5：异网线路失败不产生任何记录。
  mobilePolicy.noteFailure(telecom);
  check('异网失败不进冷却表', mobilePolicy.cooldownCount == 0,
      '${mobilePolicy.cooldownCount}');
  mobilePolicy.noteFailure(mobile);
  check('本家内网失败进冷却', mobilePolicy.cooldownCount == 1);
  check('冷却后不再进候选', !mobilePolicy.isEligible(mobile));
  clock.advance(const Duration(minutes: 4));
  check('4 分钟仍在冷却', !mobilePolicy.isEligible(mobile));
  clock.advance(const Duration(minutes: 2));
  check('超过 5 分钟自动解封', mobilePolicy.isEligible(mobile));
  check('懒清理后冷却表归零', mobilePolicy.cooldownCount == 0);

  mobilePolicy.noteFailure(public);
  check('公网失败不归通道策略管', mobilePolicy.cooldownCount == 0);
  check('公网失败后仍可播', mobilePolicy.isEligible(public));

  mobilePolicy.noteFailure(multi);
  check('未启用组播的失败同样不记', mobilePolicy.cooldownCount == 0);

  final cellPolicy = NetworkChannelPolicy(
    detector: detectorOf(_FakeLookup(<String?>['{"isp":"中国移动"}']),
        _FakeNetwork(_cellular), clock),
    clock: clock,
  );
  final cellResult = await cellPolicy.refresh(state: _cellular);
  check('蜂窝识别不发归属请求', cellResult.reason.contains('蜂窝'));
  check('蜂窝下内网源不进候选', !cellPolicy.isEligible(mobile));
  check('蜂窝下公网源仍可用', cellPolicy.isEligible(public));

  // F2：改端口后由 rewriteIfNeeded 立即生效。
  const cfg = ChannelSettings(
    multicastEnabled: true,
    udpxyHost: '192.168.5.1',
    udpxyPort: 4022,
  );
  cellPolicy.updateSettings(cfg);
  check('启用后组播不再是未配置',
      cellPolicy.multicastState != ChannelUsable.unconfigured);
  check('启用但未检测时组播仍不可用', !cellPolicy.isEligible(multi));
  final withRaw = stream('http://192.168.5.1:4022/udp/239.1.1.1:5000',
      type: LiveChannelType.multicast, rawAddr: 'udp://239.1.1.1:5000');
  check('起播前按当前端口重写',
      cellPolicy.rewriteIfNeeded(withRaw).url.contains(':4022/udp/'));
  cellPolicy.updateSettings(cfg.copyWith(udpxyPort: 7088));
  check('改端口后无需重新导入即生效',
      cellPolicy.rewriteIfNeeded(withRaw).url ==
          'http://192.168.5.1:7088/udp/239.1.1.1:5000');
  check('改设置清空旧冷却', cellPolicy.cooldownCount == 0);
  final diag = cellPolicy.diagnostics();
  check('诊断含网络类型与识别说明',
      diag.networkType.isNotEmpty && diag.carrierReason.isNotEmpty);
  check('诊断三项结果齐全',
      diag.rows().any((r) => r.$1 == 'udpxy 连通') &&
          diag.rows().any((r) => r.$1 == '组播首包') &&
          diag.rows().any((r) => r.$1 == '网络类型'));
}

// ── H. 一键检测 ────────────────────────────────────────────────────
Future<void> testMulticastCheck() async {
  print('\n== H. 组播一键检测（300ms 主机 / 1.5s 首包） ==');
  final clock = _Clock();
  final multi = stream('http://192.168.5.1:4022/udp/239.1.1.1:5000',
      type: LiveChannelType.multicast);
  const cfg = ChannelSettings(
    multicastEnabled: true,
    udpxyHost: '192.168.5.1',
    udpxyPort: 4022,
  );

  final off = NetworkChannelPolicy(clock: clock.call);
  final offResult = await off.checkMulticast(
    connect: () async => true,
    firstPacket: () async => true,
    candidates: <LiveStream>[multi],
  );
  check('未配置时不发起检测', offResult == ChannelUsable.unconfigured);
  check('未配置时给出可读原因', off.diagnostics().udpxyReason.contains('未启用'));

  final noTable = NetworkChannelPolicy(settings: cfg, clock: clock.call);
  final r0 = await noTable.checkMulticast(
    connect: () async => true,
    firstPacket: () async => true,
    candidates: <LiveStream>[],
  );
  check('无地址表时判不可用', r0 == ChannelUsable.unusable);
  check('失败定位到地址表', noTable.diagnostics().udpxyReason.contains('地址表'));

  final hostDown = NetworkChannelPolicy(settings: cfg, clock: clock.call);
  final r1 = await hostDown.checkMulticast(
    connect: () async => false,
    firstPacket: () async => true,
    candidates: <LiveStream>[multi],
  );
  check('主机不通判不可用', r1 == ChannelUsable.unusable);
  check('失败定位到主机', hostDown.diagnostics().udpxyReason.contains('主机'));
  check('主机不通时不试首包', hostDown.diagnostics().firstPacketMs == 0);

  final packetTimeout = NetworkChannelPolicy(settings: cfg, clock: clock.call);
  final r2 = await packetTimeout.checkMulticast(
    connect: () async => true,
    firstPacket: () async => false,
    candidates: <LiveStream>[multi],
  );
  check('首包超时判不可用', r2 == ChannelUsable.unusable);
  check('失败定位到首包',
      packetTimeout.diagnostics().udpxyReason.contains('首包'));

  final ok = NetworkChannelPolicy(settings: cfg, clock: clock.call);
  final r3 = await ok.checkMulticast(
    connect: () async => true,
    firstPacket: () async => true,
    candidates: <LiveStream>[multi],
  );
  check('主机通 + 首包到判可用', r3 == ChannelUsable.usable);
  check('可用后组播线路进候选', ok.isEligible(multi));
  check('可用后公网仍不丢', ok.isEligible(stream('https://a/x.m3u8')));
  check('诊断记录连通耗时', ok.diagnostics().udpxyMs >= 0);
  check('诊断记录首包耗时', ok.diagnostics().firstPacketMs >= 0);

  // F5 / N3：组播可用时优先，carrier_net 不加特权。
  final ranked = LiveSelection.rankStreams(
    ch('卫视', <LiveStream>[
      stream('https://public.example/1.m3u8', rank: 100),
      multi,
    ]),
    DeadStreamRegistry(),
    policy: ok,
  );
  check('组播可用时排在公网前', ranked.first.channelType == LiveChannelType.multicast);
  check('排序未丢公网线路', ranked.length == 2);

  final before = ok.multicastState;
  await ok.refresh(state: _otherWifi, force: true);
  check('换网络后组播结论作废', before == ChannelUsable.usable &&
      ok.multicastState == ChannelUsable.unusable);
  check('换网络后失败原因可定位',
      ok.diagnostics().udpxyReason.contains('重新检测'));
}

// ── I. 地址表导入 ──────────────────────────────────────────────────
void testImporter() {
  print('\n== I. 通道地址表导入（M1 / F11） ==');
  const importer = CarrierPlaylistImporter();
  const cfg = ChannelSettings(
    multicastEnabled: true,
    udpxyHost: '192.168.5.1',
    udpxyPort: 4022,
  );
  const m3u = '#EXTM3U\n'
      '#EXTINF:-1 group-title="央视频道",CCTV-1 综合\n'
      'udp://239.49.1.1:5000\n'
      '#EXTINF:-1 group-title="卫视频道",江苏卫视\n'
      'rtp://239.49.1.2:5002\n'
      '#EXTINF:-1 group-title="卫视频道",浙江卫视\n'
      'https://public.example/zj.m3u8\n';
  final r = importer.import(
    text: m3u,
    type: LiveChannelType.multicast,
    settings: cfg,
    version: '2026-11-07',
  );
  check('m3u 导入成功', r.ok, r.error ?? '');
  check('导入 3 个频道', r.channels.length == 3, '${r.channels.length}');
  check('组播线路计数正确', r.multicastCount == 2, '${r.multicastCount}');
  check('非组播地址归为公网', r.publicCount == 1, '${r.publicCount}');
  check('重写后的地址是 http 单播',
      r.channels.any((c) => c.streams.any((s) => s.url.contains('/udp/239.49.1.1:5000'))));
  check('rtp 走 /rtp/ 路径',
      r.channels.any((c) => c.streams.any((s) => s.url.contains('/rtp/239.49.1.2:5002'))));
  check('保留 raw_addr',
      r.channels.any((c) => c.streams.any((s) => s.rawAddr == 'udp://239.49.1.1:5000')));
  check('保留 transport',
      r.channels.any((c) => c.streams.any((s) => s.transport == 'rtp')));
  check('组播台 hasMulticast 为真',
      r.channels.any((c) => c.hasMulticast));
  check('台名归一复用线上逻辑',
      r.channels.any((c) => c.name.contains('CCTV')));

  final carrier = importer.import(
    text: '#EXTM3U\n'
        '#EXTINF:-1 group-title="央视频道",CCTV-1 综合\n'
        'http://10.10.1.1/cctv1.m3u8\n',
    type: LiveChannelType.carrierNet,
    settings: const ChannelSettings(),
    carrier: Carrier.chinaMobile,
  );
  check('内网清单导入成功', carrier.ok, carrier.error ?? '');
  check('内网线路计数正确', carrier.carrierNetCount == 1);
  check('内网线路带运营商归属',
      carrier.channels.first.streams.first.carrier == Carrier.chinaMobile);
  check('内网线路不写 raw_addr', carrier.channels.first.streams.first.rawAddr == null);
  check('内网台 hasCarrierNet 为真', carrier.channels.first.hasCarrierNet);

  const twoCol = 'CCTV-1 综合,udp://239.49.1.1:5000\n'
      '江苏卫视,udp://239.49.1.2:5002\n'
      ',#genre#\n'
      '苏州新闻综合,udp://239.49.1.3:5004\n';
  final txt = importer.import(
    text: twoCol,
    type: LiveChannelType.multicast,
    settings: cfg,
    format: AddressTableFormat.nameUrl,
  );
  check('两列文本导入成功', txt.ok, txt.error ?? '');
  check('两列文本解析出频道', txt.channels.isNotEmpty, '${txt.channels.length}');
  check('两列文本也完成重写',
      txt.multicastCount >= 1, '${txt.multicastCount}');

  check('空表给出错误', importer.import(
    text: '',
    type: LiveChannelType.multicast,
    settings: cfg,
  ).error != null);
  check('超长表被拒绝', importer.import(
    text: 'x' * (CarrierPlaylistImporter.maxInputBytes + 1),
    type: LiveChannelType.multicast,
    settings: cfg,
  ).error != null);
  final noGateway = importer.import(
    text: m3u,
    type: LiveChannelType.multicast,
    settings: const ChannelSettings(),
  );
  check('未配置 udpxy 时给出可操作错误',
      noGateway.error?.contains('udpxy') ?? false, noGateway.error ?? '');

  const dup = '#EXTM3U\n'
      '#EXTINF:-1,CCTV-1 综合\nhttps://a.example/1.m3u8\n'
      '#EXTINF:-1,CCTV-1 综合 HD\nhttps://a.example/1.m3u8\n';
  final dedup = importer.import(
    text: dup,
    type: LiveChannelType.carrierNet,
    settings: const ChannelSettings(),
    carrier: Carrier.chinaMobile,
  );
  check('同名同址去重', dedup.duplicates >= 1 || dedup.channels.first.streams.length == 1,
      'duplicates=${dedup.duplicates}');

  final s1 = const AddressTableSnapshot(
    text: 'a',
    version: 'v1',
    updatedAt: '2026-11-01',
    previousText: '',
    previousVersion: '',
  );
  final s2 = s1.next('b', 'v2', '2026-11-07');
  check('新版本保留上一版', s2.hasPrevious && s2.previousText == 'a');
  check('新版本自身内容正确', s2.text == 'b' && s2.version == 'v2');
  final back = s2.rollback();
  check('回滚回到上一版', back.text == 'a' && back.version == 'v1');
  check('回滚后不再有上一版', !back.hasPrevious);
  check('快照 JSON 往返',
      AddressTableSnapshot.fromJson(Map<String, dynamic>.from(s2.toJson()))?.text == 'b');
  check('损坏快照被拒绝',
      AddressTableSnapshot.fromJson(<String, dynamic>{'text': 42}) == null);
  check('导入结果摘要可读', r.summary.contains('频道'));
}

// ── J. 落盘与回滚 ──────────────────────────────────────────────────
Future<void> testStore() async {
  print('\n== J. 设置落盘 / 老库兼容 / 地址表回滚 ==');
  final dir = Directory.systemTemp.createTempSync('shunbo_channel_');
  try {
    final file = File('${dir.path}/config.json');
    final store = ChannelSettingsStore(FileConfigStore(file));
    final fresh = await store.load();
    check('新装读出组播关闭', !fresh.multicastEnabled);
    check('新装读出自动识别', fresh.carrierOverride == Carrier.unknown);
    check('新装无地址表', await store.loadTable() == null);

    const cfg = ChannelSettings(
      multicastEnabled: true,
      udpxyHost: '192.168.5.1',
      udpxyPort: 7088,
      carrierOverride: Carrier.chinaTelecom,
      tableVersion: 'v2',
    );
    await store.save(cfg);
    final loaded = await store.load();
    check('设置落盘往返', loaded.multicastConfigured && loaded.udpxyPort == 7088);
    check('手动覆盖落盘往返', loaded.carrierOverride == Carrier.chinaTelecom);

    const t1 = AddressTableSnapshot(
      text: 'first',
      version: 'v1',
      updatedAt: '2026-11-01',
      previousText: '',
      previousVersion: '',
    );
    await store.saveTable(t1);
    await store.saveTable(t1.next('second', 'v2', '2026-11-07'));
    check('地址表保存了上一版', (await store.loadTable())?.hasPrevious ?? false);
    final rolled = await store.rollback();
    check('回滚读出上一版内容', rolled?.text == 'first');
    check('回滚后不再可回滚', await store.rollback() == null);

    // 老库：只有 sourceConfig 等老键，没有两个新键 → 必须仍是纯公网形态。
    final legacy = File('${dir.path}/legacy.json');
    await legacy.writeAsString('{"sourceConfig":{"sources":[]}}');
    final legacyStore = ChannelSettingsStore(FileConfigStore(legacy));
    final legacySettings = await legacyStore.load();
    check('老库不改既有行为', !legacySettings.multicastEnabled &&
        legacySettings.carrierOverride == Carrier.unknown);
    check('老库无地址表', await legacyStore.loadTable() == null);

    // 人为写坏配置：不能让 App 起不来，也不能误开启组播。
    final broken = File('${dir.path}/broken.json');
    await broken.writeAsString('{"state:network-channel": "not-a-map"}');
    final brokenStore = ChannelSettingsStore(FileConfigStore(broken));
    check('损坏配置回落默认', !(await brokenStore.load()).multicastEnabled);
  } finally {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // Windows 文件句柄偶发占用，临时目录清理失败不影响断言结论。
    }
  }
}

// ── K. 选源集成 ────────────────────────────────────────────────────
Future<void> testSelection() async {
  print('\n== K. 与既有选源体系集成 ==');
  final clock = _Clock();
  final public = stream('https://public.example/1.m3u8', rank: 90);
  final mobile = stream('http://10.0.0.9/1.m3u8',
      type: LiveChannelType.carrierNet, carrier: Carrier.chinaMobile, rank: 100);
  final telecom = stream('http://10.0.0.8/1.m3u8',
      type: LiveChannelType.carrierNet, carrier: Carrier.chinaTelecom, rank: 100);
  final channel = ch('测试卫视', <LiveStream>[telecom, mobile, public]);

  final plain = LiveSelection.rankStreams(channel, DeadStreamRegistry());
  check('不传策略时行为不变（三条都在）', plain.length == 3);
  check('不传策略时画质排序不变', plain.first.qualityRank == 100);

  final unknownPolicy = NetworkChannelPolicy(
    detector: detectorOf(_FakeLookup(<String?>[null]), _FakeNetwork(_wifi), clock),
    clock: clock,
  );
  await unknownPolicy.refresh(state: _wifi);
  final filtered = LiveSelection.rankStreams(channel, DeadStreamRegistry(),
      policy: unknownPolicy);
  check('未识别时候选只剩公网', filtered.length == 1, '${filtered.length}');
  check('未识别时不会整台无候选', filtered.first.channelType == LiveChannelType.public);
  check('pickPlayable 仍能选中该台',
      LiveSelection.pickPlayable(<LiveChannel>[channel], DeadStreamRegistry(),
          policy: unknownPolicy) != null);
  check('hasLiveStream 仍为真',
      LiveSelection.hasLiveStream(channel, DeadStreamRegistry(),
          policy: unknownPolicy));

  final mobilePolicy = NetworkChannelPolicy(
    detector: detectorOf(
        _FakeLookup(<String?>['{"addr":"江苏省苏州市 移动"}']),
        _FakeNetwork(_wifi),
        clock),
    clock: clock,
  );
  await mobilePolicy.refresh(state: _wifi);
  final withCarrier = LiveSelection.rankStreams(channel, DeadStreamRegistry(),
      policy: mobilePolicy);
  check('识别移动后本家源 + 公网进候选', withCarrier.length == 2,
      '${withCarrier.length}');
  check('异网电信源始终不在候选',
      withCarrier.every((s) => s.carrier != Carrier.chinaTelecom));
  check('N3：内网源不强制优先（按首帧/画质自然排序）',
      withCarrier.first.qualityRank >= withCarrier.last.qualityRank);

  // N5：探测失败不污染异网线路 / 不产生额外候选。
  var probed = 0;
  final noCarrier = NetworkChannelPolicy(
    detector: detectorOf(_FakeLookup(<String?>[null]), _FakeNetwork(_wifi), clock),
    clock: clock,
  );
  await noCarrier.refresh(state: _wifi);
  await LiveSelection.pickProbed(
    channels: <LiveChannel>[channel],
    dead: DeadStreamRegistry(),
    policy: noCarrier,
    probe: (s) async {
      probed++;
      return false;
    },
    batch: 1,
    rounds: 1,
  );
  check('异网线路根本不发起探测', probed == 1, '$probed');
  check('异网线路不产生冷却记录', noCarrier.cooldownCount == 0);
}

// ── L. 真实控制器接入 ──────────────────────────────────────────────
Future<void> testController() async {
  print('\n== L. LiveController 端到端 ==');
  final clock = _Clock();
  final policy = NetworkChannelPolicy(
    detector: detectorOf(
        _FakeLookup(<String?>['{"addr":"江苏省苏州市 移动"}']),
        _FakeNetwork(_wifi),
        clock),
    clock: clock,
  );
  final player = _FakePlayer();
  final c = LiveController(
    player: player,
    catalogService: LiveCatalogService(builtIn: <LiveChannel>[]),
    channelPolicy: policy,
  );
  final channel = ch('测试卫视', <LiveStream>[
    stream('http://10.0.0.9/1.m3u8',
        type: LiveChannelType.carrierNet, carrier: Carrier.chinaTelecom),
    stream('https://public.example/1.m3u8'),
  ]);
  c.loadChannelsForTest(<LiveChannel>[channel]);

  await c.refreshNetwork();
  check('控制器刷新后得到识别结论', c.channelDiagnostics.carrier == '中国移动');
  check('控制器诊断含识别耗时项',
      c.channelDiagnostics.rows().any((r) => r.$1 == '识别耗时'));

  final merged = c.importAddressTable(<LiveChannel>[
    ch('测试卫视', <LiveStream>[
      stream('http://10.0.0.7/2.m3u8',
          type: LiveChannelType.carrierNet, carrier: Carrier.chinaMobile),
    ]),
  ]);
  check('地址表并入成功', merged.contains('已并入'), merged);
  check('同名台不新建第二个台',
      c.channels.where((e) => e.id == channel.id).length == 1);
  check('并入后线路数增加',
      c.channels.firstWhere((e) => e.id == channel.id).streams.length == 3);

  c.applyChannelSettings(const ChannelSettings(
    multicastEnabled: true,
    udpxyHost: '192.168.5.1',
    udpxyPort: 4022,
  ));
  check('应用设置后组播转为需重新检测',
      c.channelDiagnostics.rows().any((r) => r.$1 == '组播通道'));
  check('应用设置不改动频道表', c.channels.length == 1);

  c.dispose();
  check('dispose 后不再抛异常', true);
}

class _FakePlayer implements PlayerController {
  final List<String> loads = <String>[];
  double _volume = 100;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> load(
    String url,
    int episode,
    double rawSeconds, {
    Map<String, String> headers = const <String, String>{},
  }) async =>
      loads.add(url);

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(double rawSeconds) async {}

  @override
  Future<void> setVolume(double volume) async => _volume = volume;

  @override
  double get volume => _volume;

  @override
  Stream<double> get volumeChanges => Stream<double>.value(_volume);

  @override
  Future<double> currentRawSeconds() async => 1.0;

  @override
  Future<double> duration() async => 0;

  @override
  Future<void> dispose() async {}
}

Map<String, Object?> _netEvent({
  String kind = 'wifi',
  String key = 'wifi:wlan0:unmetered',
  bool connected = true,
  bool vpn = false,
  bool restricted = false,
  bool metered = false,
  String iface = 'wlan0',
  Object? carrierHint,
}) =>
    <String, Object?>{
      'kind': kind,
      'key': key,
      'connected': connected,
      'vpn': vpn,
      'restricted': restricted,
      'metered': metered,
      'iface': iface,
      'carrierHint': carrierHint,
    };

/// R14：Android ConnectivityManager 事件是平台侧输入，必须当不可信数据净化。
void testNetworkEvents() {
  print('\n== K. 平台网络事件解析 / 语义去重 ==');
  check('非 Map 输入拒绝', NetworkSnapshot.tryParse(null) == null);
  check('字符串输入拒绝', NetworkSnapshot.tryParse('wifi') == null);

  final wifi = NetworkSnapshot.tryParse(_netEvent());
  check('Wi-Fi 事件解析成功', wifi != null);
  check('Wi-Fi 类型正确', wifi?.state.kind == NetworkKind.wifi);
  check('缓存键原样保留', wifi?.state.key == 'wifi:wlan0:unmetered');
  check('正常网络不暂停', wifi?.shouldSuspend == false);
  check('正常网络不受限', wifi?.restricted == false);

  final cell = NetworkSnapshot.tryParse(_netEvent(
    kind: 'cellular',
    key: 'cellular:rmnet0:metered',
    metered: true,
    carrierHint: '中国移动',
    iface: 'rmnet0',
  ));
  check('蜂窝事件判为蜂窝', cell?.state.isCellular == true);
  check('系统运营商信息被采信',
      cell?.state.carrierHint == Carrier.chinaMobile);
  check('蜂窝仍需走「零请求」分支而非暂停', cell?.shouldSuspend == false);

  final conflict = NetworkSnapshot.tryParse(_netEvent(
    kind: 'cellular', key: 'cellular:rmnet0:metered',
    carrierHint: '{"isp":"中国移动 中国电信"}', iface: 'rmnet0'));
  check('互相矛盾的运营商提示按未知处理', conflict?.state.carrierHint == null);

  final vpn = NetworkSnapshot.tryParse(
      _netEvent(kind: 'vpn', key: 'vpn:wlan0:unmetered', vpn: true));
  check('VPN 必须暂停非公网通道', vpn?.shouldSuspend == true);
  check('VPN 归为未知网络', vpn?.state.kind == NetworkKind.unknown);
  check('VPN 标记保留供诊断', vpn?.vpn == true);

  final offline = NetworkSnapshot.tryParse(
      _netEvent(kind: 'unknown', key: 'offline', connected: false, restricted: true));
  check('离线必须暂停', offline?.shouldSuspend == true);
  check('离线键固定', offline?.state.key == 'offline');

  final unknownTransport = NetworkSnapshot.tryParse(
      _netEvent(kind: 'bluetooth', key: 'bluetooth:bt-pan:unmetered'));
  check('未知传输按受限处理', unknownTransport?.shouldSuspend == true);

  final empty = NetworkSnapshot.tryParse(<String, Object?>{});
  check('缺字段事件不误判为正常网络', empty?.shouldSuspend == true);

  final dirtyKey = NetworkSnapshot.tryParse(
      _netEvent(key: 'wifi:wlan0:unmetered\n伪造诊断行'));
  check('带控制字符的键被替换', dirtyKey?.state.key.endsWith('untrusted') == true);
  final longKey = NetworkSnapshot.tryParse(_netEvent(key: 'a' * 300));
  check('超长键被替换', longKey?.state.key.endsWith('untrusted') == true);
  final badType = NetworkSnapshot.tryParse(_netEvent(carrierHint: 123));
  check('非字符串运营商提示忽略', badType?.state.carrierHint == null);

  final gate = NetworkChangeGate();
  check('首帧必达（初始化需要）', gate.acceptAndParse(_netEvent()) != null);
  check('同键同态重复事件被吞', gate.acceptAndParse(_netEvent()) == null);
  check('仅接口名变化不触发重判',
      gate.acceptAndParse(_netEvent(iface: 'wlan1')) == null);
  final eth = _netEvent(kind: 'ethernet', key: 'ethernet:eth0:unmetered',
      iface: 'eth0');
  check('换网键变化放行', gate.acceptAndParse(eth) != null);
  check('离线事件放行', gate.acceptAndParse(_netEvent(
          kind: 'unknown', key: 'offline', connected: false,
          restricted: true)) != null);
  check('恢复事件放行', gate.acceptAndParse(eth) != null);
  check('受限标记翻转放行',
      gate.acceptAndParse(_netEvent(kind: 'vpn', key: 'vpn:wlan0:unmetered',
          vpn: true)) != null);
  check('脏数据不改变上一次结论',
      gate.acceptAndParse('bad') == null &&
          gate.last?.state.kind == NetworkKind.unknown);
  gate.reset();
  check('reset 后回到未初始化', gate.last == null);
  check('reset 后首帧重新必达', gate.acceptAndParse(_netEvent()) != null);
}

/// R14：离线 / VPN 的暂停必须零网络请求，恢复后才重新识别。
Future<void> testNetworkSuspend() async {
  print('\n== L. 网络受限暂停 / 恢复 ==');
  final clock = _Clock();
  final lookup = _FakeLookup(<String?>['{"addr":"江苏省苏州市 移动"}']);
  final network = _FakeNetwork(_wifi);
  final policy = NetworkChannelPolicy(
    detector: detectorOf(lookup, network, clock),
    settings: const ChannelSettings(
        multicastEnabled: true, udpxyHost: '192.168.1.1'),
    clock: clock,
  );
  await policy.refresh(state: _wifi);
  final before = lookup.calls;
  check('刷新后识别成功', policy.detection?.isUsable == true);
  check('刷新后内网通道可用',
      policy.diagnostics().carrierNet == ChannelUsable.usable);

  final mobile = stream('http://10.0.0.9/1.m3u8',
      type: LiveChannelType.carrierNet, carrier: Carrier.chinaMobile);
  policy.noteFailure(mobile);
  policy.suspend();
  check('暂停后识别结论清空', policy.detection == null);
  check('暂停后冷却清空', policy.cooldownCount == 0);
  check('暂停后内网通道判不可用',
      policy.diagnostics().carrierNet == ChannelUsable.unusable);
  check('暂停后组播判不可用', policy.multicastState == ChannelUsable.unusable);
  check('暂停零网络请求', lookup.calls == before, '${lookup.calls} vs $before');
  check('暂停后公网源仍可用',
      policy.isEligible(stream('https://public.example/1.m3u8')));
  check('暂停原因进入诊断', policy.diagnostics().rows().any(
      (r) => r.$2 == kNetworkSuspendReason));

  await policy.refresh(state: _wifi);
  check('恢复后重新识别', policy.detection?.isUsable == true);
  check('恢复后内网通道重新可用',
      policy.diagnostics().carrierNet == ChannelUsable.usable);
  check('恢复后诊断不再显示暂停', !policy.diagnostics().rows().any(
      (r) => r.$2 == kNetworkSuspendReason));
  check('恢复只发一次归属请求', lookup.calls == before + 1);
}

Future<void> main() async {
  testModel();
  testSettings();
  testHostWhitelist();
  testRewriter();
  testCarrierText();
  await testDetector();
  await testPolicy();
  await testMulticastCheck();
  testImporter();
  await testStore();
  await testSelection();
  await testController();
  testNetworkEvents();
  await testNetworkSuspend();
  print('\n回归通过：$_pass/${_pass + _fail} 断言通过');
  if (_fail > 0) exitCode = 1;
}
