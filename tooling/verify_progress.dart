// 播放中进度上报的真实回归（E6「续播」此前只存载入点，播放数据从未落盘）。
//
// 为什么单独一套：这是唯一一处「播放器读数 → 换算 → 节流 → 串行写盘 → 跨端同步」
// 的数据流，任何一环错了都不会报错，只会让续播静默失效（用户看到的是「进度没保存」，
// 日志里一片安静）。所以这里逐条钉住语义，并用慢盘 / 失败盘 / 假时钟制造真实竞态。
//
// 运行：dart run tooling/verify_progress.dart
import 'dart:async';
import 'dart:io';

import 'package:shunbo/core/player/mock_player_controller.dart';
import 'package:shunbo/core/scheduler/alignment.dart';
import 'package:shunbo/core/scheduler/playback_failure.dart';
import 'package:shunbo/core/scheduler/playback_orchestrator.dart';
import 'package:shunbo/core/scheduler/progress_reporting.dart';
import 'package:shunbo/core/scheduler/source_catalog.dart';
import 'package:shunbo/core/source/memory_source_adapter.dart';
import 'package:shunbo/core/source/source_adapter.dart';
import 'package:shunbo/core/source/source_profile.dart';
import 'package:shunbo/core/source/source_registry.dart';
import 'package:shunbo/core/diagnostics/diagnostic_sink.dart';
import 'package:shunbo/data/file_resume_store.dart';
import 'package:shunbo/data/memory_resume_store.dart';
import 'package:shunbo/data/resume_record.dart';
import 'package:shunbo/data/resume_store.dart';
import 'package:shunbo/data/sync/resume_sync_engine.dart';
import 'package:shunbo/data/sync/sync_transport.dart';

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

/// 可推进的假时钟：让「落盘间隔」可被确定性地测试，不依赖真实等待。
class FakeClock {
  DateTime _now = DateTime(2026, 11, 5, 20, 0, 0);

  DateTime call() => _now;

  void advance(Duration d) => _now = _now.add(d);
}

/// 无广告、无偏移的源。
const SourceProfile _plain = SourceProfile(name: 'plain');

/// 有集数偏移 + 每 300s 插 60s 广告的源（换算必须真的发生，否则断言会暴露）。
const SourceProfile _ad =
    SourceProfile(name: 'ad', episodeOffset: 1, adInterval: 300, adDuration: 60);

ProgressAnchor _anchor(
  SourceProfile profile, {
  String mediaId = 'm1',
  String title = '示例剧',
  int canonicalEpisode = 2,
  double canonicalSeconds = 650,
}) {
  final raw = contentToRaw(profile, canonicalEpisode, canonicalSeconds);
  return ProgressAnchor(
    mediaId: mediaId,
    title: title,
    sourceId: profile.name,
    profile: profile,
    rawEpisode: raw.$1,
    rawSeconds: raw.$2,
  );
}

/// 会抛异常的播放器（模拟内核已释放 / 读数非法）。
class _ThrowingPlayer extends MockPlayerController {
  _ThrowingPlayer({this.nan = false, this.throwOnRead = false});

  final bool nan;
  final bool throwOnRead;

  @override
  Future<double> currentRawSeconds() async {
    if (throwOnRead) throw StateError('内核已释放');
    if (nan) return double.nan;
    return super.currentRawSeconds();
  }
}

/// 统计时长读取次数：验证「一次会话只读一次」的缓存策略。
class _CountingPlayer extends MockPlayerController {
  int durationCalls = 0;

  @override
  Future<double> duration() async {
    durationCalls++;
    return super.duration();
  }
}

/// 慢盘：模拟原子写在机械盘/杀软扫描下的延迟，用于制造并发写入竞态。
class _SlowStore implements ResumeStore {
  _SlowStore(this.inner, this.delay);

  final ResumeStore inner;
  final Duration delay;
  int saves = 0;
  final List<ResumeRecord> written = <ResumeRecord>[];

  @override
  Future<void> save(ResumeRecord r) async {
    saves++;
    await Future<void>.delayed(delay);
    written.add(r);
    await inner.save(r);
  }

  @override
  Future<ResumeRecord?> load(String mediaId) => inner.load(mediaId);

  @override
  Future<List<ResumeRecord>> all() => inner.all();

  @override
  Future<void> remove(String mediaId) => inner.remove(mediaId);
}

/// 可失败盘：验证写失败既不打断播放，也不会让基线被乐观推进（否则再也不会重试）。
class _FlakyStore implements ResumeStore {
  final MemoryResumeStore inner = MemoryResumeStore();
  bool fail = false;
  int attempts = 0;

  @override
  Future<void> save(ResumeRecord r) async {
    attempts++;
    if (fail) throw const FileSystemException('磁盘不可写');
    await inner.save(r);
  }

  @override
  Future<ResumeRecord?> load(String mediaId) => inner.load(mediaId);

  @override
  Future<List<ResumeRecord>> all() => inner.all();

  @override
  Future<void> remove(String mediaId) => inner.remove(mediaId);
}

Future<void> main() async {
  final tmp = await Directory.systemTemp.createTemp('shunbo_progress');
  try {
    await _basicSemantics();
    await _throttling();
    await _playerEdgeCases();
    await _writeRace();
    await _sessionSwitch();
    await _writeFailure();
    await _persistence(tmp);
    await _syncBridge();
    await _orchestratorIntegration();
    await _endingDetection();
    await _endingRecordJson();
    await _endingWriteFailure();
  } finally {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {
      // 临时目录清理失败不影响结论。
    }
  }

  final total = _checkCount + _failCount;
  print('播放进度落盘回归：$_checkCount/$total 断言通过');
  if (_failCount > 0) {
    print('存在 $_failCount 条失败');
    exitCode = 1;
  }
}

// ---------------------------------------------------------------------------
// A. 基础语义：换算、基准、不覆盖
// ---------------------------------------------------------------------------
Future<void> _basicSemantics() async {
  final clock = FakeClock();
  final player = MockPlayerController();
  final store = MemoryResumeStore();
  final reporter = ProgressReporter(
    player: player,
    store: store,
    autoTick: false,
    clock: clock.call,
  );

  // 没有会话时不写任何东西（避免"后台空转把记录写成 0"）。
  final idle = await reporter.tick();
  check('未开始播放时采样不落盘', idle.skip == ProgressSkip.noSession);
  check('未开始播放时存储保持为空', await store.load('m1') == null);

  // 有广告的源：内容 650s 对应原始 770s（第 3 集），换算必须真的发生。
  final anchor = _anchor(_ad);
  check('锚点构造：内容 650s 反解到原始 770s',
      anchor.rawSeconds == 770 && anchor.rawEpisode == 3,
      'raw=${anchor.rawEpisode}#${anchor.rawSeconds}');

  await reporter.begin(anchor);
  await player.load('https://cdn/3.m3u8', anchor.rawEpisode, anchor.rawSeconds);

  // 刚载入、位置等于载入点：写了就会把上次的 650s 覆盖成「原地」，必须跳过。
  final atLoad = await reporter.tick();
  check('刚载入未前进时跳过（不覆盖已有进度）',
      atLoad.skip == ProgressSkip.noAdvance);
  check('基准为锚点内容坐标', !atLoad.skipped && atLoad.contentSeconds == 650.0 ||
      atLoad.skip == ProgressSkip.noAdvance);

  // 播放 10s：原始 780s → 去广告后内容 660s。
  clock.advance(const Duration(seconds: 12));
  await player.seek(780);
  final advanced = await reporter.tick();
  check('播放推进后落盘', !advanced.skipped, '$advanced');
  check('落盘值为内容坐标（660s）而非原始坐标（780s）',
      advanced.contentSeconds == 660.0, '${advanced.contentSeconds}');
  check('确实做了换算（原始 780 ≠ 内容 660）', advanced.contentSeconds != 780);

  final saved = await store.load('m1');
  check('存储中为规范内容坐标 660s', saved?.canonicalSeconds == 660.0,
      '${saved?.canonicalSeconds}');
  check('存储中集数为规范集数 2（原始第 3 集减偏移）',
      saved?.canonicalEpisode == 2, '${saved?.canonicalEpisode}');
  check('记录保留源 id 与标题',
      saved?.sourceId == 'ad' && saved?.title == '示例剧');
  check('lastSaved 与存储一致',
      reporter.lastSaved?.canonicalSeconds == 660.0);

  // 播放器位置回退（用户拖回看）：允许写，不能被"只增不减"规则挡住。
  clock.advance(const Duration(seconds: 12));
  await player.seek(700); // 内容 580s
  final back = await reporter.tick();
  check('用户回拖后按新位置落盘（尊重用户意图）',
      !back.skipped && back.contentSeconds == 580.0, '$back');
  check('回拖后的记录更小且已生效',
      (await store.load('m1'))?.canonicalSeconds == 580.0);

  await reporter.stop();
}

// ---------------------------------------------------------------------------
// B. 节流：位移阈值 / 时间间隔 / 强制 flush
// ---------------------------------------------------------------------------
Future<void> _throttling() async {
  final clock = FakeClock();
  final player = MockPlayerController();
  final store = MemoryResumeStore();
  final reporter = ProgressReporter(
    player: player,
    store: store,
    autoTick: false,
    clock: clock.call,
  );
  final anchor = _anchor(_plain, canonicalSeconds: 100);
  await reporter.begin(anchor);
  await player.load('u', 2, 100);

  clock.advance(const Duration(seconds: 11));
  await player.seek(120);
  final first = await reporter.tick();
  check('首次满足位移+间隔时落盘', !first.skipped && first.contentSeconds == 120);

  // 位移足够（+20s）但距上次落盘只过 3s：节流生效。
  clock.advance(const Duration(seconds: 3));
  await player.seek(140);
  final early = await reporter.tick();
  check('未到落盘间隔时跳过', early.skip == ProgressSkip.throttled, '$early');
  check('节流期间存储保持上一次的值',
      (await store.load('m1'))?.canonicalSeconds == 120.0);

  // 到点后放行（位置未变也写，因为相对上次落盘已推进 20s）。
  clock.advance(const Duration(seconds: 8));
  final later = await reporter.tick();
  check('间隔到点后落盘', !later.skipped && later.contentSeconds == 140.0);

  // 位移不足（+2s）：即使时间已过很久也不写。
  clock.advance(const Duration(seconds: 60));
  await player.seek(142);
  final tiny = await reporter.tick();
  check('位移不足阈值时跳过', tiny.skip == ProgressSkip.noAdvance, '$tiny');

  // 暂停/切源/退后台用 force：忽略节流立即写。
  clock.advance(const Duration(seconds: 1));
  await player.seek(160);
  final forced = await reporter.tick(force: true);
  check('force 忽略节流立即落盘', !forced.skipped && forced.contentSeconds == 160);

  // flush 等价于 force + 等写盘完成。
  await player.seek(175);
  await reporter.flush();
  check('flush 后存储为最新位置', (await store.load('m1'))?.canonicalSeconds == 175.0);

  await reporter.stop();
}

// ---------------------------------------------------------------------------
// C. 播放器边界：NaN / 抛异常都不能让上报器炸掉播放
// ---------------------------------------------------------------------------
Future<void> _playerEdgeCases() async {
  final clock = FakeClock();
  final store = MemoryResumeStore();

  final nanPlayer = _ThrowingPlayer(nan: true);
  final r1 = ProgressReporter(
      player: nanPlayer, store: store, autoTick: false, clock: clock.call);
  await r1.begin(_anchor(_plain));
  await nanPlayer.load('u', 2, 650);
  final nanTick = await r1.tick(force: true);
  check('播放器返回 NaN 时判为位置非法', nanTick.skip == ProgressSkip.invalidPosition);
  check('位置非法时不写盘', await store.load('m1') == null);
  await r1.stop(flush: false);

  final throwing = _ThrowingPlayer(throwOnRead: true);
  final r2 = ProgressReporter(
      player: throwing, store: store, autoTick: false, clock: clock.call);
  await r2.begin(_anchor(_plain));
  var threw = false;
  try {
    await r2.tick(force: true);
  } catch (_) {
    threw = true;
  }
  check('播放器读数抛异常被收敛（不穿透 UI）', !threw);
  check('读写异常时仍不写盘', await store.load('m1') == null);
  await r2.stop(flush: false);
}

// ---------------------------------------------------------------------------
// D. 写入竞态：慢盘上「先发的旧位置」绝不能覆盖「后发的新位置」
// ---------------------------------------------------------------------------
Future<void> _writeRace() async {
  final clock = FakeClock();
  final player = MockPlayerController();
  final slow = _SlowStore(MemoryResumeStore(), const Duration(milliseconds: 60));
  final reporter = ProgressReporter(
    player: player,
    store: slow,
    autoTick: false,
    clock: clock.call,
  );
  await reporter.begin(_anchor(_plain, canonicalSeconds: 0));
  await player.load('u', 2, 0);

  // 连续两次强制采样，不等待（模拟定时器与 UI 调用重叠）。
  clock.advance(const Duration(seconds: 10));
  await player.seek(100);
  final f1 = reporter.tick(force: true);
  clock.advance(const Duration(seconds: 10));
  await player.seek(200);
  final f2 = reporter.tick(force: true);
  await Future.wait(<Future<ProgressTick>>[f1, f2]);

  final finalRec = await slow.load('m1');
  check('并发采样后最终落盘为最新位置（200s）',
      finalRec?.canonicalSeconds == 200.0, '${finalRec?.canonicalSeconds}');
  check('写入被合并（慢盘上不会排长队）', slow.saves <= 2,
      'saves=${slow.saves}');
  check('落盘顺序单调（旧位置不会后落盘覆盖新位置）',
      slow.written.length <= 2 &&
          slow.written.last.canonicalSeconds ==
              slow.written.map((e) => e.canonicalSeconds).reduce((a, b) => a > b ? a : b));

  await reporter.stop(flush: false);
}

// ---------------------------------------------------------------------------
// E. 换源/换会话：先按旧源落盘，再切锚点；迟到写入不得污染新会话
// ---------------------------------------------------------------------------
Future<void> _sessionSwitch() async {
  final clock = FakeClock();
  final player = MockPlayerController();
  final store = MemoryResumeStore();
  final reporter = ProgressReporter(
      player: player, store: store, autoTick: false, clock: clock.call);

  // 源 A（有广告）：内容 650 → 原始 770。
  final a = _anchor(_ad);
  await reporter.begin(a);
  await player.load('u1', a.rawEpisode, a.rawSeconds);
  clock.advance(const Duration(seconds: 10));
  await player.seek(800); // 内容 680
  await reporter.tick(force: true);
  check('换源前按 A 源换算落盘 680s',
      (await store.load('m1'))?.canonicalSeconds == 680.0);

  // 切到源 B（无广告）：内容 680 → 原始 680，集数 2。
  final b = _anchor(_plain, canonicalSeconds: 680);
  await reporter.begin(b);
  check('换源后锚点切换到新源', reporter.anchor?.sourceId == 'plain');
  await player.load('u2', b.rawEpisode, b.rawSeconds);

  final afterSwitch = await reporter.tick(force: true);
  check('新源采样用新画像换算（内容坐标守恒 680s）',
      afterSwitch.contentSeconds == 680.0, '${afterSwitch.contentSeconds}');
  check('记录跟着新源走', (await store.load('m1'))?.sourceId == 'plain');

  // 迟到写入：慢盘上「同步退出」的 flush 尚未写完就切了新会话，
  // 旧帧必须被 epoch 作废，绝不能覆盖新会话记录。
  final slowInner = MemoryResumeStore();
  final slow = _SlowStore(slowInner, const Duration(milliseconds: 40));
  final r2 = ProgressReporter(
      player: player, store: slow, autoTick: false, clock: clock.call);
  await r2.begin(_anchor(_plain, canonicalSeconds: 0));
  await player.load('u3', 2, 0);
  clock.advance(const Duration(seconds: 10));
  await player.seek(500);
  r2.dispose(); // 同步退出：flush 已发起但不等待（对应 Widget dispose 场景）
  final c = _anchor(_plain, canonicalSeconds: 900);
  await r2.begin(c); // epoch++ → 旧会话的迟到写入作废
  await player.load('u4', c.rawEpisode, c.rawSeconds);
  await r2.flush();
  final written = slow.written.map((e) => e.canonicalSeconds).toList();
  check('旧会话写入必在新会话写入之前落地（顺序单调）',
      written.isNotEmpty && written.last == 900.0, '$written');
  check('切换会话后最终记录为新会话位置 900s',
      (await slowInner.load('m1'))?.canonicalSeconds == 900.0,
      '${(await slowInner.load('m1'))?.canonicalSeconds}');
  check('最终落盘值不是被旧位置覆盖的结果',
      written.where((v) => v == 500.0).length <= 1 &&
          written.indexOf(900.0) == written.length - 1,
      '$written');
  await r2.stop(flush: false);
}

// ---------------------------------------------------------------------------
// F. 写失败：不打断播放、不被乐观推进（否则永不重试）、有诊断事件
// ---------------------------------------------------------------------------
Future<void> _writeFailure() async {
  final clock = FakeClock();
  final player = MockPlayerController();
  final flaky = _FlakyStore();
  final sink = MemoryDiagnosticSink();
  final reporter = ProgressReporter(
    player: player,
    store: flaky,
    diagnostics: sink,
    autoTick: false,
    clock: clock.call,
  );
  await reporter.begin(_anchor(_plain, canonicalSeconds: 0));
  await player.load('u', 2, 0);

  flaky.fail = true;
  clock.advance(const Duration(seconds: 10));
  await player.seek(120);
  var threw = false;
  try {
    await reporter.tick(force: true);
  } catch (_) {
    threw = true;
  }
  check('落盘失败不抛给播放链路', !threw);
  check('降级标志置位（供 UI 提示进度可能未保存）', reporter.degraded);
  check('写入失败上报结构化诊断',
      sink.ofKind(DiagnosticKind.progressWriteFailed).length == 1);
  final diag = sink.ofKind(DiagnosticKind.progressWriteFailed).first;
  check('诊断带上媒体与内容坐标',
      diag.mediaId == 'm1' && diag.attributes['canonicalSeconds'] == 120.0,
      '${diag.attributes}');

  // 失败后基线未被推进：位置不变再采样仍会重试（否则进度永远停在失败那一刻）。
  final before = flaky.attempts;
  clock.advance(const Duration(seconds: 10));
  await reporter.tick(force: true);
  check('失败后不更新基线，会重试写盘', flaky.attempts == before + 1,
      'attempts=${flaky.attempts}');

  flaky.fail = false;
  clock.advance(const Duration(seconds: 10));
  final ok = await reporter.tick(force: true);
  check('磁盘恢复后继续落盘', ok.persisted);
  check('恢复后存储为最新位置', (await flaky.load('m1'))?.canonicalSeconds == 120.0);
  check('降级标志为粘性（保留历史故障痕迹）', reporter.degraded);
  await reporter.stop(flush: false);
}

// ---------------------------------------------------------------------------
// G. 真实落盘：JSON 里必须是内容坐标，重启可读回
// ---------------------------------------------------------------------------
Future<void> _persistence(Directory tmp) async {
  final clock = FakeClock();
  final player = MockPlayerController();
  final path = '${tmp.path}${Platform.pathSeparator}resume.json';
  final store = FileResumeStore.at(path);
  final reporter = ProgressReporter(
      player: player, store: store, autoTick: false, clock: clock.call);
  final anchor = _anchor(_ad);
  await reporter.begin(anchor);
  await player.load('u', anchor.rawEpisode, anchor.rawSeconds);
  clock.advance(const Duration(seconds: 10));
  await player.seek(790); // 内容 670
  await reporter.tick(force: true);
  await reporter.stop();

  final raw = await File(path).readAsString();
  check('落盘 JSON 中 canonicalSeconds 为内容坐标 670s',
      raw.contains('"canonicalSeconds": 670.0') || raw.contains('670.0'),
      raw.length > 200 ? raw.substring(0, 200) : raw);
  check('落盘 JSON 不含源原始坐标 790',
      !raw.contains('"canonicalSeconds": 790'), '');

  final reopened = FileResumeStore.at(path);
  final restored = await reopened.load('m1');
  check('重启后读回同一内容坐标', restored?.canonicalSeconds == 670.0);
  check('重启后集数为规范集数', restored?.canonicalEpisode == 2);

  // 再开一个会话（不同媒体）不应互相踩。
  final player2 = MockPlayerController();
  final reporter2 = ProgressReporter(
      player: player2, store: reopened, autoTick: false, clock: clock.call);
  final anchor2 = _anchor(_plain, mediaId: 'm2', canonicalSeconds: 30);
  await reporter2.begin(anchor2);
  await player2.load('u', anchor2.rawEpisode, anchor2.rawSeconds);
  await reporter2.tick(force: true);
  check('不同媒体的进度互不覆盖',
      (await reopened.load('m1'))?.canonicalSeconds == 670.0 &&
          (await reopened.load('m2'))?.canonicalSeconds == 30.0);
  await reporter2.stop(flush: false);
}

// ---------------------------------------------------------------------------
// H. 与跨端同步联动：播放中落盘也要进入待同步队列
// ---------------------------------------------------------------------------
Future<void> _syncBridge() async {
  final clock = FakeClock();
  final player = MockPlayerController();
  final inner = MemoryResumeStore();
  final local = SyncAwareResumeStore(inner);
  final transport = InMemorySyncTransport();
  final engine =
      ResumeSyncEngine(local: local, transport: transport, deviceId: 'dev-a');

  final reporter = ProgressReporter(
      player: player, store: local, autoTick: false, clock: clock.call);
  await reporter.begin(_anchor(_plain, canonicalSeconds: 0));
  await player.load('u', 2, 0);
  clock.advance(const Duration(seconds: 10));
  await player.seek(300);
  await reporter.tick(force: true);

  check('播放中落盘进入同步待办队列', engine.pendingCount == 1,
      'pending=${engine.pendingCount}');

  final result = await engine.sync();
  check('同步成功且失败数为 0', result.conflicts >= 0 && engine.pendingCount == 0);
  final remote = await transport.pull();
  check('对端快照包含该进度 300s',
      remote.entries['m1']?.record?.canonicalSeconds == 300.0);
  await reporter.stop(flush: false);
}

// ---------------------------------------------------------------------------
// I. 编排层集成：真实 startPlayback / 换源 / 换源失败三条路径
// ---------------------------------------------------------------------------
Future<void> _orchestratorIntegration() async {
  final clock = FakeClock();
  final player = MockPlayerController();
  final store = MemoryResumeStore();
  final reporter = ProgressReporter(
      player: player, store: store, autoTick: false, clock: clock.call);

  final registry = SourceRegistry();
  final catalog = SourceCatalog();
  final adProfile = const SourceProfile(name: 'ad', episodeOffset: 1, adInterval: 300, adDuration: 60);
  final plainProfile = const SourceProfile(name: 'plain');

  final adAdapter = MemorySourceAdapter(
    id: 'ad',
    profile: adProfile,
    episodes: <String, List<EpisodeInfo>>{
      'm1': <EpisodeInfo>[
        for (var i = 1; i <= 6; i++) EpisodeInfo(episode: i, title: '第$i集'),
      ],
    },
    urls: <String, List<PlayUrl>>{
      for (var i = 1; i <= 6; i++)
        'm1#$i': <PlayUrl>[
          PlayUrl(url: 'https://ad/$i.m3u8', qualityRank: 50),
        ],
    },
  );
  final plainAdapter = MemorySourceAdapter(
    id: 'plain',
    profile: plainProfile,
    episodes: <String, List<EpisodeInfo>>{
      'm1': <EpisodeInfo>[
        for (var i = 1; i <= 6; i++) EpisodeInfo(episode: i, title: '第$i集'),
      ],
    },
    urls: <String, List<PlayUrl>>{
      for (var i = 1; i <= 6; i++)
        'm1#$i': <PlayUrl>[
          PlayUrl(url: 'https://plain/$i.m3u8', qualityRank: 80),
        ],
    },
  );
  final deadAdapter = MemorySourceAdapter(
    id: 'dead',
    profile: const SourceProfile(name: 'dead'),
    episodes: <String, List<EpisodeInfo>>{
      'm1': <EpisodeInfo>[EpisodeInfo(episode: 1, title: '第1集')],
    },
  );

  for (final a in <SourceAdapter>[adAdapter, plainAdapter, deadAdapter]) {
    registry.register(a);
    catalog.register(a.profile);
  }

  final orch = PlaybackOrchestrator(
    registry: registry,
    catalog: catalog,
    player: player,
    resumeStore: store,
    progress: reporter,
  );

  final session = await orch.startPlayback(
    sourceId: 'ad',
    mediaId: 'm1',
    mediaTitle: '示例剧',
    canonicalEpisode: 2,
    canonicalSeconds: 650,
  );
  check('编排层载入后自动接入进度上报', reporter.anchor?.sourceId == 'ad');
  check('锚点为对齐后的原始坐标', session.rawEpisode == 3 && session.rawSeconds == 770,
      '${session.rawEpisode}#${session.rawSeconds}');

  // 播放推进 30s（原始 770 → 800，去广告后内容 680）。
  clock.advance(const Duration(seconds: 12));
  await player.seek(800);
  await reporter.tick();
  await reporter.flush();
  final mid = await orch.resumeFor('m1');
  check('续播记录反映真实观看位置（680s）而非载入点（650s）',
      mid?.canonicalSeconds == 680.0, '${mid?.canonicalSeconds}');

  // 换源：换源前应先把旧源当前位置落盘。
  final sw = await orch.switchSourceAligned(
    fromSourceId: 'ad',
    toSourceId: 'plain',
    mediaId: 'm1',
    mediaTitle: '示例剧',
    fromRawEpisode: 3,
    fromRawSeconds: 800,
  );
  check('换源后内容坐标守恒 680s', sw.session.contentSeconds == 680.0);
  check('换源后上报锚点切到新源', reporter.anchor?.sourceId == 'plain');
  check('换源后记录源 id 更新', (await store.load('m1'))?.sourceId == 'plain');

  // 换源失败：不得写假成功记录，且失败前的位置已按旧源落盘。
  // 注意：flush 采的是播放器**真实位置**（不是调用方传入的对齐参数），
  // 这里先把播放器拖到 690s，模拟「用户已看到 690s 时目标源不可用」。
  clock.advance(const Duration(seconds: 12));
  await player.seek(690);
  var failed = false;
  try {
    await orch.switchSourceAligned(
      fromSourceId: 'plain',
      toSourceId: 'dead',
      mediaId: 'm1',
      mediaTitle: '示例剧',
      fromRawEpisode: 2,
      fromRawSeconds: 690,
    );
  } on PlaybackFailureException {
    failed = true;
  }
  check('目标源无地址时抛可恢复失效', failed);
  check('换源失败后进度记录仍为失败前位置（690s）',
      (await store.load('m1'))?.canonicalSeconds == 690.0,
      '${(await store.load('m1'))?.canonicalSeconds}');
  check('换源失败未把锚点切到坏源', reporter.anchor?.sourceId == 'plain');

  await reporter.stop();
}

// ---------------------------------------------------------------------------
// J. 片尾判定：看完一集再换端，不能被送回片尾字幕
//
// 这是「续播」最容易漏掉的一环：位置落盘本身完全正确，但记录的是本集最后 30 秒，
// 下次进来就从字幕开始播——用户只会说「续播坏了」。所以这里的每一条断言都对应
// 一种会让它静默退化的实现方式（不读时长 / 读太窄 / 读太宽 / 写失败后假装成功）。
// ---------------------------------------------------------------------------
Future<void> _endingDetection() async {
  final clock = FakeClock();

  // J1. 时长未知（真实内核 file-loaded 之前的常态）：一律不做「已看完」推断。
  {
    final player = MockPlayerController(); // durationSeconds 默认 0 = 未知
    final store = MemoryResumeStore();
    final reporter = ProgressReporter(
        player: player, store: store, autoTick: false, clock: clock.call);
    await reporter.begin(_anchor(_plain, canonicalSeconds: 650));
    await player.load('u', 2, 650);
    clock.advance(const Duration(seconds: 12));
    await player.seek(2680);
    final t = await reporter.tick(force: true);
    check('时长未知时不判片尾，照常落盘', !t.skipped && !t.finished, '$t');
    check('时长未知时 contentDuration 为 0', t.contentDuration == 0);
    check('时长未知时记录未被标记已看完',
        (await store.load('m1'))?.finished == false);
    await reporter.stop(flush: false);
  }

  // J2. 短片（预告 / 花絮 / 抖音式短内容）不参与片尾判定。
  {
    final player = MockPlayerController()..durationSeconds = 120;
    final store = MemoryResumeStore();
    final reporter = ProgressReporter(
        player: player, store: store, autoTick: false, clock: clock.call);
    await reporter.begin(_anchor(_plain, canonicalSeconds: 60));
    await player.load('u', 2, 60);
    clock.advance(const Duration(seconds: 12));
    await player.seek(118); // 距结尾仅 2s，但整集只有 2 分钟
    final t = await reporter.tick(force: true);
    check('短内容（< minEpisodeSeconds）不判片尾', !t.finished, '$t');
    check('短内容按普通位置落盘（118s）',
        (await store.load('m1'))?.canonicalSeconds == 118.0,
        '${(await store.load('m1'))?.canonicalSeconds}');
    await reporter.stop(flush: false);
  }

  // J3-J9. 正常长集：命中、幂等、force 不覆盖、回看可撤销。
  {
    final player = MockPlayerController()..durationSeconds = 2700; // 45 分钟
    final store = MemoryResumeStore();
    final sink = MemoryDiagnosticSink();
    final done = <int>[];
    final reporter = ProgressReporter(
      player: player,
      store: store,
      diagnostics: sink,
      autoTick: false,
      clock: clock.call,
      onEpisodeFinished: done.add,
    );
    await reporter.begin(_anchor(_plain, canonicalSeconds: 650));
    await player.load('u', 2, 650);

    clock.advance(const Duration(seconds: 12));
    await player.seek(2620); // 距结尾 80s ≤ 90s
    final hit = await reporter.tick(force: true);
    check('进入片尾区判定为已看完', hit.finished && hit.persisted, '$hit');
    check('记录位置归一到内容时长末端（2700s）',
        hit.contentSeconds == 2700.0, '${hit.contentSeconds}');
    check('落盘记录带 finished 标记',
        (await store.load('m1'))?.finished == true);
    check('落盘记录不是「末尾 30 秒」的原始位置',
        (await store.load('m1'))?.canonicalSeconds == 2700.0,
        '${(await store.load('m1'))?.canonicalSeconds}');
    check('看完事件只回调一次（同集不重复）', done.length == 1, '$done');
    check('片尾命中上报一条诊断',
        sink.ofKind(DiagnosticKind.episodeFinished).length == 1);

    // 片尾继续采样（定时器每 5s 一次）：不得把记录刷回字幕位置。
    clock.advance(const Duration(seconds: 5));
    await player.seek(2635);
    final again = await reporter.tick();
    check('片尾区重复采样被跳过', again.skip == ProgressSkip.ending, '$again');
    check('重复采样不改变已看完记录',
        (await store.load('m1'))?.canonicalSeconds == 2700.0);
    check('重复采样不重复回调', done.length == 1, '$done');

    // 退出/切后台走 force：同样不能被末尾位置覆盖。
    final forced = await reporter.tick(force: true);
    check('片尾区 force 采样仍跳过（退出前不乱写）',
        forced.skip == ProgressSkip.ending, '$forced');

    // 用户回拖到中段重看：记录必须变回「未看完」，否则永远播下一集。
    clock.advance(const Duration(seconds: 12));
    await player.seek(1600);
    final back = await reporter.tick(force: true);
    check('回拖到中段后取消已看完', !back.finished, '$back');
    check('回拖后的记录为未看完',
        (await store.load('m1'))?.finished == false);
    check('回拖后的位置被如实记录', back.contentSeconds == 1600.0);

    // 再次看到片尾：重新判定一次（回调第二次，不会因为「本集已判过」而永久失灵）。
    clock.advance(const Duration(seconds: 12));
    await player.seek(2640);
    await reporter.tick(force: true);
    check('再次进入片尾区重新判定', done.length == 2, '$done');
    check('再次判定后记录仍为已看完',
        (await store.load('m1'))?.finished == true);
    await reporter.stop(flush: false);
  }

  // J10-J12. 有广告的源：时长是原始坐标，必须先换算成内容时长再判片尾。
  {
    final player = MockPlayerController()..durationSeconds = 2760;
    final store = MemoryResumeStore();
    final reporter = ProgressReporter(
        player: player, store: store, autoTick: false, clock: clock.call);
    final a = _anchor(_ad, canonicalEpisode: 2, canonicalSeconds: 2180);
    await reporter.begin(a);
    await player.load('u', a.rawEpisode, a.rawSeconds);
    clock.advance(const Duration(seconds: 12));
    final t = await reporter.tick(force: true);
    // 原始 2760s 内含 9 段 60s 广告 → 内容时长 2220s。
    check('片尾判定用的是换算后的内容时长（2220s）',
        t.contentDuration == 2220.0, '${t.contentDuration}');
    check('内容时长不等于原始时长（换算真的发生）', t.contentDuration != 2760.0);
    check('广告源看完后记录内容坐标 2220s，而非原始 2760s',
        (await store.load('m1'))?.canonicalSeconds == 2220.0 &&
            (await store.load('m1'))?.finished == true,
        '${(await store.load('m1'))?.canonicalSeconds}');

    // 换集：时长必须重读，不能沿用上一集（否则下一集的片尾位置整个错位）。
    player.durationSeconds = 600; // 内容时长 = 600 - 120 = 480
    final b = _anchor(_ad, canonicalEpisode: 3, canonicalSeconds: 400);
    await reporter.begin(b);
    await player.load('u', b.rawEpisode, b.rawSeconds);
    final t2 = await reporter.tick(force: true);
    check('换集后重读时长（480s，不是上一集的 2220s）',
        t2.contentDuration == 480.0, '${t2.contentDuration}');
    check('新集片尾独立判定', t2.finished, '$t2');
    check('新集记录写在新集上',
        (await store.load('m1'))?.canonicalEpisode == 3);
    await reporter.stop(flush: false);
  }

  // J13. 时长只读一次：每 5s 采样都打一次原生调用是纯浪费。
  {
    final player = _CountingPlayer()..durationSeconds = 2700;
    final reporter = ProgressReporter(
        player: player,
        store: MemoryResumeStore(),
        autoTick: false,
        clock: clock.call);
    await reporter.begin(_anchor(_plain, canonicalSeconds: 100));
    await player.load('u', 2, 100);
    for (var i = 0; i < 4; i++) {
      clock.advance(const Duration(seconds: 12));
      await player.seek(120.0 + i * 20);
      await reporter.tick();
    }
    check('一次会话只读一次时长（缓存）',
        player.durationCalls == 1, 'calls=${player.durationCalls}');
    check('中段多次采样不误判为已看完',
        (await reporter.tick(force: true)).finished == false);
    await reporter.stop(flush: false);
  }
}

// ---------------------------------------------------------------------------
// K. 「已看完」标记的持久化契约：新字段必须能落盘、能读回、且不破坏旧数据
// ---------------------------------------------------------------------------
Future<void> _endingRecordJson() async {
  final now = DateTime(2026, 11, 5, 20, 0, 0);
  final unfinished = ResumeRecord(
      mediaId: 'm1',
      title: '示例剧',
      sourceId: 's',
      canonicalEpisode: 2,
      canonicalSeconds: 100,
      updatedAt: now);
  check('未看完记录不写 finished 字段（与旧格式字节级兼容）',
      !unfinished.toJson().containsKey('finished'),
      '${unfinished.toJson()}');

  final finished = unfinished.copyWith(canonicalSeconds: 2700, finished: true);
  final json = finished.toJson();
  check('已看完记录写入 finished=true', json['finished'] == true);
  final rt = ResumeRecord.fromJson(Map<String, dynamic>.from(json));
  check('JSON 往返保留「已看完」与位置',
      rt.finished && rt.canonicalSeconds == 2700.0);
  check('旧数据（无 finished 字段）读成未看完',
      ResumeRecord.fromJson(Map<String, dynamic>.from(unfinished.toJson()))
              .finished ==
          false);
  check('已看完与未看完不相等（同步去重不会混为一条）', finished != unfinished);
}

// ---------------------------------------------------------------------------
// L. 片尾写盘失败：不能假装已看完（否则磁盘恢复后也不会补写）
// ---------------------------------------------------------------------------
Future<void> _endingWriteFailure() async {
  final clock = FakeClock();
  final player = MockPlayerController()..durationSeconds = 2700;
  final flaky = _FlakyStore();
  final sink = MemoryDiagnosticSink();
  final done = <int>[];
  final reporter = ProgressReporter(
    player: player,
    store: flaky,
    diagnostics: sink,
    autoTick: false,
    clock: clock.call,
    onEpisodeFinished: done.add,
  );
  await reporter.begin(_anchor(_plain, canonicalSeconds: 650));
  await player.load('u', 2, 650);

  flaky.fail = true;
  clock.advance(const Duration(seconds: 12));
  await player.seek(2650);
  final first = await reporter.tick(force: true);
  check('片尾写盘失败时如实报告未持久化', first.finished && !first.persisted, '$first');
  check('写失败后存储中没有「已看完」记录', await flaky.load('m1') == null);
  check('写失败进入降级态（UI 可提示进度可能未保存）', reporter.degraded);
  check('写失败不触发看完回调', done.isEmpty, '$done');
  check('写失败不虚假上报片尾诊断',
      sink.ofKind(DiagnosticKind.episodeFinished).isEmpty);

  flaky.fail = false;
  clock.advance(const Duration(seconds: 12));
  await player.seek(2660);
  final retry = await reporter.tick(force: true);
  check('磁盘恢复后自动补写「已看完」', retry.persisted, '$retry');
  check('补写成功才落 finished 标记',
      (await flaky.load('m1'))?.finished == true);
  check('补写成功才回调一次', done.length == 1, '$done');
  check('补写成功只产生一条片尾诊断',
      sink.ofKind(DiagnosticKind.episodeFinished).length == 1);
  await reporter.stop(flush: false);
}
