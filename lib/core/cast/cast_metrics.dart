/// 投屏指标（R12d）：把文档里的四个数字变成代码里的常量，并且**可判定**。
///
/// 单独成文件而不是散在控制器里，是为了让「门槛」只有一处定义：
/// 断言、UI 展示、诊断日志都引用同一份常量。分散写死的后果是改了阈值
/// 却漏了某处，指标就从「验收依据」退化成「一句注释」。
library;

/// 文档 R12d 的四个硬门槛。
class CastBudgets {
  const CastBudgets._();

  /// 发现超时：5 秒。超过还找不到设备就该给「未发现设备」而不是继续转圈。
  static const Duration discovery = Duration(seconds: 5);

  /// 点按到起播：≤ 8 秒。
  ///
  /// 这条约束了「直推 5 秒 + 改串流」能不能同时成立：
  /// 5 秒直推窗口 + 串流起播确认 2.5 秒 + 连接与下发余量 ≈ 8 秒。
  /// 所以串流侧的确认窗口不能再给 5 秒，否则必然超预算。
  static const Duration tapToStart = Duration(seconds: 8);

  /// 直推首帧确认窗口（R12b 明文写「5 秒未出图」）。
  static const Duration directFirstFrame = Duration(seconds: 5);

  /// 改串流后的确认窗口：预算里剩下的那一段。
  static const Duration relayFirstFrame = Duration(milliseconds: 2500);

  /// 进度回传误差 ≤ 1 秒 → 轮询间隔必须小于它，否则「误差」本身就被采样间隔撑大。
  static const Duration progressPoll = Duration(milliseconds: 900);

  /// 断连 3 秒内恢复。
  static const Duration reconnect = Duration(seconds: 3);
}

/// 一次投屏的实测结果，用于 UI 展示与诊断。
class CastReport {
  const CastReport({
    required this.discoveryMillis,
    required this.startMillis,
    required this.modeName,
    required this.reasonName,
    required this.signalName,
    required this.relayed,
  });

  final int discoveryMillis;

  /// 从「用户点了这台设备」到「确认起播」的耗时。
  ///
  /// 不含发现：发现是用户点「搜索设备」那一刻的动作，点设备时已经完成。
  /// 把它算进来会让指标看起来年年超标，却与用户实际等待无关。
  final int startMillis;

  final String modeName;
  final String reasonName;
  final String signalName;
  final bool relayed;

  bool get withinDiscovery => discoveryMillis <= CastBudgets.discovery.inMilliseconds;
  bool get withinStart => startMillis <= CastBudgets.tapToStart.inMilliseconds;
  bool get withinAll => withinDiscovery && withinStart;

  /// 一眼能看懂的摘要，直接渲染到投屏卡片上。
  String get summary {
    final d = (discoveryMillis / 1000).toStringAsFixed(1);
    final s = (startMillis / 1000).toStringAsFixed(1);
    final mode = relayed ? '串流中继' : '直推';
    return '发现 $d s · 起播 $s s · $mode（$reasonName）'
        '${withinAll ? '' : ' · 超出指标'}';
  }
}
