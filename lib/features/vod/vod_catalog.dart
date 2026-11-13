import '../../core/source/memory_source_adapter.dart';
import '../../core/source/source_adapter.dart';
import '../../core/source/source_profile.dart';

/// 点播栏目。与侧栏一一对应（直播不在其中，直播有自己的播放模型）。
enum VodSection {
  movies('电影'),
  series('电视剧'),
  documentaries('纪录片'),

  /// 短视频 / 微短剧。1.0.5 第十次修新增，排在最后：前三项的枚举序号
  /// 就是左侧导航与 `IndexedStack` 的下标，插在中间会让已有栏目错位。
  shortVideo('短视频'),

  /// 动漫 / 番剧 / 动画。1.0.5 第十二次修新增。
  ///
  /// 加这一栏的直接原因：真实类目表里动漫相关类目多达 15 个
  /// （`动漫` / `动漫片` / `动漫电影` / `国产动漫` / `日韩动漫` / `欧美动漫` /
  /// `港台动漫` / `海外动漫` / `中国动漫` / `日本动漫` / `动画片` / `AI动漫` /
  /// `AI漫剧` / `漫剧` / `有声动漫`），而旧词表把它们劈成了三份：
  /// `动漫` / `番剧` 在 [kVodSeriesMarkers] 里 ⇒ 进电视剧；`动画片` 靠
  /// 「以『片』结尾」⇒ 进电影；`AI漫剧` 靠「漫剧」⇒ 进短视频。
  /// 用户要求「所有动漫内容统一归集到该栏目」，因此独立成栏。
  ///
  /// 仍然追加在末尾：前五项 index 与 `IndexedStack` 下标全部不变。
  anime('动漫'),

  /// 综艺 / 体育 / 音乐 / 少儿等「既不是电影、也不属于另外四个栏目」的大类。
  ///
  /// 1.0.5 第十一次修：真实本地记录里电影栏目 470 条，其中 64 条「大陆综艺」、
  /// 52 条「足球」、46+46 条日韩/港台综艺、61 条「现代都市」短剧、9 条「记录片」。
  /// 根因是老 `sectionFromName()` 把认不出来的类目一律 `return movies`。
  /// 这类内容必须有个**不进任何栏目**的归属，否则只能污染别的栏目或丢掉记录；
  /// 它们仍留在本地检索记录里，可被检索命中，只是不会出现在电影栏目。
  /// 追加在最后，前五项 index 与左侧导航 / `IndexedStack` 全部不变。
  other('其他');

  const VodSection(this.label);
  final String label;
}

/// 判定「短视频内容」的词表。
///
/// 依据不是拍脑袋：默认源采集站的类目表里实测有 `短剧` / `短剧大全` /
/// `AI漫剧` / `电影解说` / `预告片` 这些一级类目，以及 `现代言情` /
/// `重生民国` 这类挂在「短剧大全」下的子类目（靠 `type_pid` 判定，
/// 见 `CmsCategoryTable`）。词表只兜住「没有类目表」的场合：
/// 契约 JSON、老版本本地缓存（v1 只有标题/副标题）、用户自填源。
///
/// 1.0.5 第十二次修：**移除 `漫剧`**。它原来在这里，导致 `AI漫剧` /
/// `漫剧` 两个真实类目被判进短视频；而 [isShortVideoItem] 在
/// [normalizeVodItem] 里先于 [vodSectionFromText] 执行，留着这一个词
/// 动漫栏目就永远抢不回这两类。现归 [kVodAnimeMarkers]。
const List<String> kShortVideoMarkers = <String>[
  '短视频',
  '短剧',
  '微剧',
  '电影解说',
  '预告片',
  '片花',
  '短片',
  '微电影',
  '影视解说',
];

/// 动漫大类。
///
/// 逐个都有真实类目证据（11 个可用采集站的 `class` 表去重后共 15 个动漫类目）：
/// `动漫` `动漫片` `动漫电影` `国产动漫` `日韩动漫` `欧美动漫` `港台动漫`
/// `海外动漫` `中国动漫` `日本动漫` `动画片` `AI动漫` `AI漫剧` `漫剧`
/// `有声动漫`。其中 `动漫` 覆盖 12 个，`动画` 覆盖 `动画片`，`漫` 覆盖
/// `AI漫剧` / `漫剧` / `有声动漫`，`国漫` / `日漫` 是站外常见别名（备而不用）。
///
/// 只放「一类内容」的词，不放单字：单字「漫」会把 `浪漫` 这类题材词拉进来。
const List<String> kVodAnimeMarkers = <String>[
  '动漫',
  '番剧',
  '动画',
  '漫剧',
  '国漫',
  '日漫',
];

/// 纪录片大类。
const List<String> kVodDocumentaryMarkers = <String>[
  '纪录',
  '记录片',
  '纪实',
];

/// 剧集大类。刻意不放单个「剧」字：`剧情片` / `喜剧片` 是电影，
/// 用「剧」字兜底会把它们整批塞进电视剧栏目。
///
/// 1.0.5 第十二次修：**移除 `动漫` / `番剧`**。这两个词原来在这里，
/// 让 `国产动漫` 等 12 个类目落进电视剧栏目；现由 [kVodAnimeMarkers]
/// 统一收口到动漫栏目。移除后 `endsWith('剧')` 仍能兜住 `欧美剧` 这类。
const List<String> kVodSeriesMarkers = <String>[
  '连续剧', '剧集', '国产剧', '欧美剧', '日韩剧',
  '港台剧', '海外剧', '韩剧', '日剧', '泰剧', '美剧', '内地剧',
];

/// 明确不属于四个内容栏目的大类（综艺 / 体育 / 音乐 / 少儿 / 资讯…）。
const List<String> kVodOtherMarkers = <String>[
  '综艺', '真人秀', '脱口秀', '选秀', '访谈', '晚会', '颁奖',
  '相声', '小品', '赛事', '足球', '篮球', '体育', '网球', '台球',
  '搏击', '赛车', '电竞', '音乐', '演唱会', 'mv', '戏曲',
  '少儿', '儿童', '教育', '新闻', '资讯', '直播', '美食', '旅游',
];

/// 电影类目信号。
const List<String> kVodMovieMarkers = <String>[
  '电影',
  '正片',
  '院线',
  '剧场版',
  'movie',
  'film',
];

/// 从一段类目文本推断栏目；`null` 表示**证据不足**，调用方不该据此改归属。
///
/// 顺序有讲究，每一步都有真实数据支撑：
/// 1. **短视频**优先：`短剧大全` / `AI短剧` 都带「剧」字，先判否则会被剧集抢走；
/// 2. **动漫**第二：`AI漫剧` 带「漫剧」、`动漫电影` 带「电影」、`动画片` 以
///    「片」结尾 —— 这三个都必须在纪录片/剧集/电影之前判，否则动漫会被
///    劈成三份（旧实现正是如此，见 [VodSection.anime] 的注释）；
/// 3. 纪录片、剧集、综艺体育依次排除；
/// 4. 最后才认电影。电影用「以『片』结尾」而不是 `contains('片')`：
///    `片花` / `预告片` 是短视频，含「片」就判电影会把它们拉回来。
VodSection? vodSectionFromText(String raw) {
  final s = raw.toLowerCase().replaceAll(RegExp(r'\s+'), '').trim();
  if (s.isEmpty) return null;
  if (isShortVideoText(s)) return VodSection.shortVideo;
  if (kVodAnimeMarkers.any((m) => s.contains(m))) return VodSection.anime;
  if (kVodDocumentaryMarkers.any((m) => s.contains(m))) {
    return VodSection.documentaries;
  }
  if (kVodSeriesMarkers.any((m) => s.contains(m)) || s.endsWith('剧')) {
    return VodSection.series;
  }
  if (kVodOtherMarkers.any((m) => s.contains(m))) return VodSection.other;
  if (s.endsWith('片') || kVodMovieMarkers.any((m) => s.contains(m))) {
    return VodSection.movies;
  }
  return null;
}

/// 电影栏目的最后一道闸：只放行「源站类目明确是电影」的条目。
///
/// [normalizeVodItem] 负责把存量记录迁到正确栏目，这里防的是**没走过归一**
/// 的路径（契约 JSON、外部直接 install）。只看 [VodItem.typeName]，**不看**
/// `genre`：`vod_class` 是题材标签，真电影也会带上「纪录片」「喜剧」这类词，
/// 拿它判栏目会把《止水之询》这种犯罪片整批踢出电影页。
/// 内置 6 条公开授权素材的 `sourceId` 是 [VodCatalog.sourceId]，一律放行。
bool isMovieSectionItem(VodItem item) {
  if (item.sourceId == VodCatalog.sourceId) return true;
  return vodSectionFromText(item.typeName) == VodSection.movies;
}

/// 文本里是否带短视频信号（大小写、空白、全角冒号都不影响）。
bool isShortVideoText(String raw) {
  if (raw.isEmpty) return false;
  final s = raw.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  for (final m in kShortVideoMarkers) {
    if (s.contains(m)) return true;
  }
  return false;
}

/// 已有条目是否属于短视频。
///
/// 只看「源站给的元信息 + 片名 + 副标题」，**不看简介**：简介里出现
/// 「短剧」两个字可能只是剧情描述，拿它归类会把整部电视剧挪错栏目。
/// `section == shortVideo` 自身也算命中，保证重复归一不会把它弹回去。
bool isShortVideoItem(VodItem item) =>
    item.section == VodSection.shortVideo ||
    isShortVideoText(item.typeName) ||
    isShortVideoText(item.genre) ||
    isShortVideoText(item.title) ||
    isShortVideoText(item.subtitle);

/// 文本里是否带动漫信号（大小写、空白都不影响）。
bool isAnimeText(String raw) {
  if (raw.isEmpty) return false;
  final s = raw.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  for (final m in kVodAnimeMarkers) {
    if (s.contains(m)) return true;
  }
  return false;
}

/// 已有条目是否属于动漫。
///
/// 与 [isShortVideoItem] 同样**不看简介**（简介里出现「动画」可能只是
/// 特效描述）。**类目字段优先**：`typeName` 是源站给的结构化归属，
/// 有它就以它为准 —— 否则《动画师》这种片名带「动画」的真电影会被
/// 误收进动漫栏目。只有类目为空（v1 老缓存、契约 JSON 没给类型）时，
/// 才退一步看片名与副标题，把散落在「其他」里的动漫捞回来。
/// `section == anime` 自身也算命中，保证重复归一不会把它弹回去。
bool isAnimeItem(VodItem item) {
  if (item.section == VodSection.anime) return true;
  if (isAnimeText(item.typeName)) return true;
  if (item.typeName.trim().isNotEmpty) return false;
  return isAnimeText(item.title) || isAnimeText(item.subtitle);
}

/// 把条目归一到正确栏目。
///
/// 「已获取到的短视频内容迁移」与「后续新增内容统一归入」共用这一处：
/// 网络新条目入库前、v1 老缓存恢复时都过这个函数，因此栏目内容、
/// 本地检索记录、检索结果三者看到的是同一个 `section`。
VodItem normalizeVodItem(VodItem item) {
  var out = item;
  // v1 老缓存没有结构化字段，但副标题本来就是 `year · area · remarks`
  // 拼出来的（`buildCmsItems`）。把确实存在的两项回填回去，老记录也能按
  // 年份/地区检索；不做任何猜测：首段不是四位年份就不动，类型字段仍留空
  // （副标题无分隔符时无法区分「类型」和「更新至 N 期」）。
  if (out.year.isEmpty || out.area.isEmpty) {
    final parts = out.subtitle
        .split('·')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (parts.length >= 2 &&
        RegExp(r'^(19|20)\d{2}$').hasMatch(parts[0]) &&
        parts[1].length <= 20) {
      out = out.copyWith(
        year: out.year.isEmpty ? parts[0] : out.year,
        area: out.area.isEmpty ? parts[1] : out.area,
      );
    }
  }
  // 短视频优先：短剧子类目、电影解说、片名带标记的都归到短视频。
  if (isShortVideoItem(out)) {
    return out.section == VodSection.shortVideo
        ? out
        : out.copyWith(section: VodSection.shortVideo);
  }
  // 动漫第二：必须排在「结构化类目」之前。`AI漫剧` 的类目文本同时命中
  // 短视频已在上一步处理；但 `动漫电影` 若走结构化类目会被判成电影、
  // `有声动漫` 也可能被别处的「有声」拉走，因此这里显式收口。
  if (isAnimeItem(out)) {
    return out.section == VodSection.anime
        ? out
        : out.copyWith(section: VodSection.anime);
  }
  // 1.0.5 第十一次修：存量分类数据修正。只用源站给的结构化类目字段，
  // 不从片名猜（片名里出现「喜剧」不等于类目是喜剧片）。
  final category = vodSectionFromText(out.typeName);
  if (category != null) {
    return category == out.section ? out : out.copyWith(section: category);
  }
  // 落在电影栏目、却拿不出电影类目证据的外部条目 ⇒ 迁到「其他」。
  // 不读 genre（题材标签），也不读副标题里的「正片」：真实数据里
  // 「2026 · 正片」的 9 条 NBA / 羽毛球赛事正是靠这两个字混进来的。
  // 真实记录里这一类是 63 条空类目综艺与 61 条「现代都市」短剧子类目。
  // 内置片库的 sourceId 是 VodCatalog.sourceId，不参与迁移。
  if (out.section == VodSection.movies &&
      out.sourceId != VodCatalog.sourceId) {
    return out.copyWith(section: VodSection.other);
  }
  return out;
}

/// 跨站去重键：`片名|年份`。
///
/// 采集站的片库互相镜像，同一部片常带 6~7 份。分页器、片库、本地检索
/// 记录三处共用这一个函数，否则会出现「界面上有两条、本地只有一条」
/// 这种不一致。年份优先取结构化的 [VodItem.year]，老缓存没存这个字段
/// 才回退到副标题里第一个四位年份。
String vodContentKey(VodItem item) {
  final title = item.title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
  if (title.isEmpty) return '';
  final y = item.year.trim().isNotEmpty
      ? item.year.trim()
      : (RegExp(r'(19|20)\d{2}').firstMatch(item.subtitle)?.group(0) ?? '');
  return y.isEmpty ? title : '$title|$y';
}

/// 元数据指纹：接口数据更新后用于判断「同一 id 的内容是否变了」。
///
/// 只覆盖展示与检索真正会读的字段；播放地址也进指纹，因为源站换线路
/// 后旧地址会一播 403，必须同步到本地记录。
String vodContentFingerprint(VodItem item) => <String>[
      item.title,
      item.subtitle,
      item.description,
      item.posterUrl,
      item.typeName,
      item.genre,
      item.area,
      item.year,
      item.section.name,
      for (final e in item.episodes) '${e.number}:${e.title}:${e.url}',
    ].join('\u0001');

/// 一集（电影就是只有 1 集的条目）。
class VodEpisode {
  final int number;
  final String title;
  final String url;

  const VodEpisode({
    required this.number,
    required this.title,
    required this.url,
  });
}

/// 一个可播放的点播条目。
class VodItem {
  final String id;
  final String title;

  /// 一行副标题（年份 · 时长 · 类型），卡片上就靠它建立辨识度。
  final String subtitle;

  final String description;

  /// 授权说明。**必须显示在详情里**：片库是公开授权素材，
  /// 不写清楚来源，用户会以为这是正常商业片库。
  final String license;

  final VodSection section;
  final List<VodEpisode> episodes;

  /// 卡片主色（无海报图时用色块区分片子，避免整页灰）。
  final int accentSeed;

  /// 海报图地址（1.0.5：第三方采集接口的 `vod_pic`）。
  ///
  /// 空串表示没有海报 —— 卡片回落成色块 + 首字主视觉。
  /// 内置片库全部留空：那些公开测试素材没有官方海报，硬凑一张只会像假海报。
  /// 非 http(s) 或带控制字符的地址在解析层就被丢弃，这里不做二次校验。
  final String posterUrl;

  /// 1.0.5：条目所属的源 id。内置片库恒为 [VodCatalog.sourceId]；
  /// 第三方接口接入的条目带自己的源 id，起播时用它去 [SourceRegistry] 找适配器，
  /// 从而复用同一套续播 / 进度落盘 / 自动连播 / 换源对齐链路。
  /// 默认值保证 1.0.4 的所有构造点无需改动、行为逐字节一致。
  final String sourceId;

  /// 1.0.5：该条目播放地址需要携带的请求头（Referer / UA 等）。
  /// 由源适配器统一持有，避免「取数带 Referer、播放不带」的一播 403。
  final Map<String, String> headers;

  /// 1.0.5 第八次修：**结构化**的分类元数据，专供顶部筛选用。
  ///
  /// 为什么不能从 [subtitle] 里再拆：subtitle 是给人看的一行字，
  /// 顺序和分隔符随源站变化（有的源只给年份、有的给「更新至 12 集」），
  /// 拿它反解会在某个源上静默错位——筛选一旦错位，用户看到的是「筛了没反应」。
  /// 这三个字段在解析入口一次性填好，UI 只读不算。
  ///
  /// 空串表示源站没给这个维度：**没给就不该出现在筛选条里**，
  /// 而不是塞一个「其他」把不存在的片子假装归类。
  final String typeName;
  final String area;
  final String year;

  /// 剧情类型（`vod_class`，如「喜剧,爱情」）。与 [typeName] 不同：
  /// `type_name` 是采集站的栏目类目（短剧 / 欧美剧 / 剧情片），
  /// `vod_class` 才是用户理解的「类型」。两者都要落进本地检索记录。
  final String genre;

  const VodItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.license,
    required this.section,
    required this.episodes,
    this.accentSeed = 0,
    this.sourceId = VodCatalog.sourceId,
    this.headers = const <String, String>{},
    this.posterUrl = '',
    this.typeName = '',
    this.area = '',
    this.year = '',
    this.genre = '',
  });

  int get episodeCount => episodes.length;
  bool get isSeries => episodes.length > 1;

  /// 归一 / 元数据刷新时复制条目。保留播放地址、请求头、源 id 等全部字段，
  /// 避免「改了栏目却把 Referer 弄丢导致一播 403」。
  VodItem copyWith({
    String? id,
    String? title,
    String? subtitle,
    String? description,
    String? license,
    VodSection? section,
    List<VodEpisode>? episodes,
    int? accentSeed,
    String? sourceId,
    Map<String, String>? headers,
    String? posterUrl,
    String? typeName,
    String? area,
    String? year,
    String? genre,
  }) =>
      VodItem(
        id: id ?? this.id,
        title: title ?? this.title,
        subtitle: subtitle ?? this.subtitle,
        description: description ?? this.description,
        license: license ?? this.license,
        section: section ?? this.section,
        episodes: episodes ?? this.episodes,
        accentSeed: accentSeed ?? this.accentSeed,
        sourceId: sourceId ?? this.sourceId,
        headers: headers ?? this.headers,
        posterUrl: posterUrl ?? this.posterUrl,
        typeName: typeName ?? this.typeName,
        area: area ?? this.area,
        year: year ?? this.year,
        genre: genre ?? this.genre,
      );
}

/// 内置片库。
///
/// **选片原则**：只用可公开分发、且**本机实测能播**的内容
/// （Blender 开源影片 CC-BY、Mux / W3C / MDN / Video.js 的公开测试素材），
/// 不内置任何需要授权或来源不明的影视资源。
///
/// 「能播」和「可分发」是两条都要满足的硬条件：内容再合法，地址解析不出来
/// 也等于零（本项目踩过——整库指向一个在部分网络下 DNS 失效的桶，
/// 三个片库栏目点开全是黑屏）。所以换片源必须实测：`curl --noproxy '*' -r 0-1024`
/// 能拿到 2xx/206 才算数。宁可少几部片子，也不要死链。
///
/// 片库对外暴露成一个普通的 [MemorySourceAdapter]，
/// 于是点播自动拥有既有的续播、进度落盘、自动连播、换源对齐能力，
/// 不需要为「内置片库」再写一套播放逻辑。
abstract final class VodCatalog {
  /// 内置源 id。UI 上会显示为「片源：内置片库」。
  static const String sourceId = '内置片库';

  // ── 片源：全部为**本机实测可达**的公开测试素材 ─────────────────────
  //
  // 这里换过一次源，原因值得记下来：原先整库指向
  // `commondatastorage.googleapis.com`（Chromecast 官方示例桶），
  // 该域名在部分网络下**DNS 直接解析不出来**（本项目实测：连一字节都发不出去），
  // 于是三个片库栏目点开全是黑屏——片库"有内容"却一集都放不出来。
  // 现在只放实测可达的地址，宁可少几部片子，也不要死链。
  static const String _muxHls =
      'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
  static const String _muxTest1 = 'https://test-streams.mux.dev/test_001/stream.m3u8';
  static const String _muxPts = 'https://test-streams.mux.dev/pts_shift/master.m3u8';
  static const String _w3 = 'https://media.w3.org/2010/05';
  static const String _oceans = 'https://vjs.zencdn.net/v/oceans.mp4';
  static const String _flower =
      'https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4';

  static const String _licenseBlender = 'Blender 基金会开源影片 · CC-BY 授权';
  static const String _licenseSample = '公开测试素材（Mux / W3C / MDN / Video.js 官方示例）· 可自由分发';

  static final List<VodItem> _items = <VodItem>[
    // ── 电影：开源影片
    VodItem(
      id: 'big-buck-bunny-hls',
      title: '大雄兔',
      subtitle: '2008 · 动画短片 · 开源 · 多码率',
      description: '一只温和的大兔子被三只小动物捉弄，最终用自己的方式回应。'
          'Blender 基金会的标志性开源影片。本条目是 HLS 多码率版本，'
          '可以在播放中切换画质线路。',
      license: _licenseBlender,
      section: VodSection.movies,
      accentSeed: 0,
      episodes: const <VodEpisode>[
        VodEpisode(number: 1, title: '正片（HLS 多码率）', url: _muxHls),
      ],
    ),
    VodItem(
      id: 'big-buck-bunny-mp4',
      title: '大雄兔 · 单文件版',
      subtitle: '2008 · 动画短片 · 开源 · 进度条可拖动',
      description: '同一部影片的单文件版本。留着它是因为它比 HLS 版本更容易'
          '验证「拖动进度 / 续播恢复位置」——HLS 直播切片的定位行为与单文件不同。',
      license: _licenseBlender,
      section: VodSection.movies,
      accentSeed: 1,
      episodes: const <VodEpisode>[
        VodEpisode(number: 1, title: '正片（MP4）', url: '$_w3/bunny/movie.mp4'),
      ],
    ),
    VodItem(
      id: 'sintel-trailer',
      title: '辛特尔 · 预告',
      subtitle: '2010 · 动画短片 · 开源',
      description: '少女辛特尔跋涉寻找失散的幼龙。Blender 基金会第三部开源影片，'
          '内置的是官方预告片。',
      license: _licenseBlender,
      section: VodSection.movies,
      accentSeed: 2,
      episodes: const <VodEpisode>[
        VodEpisode(number: 1, title: '预告片', url: '$_w3/sintel/trailer.mp4'),
      ],
    ),

    // ── 电视剧：多集条目，用来验证「选集 / 自动连播 / 跨端续播」
    VodItem(
      id: 'demo-series',
      title: '演示剧集 · 三段式',
      subtitle: '3 集 · 每集一段公开测试片',
      description: '**这不是真正的剧集**，而是三段公开测试片组成的演示条目，'
          '用来验证选集、自动连播与续播链路：看完第 1 集会推进到第 2 集，'
          '退出后重进会回到上次的位置。',
      license: _licenseSample,
      section: VodSection.series,
      accentSeed: 4,
      episodes: const <VodEpisode>[
        VodEpisode(number: 1, title: '第 1 集 · 测试片 A', url: _muxTest1),
        VodEpisode(number: 2, title: '第 2 集 · 测试片 B', url: _muxPts),
        VodEpisode(number: 3, title: '第 3 集 · 短片 C', url: '$_w3/video/movie_300.mp4'),
      ],
    ),

    // ── 纪录片：自然类公开素材
    VodItem(
      id: 'doc-oceans',
      title: '海洋 · 片段',
      subtitle: '自然纪实 · 公开素材',
      description: '一段海洋纪实画面。片库为公开授权示例内容，'
          '用于验证纪录类目的浏览与播放链路。',
      license: _licenseSample,
      section: VodSection.documentaries,
      accentSeed: 6,
      episodes: const <VodEpisode>[
        VodEpisode(number: 1, title: '正片', url: _oceans),
      ],
    ),
    VodItem(
      id: 'doc-flower',
      title: '花朵 · 微距',
      subtitle: '自然纪实 · 公开素材',
      description: 'CC0 授权的微距花卉片段，常被用于编码与画质测试。',
      license: _licenseSample,
      section: VodSection.documentaries,
      accentSeed: 7,
      episodes: const <VodEpisode>[
        VodEpisode(number: 1, title: '正片', url: _flower),
      ],
    ),
  ];

  static List<VodItem> get all => List<VodItem>.unmodifiable(_items);

  static List<VodItem> inSection(VodSection section) =>
      _items.where((i) => i.section == section).toList(growable: false);

  static VodItem? byId(String id) {
    for (final i in _items) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// 把片库包装成标准源适配器，注册进 [SourceRegistry] 后即可复用整套播放链路。
  static MemorySourceAdapter buildAdapter() {
    final episodes = <String, List<EpisodeInfo>>{};
    final urls = <String, List<PlayUrl>>{};
    for (final item in _items) {
      episodes[item.id] = item.episodes
          .map((e) => EpisodeInfo(episode: e.number, title: e.title))
          .toList(growable: false);
      for (final e in item.episodes) {
        urls['${item.id}#${e.number}'] = <PlayUrl>[
          PlayUrl(url: e.url, qualityRank: 50),
        ];
      }
    }
    return MemorySourceAdapter(
      id: sourceId,
      // 内置片库没有集数偏移、没有广告插入：画像保持全零，
      // 这样内容坐标与原始坐标完全一致，续播不会出现「差一集」。
      profile: const SourceProfile(name: sourceId),
      qualityRank: 50,
      episodes: episodes,
      urls: urls,
    );
  }
}
