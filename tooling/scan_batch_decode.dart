// 批量「能不能真出画面」判定。
//
// `scan_live_decode.dart` 是单条/按频道的串行版；这个是为了给「外部抓来的几百条
// 候选线路」做一次性体检而写的并发版：一条线路一个 Isolate，各自开 libmpv 实例，
// 判据与单条版完全一致（解码链建成 + 解码器零报错），不降级成 HTTP 200 这种假阳性。
//
// 为什么要并发：624 条 × 4s 串行要 40 分钟，并发 6 路后约 7 分钟。libmpv 的
// `mpv_wait_event` 是同步 FFI 轮询，会占住 isolate，所以必须一个 Isolate 一个实例。
//
// 用法：
//   dart run tooling/scan_batch_decode.dart --in <candidates.json> --out <result.json>
//        [--seconds 4] [--concurrency 6] [--limit 24]
//
// 输入 json：[{"group":"央视","name":"CCTV-1","url":"http://..."}]，url 可带
// `@@Referer=https://x/@@` 这种头标记（原表格式），这里会拆成真实请求头。
//
// 输出 json：逐条 {ok, detail, w, h, seconds}，另写一份只含通过项的 .m3u。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// libmpv 最小绑定
// ---------------------------------------------------------------------------
typedef _VoidPtrC = Pointer<Void> Function();
typedef _VoidPtrD = Pointer<Void> Function();
typedef _StrIntC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _StrIntD = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _StrInt2C = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _StrInt2D = int Function(Pointer<Void>, Pointer<Utf8>);
typedef _InitC = Int32 Function(Pointer<Void>);
typedef _InitD = int Function(Pointer<Void>);
typedef _CmdStrC = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _CmdStrD = int Function(Pointer<Void>, Pointer<Utf8>);
typedef _GetStrC = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _GetStrD = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _WaitC = Pointer<_MpvEvent> Function(Pointer<Void>, Double);
typedef _WaitD = Pointer<_MpvEvent> Function(Pointer<Void>, double);
typedef _DestroyC = Void Function(Pointer<Void>);
typedef _DestroyD = void Function(Pointer<Void>);

final class _MpvEvent extends Struct {
  @Int32()
  external int eventId;
  @Int32()
  external int error;
  @Uint64()
  external int replyUserdata;
  external Pointer<Void> data;
}

final class _MpvLogMessage extends Struct {
  external Pointer<Utf8> prefix;
  external Pointer<Utf8> level;
  external Pointer<Utf8> text;
  @Int32()
  external int logLevel;
}

/// 加扰 / 坏流特征。命中任意一条即判「不能播」——和单条版保持同一张表。
/// 公开给 `measure_stability.dart` 等工具复用，保证「体检」和「稳定性对比」
/// 用的是同一把尺子。
final List<RegExp> decodeBadPatterns = <RegExp>[
  RegExp(r'error while decoding'),
  RegExp(r'Reference \d+ >='),
  RegExp(r'decode_slice_header error'),
  RegExp(r'no frame!'),
  RegExp(r'corrupted'),
  RegExp(r'Invalid NAL unit'),
];

// ---------------------------------------------------------------------------
// 单条探测（在独立 Isolate 里跑）
// ---------------------------------------------------------------------------
Map<String, Object?> probeDecode(Map<String, Object?> job) {
  final url = job['url'] as String;
  final headers = (job['headers'] as Map).cast<String, String>();
  final seconds = (job['seconds'] as int);
  final libPath = job['lib'] as String;

  final lib = DynamicLibrary.open(libPath);
  final create = lib.lookupFunction<_VoidPtrC, _VoidPtrD>('mpv_create');
  final setOpt = lib.lookupFunction<_StrIntC, _StrIntD>('mpv_set_option_string');
  final init = lib.lookupFunction<_InitC, _InitD>('mpv_initialize');
  final cmd = lib.lookupFunction<_CmdStrC, _CmdStrD>('mpv_command_string');
  final getProp = lib.lookupFunction<_GetStrC, _GetStrD>('mpv_get_property_string');
  final reqLog = lib.lookupFunction<_StrInt2C, _StrInt2D>('mpv_request_log_messages');
  final wait = lib.lookupFunction<_WaitC, _WaitD>('mpv_wait_event');
  final destroy = lib.lookupFunction<_DestroyC, _DestroyD>('mpv_destroy');

  Map<String, Object?> fail(String why, {int firstFrameMs = 0}) =>
      <String, Object?>{
        'ok': false,
        'detail': why,
        'w': 0,
        'h': 0,
        'firstFrameMs': firstFrameMs,
      };

  final h = create();
  if (h == nullptr) return fail('mpv_create 失败');

  void opt(String k, String v) => setOpt(h, k.toNativeUtf8(), v.toNativeUtf8());

  opt('vo', 'null');
  opt('hwdec', 'no');
  opt('audio', 'no');
  opt('terminal', 'no');
  opt('cache', 'yes');
  opt('network-timeout', '10');
  opt('demuxer-lavf-buffersize', '32768');
  // 直播流默认会为了「找到关键帧」把 4 秒窗口耗在缓冲上，压一下探测期。
  opt('hls-bitrate', 'min');
  if (headers.isNotEmpty) {
    final fields = headers.entries
        .where((e) => !const <String>{'host', 'range'}.contains(e.key.toLowerCase()))
        .map((e) => '${e.key}: ${e.value}')
        .join(',');
    if (fields.isNotEmpty) opt('http-header-fields', fields);
  }

  if (init(h) < 0) {
    destroy(h);
    return fail('mpv_initialize 失败');
  }
  reqLog(h, 'warn'.toNativeUtf8());

  final rc = cmd(h, 'loadfile "$url"'.toNativeUtf8());
  if (rc < 0) {
    destroy(h);
    return fail('loadfile rc=$rc');
  }

  var bad = 0;
  String? firstBad;
  var firstFrameMs = 0;
  var polls = 0;
  final sw = Stopwatch()..start();
  while (sw.elapsed < Duration(seconds: seconds)) {
    final ev = wait(h, 0.05);
    // 每 ~0.5s 问一次「解码链建起来没有」，用来量化首帧时延。
    // 稳定性对比只比「能不能播」不够：慢 1 秒和慢 8 秒对用户是两种体验。
    if (++polls % 10 == 0 && firstFrameMs == 0) {
      final probe = getProp(h, 'video-params'.toNativeUtf8());
      final s = probe == nullptr ? '' : probe.toDartString();
      if (s.contains('"w"')) firstFrameMs = sw.elapsedMilliseconds;
    }
    if (ev == nullptr) continue;
    if (ev.ref.eventId != 2) continue; // MPV_EVENT_LOG_MESSAGE
    final msg = ev.ref.data.cast<_MpvLogMessage>().ref;
    final text = msg.text == nullptr ? '' : msg.text.toDartString();
    if (text.isEmpty) continue;
    for (final p in decodeBadPatterns) {
      if (p.hasMatch(text)) {
        bad++;
        firstBad ??= text;
        break;
      }
    }
  }

  final params = getProp(h, 'video-params'.toNativeUtf8());
  final codec = getProp(h, 'video-codec'.toNativeUtf8());
  final paramsStr = params == nullptr ? '' : params.toDartString();
  final codecStr = codec == nullptr ? '' : codec.toDartString();
  destroy(h);

  // 只有真的建起了解码链（拿到 w/h + codec）才算「出了画面」。
  if (!(paramsStr.contains('"w"') && codecStr.isNotEmpty)) {
    return fail('无画面（未建解码链）', firstFrameMs: firstFrameMs);
  }
  if (firstFrameMs == 0) firstFrameMs = sw.elapsedMilliseconds;
  final res = RegExp(r'"w":(\d+),"h":(\d+)').firstMatch(paramsStr);
  final w = res == null ? 0 : int.parse(res.group(1)!);
  final hh = res == null ? 0 : int.parse(res.group(2)!);

  if (bad > 0) {
    final short = (firstBad ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    final cut = short.length > 28 ? 28 : short.length;
    return <String, Object?>{
      'ok': false,
      'detail': '解码报错 ${bad}次：${short.substring(0, cut)}',
      'w': w,
      'h': hh,
      'firstFrameMs': firstFrameMs,
    };
  }
  return <String, Object?>{
    'ok': true,
    'detail': '${w}x$hh 解码无错',
    'w': w,
    'h': hh,
    'firstFrameMs': firstFrameMs,
  };
}

// ---------------------------------------------------------------------------
// 解析原表的 `@@Key=Value@@` 头标记
// ---------------------------------------------------------------------------
({String url, Map<String, String> headers}) splitHeaders(String raw) {
  final headers = <String, String>{};
  final buf = StringBuffer();
  var i = 0;
  while (i < raw.length) {
    final start = raw.indexOf('@@', i);
    if (start < 0) {
      buf.write(raw.substring(i));
      break;
    }
    buf.write(raw.substring(i, start));
    final end = raw.indexOf('@@', start + 2);
    if (end < 0) {
      buf.write(raw.substring(start));
      break;
    }
    final inner = raw.substring(start + 2, end);
    final eq = inner.indexOf('=');
    if (eq > 0) headers[inner.substring(0, eq).trim()] = inner.substring(eq + 1).trim();
    i = end + 2;
  }
  return (url: buf.toString().trim(), headers: headers);
}

// ---------------------------------------------------------------------------
Future<void> main(List<String> args) async {
  var inPath = '';
  var outPath = '';
  var seconds = 4;
  var concurrency = 6;
  var limit = 0;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--in':
        inPath = args[++i];
      case '--out':
        outPath = args[++i];
      case '--seconds':
        seconds = int.parse(args[++i]);
      case '--concurrency':
        concurrency = int.parse(args[++i]);
      case '--limit':
        limit = int.parse(args[++i]);
    }
  }
  if (inPath.isEmpty || outPath.isEmpty) {
    stderr.writeln('用法: --in <json> --out <json> [--seconds 4] [--concurrency 6] [--limit N]');
    exit(2);
  }

  final libPath = File('build/windows/x64/runner/Release/libmpv-2.dll').path;
  if (!File(libPath).existsSync()) {
    stderr.writeln('缺少 $libPath：先执行 flutter build windows --release');
    exit(2);
  }

  final raw = jsonDecode(File(inPath).readAsStringSync()) as List;
  final items = raw.cast<Map>().map((m) {
    final s = splitHeaders((m['url'] as String));
    // 输入可能已经在 `headers` 字段里带好头（解析 302 / 手工整理候选时常见），
    // 也可能沿用原表的 `@@Key=Value@@` 标记。以前只认后者，把前者**静默丢掉**，
    // 于是「带防盗链的源」在批量体检里全被判成死链——而单条工具带同样的头却
    // 能播。两种写法必须合并，标记形式优先（它是显式追加的）。
    final declared = (m['headers'] as Map?)?.map(
          (k, v) => MapEntry<String, String>('$k', '$v'),
        ) ??
        const <String, String>{};
    return <String, Object?>{
      'group': m['group'] ?? '',
      'name': m['name'] ?? '',
      'url': s.url,
      'headers': <String, String>{...declared, ...s.headers},
    };
  }).toList();
  final targets = limit > 0 && limit < items.length ? items.sublist(0, limit) : items;

  stdout.writeln('待检 ${targets.length} 条，并发 $concurrency，窗口 ${seconds}s');
  final results = <Map<String, Object?>>[];
  final swAll = Stopwatch()..start();
  var done = 0;

  // 分批跑，避免一次性起几百个 isolate 把机器拖垮。
  for (var i = 0; i < targets.length; i += concurrency) {
    final batch = targets.sublist(i, (i + concurrency).clamp(0, targets.length));
    final futures = batch.map((it) async {
      final job = <String, Object?>{
        'url': it['url'],
        'headers': it['headers'],
        'seconds': seconds,
        'lib': libPath,
      };
      Map<String, Object?> r;
      try {
        r = await Isolate.run(() => probeDecode(job));
      } catch (e) {
        r = <String, Object?>{'ok': false, 'detail': 'isolate 异常: $e', 'w': 0, 'h': 0};
      }
      done++;
      final mark = r['ok'] == true ? 'OK  ' : 'FAIL';
      stdout.writeln('[$done/${targets.length}] $mark ${r['detail']}  ${it['name']} ${it['url']}');
      return <String, Object?>{
        'group': it['group'],
        'name': it['name'],
        'url': it['url'],
        'headers': it['headers'],
        ...r,
      };
    });
    results.addAll(await Future.wait(futures));
  }

  final ok = results.where((r) => r['ok'] == true).toList();
  stdout.writeln('\n通过 ${ok.length}/${results.length}，耗时 ${swAll.elapsed.inSeconds}s');

  File(outPath).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(results));

  // 只含通过项的 m3u：把 Referer 写成 #EXTVLCOPT，顺播解析器忽略该行即退回裸 URL。
  final m3u = StringBuffer('#EXTM3U\n');
  String? cur;
  for (final r in ok) {
    final g = r['group'] as String;
    if (g != cur) {
      cur = g;
      m3u.writeln();
    }
    m3u.writeln('#EXTINF:-1 group-title="$g",${r['name']}');
    final hdrs = (r['headers'] as Map).cast<String, String>();
    for (final e in hdrs.entries) {
      m3u.writeln('#EXTVLCOPT:http-${e.key.toLowerCase()}=${e.value}');
    }
    m3u.writeln(r['url']);
  }
  final m3uPath = outPath.replaceAll(RegExp(r'\.json$'), '') + '.m3u';
  File(m3uPath).writeAsStringSync(m3u.toString());
  stdout.writeln('写出 $outPath / $m3uPath（${ok.length} 条）');
}
