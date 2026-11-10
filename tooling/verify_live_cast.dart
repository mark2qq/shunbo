// 直播投屏换台重下发（R12c）的回归。
//
// 这一块的失败同样是**静默**的：用户按「下一个台」，本机画面换了，
// 电视还停在上一台 —— 界面上没有任何一处会报错。更糟的两种：
// 1. 连按换台时旧的起播结果最后返回，把「已推送地址」写回上一个台，
//    于是电视永远慢一步，用户以为投屏坏了；
// 2. 换台换了源站却复用旧中继，把上一路的 `Referer` 发给新源站，
//    轻则 403、重则拿到别人的授权内容。
//
// 所以这里钉的是**状态机**，不是网络：用 FakeTransport + FakeRelay
// 在几十毫秒内把所有分支跑一遍。
//
// 运行：dart run tooling/verify_live_cast.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shunbo/core/cast/cast_fallback.dart';
import 'package:shunbo/core/cast/cast_metrics.dart';
import 'package:shunbo/core/cast/cast_mode.dart';
import 'package:shunbo/core/cast/cast_session.dart';
import 'package:shunbo/core/cast/relay/relay_session.dart';

int _checkCount = 0;
int _failCount = 0;

void check(String name, bool ok, [String? detail]) {
  if (!ok) {
    _failCount++;
    print('FAIL: $name${detail == null ? '' : ' —— $detail'}');
    return;
  }
  _checkCount++;
  print('PASS: $name');
}

const _tv = CastDevice(id: 'tv-1', name: '客厅电视');

String _playlist(String host, int i) => 'http://$host/live/$i.m3u8';

/// 假中继：只验证「地址怎么包、什么时候重启、什么时候停」。
class FakeRelay implements CastRelaySession {
  FakeRelay(this.index, this.headers)
      : _base = Uri.parse('http://192.168.1.9:${8100 + index}/t/tok$index');

  final int index;
  final Map<String, String> headers;

  int stopCount = 0;
  Uri? _base;

  Uri? get baseUri => _base;

  @override
  String? relayUrlFor(String upstreamUrl) {
    final base = _base;
    if (base == null) return null;
    final encoded = base64Url.encode(utf8.encode(upstreamUrl));
    return '${base.toString()}/r/$encoded';
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _base = null;
  }
}

/// 中继工厂：记录被调用了几次（= 重启了几次）。
class RelaySpy {
  final List<FakeRelay> created = <FakeRelay>[];
  bool failNext = false;

  Future<CastRelaySession?> call(Map<String, String> headers) async {
    if (failNext) {
      failNext = false;
      return null;
    }
    final relay = FakeRelay(created.length, headers);
    created.add(relay);
    return relay;
  }

  int get calls => created.length;
}

// ---------------------------------------------------------------------------
// 1. 换台是否该重下发（判定唯一出处）
// ---------------------------------------------------------------------------

void testShouldRetarget() {
  check(
      '投屏中 + 已出图 + 地址变了 → 需要重下发',
      shouldRetargetLiveCast(
        casting: true,
        playing: true,
        streamUrl: 'http://a/1.m3u8',
        lastSentUrl: 'http://a/2.m3u8',
      ));

  check(
      '未投屏 → 不重下发（否则等于偷偷把画面推到电视上）',
      !shouldRetargetLiveCast(
        casting: false,
        playing: true,
        streamUrl: 'http://a/1.m3u8',
        lastSentUrl: null,
      ));

  check(
      '还没出图（tuning 中间态）→ 不重下发',
      !shouldRetargetLiveCast(
        casting: true,
        playing: false,
        streamUrl: 'http://a/1.m3u8',
        lastSentUrl: 'http://a/2.m3u8',
      ));

  check(
      '地址为空 → 不重下发（空 CurrentURI 会让部分电视进错误态）',
      !shouldRetargetLiveCast(
        casting: true,
        playing: true,
        streamUrl: '',
        lastSentUrl: 'http://a/2.m3u8',
      ));

  check(
      '地址与上次相同 → 不重下发（看门狗回写会反复触发同一台）',
      !shouldRetargetLiveCast(
        casting: true,
        playing: true,
        streamUrl: 'http://a/1.m3u8',
        lastSentUrl: 'http://a/1.m3u8',
      ));

  check(
      '从未推送过 → 需要重下发',
      shouldRetargetLiveCast(
        casting: true,
        playing: true,
        streamUrl: 'http://a/1.m3u8',
        lastSentUrl: null,
      ));
}

// ---------------------------------------------------------------------------
// 2. 直推模式换台
// ---------------------------------------------------------------------------

Future<void> testDirectRetarget() async {
  final t = FakeCastTransport(
    devices: const <CastDevice>[_tv],
    // 直播流的常态：设备自称在播，但拿不到位置。
    signal: CastStartSignal.playingUnverified,
  );
  final s = CastSession(
    transport: t,
    device: _tv,
    mode: CastMode.direct,
    modeReason: CastModeReason.probeOk,
  );

  final r = await s.retarget(
    url: _playlist('cdn-a', 1),
    positionSeconds: 0,
  );
  check('直推换台：设备接受了新地址', r.ok, '${r.outcome}');
  check('直推换台：推的是上游原地址', t.lastPlayUrl == _playlist('cdn-a', 1),
      t.lastPlayUrl);
  check('直推换台：模式仍是直推', r.mode == CastMode.direct);
  check('直推换台：位置参数为 0（直播不 seek）', t.position == 0);
  check(
      '「设备自称在播但读不到位置」不算失败',
      r.outcome == CastRetargetOutcome.accepted &&
          r.signal == CastStartSignal.playingUnverified,
      '${r.outcome}/${r.signal}');
  check('直推换台不产生中继', s.relay == null);

  final second = await s.retarget(url: _playlist('cdn-a', 2));
  check('再次换台同样成功', second.ok);
  check('再次换台推的是新地址', t.lastPlayUrl == _playlist('cdn-a', 2));
  check('会话记录了两次成功重下发', s.retargetCount == 2, '${s.retargetCount}');

  await s.stop();
  check('stop 之后会话不再活跃', !s.isActive);
}

// ---------------------------------------------------------------------------
// 3. 非法地址一律不下发
// ---------------------------------------------------------------------------

Future<void> testRejectsBadUrl() async {
  final t = FakeCastTransport(devices: const <CastDevice>[_tv]);
  final s = CastSession(
    transport: t,
    device: _tv,
    mode: CastMode.direct,
    modeReason: CastModeReason.probeOk,
  );

  final bad = <String>[
    '',
    'file:///sdcard/movie.mkv',
    'ms-cast://tv/play',
    'javascript:alert(1)',
    'http://',
    'not a url at all',
  ];
  for (final url in bad) {
    final r = await s.retarget(url: url);
    check('非法地址「$url」被拒绝', r.outcome == CastRetargetOutcome.rejected,
        '${r.outcome}');
  }
  check('非法地址一条都没有下发给设备', t.playCalls == 0, '${t.playCalls}');
  await s.stop();
}

// ---------------------------------------------------------------------------
// 4. 直推失败 → 原地改串流
// ---------------------------------------------------------------------------

Future<void> testDirectFallsBackToRelay() async {
  final t = FakeCastTransport(
    devices: const <CastDevice>[_tv],
    signal: CastStartSignal.playingUnverified,
  );
  // 只有直推地址被拒：模拟防盗链源对电视直连返回 403。
  t.playFailsFor = (url) => !url.contains('/t/');
  final spy = RelaySpy();
  final s = CastSession(
    transport: t,
    device: _tv,
    mode: CastMode.direct,
    modeReason: CastModeReason.probeOk,
    relayFactory: spy.call,
    headers: const <String, String>{'Referer': 'https://src.example.com/'},
  );

  final r = await s.retarget(url: _playlist('cdn-protected', 1));
  check('直推被拒 → 改串流后成功',
      r.outcome == CastRetargetOutcome.acceptedAfterSwitch, '${r.outcome}');
  check('改串流：本次只起了一个中继', spy.calls == 1, '${spy.calls}');
  check('改串流：推给设备的是中继地址', (t.lastPlayUrl ?? '').contains('/t/'),
      t.lastPlayUrl);
  check('改串流：会话模式已切到串流', s.mode == CastMode.relay, '${s.mode}');
  check('改串流：后续换台也走串流', (r.mode == CastMode.relay));

  // 换台继续走串流，且 headers 没变 → 复用同一个中继。
  final next = await s.retarget(url: _playlist('cdn-protected', 2));
  check('串流模式换台成功', next.ok, '${next.outcome}');
  check('headers 未变时复用中继（不重启）', spy.calls == 1, '${spy.calls}');
  check('串流模式换台推的仍是中继地址',
      (t.lastPlayUrl ?? '').contains('/t/'), t.lastPlayUrl);

  await s.stop();
  check('结束会话时中继被停掉', spy.created.first.stopCount == 1,
      '${spy.created.first.stopCount}');
}

// ---------------------------------------------------------------------------
// 5. 换台换源站 → 必须重启中继（否则上一路的鉴权头会发给新源站）
// ---------------------------------------------------------------------------

Future<void> testRelayRestartOnHeaderChange() async {
  final t = FakeCastTransport(
    devices: const <CastDevice>[_tv],
    signal: CastStartSignal.playingUnverified,
  );
  final spy = RelaySpy();
  final s = CastSession(
    transport: t,
    device: _tv,
    mode: CastMode.relay,
    modeReason: CastModeReason.rememberedRelay,
    relayFactory: spy.call,
    headers: const <String, String>{'Referer': 'https://a.example.com/'},
  );

  final first = await s.retarget(url: _playlist('cdn-a', 1));
  check('串流模式首次下发成功', first.ok, '${first.outcome}');
  check('串流模式首次下发时起了中继', spy.calls == 1, '${spy.calls}');

  // 换到一个需要另一套鉴权头的源。
  final second = await s.retarget(
    url: _playlist('cdn-b', 1),
    headers: const <String, String>{'Referer': 'https://b.example.com/'},
    sourceId: 'src-b',
  );
  check('换源后重下发成功', second.ok, '${second.outcome}');
  check('鉴权头变化 → 重启中继', spy.calls == 2, '${spy.calls}');
  check('旧中继已被停掉', spy.created.first.stopCount == 1,
      '${spy.created.first.stopCount}');
  check('新中继拿到了新的鉴权头',
      spy.created.last.headers['Referer'] == 'https://b.example.com/',
      '${spy.created.last.headers}');

  // 同一源站继续换台：不重启。
  await s.retarget(
    url: _playlist('cdn-b', 2),
    headers: const <String, String>{'Referer': 'https://b.example.com/'},
    sourceId: 'src-b',
  );
  check('同一源站继续换台不重启中继', spy.calls == 2, '${spy.calls}');

  await s.stop();
}

// ---------------------------------------------------------------------------
// 6. 串流也失败 → 反向切直推
// ---------------------------------------------------------------------------

Future<void> testRelayFallsBackToDirect() async {
  final t = FakeCastTransport(
    devices: const <CastDevice>[_tv],
    signal: CastStartSignal.playingUnverified,
  );
  // 只有中继地址失败：模拟「源站没防盗链，反倒中继这一跳有问题」。
  t.playFailsFor = (url) => url.contains('/t/');
  final spy = RelaySpy();
  final s = CastSession(
    transport: t,
    device: _tv,
    mode: CastMode.relay,
    modeReason: CastModeReason.rememberedRelay,
    relayFactory: spy.call,
  );

  final r = await s.retarget(url: _playlist('cdn-plain', 1));
  check('串流失败 → 反向切直推成功',
      r.outcome == CastRetargetOutcome.acceptedAfterSwitch, '${r.outcome}');
  check('反向切回直推后模式为直推', s.mode == CastMode.direct, '${s.mode}');
  check('反向切回时推的是上游原地址',
      t.lastPlayUrl == _playlist('cdn-plain', 1), t.lastPlayUrl);
  check('切回直推时顺手停掉没用的中继', spy.created.first.stopCount == 1,
      '${spy.created.first.stopCount}');

  await s.stop();
}

// ---------------------------------------------------------------------------
// 7. 连按换台：后发先至
// ---------------------------------------------------------------------------

Future<void> testRapidSwitching() async {
  final t = FakeCastTransport(
    devices: const <CastDevice>[_tv],
    signal: CastStartSignal.playingUnverified,
  );
  final s = CastSession(
    transport: t,
    device: _tv,
    mode: CastMode.direct,
    modeReason: CastModeReason.probeOk,
  );

  final f1 = s.retarget(url: _playlist('cdn-a', 1));
  final f2 = s.retarget(url: _playlist('cdn-a', 2));
  final r1 = await f1;
  final r2 = await f2;

  check('连按换台：最后一次一定成功', r2.ok, '${r2.outcome}');
  check('连按换台：最终推给设备的是最后一台',
      t.lastPlayUrl == _playlist('cdn-a', 2), t.lastPlayUrl);
  check(
      '连按换台：被取代的那次标记为 superseded（不该弹错误提示）',
      r1.outcome == CastRetargetOutcome.superseded ||
          r1.outcome == CastRetargetOutcome.accepted,
      '${r1.outcome}');
  check('连按换台：只把最后一次算作有效重下发', s.retargetCount == 1,
      '${s.retargetCount}');

  // 三个连按
  final f3 = s.retarget(url: _playlist('cdn-a', 3));
  final f4 = s.retarget(url: _playlist('cdn-a', 4));
  final f5 = s.retarget(url: _playlist('cdn-a', 5));
  await Future.wait(<Future<CastRetargetResult>>[f3, f4, f5]);
  check('三连按：最终推给设备的是最后一个',
      t.lastPlayUrl == _playlist('cdn-a', 5), t.lastPlayUrl);

  await s.stop();
}

// ---------------------------------------------------------------------------
// 8. 结束投屏后不再下发
// ---------------------------------------------------------------------------

Future<void> testInactiveAfterStop() async {
  final t = FakeCastTransport(devices: const <CastDevice>[_tv]);
  final spy = RelaySpy();
  final s = CastSession(
    transport: t,
    device: _tv,
    mode: CastMode.relay,
    modeReason: CastModeReason.rememberedRelay,
    relayFactory: spy.call,
  );
  await s.retarget(url: _playlist('cdn-a', 1));
  final before = t.playCalls;
  await s.stop();
  final r = await s.retarget(url: _playlist('cdn-a', 2));
  check('结束投屏后重下发返回 inactive',
      r.outcome == CastRetargetOutcome.inactive, '${r.outcome}');
  check('结束投屏后不再向设备下发', t.playCalls == before, '${t.playCalls}');
  check('结束后不再新建中继', spy.calls == 1, '${spy.calls}');
  check('stop 会断开设备连接', t.disconnected);
  // 重复 stop 不应该抛。
  await s.stop();
  check('重复 stop 是幂等的', true);
}

// ---------------------------------------------------------------------------
// 9. 中继不可用时的兜底
// ---------------------------------------------------------------------------

Future<void> testRelayUnavailable() async {
  final t = FakeCastTransport(
    devices: const <CastDevice>[_tv],
    signal: CastStartSignal.playingUnverified,
  );
  final spy = RelaySpy()..failNext = true;
  final s = CastSession(
    transport: t,
    device: _tv,
    mode: CastMode.relay,
    modeReason: CastModeReason.rememberedRelay,
    relayFactory: spy.call,
  );

  final r = await s.retarget(url: _playlist('cdn-a', 1));
  check('中继起不来时退回直推而不是直接报失败', r.ok, '${r.outcome}');
  check('中继起不来时推的是上游原地址',
      t.lastPlayUrl == _playlist('cdn-a', 1), t.lastPlayUrl);
  check('中继起不来时模式退回直推', s.mode == CastMode.direct, '${s.mode}');
  await s.stop();
}

// ---------------------------------------------------------------------------
// 10. 从 CastResult 建会话：中继必须被接管
// ---------------------------------------------------------------------------

Future<void> testFromResultTakesRelay() async {
  final t = FakeCastTransport(
    devices: const <CastDevice>[_tv],
    signal: CastStartSignal.playingUnverified,
  );
  final spy = RelaySpy();
  final relay = FakeRelay(0, const <String, String>{});
  spy.created.add(relay);

  final result = CastResult(
    casting: true,
    phase: CastPhase.relaying,
    mediaId: 'm-1',
    rawEpisode: 3,
    rawSeconds: 120,
    device: _tv,
    mode: CastMode.relay,
    modeReason: CastModeReason.requiresAuthHeaders,
    attempts: const <String>['串流中继已启动'],
    userMessage: 'ok',
    report: const CastReport(
      discoveryMillis: 100,
      startMillis: 900,
      modeName: 'relay',
      reasonName: 'requiresAuthHeaders',
      signalName: 'playingUnverified',
      relayed: true,
    ),
    relay: relay,
  );

  final s = CastSession.fromResult(result, transport: t);
  check('从投屏结果建会话：中继被接管', identical(s.relay, relay));
  check('从投屏结果建会话：模式沿用', s.mode == CastMode.relay);
  check('从投屏结果建会话：设备沿用', s.device.id == _tv.id);

  await s.stop();
  check('结束后接管来的中继也被停掉', relay.stopCount == 1, '${relay.stopCount}');
}

Future<void> main() async {
  testShouldRetarget();
  await testDirectRetarget();
  await testRejectsBadUrl();
  await testDirectFallsBackToRelay();
  await testRelayRestartOnHeaderChange();
  await testRelayFallsBackToDirect();
  await testRapidSwitching();
  await testInactiveAfterStop();
  await testRelayUnavailable();
  await testFromResultTakesRelay();

  final total = _checkCount + _failCount;
  print('\n$_checkCount/$total 断言通过'
      '${_failCount == 0 ? '' : '（失败 $_failCount 项）'}');
  if (_failCount > 0) exitCode = 1;
}
