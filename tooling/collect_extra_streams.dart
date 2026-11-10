// 扩展线路池：为「常用频道」补充**实测通过**的候选播放线路。
//
// 背景（2026-11-09 用户反馈）：兼容版里 601 个频道只有 1 条线路，央视 / 卫视
// 共 118 台里有 79 台一条可达线路都没有，CCTV-1 的 720P/1080P 线路还被旧台账
// 判死。清单本身来自主程序运行时导出，增强源在导出那一刻可能拉取失败或按
// channelLimit 收窄，于是大量备用线路根本没并进静态清单。
//
// 本工具做三件事，且**不猜、不灌水**：
//   ① 从固化在 tooling/source_snapshots/ 的公开聚合清单（Guovin 每日测速、
//      APTV、YueChan、iptv-org 全球总索引）解析出「台名 → URL」候选；
//   ② 按台名归一化匹配到 channels.json 的常用频道（央视 / 卫视 / 苏州地方台），
//      只排除「该台自己」已有的 URL（不做全局去重：聚合源把大量线路挂错台），
//      多源轮转取样，每台最多取 N 条；
//   ③ 逐条实测：播放列表 2xx 且含 #EXTM3U → 首分片 2xx/206 且实收 ≥ 4KB。
//      跟随 302 并以**最终 URL** 解析相对分片（与 probe_legacy_streams.dart 同修）。
//      只有两段都过才写进 legacy/assets/extra_streams.json。
//
// 输出由 gen_legacy_catalog.dart 消费，最终合入 assets/channels.json；
// 每条都带 quality / probeMs / segmentBytes / source，可回溯。
//
// 用法：
//   dart run tooling/collect_extra_streams.dart                  # 用固化快照
//   dart run tooling/collect_extra_streams.dart --refresh       # 先重新下载快照
//   dart run tooling/collect_extra_streams.dart --conc=10 --timeout=8 \
//       --per-channel=10 --max=1200
//
// 注意：本机系统代理会把 127.0.0.1:1 接管成 502，探测必须 findProxy DIRECT。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const String kCatalogPath = 'legacy/assets/channels.json';
const String kOutputPath = 'legacy/assets/extra_streams.json';
const String kSnapshotDir = 'tooling/source_snapshots';
const int kMinSegmentBytes = 4096;

class _SourceSpec {
  final String file;
  final String url;
  final String format;
  const _SourceSpec(this.file, this.url, this.format);
}

const List<_SourceSpec> kSources = <_SourceSpec>[
  // 央视高清 / 卫视（运营商 OTT 单播，2026-11-09 实测可达的独立来源）。
  _SourceSpec('fanmingming_cn.m3u',
      'https://gh-proxy.com/https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/index.m3u',
      'm3u'),
  _SourceSpec('vbskycn.m3u',
      'https://gh-proxy.com/https://raw.githubusercontent.com/vbskycn/iptv/master/tv/iptv4.m3u',
      'm3u'),
  _SourceSpec('guovin.m3u',
      'https://gh-proxy.com/https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/result.m3u',
      'm3u'),
  _SourceSpec('guovin.txt',
      'https://gh-proxy.com/https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/result.txt',
      'txt'),
  _SourceSpec('aptv.m3u',
      'https://gh-proxy.com/https://raw.githubusercontent.com/kimentanm/aptv/master/m3u/iptv.m3u',
      'm3u'),
  _SourceSpec('fanmingming_ipv6.m3u',
      'https://gh-proxy.com/https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u',
      'm3u'),
  _SourceSpec('yuechan.m3u',
      'https://gh-proxy.com/https://raw.githubusercontent.com/YueChan/Live/main/IPTV.m3u',
      'm3u'),
  _SourceSpec('iptvorg_cn.m3u',
      'https://iptv-org.github.io/iptv/countries/cn.m3u', 'm3u'),
  _SourceSpec('iptvorg_index.m3u',
      'https://iptv-org.github.io/iptv/index.m3u', 'm3u'),
];

class _Entry {
  final String name;
  final String display;
  final String url;
  final String source;
  final Map<String, String> headers;
  const _Entry(this.name, this.display, this.url, this.source, this.headers);
}

class _Target {
  final int num;
  final String name;
  final Set<String> existing;
  _Target(this.num, this.name, this.existing);
}

class _Verified {
  final int num;
  final String channel;
  final String url;
  final String label;
  final int quality;
  final bool https;
  final int ms;
  final int bytes;
  final String source;
  final Map<String, String> headers;

  _Verified(this.num, this.channel, this.url, this.label, this.quality,
      this.https, this.ms, this.bytes, this.source, this.headers);

  Map<String, Object?> toJson() => <String, Object?>{
        'num': num,
        'name': channel,
        'url': url,
        'label': label,
        'quality': quality,
        'https': https,
        'probeMs': ms,
        'segmentBytes': bytes,
        'source': source,
        if (headers.isNotEmpty) 'headers': headers,
      };
}

Future<void> main(List<String> args) async {
  final bool refresh = args.contains('--refresh');
  final int conc = _intArg(args, 'conc', 10);
  final int timeoutSec = _intArg(args, 'timeout', 8);
  final int perChannel = _intArg(args, 'per-channel', 10);
  final int maxCandidates = _intArg(args, 'max', 1200);
  if (refresh) await _refresh();

  final catalogFile = File(kCatalogPath);
  if (!catalogFile.existsSync()) {
    stderr.writeln('缺少 $kCatalogPath，请先跑 gen_legacy_catalog.dart');
    exitCode = 2;
    return;
  }
  final root = jsonDecode(catalogFile.readAsStringSync()) as Map<String, Object?>;
  final channels = (root['channels'] as List).cast<Map<String, Object?>>();

  // ---- 目标频道：央视 / 卫视 / 苏州地方台 ----
  final targets = <int, _Target>{};
  final exact = <String, int>{};
  final normalized = <String, List<int>>{};
  final allUrls = <String>{};
  for (final c in channels) {
    final streams = (c['streams'] as List).cast<Map<String, Object?>>();
    for (final s in streams) {
      allUrls.add('${s['url']}');
    }
    final group = '${c['group']}';
    final city = '${c['city'] ?? ''}';
    if (group != '央视频道' && group != '卫视频道' && city != '苏州') continue;
    final num = c['num'] as int;
    final name = '${c['name']}';
    targets[num] = _Target(num, name,
        <String>{for (final s in streams) '${s['url']}'});
    exact[name.replaceAll(RegExp(r'\s+'), '')] = num;
    final key = normalizeName(name);
    normalized.putIfAbsent(key, () => <int>[]).add(num);
  }
  stdout.writeln('目标频道 ${targets.length} 台（央视 / 卫视 / 苏州地方台）');

  // ---- 解析快照，按台名匹配，只排除「本台」已有线路 ----
  //
  // 这里刻意**不做全局 URL 去重**：主程序导出的清单里，聚合源把大量线路
  // 挂在了错误的台名下（台账早已记下「低可达率来自聚合灌水」）。按全局 URL
  // 去重会让 CCTV-1~17 / 各卫视几乎拿不到任何候选——它们的线路早被别人
  // 占走了。正确口径是：按快照自己的台名重新归属到本台，只要这条 URL 还没
  // 出现在「这一台」的线路表里，就候选、再实测。跨台复用数量写进台账备查。
  // 代价是 PC 侧只验「可达 + 能下分片」，不验画面内容，已在 caveat 写明。
  final buckets = <int, Map<String, List<_Entry>>>{};
  final sourceInfo = <Map<String, Object?>>[];
  final seenCandidateUrls = <String>{};
  var crossChannelCount = 0;
  for (final spec in kSources) {
    final f = File('$kSnapshotDir/${spec.file}');
    if (!f.existsSync()) {
      stdout.writeln('[快照] ${spec.file} 缺失，跳过（可加 --refresh）');
      continue;
    }
    final text = f.readAsStringSync();
    final parsed = spec.format == 'txt' ? _parseTxt(text, spec.file)
        : _parseM3u(text, spec.file);
    sourceInfo.add(<String, Object?>{
      'file': spec.file,
      'url': spec.url,
      'bytes': f.lengthSync(),
      'entries': parsed.length,
    });
    for (final e in parsed) {
      if (!e.url.startsWith('http://') && !e.url.startsWith('https://')) {
        continue; // rtp:// / udp:// 组播线路兼容端用不了
      }
      if (e.url.contains('://[')) {
        continue; // IPv6 字面量：API 18 电视多数没有 IPv6 栈，只会拖慢探测
      }
      final num = _matchNum(e.name, e.display, exact, normalized, targets);
      if (num == null) continue;
      if (targets[num]!.existing.contains(e.url)) continue;
      if (!seenCandidateUrls.add(e.url)) continue; // 多份快照间的重复
      if (allUrls.contains(e.url)) crossChannelCount++;
      final bySource = buckets.putIfAbsent(
          num, () => <String, List<_Entry>>{});
      bySource.putIfAbsent(spec.file, () => <_Entry>[]).add(e);
    }
    stdout.writeln('[快照] ${spec.file} ${parsed.length} 条，'
        '累计去重候选 ${seenCandidateUrls.length}，'
        '匹配 ${buckets.length} 台');
  }

  // 轮转挑选：每个来源轮流取一条，避免第一份快照把 perChannel 名额吃满，
  // 保证央视 / 卫视能从 Guovin / APTV / iptv-org 多源各拿到兜底线路。
  final jobs = <MapEntry<int, _Entry>>[];
  final nums = buckets.keys.toList()..sort();
  for (final num in nums) {
    final bySource = buckets[num]!;
    final lists = <List<_Entry>>[
      for (final spec in kSources)
        if (bySource.containsKey(spec.file)) bySource[spec.file]!,
    ];
    final cursors = List<int>.filled(lists.length, 0);
    var taken = 0;
    while (taken < perChannel && jobs.length < maxCandidates) {
      var progressed = false;
      for (var i = 0; i < lists.length &&
          taken < perChannel && jobs.length < maxCandidates; i++) {
        if (cursors[i] >= lists[i].length) continue;
        jobs.add(MapEntry(num, lists[i][cursors[i]++]));
        taken++;
        progressed = true;
      }
      if (!progressed) break;
    }
  }
  stdout.writeln('待实测 ${jobs.length} 条候选，覆盖 ${buckets.length} 台'
      '（其中 $crossChannelCount 条为跨台复用，按快照台名重新归属）；'
      '并发 $conc / 超时 ${timeoutSec}s');

  // ---- 并发实测（两轮，与 probe_legacy_streams.dart 同口径）----
  // 并发一高，慢源会出现 1ms 假死；第二轮用 3 并发 / 12 秒把首轮失败项
  // 再验一遍，避免把真能播的线路误判成死线。
  final verified = <_Verified>[];
  Future<void> runPass(List<MapEntry<int, _Entry>> batch, int workers,
      int seconds, List<_Verified> passed,
      List<MapEntry<int, _Entry>> failed) async {
    var cursor = 0;
    var done = 0;
    final timeout = Duration(seconds: seconds);
    Future<void> worker() async {
      while (true) {
        final i = cursor++;
        if (i >= batch.length) return;
        final job = batch[i];
        final r = await _probeOne(
            job.key, targets[job.key]!.name, job.value, timeout);
        if (r != null) {
          passed.add(r);
        } else {
          failed.add(job);
        }
        done++;
        if (done % 50 == 0 || done == batch.length) {
          stdout.writeln(
              '[扩展线路 $done/${batch.length}] 累计通过 ${passed.length}');
        }
      }
    }

    await Future.wait(List<Future<void>>.generate(workers, (_) => worker()));
  }

  final firstFailed = <MapEntry<int, _Entry>>[];
  await runPass(jobs, conc, timeoutSec, verified, firstFailed);
  final secondFailed = <MapEntry<int, _Entry>>[];
  if (firstFailed.isNotEmpty) {
    stdout.writeln('复检 ${firstFailed.length} 条慢源：3 并发 / 12 秒');
    await runPass(firstFailed, 3, 12, verified, secondFailed);
  }
  verified.sort((a, b) =>
      a.num != b.num ? a.num.compareTo(b.num) : a.ms.compareTo(b.ms));

  final channelsWithExtra = <int>{for (final v in verified) v.num};
  final payload = <String, Object?>{
    'format': 'shunbo-extra-streams/1',
    'probedAt': DateTime.now().toUtc().toIso8601String(),
    'source': kCatalogPath,
    'scope': '央视频道 + 卫视频道 + 苏州地方台',
    'method': 'm3u8 2xx + first segment 2xx/206 >= $kMinSegmentBytes B '
        '(PC side, follows 302, final-URL base); not equal to decode success',
    'caveat': 'PC 侧网络可达性 + 分片可下载，不等价于电视端解码成功；以真机为准',
    'params': <String, Object?>{
      'concurrency': conc,
      'timeoutSeconds': timeoutSec,
      'perChannel': perChannel,
      'maxCandidates': maxCandidates,
      'recheckConcurrency': 3,
      'recheckTimeoutSeconds': 12,
      'firstPassFailed': firstFailed.length,
      'recheckPassed': firstFailed.length - secondFailed.length,
    },
    'sources': sourceInfo,
    'candidateChannels': targets.length,
    'candidateUrls': jobs.length,
    'crossChannelCandidates': crossChannelCount,
    'verifiedCount': verified.length,
    'channelsWithExtra': channelsWithExtra.length,
    'highDefinitionCount': verified.where((v) => v.quality >= 720).length,
    'cctv1HighDefinitionCount': verified
        .where((v) => v.num == 1 && v.quality >= 720)
        .length,
    'streams': <Map<String, Object?>>[
      for (final v in verified) v.toJson(),
    ],
  };
  final out = File(kOutputPath);
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(payload), flush: true);
  stdout.writeln('输出: ${out.absolute.path} (${out.lengthSync()} B)');
  stdout.writeln('通过 ${verified.length} / ${jobs.length}；覆盖 '
      '${channelsWithExtra.length} 台；高清 '
      '${payload['highDefinitionCount']} 条；CCTV-1 高清 '
      '${payload['cctv1HighDefinitionCount']} 条');
}

int _intArg(List<String> args, String name, int fallback) {
  for (final a in args) {
    if (a.startsWith('--$name=')) {
      final v = int.tryParse(a.substring(name.length + 3));
      if (v != null && v > 0) return v;
    }
  }
  return fallback;
}

Future<void> _refresh() async {
  Directory(kSnapshotDir).createSync(recursive: true);
  for (final s in kSources) {
    final path = '$kSnapshotDir/${s.file}';
    final r = await Process.run('curl', <String>[
      '-sS', '-L', '-m', '30', '-o', path, s.url,
    ]);
    final f = File(path);
    final ok = r.exitCode == 0 && f.existsSync() && f.lengthSync() > 100;
    stdout.writeln('[refresh] ${s.file} '
        '${ok ? '${f.lengthSync()} B' : '失败，沿用已有快照'}');
  }
}

// ---------------------------------------------------------------- 解析

List<_Entry> _parseM3u(String text, String source) {
  final out = <_Entry>[];
  var info = '';
  var pendingHeaders = <String, String>{};
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXTINF')) {
      info = line;
      pendingHeaders = _headersOf(line);
      continue;
    }
    if (line.startsWith('#EXTVLCOPT:')) {
      final kv = line.substring('#EXTVLCOPT:'.length);
      final at = kv.indexOf('=');
      if (at > 0) {
        final key = kv.substring(0, at).toLowerCase();
        final value = kv.substring(at + 1);
        if (key == 'http-user-agent') pendingHeaders['User-Agent'] = value;
        if (key == 'http-referer') pendingHeaders['Referer'] = value;
      }
      continue;
    }
    if (line.startsWith('#')) continue;
    if (info.isEmpty) continue;
    if (!line.startsWith('http://') && !line.startsWith('https://')) {
      info = '';
      continue;
    }
    final display = _displayOf(info);
    final tvg = RegExp(r'tvg-name="([^"]*)"').firstMatch(info)?.group(1);
    final name = (tvg != null && tvg.trim().isNotEmpty) ? tvg.trim() : display;
    out.add(_Entry(name, display.isEmpty ? name : display, line, source,
        Map<String, String>.unmodifiable(pendingHeaders)));
    info = '';
    pendingHeaders = <String, String>{};
  }
  return out;
}

List<_Entry> _parseTxt(String text, String source) {
  final out = <_Entry>[];
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty || line.contains('#genre#')) continue;
    final at = line.indexOf(',');
    if (at <= 0 || at == line.length - 1) continue;
    final name = line.substring(0, at).trim();
    final url = line.substring(at + 1).trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) continue;
    out.add(_Entry(name, name, url, source, const <String, String>{}));
  }
  return out;
}

String _displayOf(String info) {
  final at = info.lastIndexOf(',');
  return at >= 0 ? info.substring(at + 1).trim() : '';
}

Map<String, String> _headersOf(String info) {
  final out = <String, String>{};
  final ua = RegExp(r'http-user-agent="([^"]*)"').firstMatch(info)?.group(1);
  final ref = RegExp(r'http-referer="([^"]*)"').firstMatch(info)?.group(1);
  if (ua != null && ua.isNotEmpty) out['User-Agent'] = ua;
  if (ref != null && ref.isNotEmpty) out['Referer'] = ref;
  return out;
}

// ---------------------------------------------------------------- 台名匹配

/// 台名归一化：CCTV-1 / CCTV1 / CCTV-1高清 → CCTV-1；
/// 江苏卫视HD / 浙江卫视(高清) → 江苏卫视 / 浙江卫视。
/// 画质后缀只剥尾，且 4K / 5+ 这类本身就是台名的走特例。
String normalizeName(String raw) {
  var x = raw.toUpperCase().replaceAll(RegExp(r'\s+'), '').replaceAll('－', '-');
  if (x.startsWith('CCTV-4K') || x.startsWith('CCTV4K')) return 'CCTV-4K';
  if (x.startsWith('CCTV-8K') || x.startsWith('CCTV8K')) return 'CCTV-8K';
  if (x.startsWith('CCTV-5+') || x.startsWith('CCTV5+')) return 'CCTV-5+';
  final m = RegExp(r'^CCTV-?(\d{1,2})').firstMatch(x);
  if (m != null) return 'CCTV-${int.parse(m.group(1)!)}';
  x = x.replaceAll(RegExp(r'(\(.*?\)|（.*?）|\[.*?\])'), '');
  x = x.replaceAll(
      RegExp(r'(超高清|高清|标清|UHD|FHD|HD|4K|8K|1080P|720P|576P|1080I|720I)+$'),
      '');
  return x;
}

int? _matchNum(String name, String display, Map<String, int> exact,
    Map<String, List<int>> normalized, Map<int, _Target> targets) {
  for (final raw in <String>[name, display]) {
    final key = raw.replaceAll(RegExp(r'\s+'), '');
    final hit = exact[key];
    if (hit != null) return hit;
  }
  for (final raw in <String>[name, display]) {
    final list = normalized[normalizeName(raw)];
    if (list != null && list.length == 1) return list.first;
  }
  // 卫视兜底：候选名里含「XX卫视」且清单里恰有一台以它结尾。
  for (final raw in <String>[name, display]) {
    if (!raw.contains('卫视')) continue;
    final hits = <int>[];
    for (final t in targets.values) {
      if (raw.contains(t.name) || t.name.contains(raw)) hits.add(t.num);
    }
    if (hits.length == 1) return hits.first;
  }
  return null;
}

// ---------------------------------------------------------------- 实测

int _qualityOf(String label, String url) {
  final s = '$label $url'.toLowerCase();
  if (s.contains('2160') || s.contains('4k') || s.contains('uhd') ||
      s.contains('超高清')) return 2160;
  if (s.contains('1080')) return 1080;
  if (s.contains('720')) return 720;
  if (s.contains('576') || s.contains('480') || s.contains('标清')) return 576;
  return 0;
}

String _qualityLabel(int q) {
  if (q >= 2160) return '4K ';
  if (q >= 1080) return '1080P ';
  if (q >= 720) return '720P ';
  return '';
}

Future<_Verified?> _probeOne(int num, String channel, _Entry e,
    Duration timeout) async {
  final sw = Stopwatch()..start();
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..idleTimeout = const Duration(seconds: 5)
    ..autoUncompress = false
    ..findProxy = ((Uri uri) => 'DIRECT');
  try {
    final pl = await _fetch(client, e.url, e.headers, timeout, 64 * 1024);
    if (pl.status != 200 || !pl.text.contains('#EXTM3U')) return null;
    var body = pl.text;
    var base = pl.url;
    if (body.contains('#EXT-X-STREAM-INF')) {
      final variant = _firstUri(body, base);
      if (variant == null) return null;
      final v = await _fetch(client, variant, e.headers, timeout, 256 * 1024);
      if (v.status != 200 || !v.text.contains('#EXTM3U')) return null;
      body = v.text;
      base = v.url;
    }
    final seg = _firstUri(body, base);
    if (seg == null) return null;
    final chunk = await _fetch(client, seg, <String, String>{
      ...e.headers,
      'range': 'bytes=0-65535',
    }, timeout, 96 * 1024);
    if (chunk.status != 200 && chunk.status != 206) return null;
    if (chunk.bytes < kMinSegmentBytes) return null;
    final q = _qualityOf(e.display, e.url);
    final label = '扩展·${_qualityLabel(q)}${e.display}'.length > 60
        ? '扩展·${_qualityLabel(q)}${e.display}'.substring(0, 60)
        : '扩展·${_qualityLabel(q)}${e.display}';
    return _Verified(num, channel, e.url, label, q,
        e.url.toLowerCase().startsWith('https://'), sw.elapsedMilliseconds,
        chunk.bytes, e.source, e.headers);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

class _Resp {
  final int status;
  final String text;
  final int bytes;
  final String url;
  const _Resp(this.status, this.text, this.bytes, this.url);
}

Future<_Resp> _fetch(HttpClient client, String url,
    Map<String, String> headers, Duration timeout, int maxBytes) async {
  final req = await client
      .getUrl(Uri.parse(url))
      .timeout(timeout, onTimeout: () => throw TimeoutException('connect'));
  req.followRedirects = true;
  req.maxRedirects = 3;
  req.headers.set('user-agent',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Shunbo-Probe');
  for (final h in headers.entries) {
    req.headers.set(h.key, h.value);
  }
  final resp = await req.close().timeout(timeout,
      onTimeout: () => throw TimeoutException('response'));
  var finalUrl = url;
  if (resp.redirects.isNotEmpty) {
    finalUrl = resp.redirects.last.location.toString();
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in resp.timeout(timeout)) {
    builder.add(chunk);
    if (builder.length >= maxBytes) break;
  }
  final bytes = builder.takeBytes();
  return _Resp(resp.statusCode, utf8.decode(bytes, allowMalformed: true),
      bytes.length, finalUrl);
}

String? _firstUri(String body, String base) {
  for (final raw in const LineSplitter().convert(body)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final abs = Uri.tryParse(base)?.resolve(line);
    if (abs == null) continue;
    final s = abs.toString();
    if (s.startsWith('http://') || s.startsWith('https://')) return s;
  }
  return null;
}
