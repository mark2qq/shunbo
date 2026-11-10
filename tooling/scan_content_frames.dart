// 帧级内容抽样的**离线工具**（不是运行时链路）。
//
// 背景：解码门禁（scan_live_decode.dart / decode_gate.dart）只能证伪花屏。
// 反盗链提示片、黑屏、静帧卡死、循环垫片都能「解码零错误、有分辨率」，
// 却在用户眼里根本不是那个台。本工具用 libmpv 的 `vo=image` 把真实解码帧
// 落成 JPEG，再按时间均匀抽样算亮度/动态范围/时域差/感知哈希，交给
// `ContentGate` 判定。判定逻辑是纯 Dart，回归见 verify_content_gate.dart。
//
// 为什么不用 `vf=lavfi=[signalstats]`：本机 media_kit 附带的 libmpv 构建
// **任何 vf 都会直接把解码链弄没**（实测 signalstats / fps / scale 三种，
// video-params 为空、vo=image 一帧不出）。`vo=image` + 低质量 JPEG 是目前
// 这台机器上唯一能稳定拿到真实帧的路径；工具会即时删除临时帧目录。
//
// 用法：
//   dart run tooling/scan_content_frames.dart --url <地址>
//   dart run tooling/scan_content_frames.dart --in <list.json> --out <result.json>
//   可选：--seconds 4 --frames 8 --work-dir build/content_gate_frames
//
// 退出码：0 = 全部通过（含「采样不足」视为不通过）；1 = 有未通过项；2 = 缺 libmpv。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:shunbo/features/live/content_gate.dart';

typedef _VoidPtrC = Pointer<Void> Function();
typedef _VoidPtrD = Pointer<Void> Function();
typedef _StrIntC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _StrIntD = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _InitC = Int32 Function(Pointer<Void>);
typedef _InitD = int Function(Pointer<Void>);
typedef _CmdStrC = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _CmdStrD = int Function(Pointer<Void>, Pointer<Utf8>);
typedef _GetStrC = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _GetStrD = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _WaitC = Pointer<Void> Function(Pointer<Void>, Double);
typedef _WaitD = Pointer<Void> Function(Pointer<Void>, double);
typedef _DestroyC = Void Function(Pointer<Void>);
typedef _DestroyD = void Function(Pointer<Void>);

const int _gridW = 16;
const int _gridH = 9;
const int _hashW = 9;
const int _hashH = 8;

class _Job {
  const _Job({required this.name, required this.url, this.headers = const {}});
  final String name;
  final String url;
  final Map<String, String> headers;

  factory _Job.fromJson(Map<dynamic, dynamic> m) => _Job(
        name: '${m['name'] ?? m['url'] ?? ''}',
        url: '${m['url'] ?? ''}',
        headers: (m['headers'] is Map)
            ? (m['headers'] as Map).map(
                (k, v) => MapEntry<String, String>('$k', '$v'))
            : const <String, String>{},
      );
}

class _Capture {
  const _Capture({
    required this.files,
    required this.width,
    required this.height,
    required this.elapsedMs,
    this.error = '',
  });

  final List<File> files;
  final int width;
  final int height;
  final int elapsedMs;
  final String error;

  bool get ok => error.isEmpty && files.isNotEmpty;
}

/// 用 libmpv 抓一段真实帧。每次用独立目录，返回后由调用方清理。
Future<_Capture> _capture(
  DynamicLibrary lib,
  _Job job,
  Directory workDir,
  Duration window,
) async {
  if (workDir.existsSync()) workDir.deleteSync(recursive: true);
  workDir.createSync(recursive: true);

  final create = lib.lookupFunction<_VoidPtrC, _VoidPtrD>('mpv_create');
  final setOpt = lib.lookupFunction<_StrIntC, _StrIntD>('mpv_set_option_string');
  final init = lib.lookupFunction<_InitC, _InitD>('mpv_initialize');
  final cmd = lib.lookupFunction<_CmdStrC, _CmdStrD>('mpv_command_string');
  final getProp = lib.lookupFunction<_GetStrC, _GetStrD>('mpv_get_property_string');
  final wait = lib.lookupFunction<_WaitC, _WaitD>('mpv_wait_event');
  final destroy = lib.lookupFunction<_DestroyC, _DestroyD>('mpv_destroy');

  final h = create();
  if (h == nullptr) {
    return const _Capture(files: [], width: 0, height: 0, elapsedMs: 0,
        error: 'mpv_create 失败');
  }
  void opt(String k, String v) =>
      setOpt(h, k.toNativeUtf8(), v.toNativeUtf8());
  String prop(String k) {
    final p = getProp(h, k.toNativeUtf8());
    return p == nullptr ? '' : p.toDartString();
  }

  opt('vo', 'image');
  opt('vo-image-format', 'jpg');
  // 低质量够算亮度/哈希，且能把 4K 帧从 ~670KB 压到 ~140KB。
  opt('vo-image-jpeg-quality', '5');
  opt('vo-image-outdir', workDir.absolute.path.replaceAll('/', '\\'));
  opt('hwdec', 'no');
  opt('audio', 'no');
  opt('terminal', 'no');
  opt('cache', 'yes');
  opt('network-timeout', '12');
  opt('demuxer-lavf-buffersize', '32768');
  if (job.headers.isNotEmpty) {
    final fields = job.headers.entries
        .where((e) => !const <String>{'host', 'range'}
            .contains(e.key.toLowerCase()))
        .map((e) => '${e.key}: ${e.value}')
        .join(',');
    if (fields.isNotEmpty) opt('http-header-fields', fields);
  }
  final rc = init(h);
  if (rc < 0) {
    destroy(h);
    return _Capture(files: [], width: 0, height: 0, elapsedMs: 0,
        error: 'mpv_initialize rc=$rc');
  }
  final escaped = job.url.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
  final loadRc = cmd(h, 'loadfile "$escaped"'.toNativeUtf8());
  if (loadRc < 0) {
    destroy(h);
    return _Capture(files: [], width: 0, height: 0, elapsedMs: 0,
        error: 'loadfile rc=$loadRc');
  }

  final sw = Stopwatch()..start();
  while (sw.elapsed < window) {
    wait(h, 0.05);
  }
  final w = int.tryParse(prop('video-params/w')) ?? 0;
  final hh = int.tryParse(prop('video-params/h')) ?? 0;
  destroy(h);

  final files = workDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.jpg'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return _Capture(
    files: files,
    width: w,
    height: hh,
    elapsedMs: sw.elapsedMilliseconds,
    error: files.isEmpty ? '窗口内没有解出任何帧' : '',
  );
}

/// 把一张解码后的图降采样成亮度网格。
List<double> _lumaGrid(img.Image im, int w, int h) {
  final grid = <double>[];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final px = im.getPixel(
        math.min(im.width - 1, ((x + 0.5) * im.width / w).floor()),
        math.min(im.height - 1, ((y + 0.5) * im.height / h).floor()),
      );
      grid.add(0.299 * px.r.toDouble() +
          0.587 * px.g.toDouble() +
          0.114 * px.b.toDouble());
    }
  }
  return grid;
}

/// 64 位 dHash（横向相邻亮度比较）。返回 64 个 '0'/'1'，
/// ContentGate 只做字符串相等比较，不需要大整数运算。
String _dHash(img.Image im) {
  final g = _lumaGrid(im, _hashW, _hashH);
  final buf = StringBuffer();
  for (var y = 0; y < _hashH; y++) {
    for (var x = 0; x < _hashW - 1; x++) {
      buf.write(g[y * _hashW + x + 1] > g[y * _hashW + x] ? '1' : '0');
    }
  }
  return buf.toString();
}

double _meanAbsDiff(List<double> a, List<double> b) {
  if (a.length != b.length || a.isEmpty) return 255;
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    sum += (a[i] - b[i]).abs();
  }
  return sum / a.length;
}

List<FrameSample> _samplesFrom(
  List<File> files, {
  required int count,
  required int elapsedMs,
}) {
  if (files.isEmpty) return <FrameSample>[];
  final n = files.length;
  final take = math.min(count, n);
  final indices = <int>{};
  for (var i = 0; i < take; i++) {
    indices.add(take == 1 ? 0 : (i * (n - 1) / (take - 1)).round());
  }
  final ordered = indices.toList()..sort();
  final out = <FrameSample>[];
  List<double>? previous;
  for (final idx in ordered) {
    img.Image? im;
    try {
      im = img.decodeJpg(File(files[idx].path).readAsBytesSync());
    } catch (_) {
      continue;
    }
    if (im == null) continue;
    final grid = _lumaGrid(im, _gridW, _gridH);
    final mean = grid.reduce((a, b) => a + b) / grid.length;
    out.add(FrameSample(
      atMs: n <= 1 ? 0 : (idx * elapsedMs / (n - 1)).round(),
      lumaMean: mean,
      lumaMin: grid.reduce(math.min),
      lumaMax: grid.reduce(math.max),
      motion: previous == null ? 0 : _meanAbsDiff(previous, grid),
      hash: _dHash(im),
    ));
    previous = grid;
  }
  return out;
}

Future<void> main(List<String> args) async {
  var seconds = 4;
  var frames = 8;
  String? singleUrl;
  String? inputPath;
  String? outputPath;
  var workDir = 'build/content_gate_frames';
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--url':
        singleUrl = args[++i];
      case '--in':
        inputPath = args[++i];
      case '--out':
        outputPath = args[++i];
      case '--seconds':
        seconds = int.parse(args[++i]);
      case '--frames':
        frames = int.parse(args[++i]);
      case '--work-dir':
        workDir = args[++i];
    }
  }
  final jobs = <_Job>[];
  if (singleUrl != null) {
    jobs.add(_Job(name: singleUrl, url: singleUrl));
  } else if (inputPath != null) {
    final decoded = jsonDecode(File(inputPath).readAsStringSync());
    if (decoded is! List) {
      stderr.writeln('输入 JSON 应为数组');
      exit(2);
    }
    for (final e in decoded) {
      if (e is Map) jobs.add(_Job.fromJson(e));
    }
  } else {
    stderr.writeln('需要 --url <地址> 或 --in <list.json>');
    exit(2);
  }

  const libPath = 'build/windows/x64/runner/Release/libmpv-2.dll';
  if (!File(libPath).existsSync()) {
    stderr.writeln('缺少 $libPath：先执行 flutter build windows --release');
    exit(2);
  }
  final lib = DynamicLibrary.open(libPath);
  final gate = ContentGate(minSamples: math.min(6, frames));
  final results = <Map<String, Object?>>[];
  var pass = 0;
  for (var i = 0; i < jobs.length; i++) {
    final job = jobs[i];
    final dir = Directory('$workDir/job_$i');
    _Capture capture;
    try {
      capture = await _capture(lib, job, dir, Duration(seconds: seconds));
    } catch (e) {
      capture = _Capture(files: [], width: 0, height: 0, elapsedMs: 0,
          error: '抓帧异常：$e');
    }
    final samples = capture.ok
        ? _samplesFrom(capture.files,
            count: frames, elapsedMs: capture.elapsedMs)
        : <FrameSample>[];
    final verdict = capture.ok
        ? gate.evaluate(samples)
        : ContentVerdict(
            kind: ContentFaultKind.insufficient,
            reason: capture.error,
            samples: samples.length,
          );
    if (verdict.ok) pass++;
    final row = <String, Object?>{
      'name': job.name,
      'url': job.url,
      'ok': verdict.ok,
      'kind': verdict.kind.name,
      'verdict': verdict.summary,
      'width': capture.width,
      'height': capture.height,
      'capturedFrames': capture.files.length,
      'sampledFrames': samples.length,
      'meanMotion': double.parse(verdict.meanMotion.toStringAsFixed(2)),
      'loopPeriod': verdict.loopPeriod,
      'error': capture.error,
      'samples': <Map<String, Object?>>[
        for (final s in samples)
          <String, Object?>{
            'atMs': s.atMs,
            'lumaMean': double.parse(s.lumaMean.toStringAsFixed(1)),
            'lumaMin': s.lumaMin.round(),
            'lumaMax': s.lumaMax.round(),
            'motion': double.parse(s.motion.toStringAsFixed(2)),
            'hash': s.hash,
          },
      ],
    };
    results.add(row);
    print('${verdict.ok ? 'OK  ' : 'FAIL'} '
        '${job.name.padRight(18)} ${capture.width}x${capture.height} '
        '抓帧 ${capture.files.length} / 抽样 ${samples.length} :: ${verdict.summary}');
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  }
  if (outputPath != null) {
    File(outputPath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(results));
    print('\n写出 $outputPath');
  }
  print('内容判据：$pass/${jobs.length} 通过');
  if (pass != jobs.length) exitCode = 1;
}
