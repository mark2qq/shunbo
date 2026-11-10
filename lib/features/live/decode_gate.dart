/// 直播「解码门禁」：把「这条线路真的能出画面吗」变成可判定的一等公民。
///
/// 背景（2026-11-06 央视官方源逆向的教训）：`cdrm` 加密流在四层浅判据上全部
/// 通过 —— HTTP 200、有 EXTINF、分片首字节 0x47、SPS 能解析出 High/L4.0，
/// 播放器甚至会报告 `picture=yes`，但画面是满屏色块。唯一能识破它的信号是
/// 解码器日志：`h264: error while decoding MB ...` / `Reference 3 >= 3`。
///
/// 所以这套东西分三层，各司其职：
///  * [classifyDecodeLog] —— 单条内核日志 → 故障类别（纯函数）；
///  * [DecodeGate] + [DecodeWatch] —— 起播后 N 秒窗口内的判决状态机；
///  * [DecodeGateBoard] —— 判决结果的短期记忆，供选源排序使用。
///
/// 刻意**不引入任何 Flutter / player 依赖**：这些判断没有异常栈，错了只会
/// 表现为「用户盯着花屏」，必须能在纯 dart 回归里逐条钉住。
library;

import 'dart:async';

/// 内核日志里能证伪「能播」的几类故障。
enum DecodeFaultKind {
  none,

  /// 切片级加扰 / 坏流：TS 结构正常但载荷解不开，画面是色块或马赛克。
  scrambled,

  /// 容器或编码本身不被支持（含 Invalid NAL / no frame）。
  format,

  /// 网络层错误。不计入解码门禁：这类由既有内核终态错误与看门狗处理。
  network,
}

/// 加扰特征表。
///
/// 与 `tooling/scan_live_decode.dart` / `scan_batch_decode.dart` 用的是同一组
/// 正则：离线体检判「不能播」和运行时判「该换线了」必须是同一把尺子，
/// 否则会出现「体检通过、播起来又花屏」或反之。
const List<String> kScrambledLogPatterns = <String>[
  r'error while decoding',
  r'Reference \d+ >=',
  r'decode_slice_header error',
  r'no frame!',
  r'corrupted',
  r'Invalid NAL unit',
];

final List<RegExp> _scrambled = <RegExp>[
  for (final p in kScrambledLogPatterns) RegExp(p, caseSensitive: false),
];

/// 网络类日志：命中后不计入解码错误，避免把「连不上」误判成「加扰」。
final List<RegExp> _network = <RegExp>[
  RegExp(r'http error [45]\d\d', caseSensitive: false),
  RegExp(r'failed to open', caseSensitive: false),
  RegExp(r'connection (refused|timed out|reset)', caseSensitive: false),
];

/// 单条日志分类。大小写不敏感，按「先网络、后加扰」的顺序：
/// ffmpeg 有时会把一条同时含 `corrupted` 与 HTTP 错误的重试日志打出来，
/// 那种不是切片加扰。
DecodeFaultKind classifyDecodeLog(String text) {
  if (text.isEmpty) return DecodeFaultKind.none;
  for (final p in _network) {
    if (p.hasMatch(text)) return DecodeFaultKind.network;
  }
  for (final p in _scrambled) {
    if (p.hasMatch(text)) return DecodeFaultKind.scrambled;
  }
  return DecodeFaultKind.none;
}

/// 播放内核上报的一次解码故障。
class DecodeFaultEvent {
  const DecodeFaultEvent({
    required this.url,
    required this.kind,
    required this.count,
    required this.sample,
    required this.at,
  });

  /// 内核实际 load 的地址（可能已由官方源解析器换成 CDN 直连地址）。
  final String url;

  final DecodeFaultKind kind;

  /// 本条线路累计的解码错误条数（达到阈值就只发一次）。
  final int count;

  /// 第一条命中日志，用于诊断落盘。
  final String sample;

  final DateTime at;

  /// 只有「切片加扰」才需要触发换线；其它类别交给既有链路。
  bool get shouldSwitch => kind == DecodeFaultKind.scrambled;
}

/// 播放内核可选实现的解码故障源。
///
/// 为什么是**可选接口**而不是给 [PlayerController] 加强制 getter：
/// Android 平台通道内核目前不转发 mpv 日志，硬加会让所有实现都要伪造一个
/// 空流。桌面端 `MediaKitPlayerController` 实现它，其余端保持原样；
/// 没有这个能力时解码门禁自动退化为「只靠离线体检」，不会崩。
abstract interface class DecodeFaultSource {
  Stream<DecodeFaultEvent> get decodeFaults;
}

/// 一条线路的一次判决。
class DecodeVerdict {
  const DecodeVerdict({
    required this.ok,
    required this.reason,
    this.width = 0,
    this.height = 0,
    this.errorCount = 0,
    this.sample = '',
  });

  final bool ok;
  final String reason;
  final int width;
  final int height;
  final int errorCount;
  final String sample;

  bool get scrambled => reason == kReasonScrambled;

  static const String kReasonOk = '解码链正常';
  static const String kReasonScrambled = '解码报错（疑似加扰流）';
  static const String kReasonNoPicture = '未建起解码链';

  factory DecodeVerdict.pass({int width = 0, int height = 0}) => DecodeVerdict(
        ok: true,
        reason: kReasonOk,
        width: width,
        height: height,
      );

  factory DecodeVerdict.scrambledFault({
    required int errorCount,
    required String sample,
  }) =>
      DecodeVerdict(
        ok: false,
        reason: kReasonScrambled,
        errorCount: errorCount,
        sample: sample,
      );

  factory DecodeVerdict.noPicture({int errorCount = 0}) => DecodeVerdict(
        ok: false,
        reason: kReasonNoPicture,
        errorCount: errorCount,
      );
}

/// 离线体检 / 运行时共用的判决规则。
///
/// 阈值取 3 而不是 1：切台瞬间解码器可能因为「还没拿到参考帧」报一两条
/// `non-existing PPS` 级别的瞬态错误，一张健康流在窗口内是 0 条；
/// 而加扰流（实测 cdrm）在 4 秒内报 103~124 条。3 条足以把两者分开，
/// 又不会因为一次偶发抖动就把好源换掉。
class DecodeGate {
  const DecodeGate({
    this.window = const Duration(seconds: 3),
    this.errorThreshold = 3,
  });

  /// 观察窗口：起播后这么久没有解码错误，才承认「这条线路是干净的」。
  final Duration window;

  final int errorThreshold;

  DecodeVerdict evaluate({
    required bool chainBuilt,
    required int errorCount,
    required Duration observed,
    int width = 0,
    int height = 0,
    String sample = '',
  }) {
    if (errorCount >= errorThreshold) {
      return DecodeVerdict.scrambledFault(
        errorCount: errorCount,
        sample: sample,
      );
    }
    if (!chainBuilt) return DecodeVerdict.noPicture(errorCount: errorCount);
    // 有解码链但还没观察满窗口：不能提前宣布成功，否则加扰流刚建链就被放过。
    if (observed < window) return DecodeVerdict.noPicture(errorCount: errorCount);
    return DecodeVerdict.pass(width: width, height: height);
  }
}

/// 运行时的「起播后观察窗」状态机。
///
/// 由播放内核的日志流驱动，不自己开定时器：日志来了就累计，播放器的
/// 看门狗每 2 秒调一次 [tick] 检查是否该收口。这样避免再引入一条
/// 与播放状态不同步的计时链路。
class DecodeWatch {
  DecodeWatch({DecodeGate gate = const DecodeGate()}) : _gate = gate;

  final DecodeGate _gate;
  String _url = '';
  int _errors = 0;
  String _sample = '';
  DateTime? _started;
  bool _decided = false;
  bool _chainBuilt = false;

  /// 当前观察的线路（未 begin 时为空）。
  String get url => _url;

  int get errorCount => _errors;

  bool get decided => _decided;

  void begin(String url, {DateTime? now}) {
    _url = url;
    _errors = 0;
    _sample = '';
    _started = now ?? DateTime.now();
    _decided = false;
    _chainBuilt = false;
  }

  /// 换台/换线前调用：之后的迟到日志一律不接受。
  void end() {
    _url = '';
    _decided = true;
  }

  /// 内核日志到达。返回非 null 表示**当场判定为加扰**（应立即换线）。
  DecodeVerdict? onLog(String text, {DateTime? now}) {
    if (_decided || _url.isEmpty) return null;
    if (classifyDecodeLog(text) != DecodeFaultKind.scrambled) return null;
    _errors++;
    _sample = _sample.isEmpty ? text : _sample;
    if (_errors < _gate.errorThreshold) return null;
    _decided = true;
    return DecodeVerdict.scrambledFault(errorCount: _errors, sample: _sample);
  }

  /// 看门狗周期调用。观察窗走完且没攒够错误 → 记为健康。
  DecodeVerdict? tick({required bool hasPicture, DateTime? now}) {
    if (_decided || _url.isEmpty) return null;
    final start = _started;
    if (start == null) return null;
    final observed = (now ?? DateTime.now()).difference(start);
    // 有画面即视为解码链建成：media_kit 的 videoParams / width×height
    // 只有在解码器真的吐出帧后才会变正值。
    _chainBuilt = _chainBuilt || hasPicture;
    if (observed < _gate.window) return null;
    final v = _gate.evaluate(
      chainBuilt: _chainBuilt,
      errorCount: _errors,
      observed: observed,
      sample: _sample,
    );
    // 没画面且没攒够错误时不急着判死（慢源可能还在拉分片）：
    // 交给既有的起播超时链路，别在这里抢裁决权。
    if (!v.ok && !v.scrambled) return null;
    _decided = true;
    return v;
  }
}

/// 判决结果的短期记忆。
///
/// 「这条线路上次是花屏」必须在**切回同一个台**时仍然生效，否则用户会在
/// 两个台之间来回切、每次都先看几秒色块。TTL 与失效登记一致取 10 分钟：
/// 加扰是源站属性，短时间不会自己变好，但也不能永久拉黑（可能换回未加密流）。
class DecodeGateBoard {
  DecodeGateBoard({
    this.ttl = const Duration(minutes: 10),
    this.maxEntries = 200,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final int maxEntries;
  final DateTime Function() _clock;
  final Map<String, _Entry> _byUrl = <String, _Entry>{};

  int get length => _byUrl.length;

  void record(String url, DecodeVerdict verdict, {DateTime? now}) {
    if (url.isEmpty) return;
    final t = now ?? _clock();
    _prune(t);
    if (_byUrl.length >= maxEntries && !_byUrl.containsKey(url)) {
      // 先丢最旧的；懒清理已经做过一轮，这里只会淘汰一条。
      final oldest = _byUrl.entries.reduce(
        (a, b) => a.value.at.isBefore(b.value.at) ? a : b,
      );
      _byUrl.remove(oldest.key);
    }
    _byUrl[url] = _Entry(verdict, t);
  }

  DecodeVerdict? verdictOf(String url, {DateTime? now}) {
    final e = _byUrl[url];
    if (e == null) return null;
    if ((now ?? _clock()).difference(e.at) >= ttl) {
      _byUrl.remove(url);
      return null;
    }
    return e.verdict;
  }

  bool isKnownBad(String url, {DateTime? now}) {
    final v = verdictOf(url, now: now);
    return v != null && !v.ok;
  }

  /// 供选源排序用：已知花屏的地址集合。
  Set<String> knownBadUrls({DateTime? now}) {
    final t = now ?? _clock();
    _prune(t);
    return _byUrl.entries
        .where((e) => !e.value.verdict.ok)
        .map((e) => e.key)
        .toSet();
  }

  void noteGood(String url) => _byUrl.remove(url);

  void clear() => _byUrl.clear();

  void _prune(DateTime now) {
    _byUrl.removeWhere((_, e) => now.difference(e.at) >= ttl);
  }
}

final class _Entry {
  const _Entry(this.verdict, this.at);
  final DecodeVerdict verdict;
  final DateTime at;
}
