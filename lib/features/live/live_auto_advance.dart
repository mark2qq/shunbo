/// 全线路失败后的自动切台策略（纯 Dart，无 Flutter 依赖）。
///
/// 旧行为是「同一台静默重连 2 次，然后停在『暂无信号』」——正是用户反馈的
/// 「停留在原频道反复加载、重复重试或卡在加载状态」。
/// 新行为：**该台全部线路都试过且仍不能播 → 按频道表顺序切下一个台**，
/// 继续走完整的正常起播流程；一轮扫完仍全灭才进入明确终态并低频重扫。
library;

/// 记录一轮自动切台里已经试过哪些台、跳了几次。
class AutoAdvancePlanner {
  AutoAdvancePlanner({this.maxHops = 240});

  /// 单轮最多跳台次数。防止一张几百台的表在整网故障时无限紧循环。
  final int maxHops;

  final Set<String> _attempted = <String>{};
  int _hops = 0;

  int get hops => _hops;
  int get attemptedCount => _attempted.length;
  bool hasAttempted(String id) => _attempted.contains(id);
  Set<String> get attempted => Set<String>.unmodifiable(_attempted);

  /// 记一次「整台所有线路都试过且失败」。
  void recordFailure(String channelId) {
    _attempted.add(channelId);
    _hops++;
  }

  /// 本轮是否已经走完：台数已覆盖或达到跳跃上限。
  ///
  /// `total <= 1` 也视为走完——只有一个台时不该「切到同一个台」，
  /// 那等于原地反复重试，必须停下来。
  bool sweepComplete(int total) =>
      total <= 1 || _hops >= maxHops || _attempted.length >= total;

  /// 按频道表顺序找下一个候选台。
  ///
  /// 从 [fromIndex] 之后开始、到末尾回绕；[skip] 为 true 的台直接跳过
  /// （整台线路已被判失效，或本轮已经试过）。全部跳过时返回 null，
  /// 调用方据此进入「全表暂无信号」终态，而不是留在加载态空转。
  int? nextIndex(int fromIndex, int total, bool Function(int index) skip) {
    if (total < 2) return null;
    final base = fromIndex.clamp(0, total - 1);
    for (var step = 1; step < total; step++) {
      final i = (base + step) % total;
      if (!skip(i)) return i;
    }
    return null;
  }

  /// 一轮扫完 / 播放成功 / 用户手动操作后重置。
  void reset() {
    _attempted.clear();
    _hops = 0;
  }
}
