/// 电视直播的频道 / 线路模型。
///
/// 与点播的 `SourceAdapter` 刻意分开：直播没有「集数」「广告偏移」「片尾」这些语义，
/// 硬套点播的坐标模型只会把 alignment 层的换算逻辑污染成两套分支。
/// 直播需要的只有两件事——**这个台有哪些线路**、**按什么顺序试**。
library;

/// 线路所属通道（依据《顺播 · 运营商电视通道研发方案》N1）。
///
/// 通道**只是排序因子与可达性筛选依据**，不是第二套调度逻辑：
/// 三类线路共用同一张候选表、同一套健康度与换源体系。
/// 默认值 [public] 是有意为之——所有历史数据、远端索引、内置清单在没有
/// 显式标记时都必须是公网源，否则一次升级就会让整张频道表被当成内网源剔除。
enum LiveChannelType {
  /// 公网开源源（现有全部线路）。
  public,

  /// 运营商内网 CDN 源：只在对应运营商的家宽出口下可达。
  carrierNet,

  /// 运营商组播经路由器 udpxy / msd_lite 转成的 HTTP 单播。
  multicast,
}

/// 宽带运营商归属（三网通用，不写死任何一家）。
enum Carrier {
  /// 未识别 / 蜂窝 / 归属服务不可用 / 复核不一致 → 一律按公网处理。
  unknown,
  chinaMobile,
  chinaTelecom,
  chinaUnicom,
}

/// 一条可播放的直播线路。
///
/// 同一个台通常有多个官方/镜像线路，画质与可达性各不相同，
/// 所以线路要能各自携带请求头（不少 CDN 校验 Referer/UA）。
class LiveStream {
  /// 实际交给播放内核的地址。仅允许 http/https（解析阶段已过滤）。
  final String url;

  /// 线路名，用于「线路 1 / 高清 / 备用」这类展示。
  final String label;

  /// 画质优先级，越大越优先（与点播的 qualityRank 同语义）。
  final int qualityRank;

  /// 该线路必须携带的请求头；为空表示直连。
  final Map<String, String> headers;

  /// 是否经过「解码门禁」实测（建起解码链 + 解码器零报错）。
  ///
  /// 与 `qualityRank` 不是一回事：rank 是从台名 / 分组**猜**出来的画质，
  /// 这个标记是 libmpv 真的把这条流解出帧之后才置位的。选源时实测线路优先，
  /// 否则「4K」字样会把一条加密/花屏流顶到最前，用户看到的仍是色块。
  final bool decodeVerified;

  /// 起播前需要先请求一次的解析器地址（302 → 官方 CDN 直连）。
  ///
  /// 官方 CDN 普遍带时效令牌（`txSecret` / `txTime` / 一次性路径），写死在包里
  /// 几小时就过期。设了这个字段的线路会在 `player.load` 之前先解析出当次有效
  /// 的官方地址；解析失败就退回 [url]，不因为新能力让原本能播的台变黑屏。
  ///
  /// 请求头复用 [headers]（跨 origin 时由解析器自动收敛到安全头）。
  final String? resolverUrl;

  /// 线路通道。默认 [LiveChannelType.public]：老数据与所有公开索引零改动兼容。
  final LiveChannelType channelType;

  /// [channelType] 为 [LiveChannelType.carrierNet] 时归属的运营商。
  ///
  /// 与当前出口不一致时该线路**不进候选、也不记失败**（异网源试连既拉不到流，
  /// 又会污染健康分、还可能触发风控）。识别失败一律按 [Carrier.unknown] 兜底。
  final Carrier carrier;

  /// 组播线路的原始 `udp://` / `rtp://` 地址。
  ///
  /// 保留原值而非只存重写结果：用户改了 udpxy 主机或端口后要能批量重写，
  /// 不能要求重新导入地址表（方案 F2）。公网 / 内网源为空。
  final String? rawAddr;

  /// 组播传输方式（`udp` / `rtp`），决定单播路径是 `/udp/` 还是 `/rtp/`。
  final String? transport;

  const LiveStream({
    required this.url,
    this.label = '主线路',
    this.qualityRank = 0,
    this.headers = const <String, String>{},
    this.decodeVerified = false,
    this.resolverUrl,
    this.channelType = LiveChannelType.public,
    this.carrier = Carrier.unknown,
    this.rawAddr,
    this.transport,
  });

  /// 生成一份只改地址与通道元数据的副本（换 udpxy 主机/端口时批量重写用）。
  LiveStream withAddress(
    String newUrl, {
    String? rawAddr,
    String? transport,
    String? label,
  }) =>
      LiveStream(
        url: newUrl,
        label: label ?? this.label,
        qualityRank: qualityRank,
        headers: headers,
        decodeVerified: decodeVerified,
        resolverUrl: resolverUrl,
        channelType: channelType,
        carrier: carrier,
        rawAddr: rawAddr ?? this.rawAddr,
        transport: transport ?? this.transport,
      );

  /// 高清档阈值（720p 及以上）。放在模型里而不是目录层/选源层各写一份：
  /// 「哪些线路算高清」必须只有一个答案，否则 UI 显示与播放顺序会打架。
  static const int hdQualityThreshold = 70;

  /// 是否高清线路。播放时优先加载这一档（见 `LiveSelection.rankStreams`）。
  bool get isHd => qualityRank >= hdQualityThreshold;

  @override
  String toString() => 'LiveStream($label, rank=$qualityRank, $url)';
}

/// 一个电视频道。
class LiveChannel {
  /// 稳定标识（同名频道跨线路复用同一个 id，便于换线时保持选中态）。
  final String id;

  /// 台名，如「CCTV-1 综合」。
  final String name;

  /// 分组，如「央视频道」「卫视频道」「地方频道」。
  final String group;

  /// 所属分类集合：**主分类 + 叠加的内容分类**。
  ///
  /// 分类是可叠加的——「苏州新闻综合」既是「地方频道」也是「新闻」，
  /// 在频道栏的两个分类下都能找到它。这正是「新闻 / 少儿 / 体育 覆盖
  /// 央视、卫视、地方三类来源」的实现方式（见 `channel_taxonomy.dart`）。
  ///
  /// 解析阶段算好后随频道一起带过来，UI 不再二次猜测——
  /// 两处各猜一次必然出现「列表里归新闻、详情里归地方」的不一致。
  final List<String> categories;

  /// 台标文字（取台名里最有辨识度的 2~4 个字）。
  ///
  /// 刻意不用网络图片：首屏就要出画面，台标再来一次网络往返只会让列表白闪。
  final String badge;

  /// 候选线路，UI 按「健康度 → 画质」排序后尝试。
  final List<LiveStream> streams;

  /// 对外数据源里的频道标识（iptv-org 的 `tvg-id`，已去掉 `@SD` 这类 feed 后缀）。
  ///
  /// 为什么必须留着：公开索引的 M3U **每个台只给一条流**，
  /// 而同一份数据集的 `streams.json` 里同一个台往往有 4~12 条备用流。
  /// 两张表唯一的连接键就是这个 id——没有它，就无法给频道补出备用源，
  /// 「源挂了自动切换」在绝大多数台上会变成一句空话（实测 147 个台里 143 个只有 1 条）。
  final String? tvgId;

  const LiveChannel({
    required this.id,
    required this.name,
    required this.group,
    required this.badge,
    required this.streams,
    this.tvgId,
    this.categories = const <String>[],
  });

  /// 至少有一条线路才算「可播」；没有线路的台在列表里置灰。
  bool get isPlayable => streams.isNotEmpty;

  /// 是否具备组播线路（对应方案 F10 的 `channel.has_multicast`）。
  ///
  /// 用线路汇总而不是单独存一个字段：线路被导入/删除时不会出现「表说有、
  /// 实际没有」的漂移，老数据也无需迁移。
  bool get hasMulticast =>
      streams.any((s) => s.channelType == LiveChannelType.multicast);

  /// 是否具备运营商内网 CDN 线路。
  bool get hasCarrierNet =>
      streams.any((s) => s.channelType == LiveChannelType.carrierNet);

  /// 频道列表的通道标注（仅组播 / 仅公网 / 两者兼有 …）。
  String get channelLabel {
    final hasPublic =
        streams.any((s) => s.channelType == LiveChannelType.public);
    final hasCarrier = hasCarrierNet;
    final hasMulti = hasMulticast;
    if (hasMulti && !hasPublic && !hasCarrier) return '仅电视专网';
    if (hasCarrier && !hasPublic && !hasMulti) return '仅运营商内网';
    if (hasMulti && (hasPublic || hasCarrier)) return '专网 + 公网';
    if (hasCarrier && hasPublic) return '内网 + 公网';
    return '公网';
  }

  /// 是否属于某个分类（分类栏过滤用）。
  ///
  /// 优先看叠加分类集合；集合为空的老数据回落到主分组，
  /// 保证「按分类过滤」对历史频道表同样成立。
  bool inCategory(String category) =>
      categories.isEmpty ? group == category : categories.contains(category);

  /// 把线路按「实测优先 → 画质优先」排序（同优先级保持原始顺序）。
  ///
  /// 实测线路排在最前的理由：一条标着 4K 但切片加扰的流，rank 再高也只是
  /// 满屏色块；而标清但真解出帧的线路至少能看。排序只管优先级，不做过滤——
  /// 已知失效由 `DeadStreamRegistry` / `DecodeGateBoard` 在选源层处理。
  List<LiveStream> get orderedStreams {
    final indexed = streams.indexed.toList()
      ..sort((a, b) {
        if (a.$2.decodeVerified != b.$2.decodeVerified) {
          return a.$2.decodeVerified ? -1 : 1;
        }
        final byRank = b.$2.qualityRank.compareTo(a.$2.qualityRank);
        return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
      });
    return indexed.map((e) => e.$2).toList(growable: false);
  }

  /// 换台时的排序键：央视 → 卫视 → 地方 → 内容类型 → 其它。
  ///
  /// 顺序对应用户找台的直觉（「先看央视有没有，再翻卫视」），而不是字母序。
  /// 不在表里的分组统一排最后，且**组内保持入库顺序**，避免同一分组内的台每次
  /// 刷新都换位置。
  /// 通道在界面上的中文名。
  static String typeLabel(LiveChannelType type) => switch (type) {
        LiveChannelType.public => '公网',
        LiveChannelType.carrierNet => '运营商内网',
        LiveChannelType.multicast => '电视专网',
      };

  static int groupRank(String group) {
    const order = <String>[
      '央视频道',
      '卫视频道',
      '地方频道',
      '新闻',
      '体育',
      '影视',
      '少儿',
      '纪实',
      '生活',
      '购物',
      '其它频道',
    ];
    final i = order.indexOf(group);
    return i < 0 ? order.length : i;
  }
}
