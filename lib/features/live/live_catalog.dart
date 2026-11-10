import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'channel_taxonomy.dart';
import 'live_channel.dart';
import 'live_region.dart';
import 'live_source_descriptor.dart';
import 'stream_policy.dart';

/// 一次频道目录装载的结果。
class LiveCatalogSnapshot {
  /// 可直接展示的频道（已按分组排序、去重）。
  final List<LiveChannel> channels;

  /// 这次频道表从哪来（展示用，例如「公开索引（312 个）」或「内置清单」）。
  final String sourceLabel;

  /// 装载过程中的降级说明（远端不可达、条目被拒等）。空表示一切正常。
  final List<String> warnings;

  const LiveCatalogSnapshot({
    required this.channels,
    required this.sourceLabel,
    this.warnings = const <String>[],
  });

  int get channelCount => channels.length;
}

/// 频道目录：**内置清单 + 公开 M3U 索引自动合并**。
///
/// 设计意图对应「打开即用」这个硬要求：
/// 1. 内置清单保证任何网络环境下都有台可看（不依赖远端）；
/// 2. 启动时自动拉取公开 M3U 索引补齐频道表，成功就替换成更完整的清单，
///    失败**静默回退**——绝不弹一个「请配置信号源」的框拦住用户。
///
/// 远端内容一律按不可信输入处理：体积/行数/条目数/URL scheme 全有上界，
/// 解析失败只丢条目、不抛异常。
class LiveCatalogService {
  /// 内置频道（不联网即可用）。
  final List<LiveChannel> builtIn;

  /// 公开 M3U 索引地址，按顺序尝试，第一个成功的生效。
  final List<String> remotePlaylistUrls;

  /// 远端拉取超时。首屏不能被远端拖住，所以给得比较短。
  final Duration remoteTimeout;

  /// 可选增强源（城市台补充 / 全网发现 / 备用源索引）的拉取超时。
  ///
  /// 这些源走公共镜像、体积可能较大，给得比主索引宽，避免「镜像稍慢就整批掉线」——
  /// 之前 70% 频道只有单点源，根因之一就是聚合表（aptv / YueChan / Guovin）经代理镜像
  /// 时偶发超过主索引的 8s 上限被静默丢弃，于是那些「多线路」根本没并进来。
  /// 失败仍按各自路径静默降级，不影响开播。
  final Duration enhancedTimeout;

  /// 单次拉取的最大字节数（M3U 是纯文本，2 MiB 足够覆盖几万条）。
  static const int maxPlaylistBytes = 2 * 1024 * 1024;

  /// 解析上限：超过就截断，避免恶意列表把内存和 UI 拖垮。
  static const int maxChannels = 600;
  static const int maxLines = 20000;

  /// iptv-org 全球总索引比普通目录大得多（实测 2.6 MB / 2.3 万行），
  /// 单份「收窄型」源允许放大体积与行数，但仍由描述符逐份设界。
  static const int extendedPlaylistBytes = 4 * 1024 * 1024;
  static const int extendedScanLines = 30000;

  /// 备用源索引（`streams.json`）的体积上限。
  ///
  /// 比 M3U 大得多是因为它包含**全球所有**频道的所有已知流（实测 3.8 MB / 1.8 万条）。
  /// 上限仍要有：这是远端输入，不设界就等于让对端决定我们的内存占用。
  static const int maxStreamIndexBytes = 8 * 1024 * 1024;

  /// 单个频道最多保留几条线路。
  ///
  /// 从 6 提到 10 是「全网检索 + 高清优先」的直接要求：多份聚合表对同一个台
  /// 常给出 8~12 条不同 CDN / 不同分辨率的流，按 6 截断会把排在后面的
  /// 1080p/4K 线路整批丢掉。上限仍要留：全失效时换线是一条条试的。
  static const int maxStreamsPerChannel = 10;

  /// 高清画质阈值：>= 此值视为「高清线路」（720p 及以上）。
  ///
  /// 播放时优先加载这一档；阈值放到 70 而不是 90，是因为国内索引里大量
  /// 1080p 流只在台名写「高清」而没写分辨率，720p 也确实属于高清。
  static const int hdQualityThreshold = LiveStream.hdQualityThreshold;

  /// 一条线路是不是高清档。
  static bool isHdStream(LiveStream s) => s.isHd;

  /// 是否为可接受的播放地址：只放 http/https，且禁止带 userinfo（凭据泄漏面）。
  static bool isAcceptableStreamUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    if (uri.host.isEmpty) return false;
    if (uri.userInfo.isNotEmpty) return false;
    if (raw.length > 2048) return false;
    return true;
  }

  /// 购物台判定（用户明确要求从频道列表移除）。
  ///
  /// 两条判据都要：有些索引用 `group-title="Shop"`，有些直接写在台名里
  /// （实测 cn.m3u 的 `Fengshang Shopping Channel (1080p)` 两者都占）。
  /// 中文词用子串、英文词用词边界——否则 `Workshop` 会被 `\bshop\b` 之外的
  /// 宽松匹配误伤，把正常频道筛掉。
  static final RegExp _shoppingNamePattern = RegExp(
    r'(购物|电视购物|快乐购|优购物|家有购物|宜和购物|东方购物|央广购物|'
    r'聚鲨|好享购物|风尚购物|环球购物|\bshopping\b|\btv\s*shop\b|'
    r'\bhome\s*shopping\b|\bqvc\b|\bhsn\b)',
    caseSensitive: false,
  );

  static const Set<String> _shoppingGroups = <String>{
    'shop',
    'shopping',
    'home shopping',
    'qvc',
    'hsn',
    '购物',
    '购物频道',
  };

  static bool isShoppingChannel(String name, String? remoteGroup) {
    if (_shoppingNamePattern.hasMatch(name)) return true;
    if (remoteGroup == null) return false;
    for (final part in remoteGroup.split(';')) {
      if (_shoppingGroups.contains(part.trim().toLowerCase())) return true;
    }
    return false;
  }

  /// 已解析出的频道里是否仍属于购物类（防御内置清单 / 合并路径）。
  static bool isBlockedChannel(LiveChannel c) =>
      c.group == '购物' || isShoppingChannel(c.name, null);

  /// 把购物频道从最终频道表里剔除。
  ///
  /// 为什么不在 [sortChannels] 里做：那是纯排序函数，掺进过滤语义会让
  /// 「排序后条数变了」这种意外出现在所有调用方。过滤只发生在装载边界。
  static List<LiveChannel> withoutShopping(Iterable<LiveChannel> channels) =>
      channels.where((c) => !isBlockedChannel(c)).toList(growable: false);

  /// iptv-org 的省级卫视英文名 → 中文标准台名。
  ///
  /// 这是「卫视频道接入各大卫视源」的关键：公开索引把卫视写成
  /// `Hunan TV (2160p)`、`Jiangsu Satellite TV (1080p)`、`Shandong TV`，
  /// 老逻辑只认中文「卫视」，于是这些台全被挤进「地方频道 / 其它频道」，
  /// 卫视频道分组几乎是空的。归一成中文名后，还能与国内索引里的
  /// 「湖南卫视 / 江苏卫视」按同一 id 合并成**多线路**（见 [channelIdFor]）。
  ///
  /// key 为 [satelliteKey] 的结果；只收**主频道全名**，
  /// `Hunan News Channel` / `Shandong TV Children's Channel` 这类地面频道
  /// 不会命中，仍按地方台展示。
  static const Map<String, String> satelliteAliases = <String, String>{
    'anhuitv': '安徽卫视',
    'beijingsatellitetv': '北京卫视',
    'bingtuansatellitetv': '兵团卫视',
    'dragontv': '东方卫视',
    'dragontvinternational': '东方卫视',
    'guangdongsatellitetv': '广东卫视',
    'guizhoutv': '贵州卫视',
    'hebeitv': '河北卫视',
    'heilongjiangtv': '黑龙江卫视',
    'hunantv': '湖南卫视',
    'jiangsusatellitetv': '江苏卫视',
    'jiangxitv': '江西卫视',
    'liaoningtv': '辽宁卫视',
    'neimonggoltv': '内蒙古卫视',
    'ningxiasatellitechannel': '宁夏卫视',
    'qinghaitv': '青海卫视',
    'shandongsatellitetv': '山东卫视',
    'shandongtv': '山东卫视',
    'shenzhensatellitetv': '深圳卫视',
    'sichuansatellitetv': '四川卫视',
    'tianjintv': '天津卫视',
    'yanbiansatellitetv': '延边卫视',
    'yunnansatellitetv': '云南卫视',
    'zhejiangsatellitetv': '浙江卫视',
  };

  /// 中文**旧台名 → 现行台名**的归一表。
  ///
  /// 与 [satelliteAliases]（英文→中文）互补：这里处理中文语境下的更名 / 别名，
  /// 例如「上海卫视」2002 年已更名为「东方卫视」，二者本为同一台。
  /// 不归一的话，两份索引若各返回一种写法，频道栏会出现「双列」、
  /// 数字编号也会分裂成两个号。
  ///
  /// 在 [canonicalName] 末尾应用：归一后的名字再走 [channelIdFor] 合并、
  /// [fixedNumberOf] 取号，从而始终是同一个频道、同一个号。
  static const Map<String, String> legacyStationNames = <String, String>{
    '上海卫视': '东方卫视',
    // 聚合表里的台名前缀 / 简写：与正式台名是同一个台，不归并就会在频道栏
    // 出现双列，且数字编号落到自动分配（实测 BRTV 北京卫视→113、黑龙卫视→140）。
    'BRTV 北京卫视': '北京卫视',
    '黑龙卫视': '黑龙江卫视',
    // CGTN 纪录频道的中英文 / 错字写法：都是同一个台，统一成「CGTN纪录」。
    // 不归一的话三个台名抢同一个固定号 21，rebuild 只留一个、另两个被
    // 自动分配（实测 CGTN纪录→54、CGTN记录→57），按 21 跳台会切错。
    'CGTN Documentary': 'CGTN纪录',
    'CGTN 纪录': 'CGTN纪录',
    'CGTN记录': 'CGTN纪录',
  };

  /// 台名匹配键：小写、只留字母数字与汉字。
  /// 这样 `Hunan TV` / `Hunan-TV` / `HUNAN TV` 都落到同一个 key。
  static String satelliteKey(String name) => name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fa5]'), '');

  /// 把英文卫视台名归一成中文标准名；已经是中文卫视名或不是卫视时返回 null。
  static String? satelliteNameOf(String canonical) {
    if (canonical.contains('卫视')) return null;
    return satelliteAliases[satelliteKey(canonical)];
  }

  /// 注入 HTTP 客户端的能力（回归脚本用它把 URL 指向本机 HttpServer）。
  final HttpClient Function()? httpClientFactory;

  /// 备用源索引地址（`streams.json`）。为 null 时只用 M3U 索引里的单条线路。
  final String? streamIndexUrl;

  /// 城市台补充索引：只从中挑「台名能推断出城市」的条目。
  ///
  /// 三份主索引（iptv-org cn/zho + 国内 ipv6 表）实测**一个苏州台都没有**，
  /// 而 IP 定位默认城市恰恰是这类地市台；不补这一份，
  /// 「按 IP 默认显示当前城市频道」在苏州就永远退化成「全部城市」。
  /// 现在放两份**不同镜像**的同一数据集：任一镜像挂掉仍有苏州台。
  final List<String> citySupplementUrls;

  /// 全网检索源（可插拔，见 [LiveSourceDescriptor]）。
  ///
  /// 每份源自带格式、收窄范围与体积上限；失败静默跳过，不影响主链路。
  /// 默认空表而不是全局常量：回归脚本构造服务时不能被迫去访问真实外网。
  final List<LiveSourceDescriptor> discoverySources;

  /// 备用源索引的额外镜像；按顺序尝试，第一份拿到数据就收工。
  ///
  /// 与 [streamIndexUrl] 合并去重，老调用方只传 `streamIndexUrl` 也照常工作。
  final List<String> streamIndexUrls;

  LiveCatalogService({
    this.builtIn = const <LiveChannel>[],
    this.remotePlaylistUrls = const <String>[],
    this.remoteTimeout = const Duration(seconds: 6),
    this.enhancedTimeout = const Duration(seconds: 15),
    this.httpClientFactory,
    this.streamIndexUrl = kDefaultStreamIndexUrl,
    this.citySupplementUrls = const <String>[],
    this.discoverySources = const <LiveSourceDescriptor>[],
    this.streamIndexUrls = const <String>[],
  });

  /// 装载频道表。**永不抛异常**：任何失败都以「退化到内置清单」收场。
  ///
  /// [remote] 为 false 时只返回内置清单（设置页「只用内置信号」开关会用到）。
  /// **第一阶段（快路径）**：只拉主索引（内置 + iptv-org 官方目录），立刻返回可播频道表。
  ///
  /// 为什么要把装载拆成两段：首屏真正需要的只是「一批能播的台」，
  /// 而旧实现把「全网发现源（多 MB 聚合表）+ 备用源索引（streams.json 3.8 MB）」
  /// 也塞进同一个 await 里——那些是**可选的覆盖率增强**，却让首帧硬等 10~15 秒。
  /// 拆开后首帧只等两份小目录（亚秒~1 秒），备用线路与地市长尾在后台补齐，
  /// 用户先看到画面，频道表随后自动变宽。
  ///
  /// 失败语义与原 [load] 完全一致：主索引全挂 → 退回内置清单并保留 warnings。
  Future<LiveCatalogSnapshot> loadBase({bool remote = true}) async {
    final warnings = <String>[];
    if (!remote || remotePlaylistUrls.isEmpty) {
      final visible = StreamPolicy.apply(withoutShopping(builtIn));
      return LiveCatalogSnapshot(
        channels: sortChannels(visible),
        sourceLabel: '内置清单（${visible.length} 个频道）',
        warnings: warnings,
      );
    }

    // 并发拉主索引：不同索引对同一个台给出的线路往往不同（一份给 720p、
    // 另一份给另一个 CDN），少拉一份就等于少一个备用源。
    final fetched = <LiveChannel>[];
    final playlists = await Future.wait(
      remotePlaylistUrls.map((url) => _fetchPlaylist(url, warnings)),
    );
    for (final p in playlists) {
      if (p != null) fetched.addAll(p);
    }

    // 主索引全挂时退回内置清单：增强源不该把「只有城市台」伪装成完整频道表。
    if (fetched.isEmpty) {
      final visible = StreamPolicy.apply(withoutShopping(builtIn));
      return LiveCatalogSnapshot(
        channels: sortChannels(visible),
        sourceLabel: '内置清单（${visible.length} 个频道）',
        warnings: warnings,
      );
    }

    var merged = withoutShopping(mergeChannels(builtIn: builtIn, remote: fetched));
    // 候选层收口：拉黑已知占位/反盗链主机（它们能骗过解码门禁），
    // 并补齐站点强制请求头（缺了必 403，补了才 200）。必须在 normalizeStreams
    // 之前：否则占位线路会先占掉「单台封顶」的名额，把真线路挤出去。
    merged = StreamPolicy.apply(merged);
    // 基线也先跑一遍收口，保证「能播的第一屏」本身就是干净、按画质排好的。
    merged = normalizeStreams(merged);
    merged = mergeDuplicateStations(merged);
    return LiveCatalogSnapshot(
      channels: merged,
      sourceLabel: '公开索引（${merged.length} 个频道）',
      warnings: warnings,
    );
  }

  /// **第二阶段（后台增强）**：在基线快照上补齐城市台 / 全网发现源 / 备用源索引。
  ///
  /// 纯增量、可重复调用；任一源失败静默（只有备用源索引会往 warnings 记降级）。
  /// 返回的频道表是「基线 ∪ 增强」，当前正在播的台按 id 保留，不会打断播放。
  Future<LiveCatalogSnapshot> enhanceSnapshot(LiveCatalogSnapshot base) async {
    final warnings = <String>[...base.warnings];
    final indexUrls = <String>{
      if (streamIndexUrl != null) streamIndexUrl!,
      ...streamIndexUrls,
    }.toList(growable: false);

    // 备用源索引与「发现/城市源」**并发**拉取：总耗时约等于最慢的一份，而不是相加。
    final streamsFuture = _fetchFirstStreamIndex(indexUrls, warnings);

    // 城市台补充索引 + 全网发现源都是「可选增强」：失败静默，绝不因为
    // 某个镜像挂了就在 UI 上弹橙色降级提示（那会让用户误以为主信号源坏了）。
    final supplements = await Future.wait(<Future<List<LiveChannel>?>>[
      ...citySupplementUrls.map(_fetchCitySupplement),
      ...discoverySources.map(_fetchDiscovery),
    ]);
    final extra = <LiveChannel>[];
    for (final s in supplements) {
      if (s != null) extra.addAll(s);
    }

    var merged = withoutShopping(mergeChannels(builtIn: base.channels, remote: extra));

    // 用 streams.json 给每个台补备用源（M3U 索引一台一条，同名台常有 4~12 条）。
    final index = await streamsFuture;
    if (index != null && index.isNotEmpty) {
      merged = withBackupStreams(merged, index);
    }

    // 统一收口：删占位线路 / 补站点请求头 → 按地址去重 → 高清排前 →
    // 单台线路封顶 → 同名站点合并兜底。
    merged = StreamPolicy.apply(merged);
    merged = normalizeStreams(merged);
    merged = mergeDuplicateStations(merged);

    // 备用源覆盖率写进来源说明而不是 warnings（覆盖率是正常信息，不是降级）。
    final withMulti = merged.where((c) => c.streams.length >= 2).length;
    final withHd = merged.where((c) => c.streams.any(isHdStream)).length;
    return LiveCatalogSnapshot(
      channels: merged,
      sourceLabel: '全网索引 + 内置（${merged.length} 个频道 · '
          '$withMulti 个台有备用源 · $withHd 个台有高清线路）',
      warnings: warnings,
    );
  }

  /// 按序尝试多份备用源索引，第一份成功即返回。
  ///
  /// streams.json 有 3.8 MB，不该把多份镜像都拉一遍；失败（含损坏）就顺延下一份，
  /// 全失败返回 null（备用源只是优化项，不影响基线频道表）。
  Future<Map<String, List<LiveStream>>?> _fetchFirstStreamIndex(
    List<String> urls,
    List<String> warnings,
  ) async {
    for (final url in urls) {
      final index = await _fetchStreamIndex(url, warnings);
      if (index != null && index.isNotEmpty) return index;
    }
    return null;
  }

  /// 一次性装载（基线 + 增强）。工具与回归用它拿完整频道表；
  /// 首屏播放走 [loadBase] + 后台 [enhanceSnapshot]，不要在这里等齐全部网络。
  Future<LiveCatalogSnapshot> load({bool remote = true}) async {
    final base = await loadBase(remote: remote);
    // 内置回退或关闭远端时没有可增强的基线，保持原样。
    if (!remote || base.channels.isEmpty) return base;
    if (base.sourceLabel.startsWith('内置清单')) return base;
    return enhanceSnapshot(base);
  }

  /// 拉一份索引并解析；失败返回 null 并写一条降级说明（不抛异常）。
  Future<List<LiveChannel>?> _fetchPlaylist(String url, List<String> warnings) async {
    try {
      // 先直连；只有失败才走系统代理。注入客户端时只试一次，避免同一台测试服务器被打两次。
      var text = await _fetchText(url, useProxy: false);
      if (text == null && httpClientFactory == null) {
        text = await _fetchText(url, useProxy: true);
      }
      if (text == null) {
        // 证书失败与「网络不通」必须分开说：前者重试无意义（乐视专项要求）。
        warnings.add(tlsFailed(url)
            ? '索引证书握手失败：${_hostOf(url)}（该源需要较新证书，换网络无效）'
            : '索引不可达：${_hostOf(url)}');
        return null;
      }
      final parsed = parseM3U(text);
      if (parsed.isEmpty) {
        warnings.add('索引无可用频道：${_hostOf(url)}');
        return null;
      }
      return parsed;
    } catch (e) {
      warnings.add('索引解析失败：${_hostOf(url)}（${_shortError(e)}）');
      return null;
    }
  }

  /// 拉城市台补充索引，并把结果收窄到「台名能推断出城市」的条目。
  ///
  /// 这份公开表有 1600+ 条，绝大多数是央视/卫视的重复线路和省级台；
  /// 全量并入会把首屏线路探测窗口挤满死链。所以只留城市台，
  /// 输出量级从 ~1600 降到 ~百级，安全边界没有变宽。
  ///
  /// 另一处坑：城市台在这份表里排得很靠后（实测苏州在第 1448 行、
  /// 第 600 条 `#EXTINF` 之后），沿用默认 600 条上限会把它们全截掉。
  /// 因此这里放宽扫描上限，但用 `cityOnly` 约束输出集合。
  Future<List<LiveChannel>?> _fetchCitySupplement(String url) async {
    try {
      var text = await _fetchText(url, useProxy: false, timeout: enhancedTimeout);
      if (text == null && httpClientFactory == null) {
        text = await _fetchText(url, useProxy: true, timeout: enhancedTimeout);
      }
      if (text == null) return null;
      final parsed = parseM3U(text, channelLimit: maxLines, cityOnly: true);
      return parsed.isEmpty ? null : parsed;
    } catch (_) {
      // 补充源是纯增强：任何异常都静默跳过，不写 warnings、不打断开播。
      return null;
    }
  }

  /// 拉一份「全网发现源」，并按描述符收窄输出。
  ///
  /// 与城市台补充一样是纯增强：任何异常（含格式不支持、主机不可达）都静默
  /// 返回 null，不写 warning、不打断首屏。
  Future<List<LiveChannel>?> _fetchDiscovery(LiveSourceDescriptor source) async {
    // 正式装配只允许 https（见 isWellFormed）；注入 HttpClient 的回归场景
    // 允许本机 http，否则没法用本地 HttpServer 端到端验证全网检索链路。
    if (!source.isWellFormed && httpClientFactory == null) return null;
    final uri = Uri.tryParse(source.url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    try {
      var text = await _fetchText(
        source.url,
        useProxy: false,
        maxBytes: source.maxBytes ?? maxPlaylistBytes,
        timeout: enhancedTimeout,
      );
      if (text == null && httpClientFactory == null) {
        text = await _fetchText(
          source.url,
          useProxy: true,
          maxBytes: source.maxBytes ?? maxPlaylistBytes,
          timeout: enhancedTimeout,
        );
      }
      if (text == null) return null;

      final scanLines = source.scanLines ?? maxLines;
      final narrowed = source.scope != LiveSourceScope.all;
      // 收窄型源必须扫到文件末尾（苏州在聚合表第 1448 行、全球总索引第 2 万行），
      // 用 600 条默认上界会把它们全截掉；被过滤掉的条目不占额度。
      final channelLimit =
          source.channelLimit ?? (narrowed ? scanLines : maxChannels);
      final List<LiveChannel> parsed;
      if (source.format == LiveSourceFormat.nameUrl) {
        parsed = parseNameUrl(
          text,
          channelLimit: channelLimit,
          cityOnly: source.scope == LiveSourceScope.cityOnly,
          nationalOnly: source.scope == LiveSourceScope.nationalOnly,
          chinaOnly: source.scope == LiveSourceScope.chinaOnly,
          hdOnly: source.scope == LiveSourceScope.hdOnly,
        );
      } else {
        parsed = parseM3U(
          text,
          channelLimit: channelLimit,
          scanLines: scanLines,
          cityOnly: source.scope == LiveSourceScope.cityOnly,
          nationalOnly: source.scope == LiveSourceScope.nationalOnly,
          chinaOnly: source.scope == LiveSourceScope.chinaOnly,
          hdOnly: source.scope == LiveSourceScope.hdOnly,
        );
      }
      return parsed.isEmpty ? null : parsed;
    } catch (_) {
      return null;
    }
  }

  static String _hostOf(String url) => Uri.tryParse(url)?.host ?? url;

  static String _shortError(Object e) {
    final s = e.toString();
    return s.length <= 48 ? s : '${s.substring(0, 48)}…';
  }

  /// 拉取文本，超时/非 200/超限都返回 null（由调用方决定是否降级）。
  ///
  /// [useProxy] 决定是否走系统代理。公开索引是 CDN 静态文件，**直连往往比代理稳**：
  /// 实测本机走系统代理会被中转成 502，而 `--noproxy` 直连拿得到 200/31KB。
  /// 所以调用方先试直连，失败再退回代理（企业网里往往反过来，两种都要顾到）。
  /// 记录「TLS 握手失败过」的主机。
  ///
  /// 单独记一份而不是只写一句 warning：内置清单/索引里的地址在播放阶段还会
  /// 再被拉一次，那时拿不到这里的 warning 文本。有了这份集合，播放失败时
  /// 就能区分「网络不通」和「证书太旧」——后者换网络重试一百次也没用。
  final Set<String> _tlsFailedHosts = <String>{};

  /// 该地址的主机是否发生过 TLS 握手失败。
  bool tlsFailed(String url) => _tlsFailedHosts.contains(_hostOf(url));

  /// 清空 TLS 失败记录（每次重新装载频道表时调用，避免陈旧结论误导用户）。
  void resetTlsFailures() => _tlsFailedHosts.clear();

  Future<String?> _fetchText(
    String url, {
    required bool useProxy,
    int maxBytes = maxPlaylistBytes,
    Duration? timeout,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    // 注入的客户端由调用方完全掌控（回归脚本用它把请求指到本机 HttpServer，
    // 并强制 DIRECT —— 本机回环不能被系统代理接管，否则测试会被转成 502）。
    final t = timeout ?? remoteTimeout;
    final client = httpClientFactory?.call() ??
        (HttpClient()
          ..findProxy = useProxy
              ? HttpClient.findProxyFromEnvironment
              : ((_) => 'DIRECT'));
    client.connectionTimeout = t;
    try {
      final request = await client.getUrl(uri).timeout(t);
      request.headers.set(HttpHeaders.userAgentHeader, 'shunbo/1.0');
      final response = await request.close().timeout(t);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(remoteTimeout)) {
        bytes.addAll(chunk);
        if (bytes.length > maxBytes) break;
      }
      return utf8.decode(bytes, allowMalformed: true);
    } on TimeoutException {
      return null;
    } on SocketException {
      return null;
    } on HandshakeException {
      _tlsFailedHosts.add(_hostOf(url));
      return null;
    } on HttpException {
      return null;
    } finally {
      // HttpClient 必须关：残留连接会挂住 Dart 进程（本项目已经踩过一次）。
      client.close(force: true);
    }
  }

  /// 探测一条直播线路是否「真的在吐流」。
  ///
  /// 只看 HTTP 状态 + 能否读到第一个数据块，**不解析播放列表内容**：
  /// 目的是在开播前几秒内把死地址筛掉，而不是做完整的流校验。
  /// 读到一个块就立刻断开，流量开销可以忽略。
  ///
  /// [headers] 必须是该线路自己声明的请求头（M3U 的 `http-referer` /
  /// `http-user-agent`，streams.json 的 `referrer` / `user_agent`）。
  ///
  /// **这是「央视/卫视播不了」最早的根因之一**：探测只带 `shunbo/1.0`，
  /// 而播放阶段带了线路声明的 `Referer`。对需要防盗链的源站，探测算出的
  /// 结果是「403 / 无响应」，调用方立即 `markDead` + `return false`，
  /// **`player.load` 根本没被调用过** —— 一条本来能播的线路被自己的探测判死，
  /// 而且会被写进失效表，10 分钟内不再重试。探测与播放必须用同一套请求头，
  /// 否则「探测通过」与「能播」就不再是同一件事。
  Future<bool> probe(
    String url, {
    Duration timeout = const Duration(seconds: 3),
    Map<String, String> headers = const <String, String>{},
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return false;
    }
    final client = httpClientFactory?.call() ??
        (HttpClient()..findProxy = ((_) => 'DIRECT'));
    client.connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      applyStreamHeaders(request, headers);
      final response = await request.close().timeout(timeout);
      final ok = response.statusCode >= 200 && response.statusCode < 400;
      if (!ok) {
        await response.drain<void>();
        return false;
      }
      // 能读到第一个块才算数：有些镜像会先回 200 再挂住不吐数据。
      await response.timeout(timeout).first;
      return true;
    } on HandshakeException {
      _tlsFailedHosts.add(_hostOf(url));
      return false;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// 把线路声明的请求头写进探测请求。
  ///
  /// 只放行 UA / Referer / Origin / Cookie / Authorization 这几个真的会影响
  /// 授权判定的字段：M3U 里的属性来自不可信远端，不能让它顺手把
  /// `Host` / `Range` / `Connection` 这类传输层字段改掉（改 `Host` 等于
  /// 让请求打到别的虚拟主机，探测结果与播放结果差异会变成无法解释的谜）。
  static const Set<String> _forwardableHeaders = <String>{
    'user-agent',
    'referer',
    'origin',
    'cookie',
    'authorization',
  };

  static final Map<String, String> _headerNameCache = <String, String>{};

  static void applyStreamHeaders(
    HttpClientRequest request,
    Map<String, String> headers,
  ) {
    // 默认 UA 先落地：线路没声明 UA 时保持与播放阶段一致。
    request.headers.set(HttpHeaders.userAgentHeader, 'shunbo/1.0');
    for (final entry in headers.entries) {
      final lower = entry.key.toLowerCase();
      if (!_forwardableHeaders.contains(lower)) continue;
      if (entry.value.isEmpty) continue;
      // 逐字符检查：请求头的值里出现 CR/LF 就是请求头注入，
      // 远端列表可以因此把任意内容塞进我们的请求。
      if (entry.value.contains('\r') || entry.value.contains('\n')) continue;
      // 用规范化后的名字，避免 `referer` 与 `Referer` 被 HttpClient 当成两项。
      final name = _headerNameCache.putIfAbsent(
        lower,
        () => lower.split('-').map((p) => p.isEmpty ? p : '${p[0].toUpperCase()}${p.substring(1)}').join('-'),
      );
      request.headers.set(name, entry.value);
    }
  }

  /// 解析 M3U / M3U8 频道表。
  ///
  /// 只认 `#EXTINF` 行的 `group-title` / `tvg-name` / `tvg-logo` 与紧随其后的 URL 行；
  /// 其它扩展标签一律忽略（`#EXTVLCOPT` 之类可能携带本地文件或脚本路径，不该执行）。
  ///
  /// [channelLimit] 默认 [maxChannels]，是「输出条目」的安全上界；
  /// [scanLines] 是「扫描行数」上界（全球总索引 2.3 万行，默认 2 万行会漏掉尾部）。
  /// [cityOnly] / [chinaOnly] / [hdOnly] 都是**过滤在计数之前**的收窄条件，
  /// 被丢掉的条目不占额度——否则苏州台（排在聚合表第 1448 行）永远扫不到。
  static List<LiveChannel> parseM3U(
    String text, {
    int channelLimit = maxChannels,
    int scanLines = maxLines,
    bool cityOnly = false,
    bool nationalOnly = false,
    bool chinaOnly = false,
    bool hdOnly = false,
  }) {
    if (scanLines <= 0 || channelLimit <= 0) return const <LiveChannel>[];
    final lines = const LineSplitter().convert(text);
    final limit = lines.length > scanLines ? scanLines : lines.length;
    final out = <LiveChannel>[];

    String? pendingName;
    String? pendingGroup;
    var pendingAttrs = const <String, String>{};

    for (var i = 0; i < limit; i++) {
      final raw = lines[i].trim();
      if (raw.isEmpty) continue;

      if (raw.toUpperCase().startsWith('#EXTINF')) {
        final commaAt = raw.lastIndexOf(',');
        pendingName =
            commaAt >= 0 && commaAt + 1 < raw.length ? raw.substring(commaAt + 1).trim() : null;
        pendingAttrs = _parseAttributes(raw);
        final group = pendingAttrs['group-title']?.trim();
        pendingGroup = (group == null || group.isEmpty) ? null : group;
        continue;
      }
      if (raw.startsWith('#')) continue;

      // 到这里这一行是地址；没有配对的 #EXTINF 就跳过（裸 URL 无法命名）。
      final original = pendingName;
      if (original == null || original.isEmpty) {
        pendingName = null;
        continue;
      }
      pendingName = null;
      if (!isAcceptableStreamUrl(raw)) continue;

      // 购物台整体剔除：连频道对象都不建，避免它占掉 600 条上限的额度，
      // 也避免用户在某些分组里仍能看到它（过滤是「从频道列表移除」而不是仅隐藏）。
      if (isShoppingChannel(original, pendingGroup)) {
        pendingAttrs = const <String, String>{};
        pendingGroup = null;
        continue;
      }

      // 台名先规范化再去重：索引里同一个台常以「CCTV-1 (720p)」「CCTV-1 HD (1080p)」
      // 「CCTV-1」三条出现，直接按原始名建频道会让用户在列表里看到三个 CCTV-1，
      // 而且每个只有一条线路——「画质与线路切换」就无从谈起。
      // 规范化后它们合并成一个台、三条线路，线路按画质分排序。
      final canonical = canonicalName(original);
      // 英文卫视名归一成中文标准名后，与国内索引里的「XX卫视」算出同一个 id，
      // 两条索引的线路因此合并到同一个台——卫视频道不再是空的。
      final satellite = satelliteNameOf(canonical);
      final name = satellite ?? canonical;
      final tvgId = normalizeTvgId(pendingAttrs['tvg-id']);
      final baseRank = qualityRankOf(original, remoteGroup: pendingGroup);
      // IPv6 直连地址在纯 IPv4 网络下必死：把它排到本台线路最后，
      // 优先走 IPv4 线路；本台只有 IPv6 一条时也至少不会被「高清优先」顶到前面。
      final isIpv6 = _isIpv6Host(raw);
      final rank = isIpv6 ? baseRank - 1000 : baseRank;
      // 收窄条件全部放在计数之前：被丢掉的条目不占额度。
      // 城市台补充：只让「苏州新闻综合」「青岛 QTV-1」这类能定位到城市的
      // 条目过关。央视/卫视/省级台在这个模式下全部丢弃，避免重复线路灌进来。
      if (cityOnly && CityDirectory.inferCity(name, tvgId: tvgId) == null) {
        pendingAttrs = const <String, String>{};
        pendingGroup = null;
        continue;
      }
      // 国家级台专收：央视（CCTV / CGTN / CETV）与卫视。
      // 判定**只看台名**（remoteGroup 传 null）：聚合表里 `group-title` 是
      // `📺央视频道` 这类带表情的展示分组，不能让它决定归属；而台名能稳定判定。
      // 这是「央视频道整批无源」的补强：iptv-org 目录里 CCTV-1..17 几乎全部
      // 挂在同一批境外中转 IP 上，一旦那批 IP 抽风就一个台都放不出来，
      // 而聚合表（每日测速）里的央视线路正好是另一批。
      if (nationalOnly) {
        final g = explicitGroupOf(name, null);
        if (g != '央视频道' && g != '卫视频道') {
          pendingAttrs = const <String, String>{};
          pendingGroup = null;
          continue;
        }
      }
      // 全球总索引：只留中国相关条目（tvg-id 以 .cn 结尾 / 台名或分组含汉字），
      // 否则 1.1 万条境外频道会把央视卫视挤出首屏、占满探测窗口。
      if (chinaOnly && !isChineseEntry(name, tvgId, pendingGroup)) {
        pendingAttrs = const <String, String>{};
        pendingGroup = null;
        continue;
      }
      // 高清专表：只收 720p 及以上。
      if (hdOnly && rank < hdQualityThreshold) {
        pendingAttrs = const <String, String>{};
        pendingGroup = null;
        continue;
      }
      if (out.length >= channelLimit) break;
      final headers = _headersOf(pendingAttrs);
      // 来源归属 + 分类策略一次性算完：主分类决定频道归哪一栏，
      // 叠加分类决定它同时出现在「新闻 / 少儿 / 体育」等哪几栏。
      final tax = ChannelTaxonomy.resolve(
        name,
        remoteGroup: pendingGroup,
        tvgId: tvgId,
        // 原始台名里带着栏目线索（`CCTV-13 新闻`），归一后就没了。
        originalName: original,
      );
      final group = tax.primary;
      // 身份用的分组比展示分组更细：分组是**兜底猜出来的**时，
      // 身份里保留原值——否则 `A组/同名台` 与 `B组/同名台` 都会被归到
      // 「地方频道」而撞同一个 id，合并后用户点 A 组播的可能是 B 组那条流。
      // 卫视归一例外：英文台名已折算成唯一中文台名，必须与中文索引合并成多线路。
      final identity = (satellite == null &&
              explicitGroupOf(name, pendingGroup) == null &&
              pendingGroup != null &&
              pendingGroup.trim().isNotEmpty)
          ? pendingGroup.trim()
          : group;
      out.add(LiveChannel(
        id: channelIdFor(name, identity),
        name: name,
        group: group,
        categories: tax.categories,
        badge: _badgeOf(name),
        tvgId: tvgId,
        streams: <LiveStream>[
          LiveStream(
            url: raw,
            // 线路名保留原始写法（含分辨率），用户才能分清「这条是 720p 还是 1080p」。
            label: original == name ? '索引线路' : original,
            qualityRank: rank,
            headers: headers,
          ),
        ],
      ));
      pendingAttrs = const <String, String>{};
      pendingGroup = null;
    }
    return out;
  }

  /// 解析国内聚合表常见的 `台名,地址` 纯文本（`#genre#` 行分节）。
  ///
  /// 为什么要单独支持这种格式：`Guovin/iptv-api` 同时输出 `result.m3u` 与
  /// `result.txt`，后者是苏州台的第二份独立来源（M3U 解析规则变动时仍能拿到）。
  /// 它是**不可信文本**：分节行 / 注释 / 超长行 / 非 http 地址一律丢弃，
  /// 且同样支持 cityOnly / chinaOnly / hdOnly 收窄（过滤在计数之前）。
  static List<LiveChannel> parseNameUrl(
    String text, {
    int channelLimit = maxChannels,
    int scanLines = maxLines,
    bool cityOnly = false,
    bool nationalOnly = false,
    bool chinaOnly = false,
    bool hdOnly = false,
  }) {
    if (scanLines <= 0 || channelLimit <= 0) return const <LiveChannel>[];
    final lines = const LineSplitter().convert(text);
    final limit = lines.length > scanLines ? scanLines : lines.length;
    final out = <LiveChannel>[];
    String? pendingGroup;
    for (var i = 0; i < limit; i++) {
      var line = lines[i].trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith('\uFEFF')) line = line.substring(1).trim();
      final comma = line.indexOf(',');
      if (comma <= 0 || comma + 1 >= line.length) continue;
      final original = line.substring(0, comma).trim();
      final tail = line.substring(comma + 1).trim();
      // `🕘️更新时间,#genre#` / `☘️江苏频道,#genre#` 是分节标题：
      // 记住分组名，后面的城市台才能归到「地方频道」而不是「其它频道」。
      if (tail == '#genre#') {
        pendingGroup = original.isEmpty ? null : original;
        continue;
      }
      if (!isAcceptableStreamUrl(tail)) continue;
      if (original.isEmpty || original.length > 64) continue;
      // `2026-08-27 14:06:22,http://...` 是聚合表写在「更新时间」分节里的
      // 时间戳元信息，不是台名；留着会在频道栏多出一条日期频道。
      if (RegExp(r'^\d{4}[-/]\d{1,2}[-/]\d{1,2}').hasMatch(original)) continue;
      if (isShoppingChannel(original, pendingGroup)) continue;

      final canonical = canonicalName(original);
      final satellite = satelliteNameOf(canonical);
      final name = satellite ?? canonical;
      final baseRank = qualityRankOf(original, remoteGroup: pendingGroup);
      final isIpv6 = _isIpv6Host(tail);
      final rank = isIpv6 ? baseRank - 1000 : baseRank;
      if (cityOnly && CityDirectory.inferCity(name) == null) continue;
      if (nationalOnly) {
        // 与 [parseM3U] 同一条规则：只看台名判定国家级归属。
        final g = explicitGroupOf(name, null);
        if (g != '央视频道' && g != '卫视频道') continue;
      }
      if (chinaOnly && !isChineseEntry(name, null, pendingGroup)) continue;
      if (hdOnly && rank < hdQualityThreshold) continue;
      if (out.length >= channelLimit) break;

      final tax = ChannelTaxonomy.resolve(
        name,
        remoteGroup: pendingGroup,
        tvgId: null,
        originalName: original,
      );
      final group = tax.primary;
      // 与 [parseM3U] 保持同一套身份规则：兜底猜出的分组不当 id 前缀，
      // 避免 `#genre#` 下两个不同分节的同名台被合并成一个频道。
      final identity = (satellite == null &&
              explicitGroupOf(name, pendingGroup) == null &&
              pendingGroup != null &&
              pendingGroup.trim().isNotEmpty)
          ? pendingGroup.trim()
          : group;
      out.add(LiveChannel(
        id: channelIdFor(name, identity),
        name: name,
        group: group,
        categories: tax.categories,
        badge: _badgeOf(name),
        streams: <LiveStream>[
          LiveStream(
            url: tail,
            label: original == name ? '聚合线路' : original,
            qualityRank: rank,
          ),
        ],
      ));
    }
    return out;
  }

  /// 条目是否「中国相关」：给 iptv-org 全球总索引做收窄。
  ///
  /// 只认三个客观信号：tvg-id 以 `.cn` 结尾、台名含汉字、分组含汉字。
  /// 不做「英文名猜省份」这类模糊判断——猜错会把境外频道灌进中文频道表。
  static bool isChineseEntry(String name, String? tvgId, String? remoteGroup) {
    if (tvgId != null && tvgId.toLowerCase().endsWith('.cn')) return true;
    const cjk = r'[\u4e00-\u9fa5]';
    if (RegExp(cjk).hasMatch(name)) return true;
    if (remoteGroup != null && RegExp(cjk).hasMatch(remoteGroup)) return true;
    return false;
  }

  /// 从 `#EXTINF` 属性里取播放必须带的请求头。
  ///
  /// 国内 4K/聚合表普遍用 `http-user-agent` / `http-referer` 标注；
  /// 以前只解析 group-title 与 tvg-id，这些头被丢掉，结果就是
  /// 「探测 200、播放 403」——线路明明存在却放不出来。
  static Map<String, String> _headersOf(Map<String, String> attrs) {
    final out = <String, String>{};
    final ua = attrs['http-user-agent']?.trim();
    final ref = attrs['http-referer']?.trim() ?? attrs['http-referrer']?.trim();
    if (ua != null && ua.isNotEmpty) out['User-Agent'] = ua;
    if (ref != null && ref.isNotEmpty) out['Referer'] = ref;
    return out;
  }

  /// 规范化 `tvg-id`：去掉 `@SD` / `@HD` 这类 feed 后缀。
  ///
  /// 为什么必须去掉：M3U 里同一个台的不同 feed 写成 `CCTV1.cn@SD`、`CCTV1.cn@HD`，
  /// 而 `streams.json` 的 `channel` 字段只有 `CCTV1.cn`。
  /// 不去后缀就一条都对不上，备用源补不进来（表现是「补了但一个台都没多出线路」）。
  static String? normalizeTvgId(String? raw) {
    if (raw == null) return null;
    var v = raw.trim();
    // `at >= 0` 而不是 `> 0`：`@HD` 这种前缀是 feed 而没有基础 id，
    // 截完是空串 → 返回 null。用 `> 0` 会把它原样返回，
    // 于是所有无基础 id 的条目被当成同一个 key `@HD` 合并到一起。
    final at = v.indexOf('@');
    if (at >= 0) v = v.substring(0, at);
    return v.isEmpty ? null : v;
  }

  /// 拉备用源索引，返回 `tvg-id → 线路列表`。
  ///
  /// 失败一律返回 null（调用方按「没有备用源」继续跑）：这只是增强项，
  /// 它挂了不应该影响开播，更不能让首屏等它。
  Future<Map<String, List<LiveStream>>?> _fetchStreamIndex(
    String url,
    List<String> warnings,
  ) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    final client = httpClientFactory?.call() ??
        (HttpClient()..findProxy = ((_) => 'DIRECT'));
    client.connectionTimeout = enhancedTimeout;
    try {
      final request = await client.getUrl(uri).timeout(enhancedTimeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'shunbo/1.0');
      final response = await request.close().timeout(enhancedTimeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        warnings.add('备用源索引不可达：${_hostOf(url)}（HTTP ${response.statusCode}）');
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(remoteTimeout)) {
        bytes.addAll(chunk);
        if (bytes.length > maxStreamIndexBytes) break;
      }
      return parseStreamIndex(utf8.decode(bytes, allowMalformed: true));
    } on TimeoutException {
      warnings.add('备用源索引超时：${_hostOf(url)}');
      return null;
    } on SocketException {
      warnings.add('备用源索引不可达：${_hostOf(url)}');
      return null;
    } catch (e) {
      warnings.add('备用源索引解析失败：${_hostOf(url)}（${_shortError(e)}）');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 解析 `streams.json` 形态的数据（`[{channel, url, quality, user_agent, referrer}, …]`）。
  ///
  /// 按不可信输入处理：非数组 / 元素不是对象 / 字段类型不对，统统跳过该条；
  /// 地址仍过 [isAcceptableStreamUrl]（禁 rtsp、userinfo 等）。
  static Map<String, List<LiveStream>> parseStreamIndex(String json) {
    final out = <String, List<LiveStream>>{};
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return out;
    }
    if (decoded is! List) return out;

    // 去重下标的辅助集合：不能用 `lines.any(...)`，1.8 万条里某个台若有
    // 上千条就会退化成 O(n²)。
    final seenByChannel = <String, Set<String>>{};
    for (final item in decoded) {
      if (item is! Map) continue;
      final channel = normalizeTvgId(item['channel'] is String ? item['channel'] as String : null);
      final url = item['url'] is String ? (item['url'] as String).trim() : null;
      if (channel == null || url == null || url.isEmpty) continue;
      if (!isAcceptableStreamUrl(url)) continue;

      final lines = out.putIfAbsent(channel, () => <LiveStream>[]);
      if (!seenByChannel.putIfAbsent(channel, () => <String>{}).add(url)) continue;

      // 有些源站校验 Referer / UA，索引里已经给了就直接带上；
      // 不带的话这类线路会「探测 200、播放 403」。
      final headers = <String, String>{};
      final ua = item['user_agent'];
      if (ua is String && ua.isNotEmpty) headers['User-Agent'] = ua;
      final ref = item['referrer'];
      if (ref is String && ref.isNotEmpty) headers['Referer'] = ref;

      final quality = item['quality'] is String ? item['quality'] as String : '';
      lines.add(LiveStream(
        url: url,
        label: _backupLabel(quality, url),
        qualityRank: qualityRankOf(quality),
        headers: headers,
      ));
    }
    // **先按画质降序、再截断**：streams.json 里标清条目往往排在 1080p/2160p
    // 前面，旧实现「先到先留 6 条」等于把高清线路整批丢掉——这正是
    // 「高清线路源太少」的一个隐蔽成因。排序用 indexed 保证稳定。
    for (final key in out.keys.toList(growable: false)) {
      final lines = out[key]!;
      if (lines.length <= 1) continue;
      final indexed = lines.indexed.toList()
        ..sort((a, b) {
          final byRank = b.$2.qualityRank.compareTo(a.$2.qualityRank);
          return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
        });
      out[key] = indexed
          .take(maxStreamsPerChannel)
          .map((e) => e.$2)
          .toList(growable: false);
    }
    return out;
  }

  static String _backupLabel(String quality, String url) {
    final host = Uri.tryParse(url)?.host ?? '备用源';
    return quality.isEmpty ? '备用 · $host' : '备用 · $quality · $host';
  }

  /// 把备用源并进频道：只补不替换，按 URL 去重，每台最多 [maxStreamsPerChannel] 条。
  ///
  /// 顺序上把 M3U 里那条放在第一位（它是索引主推的线路），备用源排在后面；
  /// 实际播放顺序由健康度决定，这里只保证「不丢原有线路」。
  static List<LiveChannel> withBackupStreams(
    List<LiveChannel> channels,
    Map<String, List<LiveStream>> index,
  ) {
    final out = <LiveChannel>[];
    for (final c in channels) {
      final id = c.tvgId;
      final extra = id == null ? null : index[id];
      if (extra == null || extra.isEmpty) {
        out.add(c);
        continue;
      }
      final seen = c.streams.map((s) => s.url).toSet();
      final merged = <LiveStream>[...c.streams];
      // 备用源按画质降序补入：额度有限时先保住 1080p/4K，
      // 而不是让先到的标清线路把高清线路挤出去。
      final rankedExtra = extra.indexed.toList()
        ..sort((a, b) {
          final byRank = b.$2.qualityRank.compareTo(a.$2.qualityRank);
          return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
        });
      for (final e in rankedExtra) {
        final s = e.$2;
        if (merged.length >= maxStreamsPerChannel) break;
        if (seen.contains(s.url)) continue;
        seen.add(s.url);
        merged.add(s);
      }
      out.add(merged.length == c.streams.length
          ? c
          : LiveChannel(
              id: c.id,
              name: c.name,
              group: c.group,
              badge: c.badge,
              tvgId: c.tvgId,
              streams: merged,
            ));
    }
    return out;
  }

  /// 台名规范化：去掉分辨率与来源标注，得到「可以拿去当 id、也可以直接展示」的台名。
  ///
  /// 处理形态（都来自真实索引，不是假想）：
  /// - `CCTV-1 (720p)` / `CCTV-1 HD (1080p)` / `CCTV-1` → `CCTV-1`
  /// - `Hunan TV (2160p)` → `Hunan TV`
  /// - `Chuxiong News Channel [Not 24/7]` → `Chuxiong News Channel`
  /// - `CCTV-5+` 保持原样（`+` 是台名的一部分，不能当分隔符吃掉）
  static String canonicalName(String raw) {
    var s = raw.trim();
    // 括号里的分辨率或运营标注：全角/半角括号与方括号都算。
    s = s.replaceAll(RegExp(r'[\(（\[][^\)）\]]{0,24}[\)）\]]'), ' ');
    // 裸分辨率后缀：1080p / 720P / 576i。
    s = s.replaceAll(RegExp(r'\b\d{3,4}[pPiI]\b'), ' ');
    // 独立的画质词：HD / UHD / SD。
    //
    // **刻意不削 4K / 8K**：它们是台名的一部分——`CCTV 4K`（超高清频道）削掉「4K」
    // 就只剩「CCTV」，会和任何叫 CCTV 的条目撞在一起，用户点进去发现台不对。
    // 而 HD/UHD/SD 在中文索引里只作画质标注用（`CCTV-1 HD`），削掉不丢信息。
    s = s.replaceAll(RegExp(r'\b(HD|UHD|SD)\b', caseSensitive: false), ' ');
    // 中文画质后缀（「CCTV-1 高清」「湖南卫视 超清」）必须削掉，否则
    // 同一台的高清线路会被当成另一个频道，用户在列表里看到两个台、
    // 而每个台都只有一条线路——「高清优先」和「换线路」都无从谈起。
    //
    // 只削**结尾**：「高清频道」这类把画质词当台名主体的不动。
    // 4K/8K 刻意不削（见上面说明），它们是独立频道身份。
    s = s.replaceAll(RegExp(r'(超高清|超清|高清|标清|蓝光)\s*$'), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    s = s.replaceAll(RegExp(r'[\s\-_,]+$'), '').trim();
    // `CCTV4` / `CCTV 4` → `CCTV-4`：同一个台的两种写法必须归一，
    // 否则频道栏里出现两个 CCTV-4，数字编号也会跟着分裂。
    s = s.replaceAllMapped(
      RegExp(r'^CCTV\s*(\d{1,2})(?![0-9])', caseSensitive: false),
      (m) => 'CCTV-${m.group(1)}',
    );
    s = _stripCctvProgram(s);
    s = _canonicalEducation(s.isEmpty ? raw.trim() : s);
    // 中文旧台名 → 现行台名（如「上海卫视」→「东方卫视」），归一成同一个台，
    // 避免频道栏双列、数字编号分裂。
    final legacy = legacyStationNames[s];
    return legacy ?? s;
  }

  /// 央视台名里的**栏目后缀**（`CCTV-1 综合` / `CCTV-6 电影`）不算台名的一部分。
  ///
  /// 同一个台在不同索引里写法不同：一份写 `CCTV-1`，另一份写 `CCTV-1综合`。
  /// 不削掉就会在频道栏里看到两个 CCTV-1，各只有一条线路——
  /// 数字编号也会分裂（一个拿 1，另一个只能拿 36），「按 1 跳 CCTV-1」
  /// 就变得不确定。
  ///
  /// 只削**完全等于**已知栏目词的尾巴：`CCTV-4 America` / `CCTV 4K`
  /// 这类带后缀但不是栏目词的写法保持原样（它们本来就是不同的台）。
  static const List<String> kCctvProgramWords = <String>[
    '综合', '财经', '综艺', '国际', '体育', '电影', '电视剧', '纪录', '科教',
    '戏曲', '社会与法', '新闻', '少儿', '音乐', '奥林匹克', '农业农村',
    '国防农业', '军事',
  ];

  static String _stripCctvProgram(String s) {
    final m = RegExp(r'^(CCTV[- ]?\d{1,2}[+＋]?)\s*(.*)$', caseSensitive: false)
        .firstMatch(s.trim());
    if (m == null) return s;
    var tail = (m.group(2) ?? '').trim();
    if (tail.endsWith('频道')) {
      tail = tail.substring(0, tail.length - 2).trim();
    }
    if (!kCctvProgramWords.contains(tail)) return s;
    return m.group(1)!;
  }

  /// 中国教育电视台（CETV）的台名归一。
  ///
  /// `CETV-1`（iptv-org 中国目录的写法）与 `中国教育1台`（国内聚合表的写法）
  /// 指的是**同一个台**。不归一，频道栏里就会出现两个教育台、各自只有一条线路，
  /// 「换线路 / 高清优先」都无从谈起。
  ///
  /// 归一后统一叫 `中国教育N台`，四个台合并成四个频道——
  /// 它们是**国家级教育台**，与 CCTV 同属央视频道（见 [explicitGroupOf]）。
  static String _canonicalEducation(String s) {
    final m = RegExp(
      r'^(?:cetv|中国教育(?:电视台)?)\s*[-_]?\s*([1-4])\s*(?:台|频道)?$',
      caseSensitive: false,
    ).firstMatch(s.trim());
    if (m == null) return s;
    return '中国教育${m.group(1)}台';
  }

  /// 从原始写法里读画质等级（0..100）。
  ///
  /// 用途：同一个台的多条线路要能「按画质优先」排序（[LiveChannel.orderedStreams]），
  /// 用户在 UI 里也能看到「高清/标清」的实际差别。
  /// 未知分辨率给 60，落在 720p 与 576p 之间：不硬挤到最低档，
  /// 否则大量没标分辨率的线路会被排到确认可用的低码率线路后面。
  ///
  /// 全网检索扩到中文聚合表后，光认 `1080p` 这种英文分辨率会漏掉一大半高清源：
  /// 它们只写「高清」「超清」「蓝光」「4K」，或者干脆把画质标在 group-title 上
  /// （`4K8K频道` / `高清频道`）。补上这些写法，高清线路数量才真的多起来。
  static int qualityRankOf(String raw, {String? remoteGroup}) {
    final s = raw.toLowerCase();
    final g = (remoteGroup ?? '').toLowerCase();
    // 4K / 8K / 超高清。
    if (s.contains('4320p') || s.contains('8k') ||
        s.contains('2160p') || s.contains('4k') ||
        s.contains('uhd') || s.contains('超高清') || s.contains('超清')) {
      return 100;
    }
    // 1080 / 全高清 / 中文「高清」。
    if (s.contains('1080p') || s.contains('1080i') ||
        s.contains('fhd') || s.contains('蓝光') || s.contains('高清')) {
      return 90;
    }
    if (s.contains('720p') || s.contains('720i') ||
        RegExp(r'(^|[^a-z])hd([^a-z]|$)').hasMatch(s)) {
      return 70;
    }
    if (s.contains('576p') || s.contains('576i')) return 50;
    if (s.contains('480p') || s.contains('360p') ||
        s.contains('标清') || RegExp(r'(^|[^a-z])sd([^a-z]|$)').hasMatch(s)) {
      return 40;
    }
    // 台名没标但分组标了：`4K8K频道` / `高清频道` 这类国内聚合表很常见。
    if (g.contains('4k') || g.contains('8k') || g.contains('超高清')) return 100;
    if (g.contains('高清') || g.contains('1080') || g.contains('超清')) return 90;
    return 60;
  }

  /// 远端索引的英文分组 → 本项目的分组。
  ///
  /// 为什么要映射而不是直接沿用：公开索引的分组是 iptv-org 按**内容类型**打的
  /// （General / News / Movies…），中文用户看到「General」「Undefined」既陌生又
  /// 分不清「哪个是央视」。而且它的 General 里混着央视和地方台，
  /// 央视和地方台必须分开，否则「央视优先」的排序和分类 chip 全乱。
  static const Map<String, String> _groupByRemote = <String, String>{
    'general': '地方频道',
    'news': '新闻',
    'sports': '体育',
    'movies': '影视',
    'documentary': '纪实',
    'kids': '少儿',
    'animation': '少儿',
    'family': '少儿',
    'shop': '购物',
    'lifestyle': '生活',
    'education': '生活',
    'culture': '生活',
    'music': '生活',
    'entertainment': '生活',
    'business': '生活',
    'weather': '生活',
    'science': '生活',
  };

  /// 由**明确规则**推断出的分组；`null` 表示只能走兜底推断。
  ///
  /// 顺序不能反：索引里 `CCTV-7 (720p)` 的 group-title 是 `Education`、
  /// `CCTV-9` 是 `Documentary`、`CCTV-12` 是 `Lifestyle`——按内容分类，
  /// 于是「央视」这一栏会被拆成十几份。中文直播软件的惯例是**按台归属分类**，
  /// 所以台名能判定归属时一律以台名为准。
  ///
  /// 单独抽出这个方法还有一个用途：[parseM3U] 计算频道 id 时需要知道
  /// 这次分组是不是「猜出来的」。猜出来的分组不能拿来当 id 前缀，否则
  /// `A组/同名台` 与 `B组/同名台` 都会被兜底成「地方频道」而撞同一个 id。
  static String? explicitGroupOf(String name, String? remoteGroup) {
    final n = name.toLowerCase();
    if (RegExp(r'(^|[^a-z])(cctv|cgtn|cetv)').hasMatch(n)) return '央视频道';
    // 中国教育电视台（CETV）是**国家级教育台**，属于央视体系。
    // 公开索引里它被挂在「卫视频道」下（`中国教育1台`），但把它算成卫视
    // 会让「央视频道」少四个台、也会让卫视栏多四个不该在那儿的台。
    if (name.contains('中国教育') || name.contains('教育电视台')) {
      return '央视频道';
    }
    if (name.contains('卫视')) return '卫视频道';
    if (remoteGroup != null) {
      // 多标签形如 "Animation;Kids"：取第一个能映射的。
      for (final part in remoteGroup.split(';')) {
        final key = part.trim().toLowerCase();
        final mapped = _groupByRemote[key] ?? _chineseGroupOf(part.trim());
        if (mapped != null) return mapped;
      }
    }
    return null;
  }

  /// 推断频道分组：**来源归属优先，内容分类只在该分类允许该来源时生效**。
  ///
  /// 规则集中在 [ChannelTaxonomy]（一份可被回归逐条断言的配置）：
  /// * 来源=央视 → 「央视频道」；来源=卫视 → 「卫视频道」；来源=地方 → 「地方频道」；
  /// * 来源=全网其它视频源 → 默认「其它频道」，只有内容分类是「纪实」时
  ///   才归「纪实」（纪实这一类明确收录央视 + 全网其它视频源）。
  ///
  /// 内容分类（新闻 / 体育 / 少儿 / 影视 / 生活）是**叠加**分类：一个
  /// 「苏州新闻综合」既是「地方频道」也是「新闻」，在频道栏里两个分类都能看到它。
  /// 判定顺序见 [ChannelTaxonomy.thematicOf]。
  static String inferGroup(
    String name,
    String? remoteGroup, {
    String? tvgId,
  }) {
    // 购物台是「剔除标记」：目录层据此把它整条去掉（连频道对象都不建），
    // 不是一种展示分类，所以这里单独短路返回。
    if (remoteGroup != null && remoteGroup.contains('购物')) return '购物';
    return ChannelTaxonomy.resolve(
      name,
      remoteGroup: remoteGroup,
      tvgId: tvgId,
    ).primary;
  }

  /// 该台所属的**全部分类**（主分类 + 叠加的内容分类）。
  ///
  /// 分类栏过滤用的是这个集合而不是主分类：
  /// 「苏州新闻综合」的主分类是「地方频道」，同时也是「新闻」，
  /// 两个分类栏里都要能看到它。
  static List<String> categoriesOf(
    String name,
    String? remoteGroup, {
    String? tvgId,
    String? originalName,
  }) {
    return ChannelTaxonomy.resolve(
      name,
      remoteGroup: remoteGroup,
      tvgId: tvgId,
      originalName: originalName,
    ).categories;
  }

  /// 中文 `group-title` → 本项目的分组。
  ///
  /// 国内索引直接写「央视频道 / 卫视频道 / 浙江频道 / 内蒙频道」，
  /// 而 [_groupByRemote] 只认 iptv-org 的英文分类。少了这层，
  /// 这 82 个台会全部掉进「其它频道」，卫视与地方频道两栏仍然是空的。
  /// 「XX频道」这种省级栏目统一归「地方频道」，城市归属再由
  /// `LiveRegion.CityDirectory` 从台名推断。
  static String? _chineseGroupOf(String raw) {
    final g = raw.trim();
    if (g.isEmpty) return null;
    if (g.contains('购物')) return '购物';
    if (g == '央视频道' || g == '央视') return '央视频道';
    if (g == '卫视频道' || g == '卫视') return '卫视频道';
    if (g == '地方频道' || g == '地方台') return '地方频道';
    if (g.contains('少儿') || g.contains('卡通') || g.contains('动画')) {
      return '少儿';
    }
    if (g.contains('新闻')) return '新闻';
    if (g.contains('体育')) return '体育';
    if (g.contains('影视') || g.contains('电影') || g.contains('电视剧')) {
      return '影视';
    }
    if (g.contains('纪实') || g.contains('纪录')) return '纪实';
    if (g.contains('生活') || g.contains('综艺') || g.contains('娱乐')) {
      return '生活';
    }
    if (g.contains('其它') || g.contains('其他')) return '其它频道';
    // 「浙江频道」「内蒙频道」「江苏频道」这类省级/地市栏目。
    if (g.endsWith('频道')) return '地方频道';
    return null;
  }

  static final RegExp _attrPattern = RegExp(r'([A-Za-z0-9_-]+)="([^"]*)"');

  static Map<String, String> _parseAttributes(String line) {
    final map = <String, String>{};
    for (final m in _attrPattern.allMatches(line)) {
      final key = m.group(1);
      final value = m.group(2);
      if (key != null && value != null) map[key.toLowerCase()] = value;
    }
    return map;
  }

  /// 频道 id：**分组名 + 台名**双归一化。
  ///
  /// **必须是 public**：内置清单与远端解析必须用同一套规则，
  /// 否则同一个台会因为「内置写死常量、远端算出来另一串」而合并失败，
  /// 用户看到的是频道列表里 CCTV-1 出现两次。
  ///
  /// 分组前缀用**分组名本身**而不是分组排序号：排序号对未知分组会统统退化成
  /// 同一个值，于是「A组/同名台」和「B组/同名台」会被误判成同一个频道。
  static String channelIdFor(String name, String group) =>
      '${_normalize(group)}:${_normalize(name)}';

  static String _normalize(String raw) => raw
      .toLowerCase()
      // `+` 必须先换成字母再归一化：`CCTV+ 1`（央视国际的付费频道）与
      // `CCTV-1`（综合频道）是完全不同的两个台，而标点会被下面的规则统统吃掉，
      // 不特判就会合并成同一个台，用户点 CCTV-1 结果播的是外语频道。
      .replaceAll('+', 'plus')
      .replaceAll(RegExp(r'[\s\-_·・]+'), '')
      .replaceAll(RegExp(r'[^\w\u4e00-\u9fa5]'), '');

  /// 台标文字：去掉「高清」「HD」「频道」这类后缀，最多留 4 个字符。
  static String _badgeOf(String name) {
    var s = name
        .replaceAll(RegExp(r'(高清|超清|标清|蓝光|HD|UHD|SD|\d{3,4}[Pp])'), '')
        .trim();
    if (s.isEmpty) s = name;

    // 央视台只留**频道号**：台名截前 4 个字的话，CCTV-1 到 CCTV-17 会全部变成
    // 「CCTV」，用户在频道栏里一眼分不出是哪个台（本项目实测过，整列台标一样）。
    // 只留号码（`1`、`13`、`5+`、`4K`）才真正有区分度。
    final cctv = RegExp(r'^CCTV[- ]?(\S+)$', caseSensitive: false).firstMatch(s);
    if (cctv != null) {
      final tail = cctv.group(1)!;
      // 纯号码、带 + 或 4K/8K 这类后缀直接用；Billiards / Health 这类长名字
      // 塞不进 44px 的方块，退回通用台标。
      if (RegExp(r'^\d{1,2}[+\w]{0,2}$').hasMatch(tail)) return tail;
      return 'CCTV';
    }
    // 结尾带号码的中文台名（`中国教育1台` / `百事通体育1`）：台标取
    // 「前缀末两字 + 号码」。否则四个教育台共用同一个「中国教育」台标，
    // 频道栏里一列台标完全一样，用户分不出是哪个台——这与央视台标
    // 只留频道号是同一个问题。
    final numbered = RegExp(r'^(.*?)(\d{1,2})台?$').firstMatch(s);
    if (numbered != null) {
      final prefix = numbered.group(1)!;
      final digits = numbered.group(2)!;
      if (prefix.length >= 2) {
        return '${prefix.substring(prefix.length - 2)}$digits';
      }
    }
    return s.length <= 4 ? s : s.substring(0, 4);
  }

  /// 合并内置与远端：**内置台的线路优先**（它们是验证过形态的直链），
  /// 远端只用来补频道与补线路，不会把内置台挤掉。
  static List<LiveChannel> mergeChannels({
    required List<LiveChannel> builtIn,
    required List<LiveChannel> remote,
  }) {
    final byId = <String, LiveChannel>{};
    for (final c in builtIn) {
      byId[c.id] = c;
    }
    for (final c in remote) {
      final existing = byId[c.id];
      if (existing == null) {
        byId[c.id] = c;
        continue;
      }
      // 同名频道：把远端线路并进来（去重），保留内置台名与分组。
      final seen = existing.streams.map((s) => s.url).toSet();
      final extra = c.streams.where((s) => !seen.contains(s.url)).toList();
      if (extra.isEmpty) continue;
      byId[c.id] = LiveChannel(
        id: existing.id,
        name: existing.name,
        group: existing.group,
        // 叠加分类取并集：同一个台在不同索引里可能被判成不同内容分类
        // （一份写 group-title="News"，另一份靠台名判），合并后要都保留。
        categories: <String>{...existing.categories, ...c.categories}.toList(),
        badge: existing.badge,
        // tvgId 是「补备用源」的连接键：内置台可能没有，远端条目有就继承过来。
        tvgId: existing.tvgId ?? c.tvgId,
        streams: <LiveStream>[...existing.streams, ...extra],
      );
    }
    return sortChannels(byId.values);
  }

  /// 装载末尾的线路收口：去重 → 高清在前 → 单台封顶。
  ///
  /// 多份全网索引合并后，同一个台可能有十几条线路，且顺序取决于「哪份源先返回」。
  /// 不收口的话：① 重复地址会让「换线路」在两条一样的流之间空转；
  /// ② 标清线路先到就把后面 1080p/4K 挤出额度；③ 单台线路无限增长，
  /// 全失效自动切台时要逐条试完才能跳到下一个台。
  ///
  /// 排序是**稳定**的：同画质保持入库顺序，不会每次刷新都换一条。
  static List<LiveChannel> normalizeStreams(
    Iterable<LiveChannel> channels, {
    int limit = maxStreamsPerChannel,
  }) {
    if (limit <= 0) return const <LiveChannel>[];
    final out = <LiveChannel>[];
    for (final c in channels) {
      final seen = <String>{};
      final unique = <LiveStream>[];
      for (final s in c.streams) {
        if (seen.add(s.url)) unique.add(s);
      }
      final indexed = unique.indexed.toList()
        ..sort((a, b) {
          final byRank = b.$2.qualityRank.compareTo(a.$2.qualityRank);
          return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
        });
      final kept = indexed
          .take(limit)
          .map((e) => e.$2)
          .toList(growable: false);
      final unchanged = kept.length == c.streams.length &&
          kept.indexed.every((e) => identical(e.$2, c.streams[e.$1]));
      out.add(unchanged
          ? c
          : LiveChannel(
              id: c.id,
              name: c.name,
              group: c.group,
              categories: c.categories,
              badge: c.badge,
              tvgId: c.tvgId,
              streams: kept,
            ));
    }
    return out;
  }

  /// 同一「站点」被不同索引拆成多个频道对象时，把它们的线路合并回一个频道。
  ///
  /// 背景：`channelIdFor(name, group)` 把**原始 group-title** 也编进了频道 id。
  /// 同一个台在 A 索引写成 `group="Phoenix"`、在 B 索引写成 `group="News"`，
  /// 就会算出两个不同的 id，于是「凤凰资讯」在频道栏里出现两次——
  /// 一次 4 条线路、一次 1 条线路。用户看到那条只有 1 条线路的「凤凰资讯」，
  /// 就是典型的「频道缺少数据源」误报（其实另有同名的 4 线路台）。
  ///
  /// 这里用**台名归一键**（`_normalize(name)`，去空格/符号/大小写）把同名站点
  /// 归并：保留线路最多的那个 id（它的编号/偏好记忆都还在），把其余对象的线路
  /// **并集**并进来，再丢掉弱重复行。id 不变 —— 已落盘的频道号与「上次顺畅线路」
  /// 记忆全部保留，不会被重新分配。
  ///
  /// 顺带继承：若存活台 tvg-id 为空、而被合并台带 tvg-id，则补上，
  /// 让它能走通 streams.json 的多线路备用（附带修一部分「无备用源」）。
  static List<LiveChannel> mergeDuplicateStations(List<LiveChannel> channels) {
    final groups = <String, List<LiveChannel>>{};
    for (final c in channels) {
      groups.putIfAbsent(_normalize(c.name), () => <LiveChannel>[]).add(c);
    }
    final out = <LiveChannel>[];
    for (final entry in groups.entries) {
      final list = entry.value;
      if (list.length == 1) {
        out.add(list.first);
        continue;
      }
      // 存活台：线路最多者优先；并列时优先「含 IPv4 线路」者；再并列保留先出现者。
      LiveChannel survivor = list.first;
      for (final c in list.skip(1)) {
        if (_betterSurvivor(c, survivor)) survivor = c;
      }
      final seen = <String>{};
      final merged = <LiveStream>[];
      for (final c in list) {
        for (final s in c.streams) {
          if (seen.add(s.url)) merged.add(s);
        }
      }
      String? tvg = survivor.tvgId;
      if (tvg == null || tvg.isEmpty) {
        for (final c in list) {
          if (c.tvgId != null && c.tvgId!.isNotEmpty) {
            tvg = c.tvgId;
            break;
          }
        }
      }
      out.add(LiveChannel(
        id: survivor.id,
        name: survivor.name,
        group: survivor.group,
        categories: survivor.categories,
        badge: survivor.badge,
        tvgId: tvg,
        streams: merged,
      ));
    }
    return out;
  }

  /// 选存活台的判据：线路更多者更优；并列时「含 IPv4 线路」者更优。
  static bool _betterSurvivor(LiveChannel a, LiveChannel b) {
    if (a.streams.length != b.streams.length) {
      return a.streams.length > b.streams.length;
    }
    final aV4 = a.streams.any((s) => !_isIpv6Host(s.url));
    final bV4 = b.streams.any((s) => !_isIpv6Host(s.url));
    return aV4 && !bV4;
  }

  /// 地址 host 是否为 IPv6 字面量（`[....]` 或被冒号包裹）。
  static bool _isIpv6Host(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.contains('[') || host.contains(':');
  }

  /// 分组排序 + 组内稳定顺序。
  ///
  /// 组内不只按入库顺序：索引里 CCTV 各频道的出现顺序是乱的，直接照搬会让
  /// 用户在「央视频道」里看到 CCTV-1、CCTV-6、CCTV-2 这样跳着排。
  /// 所以组内再按**台名里的号码**升序（CCTV-1 → CCTV-2 → …），
  /// 号码相同或没有号码时退回入库顺序（`indexed` 保证稳定）。
  static List<LiveChannel> sortChannels(Iterable<LiveChannel> channels) {
    final list = channels.toList();
    final indexed = list.indexed.toList()
      ..sort((a, b) {
        final byGroup = LiveChannel.groupRank(a.$2.group)
            .compareTo(LiveChannel.groupRank(b.$2.group));
        if (byGroup != 0) return byGroup;
        final byNumber = _numberOf(a.$2.name).compareTo(_numberOf(b.$2.name));
        if (byNumber != 0) return byNumber;
        return a.$1.compareTo(b.$1);
      });
    return indexed.map((e) => e.$2).toList(growable: false);
  }

  static final RegExp _numberPattern = RegExp(r'(\d{1,3})');

  /// 台名里的频道号；没有号码的排到本组最后。
  ///
  /// `CCTV+ 1` 这类付费频道加 1000 偏移排在同号公共频道之后：
  /// 用户找「CCTV-1」时不该先看到外语付费频道。
  ///
  /// 提取前必须先剥掉**分辨率 / 画质后缀**：`4K` / `8K` / `1080p` / `高清`
  /// 是画质标注，不是台号。否则「深圳卫视4K」会被误把「4K」里的 4 当成台号，
  /// 排到卫视频道最前（4 < 101），于是「自动切台 / 下一台」会跳到与它相邻的
  /// 北京卫视，而非用户预期的顺序——实测正是「点击深圳卫视4K 误切到北京卫视」的根因。
  static int _numberOf(String name) {
    final cleaned = name
        // 括号里的分辨率/运营标注。
        .replaceAll(RegExp(r'[\(（\[][^\)）\]]{0,24}[\)）\]]'), ' ')
        // 裸分辨率后缀：1080p / 720P / 576i。
        .replaceAll(RegExp(r'\b\d{3,4}[pPiI]\b'), ' ')
        // 独立的 4K / 8K：这是画质档，不是台号。
        .replaceAll(RegExp(r'\b[48][Kk]\b'), ' ')
        // 结尾的中文画质后缀。
        .replaceAll(RegExp(r'(超高清|超清|高清|标清|蓝光)\s*$'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final m = _numberPattern.firstMatch(cleaned);
    if (m == null) return 9999;
    final n = int.tryParse(m.group(1)!) ?? 9999;
    return cleaned.contains('+') ? n + 1000 : n;
  }

  /// 排序用台号（[sortChannels] 使用，见 [_numberOf]）。
  ///
  /// 暴露为公开方法，便于回归脚本直接断言「4K/8K 不被当成台号」。
  static int sortKeyOf(String name) => _numberOf(name);
}

/// 内置频道清单。
///
/// **这里刻意很短，只有一条演示信号——这是实测后的决定，不是没做完。**
///
/// 原先这里硬编码了 31 个台（CCTV-1..17 + 14 个卫视）指向北邮公开镜像
/// `ivi.bupt.edu.cn`，每个台两条线路。实测该镜像**整站关停**（直连与代理都超时），
/// 于是产生了一串连锁故障：
/// 1. 31 个台 × 2 条线路全部是死链，用户点任何一个台都只能看到「正在连接」；
/// 2. 更糟的是首屏选台会先探测列表最前面的几个台，而最前面正好是这 31 个死台，
///    探测窗口（8 个并发）被死链占满 → 首屏必然黑屏，最后退到兜底流；
/// 3. 「有 31 个内置台」给了用户「信号源已就绪」的错觉，实际一个都放不出来。
///
/// 结论：**硬编码的直播地址一定会烂掉**（公开镜像的生命周期以月计），
/// 而死链比没有更糟——它会把「本来能播的远端频道」挤到探测窗口之外。
/// 所以信号源只留一条路：启动时从公开索引自动获取（见 [kDefaultLiveIndexUrls]），
/// 内置只保留一条**用来区分「信号源坏了」和「播放内核坏了」**的演示信号。
///
/// 这条演示流是 HLS 而不是 MP4：它和真实直播走完全相同的取流路径
/// （拉 playlist → 拉分片 → 解码），所以它出画面就说明内核链路是通的。
abstract final class BuiltInLiveChannels {
  static const String demoUrl =
      'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

  static List<LiveChannel> get all => <LiveChannel>[
        LiveChannel(
          id: LiveCatalogService.channelIdFor('演示信号 · HLS 测试', '其它频道'),
          name: '演示信号 · HLS 测试',
          group: '其它频道',
          badge: '演示',
          streams: const <LiveStream>[
            LiveStream(
              url: demoUrl,
              label: '公开测试流（HLS）',
              qualityRank: 50,
            ),
          ],
        ),
      ];
}

/// 默认公开索引（主链路，阻塞首屏）。
///
/// 只放「小、快、直连」的 iptv-org 官方目录：iptv-org 的 GitHub Pages 域名
/// （`iptv-org.github.io`）在本机与国内网络都稳定直连、几 KB、亚秒返回，
/// 即使其它镜像全挂，这份也能独立撑起一份可看的频道表。
///
/// 国内 IPv6 直连表（fanmingming）已经**移出主链路**，改放到
/// [kDefaultDiscoverySources] 作为「可选增强」：它体积大（MB 级）、走代理镜像，
/// 且在纯 IPv4 网络下整份都不可用——放进主链路既会拖慢/警告首屏，又会在
/// 普通网络下贡献一堆排到最后的死链。挪到增强源后，失败静默、不阻塞、不告警，
/// 只在双栈/校园网等能用到 IPv6 的环境才生效。
const List<String> kDefaultLiveIndexUrls = <String>[
  'https://iptv-org.github.io/iptv/countries/cn.m3u',
  'https://iptv-org.github.io/iptv/languages/zho.m3u',
];

/// 城市台补充索引（可选增强，见 [LiveCatalogService.citySupplementUrls]）。
///
/// 实测三份主索引里 **没有一个苏州台**，而 IP 定位默认城市正是这类地市台。
/// 这份公开表按省份分组，含「苏州新闻综合 / 苏州社会经济 / 苏州文化生活 /
/// 苏州生活资讯 / 苏州4k」等地市台；只挑城市台条目并入，主频道表不受影响。
/// 它经公共镜像接入：镜像挂了只是少一批城市台，主链路照常出画面。
const List<String> kDefaultCitySupplementUrls = <String>[
  'https://ghproxy.net/https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/result.m3u',
  // 同一份数据的第二个镜像：镜像站经常整周不可用，只挂一个等于
  // 「苏州台时有时无」。两条并发拉、地址去重，任一成功即稳定收录。
  'https://gh-proxy.com/https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/result.m3u',
];

/// 全网检索源（在保留 iptv-org 目录检索的基础上扩展）。
///
/// **这些源全部是「可选增强」**：任一失败静默跳过，主链路与内置清单一律照常出画面。
/// 它们走公共代理镜像，拉取超时统一用 [LiveCatalogService.enhancedTimeout]
/// （比主索引宽），避免「镜像偶发慢一点就整批被静默丢弃」——这正是此前
/// 「70% 频道只有单点源」的根因之一：多线路聚合表被主索引的 8s 上限掐掉，
/// 那些备用线路根本没并进来。
///
/// **镜像策略**：每个源都给 `gh-proxy.com`（实测直连稳定、亚秒~5s 返回）与
/// `ghproxy.net`（老牌镜像，偶发抖动）两条，loader 并发各试一次、URL 去重，
/// 任一成功即收录；某天一个镜像整周不可用，另一个顶上，不会让对应来源的
/// 多线路整体消失。
///
/// 分工：
/// * `result.txt` —— 与 Guovin `result.m3u` 同数据集但**不同格式**的苏州第二来源；
///   M3U 生成规则变了 txt 仍能给出苏州 5 个台。
/// * `kimentanm/aptv` —— 4K / 8K 专组，带 `http-user-agent` / `http-referer`，
///   是「高清线路源太少」最直接的补强，还额外给一条「苏州4K」。
/// * `YueChan/Live` —— 另一批中文 4K 与卫视镜像线路。
/// * `iptv-org/streams/cn.m3u` —— iptv-org **中国台的全部线路表**（516 条、
///   174 条带 1080 标注），不是「一台一条」的目录：线路数与高清源数量
///   提升最大的一份，仍属 iptv-org 检索体系。
/// * `iptv-org/index.m3u` —— **全球总索引**（1.1 万条 / 2.6 MB），用
///   `chinaOnly` 收窄到中国相关条目（含境外中文台），补目录里没有的语种维度。
///   体积与扫描行数单独放大，否则默认 2 MiB / 2 万行会把它尾部截掉。
/// * `fanmingming/live` 的 `ipv6.m3u` —— **国内 IPv6 直连表**，已从主链路移出：
///   只在双栈 / 校园网等能用 IPv6 的环境生效，纯 IPv4 下整份不可用（已被降权排在最后）。
const List<LiveSourceDescriptor> kDefaultDiscoverySources =
    <LiveSourceDescriptor>[
  // ★ 央视/卫视线路补强（本轮新增，直击「央视全台不能播」）
  //
  // 主索引 iptv-org 的 cn.m3u 里 CCTV-1..17 几乎全部指向同一批境外中转 IP
  // （74.91.26.218 / 69.30.245.50 / 198.204.240.250 / 192.151.150.154）。
  // 实测这批 IP 首字节要 1.5~5.1 秒、且频繁整站无响应：一旦它们抽风，
  // 17 个央视台**一条能播的线路都不剩**，用户看到的就是「央视全都不能播」。
  //
  // 聚合表（Guovin）对同一批台给出的是**另一批**线路，且带每日测速排序。
  // 只用 `nationalOnly` 收窄（央视 + 卫视），不并入六七百条省市台——
  // 全量并入会把单台线路上限和首屏探测窗口一起挤爆。
  LiveSourceDescriptor(
    'https://gh-proxy.com/https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/result.m3u',
    scope: LiveSourceScope.nationalOnly,
    channelLimit: 400,
    label: '央视/卫视补强',
  ),
  LiveSourceDescriptor(
    'https://ghproxy.net/https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/result.m3u',
    scope: LiveSourceScope.nationalOnly,
    channelLimit: 400,
    label: '央视/卫视补强(备用)',
  ),
  LiveSourceDescriptor(
    'https://gh-proxy.com/https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/result.txt',
    format: LiveSourceFormat.nameUrl,
    scope: LiveSourceScope.cityOnly,
    label: '苏州补充·txt',
  ),
  LiveSourceDescriptor(
    'https://ghproxy.net/https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/result.txt',
    format: LiveSourceFormat.nameUrl,
    scope: LiveSourceScope.cityOnly,
    label: '苏州补充·txt(备用)',
  ),
  LiveSourceDescriptor(
    'https://gh-proxy.com/https://raw.githubusercontent.com/kimentanm/aptv/master/m3u/iptv.m3u',
    label: '4K/高清聚合',
  ),
  LiveSourceDescriptor(
    'https://ghproxy.net/https://raw.githubusercontent.com/kimentanm/aptv/master/m3u/iptv.m3u',
    label: '4K/高清聚合(备用)',
  ),
  LiveSourceDescriptor(
    'https://gh-proxy.com/https://raw.githubusercontent.com/YueChan/Live/main/IPTV.m3u',
    label: '中文高清聚合',
  ),
  LiveSourceDescriptor(
    'https://ghproxy.net/https://raw.githubusercontent.com/YueChan/Live/main/IPTV.m3u',
    label: '中文高清聚合(备用)',
  ),
  LiveSourceDescriptor(
    'https://gh-proxy.com/https://raw.githubusercontent.com/iptv-org/iptv/master/streams/cn.m3u',
    label: 'iptv-org 中国全线路',
  ),
  LiveSourceDescriptor(
    'https://ghproxy.net/https://raw.githubusercontent.com/iptv-org/iptv/master/streams/cn.m3u',
    label: 'iptv-org 中国全线路(备用)',
  ),
  LiveSourceDescriptor(
    'https://iptv-org.github.io/iptv/index.m3u',
    scope: LiveSourceScope.chinaOnly,
    maxBytes: LiveCatalogService.extendedPlaylistBytes,
    scanLines: LiveCatalogService.extendedScanLines,
    label: 'iptv-org 全球总索引（中国条目）',
  ),
  LiveSourceDescriptor(
    'https://gh-proxy.com/https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u',
    label: 'IPv6 直连表',
    maxBytes: 6 * 1024 * 1024,
  ),
  LiveSourceDescriptor(
    'https://ghproxy.net/https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u',
    label: 'IPv6 直连表(备用)',
    maxBytes: 6 * 1024 * 1024,
  ),
];

/// 备用源索引（`streams.json`）的镜像清单，按顺序尝试。
///
/// 目前只有 iptv-org 官方 API 这一份稳定可用（实测多个公共镜像对该路径
/// 返回 403/404）。保留列表结构是为了以后加镜像时**只改常量、不改调用方**；
/// 挂掉的镜像只写一条 warning，不会打断开播。
const List<String> kDefaultStreamIndexUrls = <String>[
  kDefaultStreamIndexUrl,
];

/// 备用源索引：同一批频道的**全部已知流**。
///
/// M3U 索引每个台只给一条流，这张表才有多线路（实测 CCTV-1 有 4 条、
/// 深圳卫视 12 条）。用 `tvg-id` 关联，缺了它「自动换源」基本没有备用源可用。
///
/// 体积约 3.8 MB：只在启动时拉一次、失败静默跳过，不影响开播。
const String kDefaultStreamIndexUrl =
    'https://iptv-org.github.io/api/streams.json';
