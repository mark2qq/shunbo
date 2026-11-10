/// 内容级正确性判据：黑屏 / 静帧 / 纯色测试卡 / 循环垫片。
///
/// 为什么需要它（第十二轮实测教训）：`live.264788.xyz/channel/sichuanweishi4k`
/// 三轮 libmpv 解码都判「1920x1080 解码无错」，实际是 302 到
/// `error_account_pirated.mp4` 的**反盗链提示片**。解码门禁只能证伪花屏，
/// 证不了「画面里到底是不是这个台」。帧级统计是离线能做到的下一层：
/// 用连续抽帧的亮度均值/动态范围/时域差/感知哈希，把「根本没内容」
/// 和「内容在循环」这两类假可播从清单里剔掉。
///
/// **明确的判据边界**（不要越界宣称）：
/// * 能抓：黑屏、静帧卡死、纯色/彩条测试卡、短周期循环垫片、台标不动的假直播；
/// * 抓不到：**错台**（A 台画面套 B 台名字）、黑屏上只有一个台标、
///   OCR 才能辨认的提示文字、内容正确但画质低。这些需要帧级 OCR / 台标模板
///   或人工抽检，当前不做，也不写进「通过」结论。
///
/// 纯 Dart，不依赖 flutter / 图像库：采样器（`tooling/scan_content_frames.dart`）
/// 负责把真实帧转成 [FrameSample]，本模块只做判定，因此裸 `dart run` 可回归。
library;

/// 帧级采样。数值全部是 0..255 的亮度标度，与具体分辨率无关。
class FrameSample {
  const FrameSample({
    required this.atMs,
    required this.lumaMean,
    required this.lumaMin,
    required this.lumaMax,
    required this.motion,
    this.hash = '',
  });

  /// 相对起播的时间（毫秒）。采样器均匀抽取，判定只用它算覆盖率。
  final int atMs;

  final double lumaMean;
  final double lumaMin;
  final double lumaMax;

  /// 与上一帧的平均绝对亮度差。首帧没有前帧时传 0，判定会跳过它。
  final double motion;

  /// 感知哈希（十六进制）。空串表示采样器没给，循环检测会自动跳过。
  final String hash;

  double get dynamicRange => lumaMax - lumaMin;
}

enum ContentFaultKind {
  none,

  /// 采样不足：**不能判成通过**，否则「根本没出图」会被当成内容正常。
  insufficient,

  /// 长时间近黑（黑屏 / 无信号）。
  black,

  /// 时域差长期接近 0（静帧 / 卡死）。
  frozen,

  /// 单帧动态范围极小（纯色 / 测试卡 / 只有台标的纯底）。
  flat,

  /// 感知哈希出现短周期重复（循环垫片）。
  loop,
}

class ContentVerdict {
  const ContentVerdict({
    required this.kind,
    required this.reason,
    required this.samples,
    this.blackRatio = 0,
    this.frozenRatio = 0,
    this.flatRatio = 0,
    this.loopPeriod = 0,
    this.meanMotion = 0,
  });

  final ContentFaultKind kind;
  final String reason;
  final int samples;
  final double blackRatio;
  final double frozenRatio;
  final double flatRatio;

  /// 检出的循环周期（帧数）；0 表示未检出。
  final int loopPeriod;
  final double meanMotion;

  bool get ok => kind == ContentFaultKind.none;

  /// 给离线清单 / 诊断页的一行摘要。
  String get summary => ok
      ? '内容正常（$samples 帧）'
      : '${labelOf(kind)}：$reason（$samples 帧）';

  static String labelOf(ContentFaultKind k) => switch (k) {
        ContentFaultKind.none => '内容正常',
        ContentFaultKind.insufficient => '采样不足',
        ContentFaultKind.black => '黑屏',
        ContentFaultKind.frozen => '静帧',
        ContentFaultKind.flat => '纯色画面',
        ContentFaultKind.loop => '循环垫片',
      };
}

/// 判定阈值集中在这里，改一处即可，回归用合成序列钉住每个分支。
class ContentGate {
  const ContentGate({
    this.minSamples = 6,
    this.blackLuma = 22,
    this.blackRatio = 0.8,
    this.flatRange = 8,
    this.flatRatio = 0.8,
    this.frozenMotion = 1.2,
    this.frozenRatio = 0.8,
    this.loopMinPeriod = 2,
    this.loopSimilarity = 0.85,
  });

  final int minSamples;
  final double blackLuma;
  final double blackRatio;
  final double flatRange;
  final double flatRatio;
  final double frozenMotion;
  final double frozenRatio;
  final int loopMinPeriod;
  final double loopSimilarity;

  ContentVerdict evaluate(List<FrameSample> samples) {
    if (samples.length < minSamples) {
      return ContentVerdict(
        kind: ContentFaultKind.insufficient,
        reason: '只采到 ${samples.length} 帧，少于 $minSamples 帧下限',
        samples: samples.length,
      );
    }
    final n = samples.length;
    final blackCount = samples.where((s) => s.lumaMean <= blackLuma).length;
    final flatCount = samples.where((s) => s.dynamicRange <= flatRange).length;
    // 首帧没有前帧，motion 不参与判定。
    final motions = <double>[for (var i = 1; i < n; i++) samples[i].motion];
    final frozenCount = motions.where((m) => m <= frozenMotion).length;
    final meanMotion = motions.isEmpty
        ? 0.0
        : motions.reduce((a, b) => a + b) / motions.length;
    final blackR = blackCount / n;
    final flatR = flatCount / n;
    final frozenR = motions.isEmpty ? 0.0 : frozenCount / motions.length;

    // 顺序有讲究：黑屏与纯色都是「没内容」，先判最确定的；
    // 循环垫片往往也接近静帧，但「周期性重复」信息量更大，优先报循环。
    if (blackR >= blackRatio) {
      return ContentVerdict(
        kind: ContentFaultKind.black,
        reason: '${(blackR * 100).round()}% 帧近黑（亮度 ≤ $blackLuma）',
        samples: n,
        blackRatio: blackR,
        flatRatio: flatR,
        frozenRatio: frozenR,
        meanMotion: meanMotion,
      );
    }
    if (flatR >= flatRatio) {
      return ContentVerdict(
        kind: ContentFaultKind.flat,
        reason: '${(flatR * 100).round()}% 帧动态范围 ≤ $flatRange（纯色/测试卡）',
        samples: n,
        blackRatio: blackR,
        flatRatio: flatR,
        frozenRatio: frozenR,
        meanMotion: meanMotion,
      );
    }

    final period = _loopPeriod(samples);
    if (period > 0) {
      return ContentVerdict(
        kind: ContentFaultKind.loop,
        reason: '感知哈希以 $period 帧为周期重复',
        samples: n,
        blackRatio: blackR,
        flatRatio: flatR,
        frozenRatio: frozenR,
        loopPeriod: period,
        meanMotion: meanMotion,
      );
    }
    if (frozenR >= frozenRatio) {
      return ContentVerdict(
        kind: ContentFaultKind.frozen,
        reason: '${(frozenR * 100).round()}% 帧时域差 ≤ $frozenMotion（平均 $meanMotion）',
        samples: n,
        blackRatio: blackR,
        flatRatio: flatR,
        frozenRatio: frozenR,
        meanMotion: meanMotion,
      );
    }
    return ContentVerdict(
      kind: ContentFaultKind.none,
      reason: '亮度/动态范围/时域差与哈希均无异常',
      samples: n,
      blackRatio: blackR,
      flatRatio: flatR,
      frozenRatio: frozenR,
      meanMotion: meanMotion,
    );
  }

  /// 找到一个短周期 p，使 hash[i] == hash[i+p] 的占比 ≥ [loopSimilarity]。
  /// 周期上限取 n/2，避免把「只有两帧重复」误判成 1 帧周期。
  int _loopPeriod(List<FrameSample> samples) {
    if (samples.any((s) => s.hash.isEmpty)) return 0;
    final n = samples.length;
    for (var p = loopMinPeriod; p <= n ~/ 2; p++) {
      var same = 0;
      var compared = 0;
      for (var i = 0; i + p < n; i++) {
        compared++;
        if (samples[i].hash == samples[i + p].hash) same++;
      }
      if (compared > 0 && same / compared >= loopSimilarity) return p;
    }
    return 0;
  }
}
