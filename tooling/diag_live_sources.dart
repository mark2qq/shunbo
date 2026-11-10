/// 直播源真实可达性诊断（一次性排查工具，不进门禁）。
///
/// 目的：把「央视/卫视播不了」从感觉变成数据。对频道表里的央视频道与卫视频道
/// 逐条线路探测，并**分别**用两种方式探：
///
/// * `bare` —— 当前 `LiveCatalogService.probe` 的真实行为：只带 `User-Agent: shunbo/1.0`；
/// * `withHeaders` —— 带上线路自己声明的 `Referer` / `User-Agent`。
///
/// 两者差异就是「防盗链线路被误判为死链」的影响面。失败按阶段分类
/// （DNS / TCP / TLS / HTTP 状态 / 无数据），因为不同阶段的处置方式完全不同：
/// TLS 换网络无效，HTTP 403 要补 Referer，超时多半是镜像本身挂了。
///
/// 用法：`dart run tooling/diag_live_sources.dart [每台线路数]`
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';

enum ProbeStage { ok, dns, tcp, tls, http, noData, other }

/// 一条线路在「裸探 ×2 → 带头 ×1」这套对照下的最终结论。
enum _Outcome {
  /// 裸探一次就成功。
  bareOk,

  /// 裸探首次失败、重试成功：瞬时抖动，与请求头无关。
  flaky,

  /// 两次裸探都失败，带线路声明的请求头才成功。
  headerRescue,

  /// 三次都失败。
  dead,
}

class ProbeResult {
  ProbeResult(this.stage, {this.detail = '', this.ms = 0});

  final ProbeStage stage;
  final String detail;
  final int ms;

  bool get ok => stage == ProbeStage.ok;
}

Future<ProbeResult> _probe(
  String url, {
  Map<String, String> headers = const <String, String>{},
  Duration timeout = const Duration(seconds: 6),
}) async {
  final watch = Stopwatch()..start();
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasAuthority) {
    return ProbeResult(ProbeStage.other, detail: '地址非法');
  }
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..findProxy = ((_) => 'DIRECT')
    ..userAgent = null;
  try {
    final req = await client.getUrl(uri).timeout(timeout);
    // 与生产环境一致：默认 UA 是 shunbo/1.0；线路自带 UA 时覆盖。
    req.headers.set(HttpHeaders.userAgentHeader,
        headers['User-Agent'] ?? headers['user-agent'] ?? 'shunbo/1.0');
    final ref = headers['Referer'] ?? headers['referer'];
    if (ref != null && ref.isNotEmpty) {
      req.headers.set(HttpHeaders.refererHeader, ref);
    }
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-2047');
    final resp = await req.close().timeout(timeout);
    final code = resp.statusCode;
    if (code < 200 || code >= 400) {
      await resp.drain<void>().catchError((Object _) {});
      watch.stop();
      return ProbeResult(ProbeStage.http, detail: 'HTTP $code', ms: watch.elapsedMilliseconds);
    }
    // 首块数据：有些镜像回 200 之后挂住不吐字节。
    // **只能读一次**：`first` 会订阅并在首个事件后取消，再 `drain` 就是
    // 「Stream has already been listened to」——第一版脚本踩了这个坑，
    // 把 30 条正常响应全记成了「其它」失败。
    final first = await resp.timeout(timeout).first;
    watch.stop();
    if (first.isEmpty) {
      return ProbeResult(ProbeStage.noData, detail: '首块为空', ms: watch.elapsedMilliseconds);
    }
    return ProbeResult(ProbeStage.ok, ms: watch.elapsedMilliseconds);
  } on HandshakeException catch (e) {
    watch.stop();
    return ProbeResult(ProbeStage.tls,
        detail: (e.message.isEmpty ? '证书握手失败' : e.message), ms: watch.elapsedMilliseconds);
  } on SocketException catch (e) {
    watch.stop();
    final msg = e.message;
    if (e.osError?.errorCode == 11001 || msg.contains('Failed host lookup')) {
      return ProbeResult(ProbeStage.dns, detail: msg, ms: watch.elapsedMilliseconds);
    }
    return ProbeResult(ProbeStage.tcp,
        detail: e.osError == null ? msg : 'errno ${e.osError!.errorCode}', ms: watch.elapsedMilliseconds);
  } on TimeoutException {
    watch.stop();
    return ProbeResult(ProbeStage.tcp, detail: '超时', ms: watch.elapsedMilliseconds);
  } catch (e) {
    watch.stop();
    return ProbeResult(ProbeStage.other, detail: '$e', ms: watch.elapsedMilliseconds);
  } finally {
    client.close(force: true);
  }
}

bool _isTarget(LiveChannel c) {
  if (c.group.contains('央视') || c.group.contains('卫视')) return true;
  return RegExp(r'CCTV|央视|卫视|CGTN').hasMatch(c.name);
}

String _stageLabel(ProbeStage s) => switch (s) {
      ProbeStage.ok => '可播',
      ProbeStage.dns => 'DNS 失败',
      ProbeStage.tcp => '连接失败/超时',
      ProbeStage.tls => '证书握手失败',
      ProbeStage.http => 'HTTP 拒绝',
      ProbeStage.noData => '无数据',
      ProbeStage.other => '其它',
    };

Future<void> main(List<String> args) async {
  final perChannel = args.isEmpty ? 3 : (int.tryParse(args.first) ?? 3);
  final service = LiveCatalogService(
    builtIn: const <LiveChannel>[],
    remotePlaylistUrls: kDefaultLiveIndexUrls,
  );
  stdout.writeln('拉取完整频道表（含备用源索引与全网增强）…');
  final snap = await service.load(remote: true);
  stdout.writeln('频道 ${snap.channels.length} 个 · ${snap.sourceLabel}');
  if (snap.warnings.isNotEmpty) {
    stdout.writeln('告警：${snap.warnings.join(' / ')}');
  }

  final targets = snap.channels.where(_isTarget).toList();
  // 只取前若干条线路，避免一个台 10 条把整个诊断拖到几十分钟。
  final entries = <(LiveChannel, LiveStream)>[];
  for (final c in targets) {
    final list = c.orderedStreams.take(perChannel).toList();
    for (final s in list) {
      entries.add((c, s));
    }
  }
  stdout.writeln('目标频道 ${targets.length} 个 / 线路 ${entries.length} 条'
      '（每台上限 $perChannel）\n');

  final outcomeCount = <_Outcome, int>{};
  var rescued = 0;
  final rescuedSamples = <String>[];
  final flakySamples = <String>[];
  final deadSamples = <String, List<String>>{};

  var done = 0;
  // 并发 12：够快又不至于把本机 NAT 打满导致全是「超时」的假阴性。
  for (var i = 0; i < entries.length; i += 12) {
    final slice = entries.skip(i).take(12).toList();
    final results = await Future.wait(slice.map((e) async {
      // 严格三段对照。第一版脚本是「裸 → 带头」各一次，结果把
      // 「第一次超时、第二次成功」的瞬时抖动全算成了「缺 Referer」：
      // 8 条所谓「误判」里 8 条的 headers 都是空的，根本没有头可补。
      // 现在先裸探两次，两次都失败才算「裸探测确实打不开」，
      // 此时才值得用线路声明的头再试一次。
      final first = await _probe(e.$2.url);
      if (first.ok) return (e, first, null, _Outcome.bareOk);
      final second = await _probe(e.$2.url);
      if (second.ok) return (e, second, null, _Outcome.flaky);
      if (e.$2.headers.isEmpty) return (e, second, null, _Outcome.dead);
      final withHeaders = await _probe(e.$2.url, headers: e.$2.headers);
      return (e, withHeaders, second, withHeaders.ok
          ? _Outcome.headerRescue
          : _Outcome.dead);
    }));
    for (final r in results) {
      final (e, finalProbe, _, outcome) = r;
      outcomeCount[outcome] = (outcomeCount[outcome] ?? 0) + 1;
      final host = Uri.tryParse(e.$2.url)?.host ?? '?';
      if (outcome == _Outcome.headerRescue) {
        rescued++;
        final hd = e.$2.headers.entries.map((x) => '${x.key}=${x.value}').join(',');
        if (rescuedSamples.length < 10) {
          rescuedSamples.add('${e.$1.name} · ${e.$2.label} · $hd\n    ${e.$2.url}'
              '\n    两次裸探均失败 → 带头可播 ${finalProbe.ms}ms');
        }
      }
      if (outcome == _Outcome.flaky && flakySamples.length < 6) {
        flakySamples.add('${e.$1.name} · ${host}（第一次超时/失败，重试 ${finalProbe.ms}ms 成功）');
      }
      if (outcome != _Outcome.bareOk) {
        final key = '${_stageLabel(finalProbe.stage)} ${finalProbe.detail}';
        deadSamples.putIfAbsent(key, () => <String>[]).add('${e.$1.name} $host');
      }
      done++;
      if (done % 20 == 0) stdout.writeln('  已探 $done/${entries.length}…');
    }
  }

  stdout.writeln('\n=== 归因（每条线路严格判定） ===');
  stdout.writeln('裸探一次即成功：${outcomeCount[_Outcome.bareOk] ?? 0}');
  stdout.writeln('裸探失败、重试成功（瞬时抖动，与请求头无关）：'
      '${outcomeCount[_Outcome.flaky] ?? 0}');
  stdout.writeln('两次裸探都失败、带线路声明的头才成功（真需要 Referer/UA）：'
      '${outcomeCount[_Outcome.headerRescue] ?? 0}');
  stdout.writeln('三次都失败（真死链 / 网络不可达）：'
      '${outcomeCount[_Outcome.dead] ?? 0}');
  if (flakySamples.isNotEmpty) {
    stdout.writeln('\n--- 抖动样例（说明「重试一次」本身就能救回一部分） ---');
    for (final s in flakySamples) {
      stdout.writeln('· $s');
    }
  }
  if (rescuedSamples.isNotEmpty) {
    stdout.writeln('\n--- 真·防盗链误判样例 ---');
    for (final s in rescuedSamples) {
      stdout.writeln('· $s');
    }
  }

  // 失败归因 Top：给出「主要死法」，便于判断修复方向。
  final ranked = deadSamples.entries.toList()
    ..sort((a, b) => b.value.length.compareTo(a.value.length));
  stdout.writeln('\n--- 带头发送仍失败的原因分布（前 8） ---');
  for (final e in ranked.take(8)) {
    stdout.writeln('${e.value.length.toString().padLeft(4)} × ${e.key}');
  }

  // 按主机聚合：一个镜像挂掉会带走整个台的线路，这条比「哪条失败」更有用。
  final hostFails = <String, int>{};
  for (final list in deadSamples.values) {
    for (final item in list) {
      final host = item.split(' ').last;
      hostFails[host] = (hostFails[host] ?? 0) + 1;
    }
  }
  final hostRanked = hostFails.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  stdout.writeln('\n--- 失败最集中的主机（前 12） ---');
  for (final e in hostRanked.take(12)) {
    stdout.writeln('${e.value.toString().padLeft(4)} × ${e.key}');
  }

  stdout.writeln('\n--- 每个目标频道「整台是否一条都播不了」（裸探两次，带头再兜一次） ---');
  final byChannel = <String, bool>{};
  // 逐台顺序探测（并发降到 4）：前面那轮为了速度并发 12，结果里必然混入
  // 被自己打满带宽导致的超时。判断「这个台到底能不能看」必须用低并发重测。
  final channelsSlice = targets.toList();
  for (var i = 0; i < channelsSlice.length; i += 4) {
    final slice = channelsSlice.skip(i).take(4).toList();
    final results = await Future.wait(slice.map((c) async {
      for (final s in c.orderedStreams) {
        final first = await _probe(s.url);
        if (first.ok) return (c, true);
        final second = await _probe(s.url);
        if (second.ok) return (c, true);
        if (s.headers.isNotEmpty) {
          final w = await _probe(s.url, headers: s.headers);
          if (w.ok) return (c, true);
        }
      }
      return (c, false);
    }));
    for (final r in results) {
      byChannel[r.$1.name] = r.$2;
    }
  }
  final unplayable = byChannel.entries.where((e) => !e.value).map((e) => e.key).toList();
  final playable = byChannel.length - unplayable.length;
  stdout.writeln('整台一条都播不了：${unplayable.length}/${byChannel.length}'
      '（能播 $playable）');
  stdout.writeln(unplayable.take(40).join('、'));

  // 附：频道表线路数分布，验证「多线路」是否真的并进来了。
  final multi = targets.where((c) => c.streams.length >= 2).length;
  final totalStreams = targets.fold<int>(0, (s, c) => s + c.streams.length);
  stdout.writeln('\n央视/卫视中拥有 ≥2 条线路的：$multi/${targets.length}'
      '；线路总数 $totalStreams');

  stdout.writeln('\nJSON ${jsonEncode(<String, Object?>{
        'targets': targets.length,
        'streams': entries.length,
        'headerRescue': rescued,
        'playableChannels': playable,
      })}');
}
