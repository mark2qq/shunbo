/// 直播「全网检索」的源描述。
///
/// 原来只接两份 iptv-org 目录，线路数受限于「一份目录一个台一条流」。
/// 扩到全网后源的形态变多了：有标准 M3U、有 `名称,地址` 的纯文本、
/// 有按省份分组的聚合表、还有 iptv-org 的**全球**总索引。
/// 把「格式 / 收窄范围 / 体积与行数上限」显式建模，才能让新增源只改数据、
/// 不改解析主流程；也让回归能直接用常量断言「苏州到底有几份独立来源」。
library;

/// 源文件的文本格式。
enum LiveSourceFormat {
  /// 标准 M3U / M3U8（`#EXTINF` + 紧跟一行地址）。
  m3u,

  /// 国内聚合表常见的纯文本：`台名,地址`，以 `,#genre#` 行分节。
  nameUrl,
}

/// 这份源要收窄到哪个范围。
///
/// 为什么需要收窄：全网总索引有 1.1 万条，直接全量灌进频道表会把
/// 央视/卫视挤到后面，还会让首屏探测窗口全被境外死链占满。
enum LiveSourceScope {
  /// 全量并入（规模本身可控的中文聚合表）。
  all,

  /// 只留「台名能推断出城市」的地方台（苏州等城市频道靠它）。
  cityOnly,

  /// 只留国家级台：央视频道（CCTV / CGTN / CETV）与卫视频道。
  ///
  /// 为什么需要单独一档：聚合表（Guovin）对央视/卫视给的线路最多、也是唯一
  /// 会做**每日测速**的一份，但它同时带 600+ 条省市级台。全量并入会挤爆
  /// 单台线路上限与首屏探测窗口；只收城市台（[cityOnly]）又会把央视整批丢掉——
  /// 这正是「央视全台无源」的直接原因：iptv-org 目录里 CCTV-1..17 几乎全部
  /// 指向同一批境外中转 IP，一条都不能播时没有任何备份。
  nationalOnly,

  /// 只留中国相关条目（iptv-org 全球总索引用）。
  chinaOnly,

  /// 只留高清 / 超高清标注的条目。
  hdOnly,
}

/// 一份可插拔的检索源。
class LiveSourceDescriptor {
  const LiveSourceDescriptor(
    this.url, {
    this.format = LiveSourceFormat.m3u,
    this.scope = LiveSourceScope.all,
    this.maxBytes,
    this.scanLines,
    this.channelLimit,
    this.label = '',
  });

  final String url;
  final LiveSourceFormat format;
  final LiveSourceScope scope;

  /// 单份体积上限（字节）；null 用 `LiveCatalogService.maxPlaylistBytes`。
  final int? maxBytes;

  /// 扫描行数上限；null 用 `LiveCatalogService.maxLines`。
  final int? scanLines;

  /// 输出条目上限；null 由 [scope] 决定（收窄类源扫全表，全量源用 600）。
  final int? channelLimit;

  /// 诊断用的短名，不参与业务逻辑。
  final String label;

  /// 地址必须是 https 且落在已知主机上：源清单是编译期常量，
  /// 但依然要防手滑写进 `file:` / `javascript:` / 带凭据的地址。
  bool get isWellFormed {
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  @override
  String toString() =>
      'LiveSource(${label.isEmpty ? url : label}, ${format.name}/${scope.name})';
}
