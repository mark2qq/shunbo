// 线路「能不能真播」的判定工具（不是 HTTP 200，也不是有没有 TS 同步字节）。
//
// 为什么需要它：这一轮踩了两次同样的坑 ——
//   ① 只看 HTTP 200 就以为通了（央视官方 CDN 对任意频道名都返回合法 master 清单）；
//   ② 只看「分片首字节是 0x47、清单里有 EXTINF」就以为通了（`cdrm` 那条链路
//      TS 结构完好、SPS/PPS 都在，但**切片载荷是加密的**，解码出来是满屏色块）。
// 这两种假成功在界面上的表现都是「有画面」——首帧检测会通过，用户看到的是花屏。
//
// 唯一可信的判据是**解码器有没有报错**：加扰流的典型日志是
//   `h264: error while decoding MB x y, bytestream N`
//   `h264: Reference 3 >= 3`
// 所以这里直接用 libmpv 播 4 秒，经 `mpv_request_log_messages` 抓日志行数。
//
// 用法：
//   dart run tooling/scan_live_decode.dart                      # 全台抽检（每台前 3 条）
//   dart run tooling/scan_live_decode.dart --group 央视频道
//   dart run tooling/scan_live_decode.dart --url <地址>         # 只测一条
//   dart run tooling/scan_live_decode.dart --per 5 --seconds 5
//
// 退出码：0 = 至少有一条通过；1 = 全部失败（便于脚本判定）。
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:shunbo/features/live/live_catalog.dart';
import 'package:shunbo/features/live/live_channel.dart';

// ---------------------------------------------------------------------------
// libmpv 最小绑定（只用到 create/option/init/command/property/log/destroy）
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

/// `mpv_event`（client.h）。只用 event_id / data 两个字段。
final class _MpvEvent extends Struct {
  @Int32()
  external int eventId;
  @Int32()
  external int error;
  @Uint64()
  external int replyUserdata;
  external Pointer<Void> data;
}

/// `mpv_event_log_message`。
final class _MpvLogMessage extends Struct {
  external Pointer<Utf8> prefix;
  external Pointer<Utf8> level;
  external Pointer<Utf8> text;
  @Int32()
  external int logLevel;
}

/// 一次探测的结果。
class DecodeResult {
  DecodeResult(this.url, this.ok, this.detail);
  final String url;
  final bool ok;
  final String detail;

  @override
  String toString() => '${ok ? 'OK  ' : 'FAIL'} ${detail.padRight(42)} $url';
}

/// 加扰 / 坏流的特征日志。命中任意一条即判「不能播」。
final List<RegExp> _badPatterns = <RegExp>[
  RegExp(r'error while decoding'),
  RegExp(r'Reference \d+ >='),
  RegExp(r'decode_slice_header error'),
  RegExp(r'no frame!'),
  RegExp(r'corrupted'),
  RegExp(r'Invalid NAL unit'),
];

Future<DecodeResult> probeOne(
  DynamicLibrary lib,
  LiveStream stream, {
  Duration window = const Duration(seconds: 4),
}) async {
  final create = lib.lookupFunction<_VoidPtrC, _VoidPtrD>('mpv_create');
  final setOpt = lib.lookupFunction<_StrIntC, _StrIntD>('mpv_set_option_string');
  final init = lib.lookupFunction<_InitC, _InitD>('mpv_initialize');
  final cmd = lib.lookupFunction<_CmdStrC, _CmdStrD>('mpv_command_string');
  final getProp = lib.lookupFunction<_GetStrC, _GetStrD>('mpv_get_property_string');
  final reqLog =
      lib.lookupFunction<_StrInt2C, _StrInt2D>('mpv_request_log_messages');
  final wait = lib.lookupFunction<_WaitC, _WaitD>('mpv_wait_event');
  final destroy = lib.lookupFunction<_DestroyC, _DestroyD>('mpv_destroy');

  final h = create();
  if (h == nullptr) return DecodeResult(stream.url, false, 'mpv_create 失败');

  void opt(String k, String v) =>
      setOpt(h, k.toNativeUtf8(), v.toNativeUtf8());

  // vo=null：不建窗口、不占屏，只跑解码链。
  opt('vo', 'null');
  opt('hwdec', 'no');
  opt('audio', 'no');
  opt('terminal', 'no');
  opt('cache', 'yes');
  opt('network-timeout', '12');
  // 直播流不要 seek/预读太久，否则窗口内还没有数据。
  opt('demuxer-lavf-buffersize', '32768');
  // 线路自带的请求头（不少 CDN 校验 Referer / UA）：拼进 http-header-fields。
  if (stream.headers.isNotEmpty) {
    final fields = stream.headers.entries
        .where((e) => !const <String>{'host', 'range'}
            .contains(e.key.toLowerCase()))
        .map((e) => '${e.key}: ${e.value}')
        .join(',');
    if (fields.isNotEmpty) opt('http-header-fields', fields);
  }
  init(h);
  reqLog(h, 'warn'.toNativeUtf8());

  final rc = cmd(h, 'loadfile "${stream.url}"'.toNativeUtf8());
  if (rc < 0) {
    destroy(h);
    return DecodeResult(stream.url, false, 'loadfile rc=$rc');
  }

  var bad = 0;
  String? firstBad;
  var sawVideo = false;
  final sw = Stopwatch()..start();
  while (sw.elapsed < window) {
    final ev = wait(h, 0.05);
    if (ev == nullptr) continue;
    final id = ev.ref.eventId;
    if (id != 2) continue; // MPV_EVENT_LOG_MESSAGE
    final msg = ev.ref.data.cast<_MpvLogMessage>().ref;
    final text = msg.text == nullptr ? '' : msg.text.toDartString();
    if (text.isEmpty) continue;
    for (final p in _badPatterns) {
      if (p.hasMatch(text)) {
        bad++;
        firstBad ??= text;
        break;
      }
    }
  }
  // 走到这里再取一次 video-params：只有真的解出画面参数才算「起了」。
  final params = getProp(h, 'video-params'.toNativeUtf8());
  final codec = getProp(h, 'video-codec'.toNativeUtf8());
  final paramsStr = params == nullptr ? '' : params.toDartString();
  final codecStr = codec == nullptr ? '' : codec.toDartString();
  sawVideo = paramsStr.contains('"w"') && codecStr.isNotEmpty;
  destroy(h);

  if (!sawVideo) return DecodeResult(stream.url, false, '无画面（未建解码链）');
  if (bad > 0) {
    final short = (firstBad ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    return DecodeResult(stream.url, false, '解码报错 ${bad}次：${short.substring(0, short.length > 26 ? 26 : short.length)}');
  }
  // 从 video-params 里抠分辨率，方便判断是不是被降质了。
  final res = RegExp(r'"w":(\d+),"h":(\d+)').firstMatch(paramsStr);
  return DecodeResult(
      stream.url, true, res == null ? '解码无错' : '${res.group(1)}x${res.group(2)} 解码无错');
}

Future<void> main(List<String> args) async {
  String? url;
  String? group;
  var per = 3;
  var seconds = 4;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--url':
        url = args[++i];
      case '--group':
        group = args[++i];
      case '--per':
        per = int.parse(args[++i]);
      case '--seconds':
        seconds = int.parse(args[++i]);
    }
  }

  final libPath = File('build/windows/x64/runner/Release/libmpv-2.dll').path;
  if (!File(libPath).existsSync()) {
    stderr.writeln('缺少 $libPath：先执行 flutter build windows --release');
    exit(2);
  }
  final lib = DynamicLibrary.open(libPath);
  final window = Duration(seconds: seconds);

  if (url != null) {
    final r = await probeOne(lib, LiveStream(url: url), window: window);
    stdout.writeln(r);
    exit(r.ok ? 0 : 1);
  }

  stdout.writeln('装载频道表…');
  final svc = LiveCatalogService(
    builtIn: BuiltInLiveChannels.all,
    remotePlaylistUrls: kDefaultLiveIndexUrls,
    streamIndexUrl: kDefaultStreamIndexUrl,
    streamIndexUrls: kDefaultStreamIndexUrls,
    citySupplementUrls: kDefaultCitySupplementUrls,
    discoverySources: kDefaultDiscoverySources,
    remoteTimeout: const Duration(seconds: 8),
  );
  var snap = await svc.load(remote: true);
  snap = await svc.enhanceSnapshot(snap);
  stdout.writeln('频道 ${snap.channels.length} · ${snap.sourceLabel}');

  final targets = snap.channels
      .where((c) => group == null || c.group == group)
      .where((c) => c.streams.isNotEmpty)
      .toList();
  stdout.writeln('待测 ${targets.length} 个台，每台前 $per 条线路，每条 ${seconds}s\n');

  var okChannels = 0;
  var totalLines = 0;
  var okLines = 0;
  final failedChannels = <String>[];
  final okHosts = <String, int>{};

  for (final c in targets) {
    final pick = c.orderedStreams.take(per).toList();
    var hit = false;
    final rows = <String>[];
    for (final s in pick) {
      totalLines++;
      final r = await probeOne(lib, s, window: window);
      if (r.ok) {
        hit = true;
        okLines++;
        final host = Uri.tryParse(s.url)?.host ?? '?';
        okHosts[host] = (okHosts[host] ?? 0) + 1;
      }
      rows.add('    ${r.ok ? 'OK  ' : 'FAIL'} ${r.detail.padRight(30)} ${s.url}');
    }
    if (hit) {
      okChannels++;
      stdout.writeln('✅ ${c.name}');
    } else {
      failedChannels.add(c.name);
      stdout.writeln('❌ ${c.name}');
    }
    rows.forEach(stdout.writeln);
  }

  stdout.writeln('\n================ 汇总 ================');
  stdout.writeln('台：$okChannels/${targets.length} 有可解码线路');
  stdout.writeln('线路：$okLines/$totalLines 可解码');
  if (okHosts.isNotEmpty) {
    final ranked = okHosts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    stdout.writeln('可用主机：${ranked.map((e) => '${e.key}×${e.value}').join(', ')}');
  }
  if (failedChannels.isNotEmpty) {
    stdout.writeln('整台不可解码 ${failedChannels.length}：${failedChannels.join('、')}');
  }
  exit(okLines > 0 ? 0 : 1);
}
