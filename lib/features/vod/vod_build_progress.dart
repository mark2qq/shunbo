/// 生成「新接口索引目录」时的进度快照（1.0.5 第二十六次修）。
///
/// 用户红标：「正常能获取时要有进度条」。生成一份新接口的目录要连
/// 接口、按站点取页、再写盘，弱网下轻松几十秒 —— 之前界面上只有一行
/// 不变的字，用户看不出到底是在动还是卡死了。
///
/// 这个文件只放**纯数据**：不 import Flutter、不碰 IO，因此 `dart run`
/// 门禁能把 [fraction] / [note] 的整张表直接核完，不必起界面。
/// 生产者是 [VodSession]（它知道批次数与站点数），消费者是设置页与点播页。
library;

/// 生成索引经历的四个阶段。`done` / `failed` 只会出现在终态，
/// 它们存在的意义是让 UI 能把「100% / 失败」也走同一条渲染路径，
/// 而不是另外拼一套文案。
enum VodBuildStage {
  /// 连接口、读配置、识别采集站。总站点数还不知道 ⇒ 只能给不确定进度。
  connecting,

  /// 按站点取页。这是耗时最长的一段，有确定的站点总数可当进度条分母。
  fetching,

  /// 把条目写进该接口自己的目录文件（原子写）。
  saving,

  /// 完成。
  done,

  /// 失败（接口不可达 / 没返回可播条目 / 写盘失败 / 超时）。
  failed,
}

/// 一次生成的进度快照。**不可变**：每次上报都是一个新对象，
/// UI 直接比较对象相等即可判「有没有变化」，不必另外记时间戳。
class VodBuildProgress {
  const VodBuildProgress({
    required this.stage,
    this.sitesDone = 0,
    this.sitesTotal = 0,
    this.items = 0,
  });

  /// 刚开始：还在连接口。
  const VodBuildProgress.connecting() : this(stage: VodBuildStage.connecting);

  final VodBuildStage stage;

  /// 已经翻完（或判定不可用）的站点数。
  final int sitesDone;

  /// 本次一共要过多少个站。
  final int sitesTotal;

  /// 已经拿到的可播片源条数。
  final int items;

  bool get finished =>
      stage == VodBuildStage.done || stage == VodBuildStage.failed;

  /// 0..1 的**确定性**进度；null 表示「总工作量还不确定」，UI 用不确定进度条。
  ///
  /// 两条刻意的处理：
  ///  * `fetching` 封顶 **0.9** —— 站点翻完不等于目录写完，进度条先到 100%
  ///    再停住比停在 90% 更让人觉得卡死；
  ///  * 下限给 **0.02** —— 刚进 fetching 时 0/45 是 0%，条形图空着看不出
  ///    已经在跑，留一点点长度当「已启动」的信号。
  double? get fraction {
    switch (stage) {
      case VodBuildStage.connecting:
        return null;
      case VodBuildStage.fetching:
        if (sitesTotal <= 0) return null;
        final raw = sitesDone / sitesTotal;
        if (raw.isNaN) return null;
        return raw.clamp(0.02, 0.9).toDouble();
      case VodBuildStage.saving:
        return 0.95;
      case VodBuildStage.done:
        return 1;
      case VodBuildStage.failed:
        return null;
    }
  }

  /// 进度条下面那一行字。数字一律用「已 / 共」而不是百分数：
  /// 用户关心的是「还在不在动」，45 个站翻到第 12 个比 27% 更具体。
  String get note {
    switch (stage) {
      case VodBuildStage.connecting:
        return '正在连接接口并读取配置…';
      case VodBuildStage.fetching:
        return sitesTotal > 0
            ? '正在获取片源：已完成 $sitesDone/$sitesTotal 个站，已取 $items 条…'
            : '正在获取片源，已取 $items 条…';
      case VodBuildStage.saving:
        return '正在写入独立索引目录（$items 条）…';
      case VodBuildStage.done:
        return '索引目录已生成（$items 条）';
      case VodBuildStage.failed:
        return '获取失败';
    }
  }

  @override
  bool operator ==(Object other) =>
      other is VodBuildProgress &&
      other.stage == stage &&
      other.sitesDone == sitesDone &&
      other.sitesTotal == sitesTotal &&
      other.items == items;

  @override
  int get hashCode => Object.hash(stage, sitesDone, sitesTotal, items);

  @override
  String toString() =>
      'VodBuildProgress(${stage.name}, $sitesDone/$sitesTotal, $items)';
}
