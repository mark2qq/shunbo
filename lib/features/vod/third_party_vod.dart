/// 1.0.5 第三方点播数据接入 —— **纯数据解析层**。
///
/// 支持两种第三方接口形态：
///  * 顺播点播数据契约 JSON（顶层 `items`）：自备 / 已授权接口，直接给出
///    影片、剧集与播放地址；
///  * TVBox 配置里的苹果 CMS V10 采集站（`sites`）：`?ac=list`
///    取影片列表、`?ac=detail&ids=` 取 `vod_play_url`，都是普通 HTTP JSON。
///
/// 关于 `type:3` / `csp_*` / `spider jar` 站点（1.0.5 第二次放宽）：
/// 这类站点在 TVBox 里靠执行外部 JS / jar 才产出数据，本客户端**不运行**任何
/// 外部代码（没有 JVM、没有 JS 引擎）。但实测相当一部分 `type:3` 站点的
/// `api` 字段本身就是一条 HTTP 采集地址 —— 它们只是被标了 3 号类型，
/// 用普通 CMS 协议照样能取到列表与详情。因此新增「允许执行外部代码」开关：
/// 打开后这类**带 http(s) api 的插件站也会进入探测池**，用同一条纯数据协议尝试；
/// `api` 是 `csp_xxx` 这种脚本名的（真的必须跑脚本）仍然跳过并如实计数。
///
/// 本文件不依赖 Flutter，也不发网络请求，可在裸 `dart run` 下回归。
/// 无论开关怎么设，这里始终是**零代码执行**的纯数据解析层：
/// 不启动子进程、不加载类、不跑脚本，只把 HTTP 正文变成结构体。
library;

import 'dart:convert';
import 'dart:isolate';

import 'vod_catalog.dart';

/// 单次接入的条目上限（安全天花板，不是业务上限）。
///
/// 60 → 240（2026-11-11 第一次）：一份配置里常有 10 个以上可用采集站。
/// 240 → 360（2026-11-11 第二次）：站点上限提到 100 后，若仍按 240 截断，
/// 后半程真正能出片的站点会被前 20 个站占满额度。
/// 360 → 20000（2026-11-11 第三次）：接入分页后这个值不再是「一次导入多少」，
/// 而是**进程内条目数的安全天花板**。实测默认源 20 个站合计
/// 1,197,091 部（`pagecount` 累加），逐页拉完既不可能也不需要全量驻留内存；
/// 这里只兜住「用户一直点加载更多」不会把内存吃光。
const int kMaxThirdPartyItems = 20000;

/// 分页器每页取多少部（= 采集站 `ac=list` 的默认 `limit`）。
const int kVodItemsPerSitePage = 20;

/// 分页器一轮取几个站。
///
/// 3 太慢（一批只有 20–40 条新增，翻十几批才两三百部），8 以上又会让
/// 「最慢的那个站」拖住整批。5 是实测折中：一批 4 秒左右、新增 40–80 部。
const int kVodSitesPerBatch = 5;

/// 落盘缓存最多保存多少条（**按实测体积定档，不是拍脑袋**）。
///
/// 2500 → 10000（2026-11-11 第四次）：需求要求「初始化即完整目录、检索优先查
/// 本地」，2500 条只够翻十几页就撞上限，后台补进来的新片会挤掉老片 ——
/// 用户搜一部昨天还看过的片子却搜不到，这比「加载慢」更糟。
///
/// 定档依据（真机落盘文件 + `dart run` 实测，不是估算）：
///  * 2500 条 = 5,948,057 B（字符 5,202,908），`episodes` 占 **71.1%**
///    （50954 条剧集 / 平均 20.4 条/部，p90 是 58 条、最大 200 条），
///    平均单条 2967 B —— 体积主要由播放地址撑起，不是元数据；
///  * 读盘 28 ms + `jsonDecode` 29–46 ms ⇒ 冷启动这一档约 75 ms，无感；
///  * 线性外推到 10000 条：约 24 MB / 解码 130–190 ms，加 `fromRecords` 的
///    逐条归一仍在半秒内，电视盒子启动不会变成「卡两秒」；
///  * 而 [kMaxThirdPartyItems] 的 20000 条要 47 MB / 解码 600 ms 起，
///    老盒子 NAND 慢 3–5 倍 ⇒ 会明显拖慢冷启动，**所以不跟内存天花板对齐**。
///
/// 与「完整目录」的关系要说实话：接口自己统计百万级（默认源 20 站合计
/// 1,197,091 部），物理上装不进电视。这里的 10000 条是**本地检索库的容量**，
/// 后台全量同步到 [kMaxThirdPartyItems] 为止；超出容量的部分仍在内存里可看，
/// 只是不落盘 —— 冷启动后由后台按批补回。
const int kVodCacheMaxItems = 10000;

/// 落盘文件的体积护栏：超过这个大小直接判定文件不可信，走网络重建。
///
/// 存在的意义是防「磁盘被外部改过 / 旧版本写坏了」把冷启动拖死：
/// 10000 条约 24 MB，留 3 倍余量。没有这条护栏时，一个 200 MB 的畸形
/// JSON 会让 `jsonDecode` 卡住几秒，用户看到的就是「App 启动黑屏」。
const int kMaxVodLibraryBytes = 72 * 1024 * 1024;

/// 初始化时后台「一次把目录补全」的批次数与总预算（1.0.5 第十一次修）。
///
/// 「完整目录」的边界要如实说清：接口自己统计百万级，物理上装不进电视，
/// [kMaxThirdPartyItems] 才是内存天花板。这里的完整指**翻到分页器 done
/// 或触到天花板**，全程后台自动完成，用户不需要点「加载更多」。
/// 240 批 × 5 站/批 × 20 条/站 = 24000，足够触到 20000 上限；
/// 5 分钟是慢站兜底，预算到点收工，已拿到的条目照常入库并落盘。
const int kVodFullSyncMaxBatches = 240;
const Duration kVodFullSyncBudget = Duration(minutes: 5);

/// 单条目的剧集上限。
const int kMaxThirdPartyEpisodes = 200;

/// 单次导入最多探测多少个站点（需求明确：maxSites = 100）。
///
/// 只是上限，实际取 `min(配置内站点数, 100)`。原值 32 会让配置里第 33 名以后的
/// 站点从未被请求 —— 而采集站可用率不高（实测 20 站 11 可达），排得靠后的
/// 仍可能出片，用户看到的却是「片源没全部加载」。
const int kMaxThirdPartySites = 100;

/// 每个站点取多少部影片。
///
/// 20 部（4 个详情批次）是实测的折中：单站贡献的片量够看，
/// 又不会让一个慢站把整轮导入拖长。12 部会让同一个配置少掉三成条目
/// （实测默认源：12 → 108 部，20 → 180 部），用户看到的就是「片源变少了」。
const int kMaxThirdPartyItemsPerSite = 20;

const int kMaxThirdPartyUrlLength = 2048;
const int kMaxThirdPartyFieldLength = 240;
const int kMaxThirdPartyConfigBytes = 256 * 1024;
const int kMaxThirdPartyPosterLength = 2048;

const String kThirdPartyLicense =
    '第三方接口提供 · 版权与授权由接口方及使用者自行确认';

/// 只放行反盗链常用头；Host / Connection / Cookie / Authorization 等一律忽略，
/// 避免外部配置借播放链路注入凭证或改写请求语义。
const Set<String> kAllowedPlaybackHeaderNames = <String>{
  'referer',
  'user-agent',
  'origin',
};

enum VodConfigKind {
  /// 顺播点播数据契约，已直接产出条目。
  contract,

  /// TVBox 配置里含可接入的 `type:1` 采集站。
  cmsSites,

  /// 只有插件型站点（csp_ / jar / type:3），没有可接入的纯数据接口。
  pluginOnly,

  /// 不是可识别的配置。
  malformed,
}

/// 一个可接入的苹果 CMS 采集站。
class CmsSite {
  const CmsSite({
    required this.key,
    required this.name,
    required this.api,
    this.plugin = false,
  });

  final String key;
  final String name;
  final String api;

  /// 配置里标的是 `type:3`（插件型），但 `api` 是一条 http(s) 采集地址。
  /// 只有在「允许执行外部代码」打开时才会进入探测池。
  final bool plugin;

  String get listUrl => _withAc(api, 'list');

  /// 第 [page] 页的列表地址（苹果 CMS 的分页参数是 `pg`，从 1 开始）。
  ///
  /// 1.0.5 第三次修的关键：原来只请求 `?ac=list`（等价 `pg=1`），
  /// 每个站只拿到 20 部，20 个站合计 180 部 —— 而接口统计的片量是百万级。
  String listUrlAt(int page) =>
      page <= 1 ? listUrl : _withAc(api, 'list', extra: 'pg=$page');

  /// 第 [page] 页的**详情列表**地址：`?ac=detail&pg=N`。
  ///
  /// 苹果 CMS 的这个接口一次就返回 20 部的完整信息（含 `vod_play_url`），
  /// 相当于「列表 + 20 次详情」的合并版。实测同样 20 部：
  /// 走 list + 分批 detail 要 6 个请求、3–8 秒；走 detail&pg 只要 1 个请求、
  /// 1.3–3.6 秒。分页要翻几百页，这一条决定了「加载更多」是 3 秒还是 8 秒。
  String detailPageUrl(int page) =>
      page <= 1 ? _withAc(api, 'detail') : _withAc(api, 'detail', extra: 'pg=$page');

  String detailUrl(Iterable<String> ids) =>
      _withAc(api, 'detail', extra: 'ids=${ids.join(',')}');
}

/// 列表接口里的一条影片元数据（不含播放地址）。
class CmsEntry {
  const CmsEntry({
    required this.id,
    required this.title,
    required this.typeName,
    required this.remarks,
    required this.year,
    required this.area,
    this.pic = '',
    this.typeId = '',
    this.genre = '',
  });

  final String id;
  final String title;
  final String typeName;
  final String remarks;
  final String year;
  final String area;

  /// 海报图（已按站点 host 解析成绝对地址；解析不出来就是空串）。
  final String pic;

  /// 类目 id（`type_id`）。配合 [CmsCategoryTable] 才能把「现代言情」
  /// 这种看不出是短剧的子类目，顺着 `type_pid` 归到短视频栏目。
  final String typeId;

  /// 剧情类型（`vod_class`）：与栏目类目 `type_name` 不是一个维度。
  final String genre;
}

/// 苹果 CMS 类目表中的一项。
class CmsCategory {
  const CmsCategory({
    required this.id,
    required this.parentId,
    required this.name,
  });

  final String id;
  final String parentId;
  final String name;
}

/// 站点类目表（`?ac=list` 响应里的 `class` 数组）。
///
/// 为什么要单独解析：实测暴风资源把「短剧大全」拆成 `重生民国` /
/// `现代言情` / `AI漫剧` 等子类目，它们的 `type_name` 里**没有「短剧」**
/// 两个字，只按名字归类会把上万部短剧漏进电影 / 电视剧栏目。
/// 类目表带 `type_pid`，顺着父链就能认出来。
class CmsCategoryTable {
  const CmsCategoryTable(this.byId);

  static const CmsCategoryTable empty =
      CmsCategoryTable(<String, CmsCategory>{});

  final Map<String, CmsCategory> byId;

  bool get isEmpty => byId.isEmpty;

  /// 该类目（或其祖先类目）是否属于短视频。
  ///
  /// 带 visited 集合：脏数据里出现过 `type_pid` 自指 / 成环，
  /// 不设防会让整批解析卡死。
  bool isShortVideo(String typeId) {
    var cursor = typeId;
    final seen = <String>{};
    while (cursor.isNotEmpty && cursor != '0' && seen.add(cursor)) {
      final c = byId[cursor];
      if (c == null) return false;
      if (isShortVideoText(c.name)) return true;
      cursor = c.parentId;
    }
    return false;
  }

  /// 该类目（或其祖先类目）是否属于动漫。
  ///
  /// 与 [isShortVideo] 同一套父链遍历：实测有站点把动漫拆成
  /// `国产动漫` / `日韩动漫` 等子类目挂在 `动漫` 之下，名字本身已带
  /// 「动漫」；但也有站点只把 `漫剧` 挂在 `短剧大全` 之下，
  /// 必须顺父链才能判断。同样带 visited 集合防成环。
  bool isAnime(String typeId) {
    var cursor = typeId;
    final seen = <String>{};
    while (cursor.isNotEmpty && cursor != '0' && seen.add(cursor)) {
      final c = byId[cursor];
      if (c == null) return false;
      if (isAnimeText(c.name)) return true;
      cursor = c.parentId;
    }
    return false;
  }
}

/// 从 `?ac=list`（或任何带 `class` 的响应）里解析类目表。
///
/// 没有 `class` 字段时返回空表，调用方自动回落到「按 `type_name` 文本归类」，
/// 不会因为站点少给一个字段就丢掉整页内容。
CmsCategoryTable parseCmsCategories(String text) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    return CmsCategoryTable.empty;
  }
  if (decoded is! Map) return CmsCategoryTable.empty;
  return _categoriesFrom(decoded['class']);
}

CmsCategoryTable _categoriesFrom(Object? raw) {
  if (raw is! List) return CmsCategoryTable.empty;
  final out = <String, CmsCategory>{};
  for (final r in raw) {
    if (r is! Map) continue;
    final m = Map<String, dynamic>.from(r);
    final id = _asText(m['type_id']);
    if (id.isEmpty) continue;
    out[id] = CmsCategory(
      id: id,
      parentId: _asText(m['type_pid']),
      name: _clip(_asText(m['type_name']), 40),
    );
  }
  return out.isEmpty ? CmsCategoryTable.empty : CmsCategoryTable(out);
}

/// 列表接口的一页结果：影片元数据 + 分页元信息。
///
/// 分页元信息是 1.0.5 第三次修的核心：苹果 CMS 的 `ac=list` 响应里带
/// `page` / `pagecount` / `total` / `limit`，据此才能知道「这个站总共多少部、
/// 还有没有下一页」。原来把这些字段整个丢掉，于是永远只拿到第一页 20 部。
class CmsListing {
  const CmsListing({
    required this.entries,
    this.page = 1,
    this.pageCount = 0,
    this.total = 0,
    this.limit = 0,
    this.categories = CmsCategoryTable.empty,
  });

  final List<CmsEntry> entries;
  final int page;

  /// 该站的类目表（只在带 `class` 的响应里有）。
  final CmsCategoryTable categories;

  /// 总页数（0 表示接口没给，按「取到空页为止」处理）。
  final int pageCount;

  /// 该站总片量（0 表示接口没给）。
  final int total;

  /// 每页条数（0 表示接口没给）。
  final int limit;

  bool get hasMore => pageCount <= 0 || page < pageCount;

  /// 粗略估算「还没取到的条数」，用于界面上「还有 N 部」的提示。
  int get remaining {
    if (total <= 0 || limit <= 0) return 0;
    final left = total - page * limit;
    return left > 0 ? left : 0;
  }
}

/// `?ac=detail&pg=N` 的一页：元数据 + 详情（含剧集）一次拿全。
class CmsDetailPage {
  const CmsDetailPage({
    required this.entries,
    required this.details,
    this.page = 1,
    this.pageCount = 0,
    this.total = 0,
    this.limit = 0,
    this.categories = CmsCategoryTable.empty,
  });

  final List<CmsEntry> entries;
  final Map<String, CmsDetail> details;
  final CmsCategoryTable categories;
  final int page;
  final int pageCount;
  final int total;
  final int limit;

  bool get hasPlayableDetails =>
      details.values.any((d) => d.episodes.isNotEmpty);
}

/// 详情接口解析出的正文与剧集。
class CmsDetail {
  const CmsDetail({
    required this.content,
    required this.episodes,
    this.poster = '',
    this.genre = '',
  });

  final String content;
  final List<VodEpisode> episodes;

  /// 详情里的海报（列表没给 `vod_pic` 时用它兜底）。
  final String poster;

  /// `vod_class`（真题材，如「喜剧,爱情」）。
  ///
  /// **列表接口常常不给这个字段**（实测本地 1 万条缓存里 71.5% 为空），
  /// 详情接口才稳定返回。所以内置索引点开一部片时，这是唯一能补上
  /// 「类型」维度的时机。
  final String genre;
}

class VodConfigScan {
  const VodConfigScan({
    required this.kind,
    required this.reason,
    this.sites = const <CmsSite>[],
    this.contractItems = const <VodItem>[],
    this.headers = const <String, String>{},
    this.name = '',
    this.totalSites = 0,
    this.pluginSites = 0,
    this.externalCodeSites = 0,
  });

  final VodConfigKind kind;
  final String reason;
  final List<CmsSite> sites;
  final List<VodItem> contractItems;
  final Map<String, String> headers;
  final String name;
  final int totalSites;

  /// 被跳过的插件型站点数（`csp_*` 脚本、或未开启「允许外部代码」时的 `type:3`）。
  final int pluginSites;

  /// 已放行、进入探测池的插件型站点数（`type:3` 且 `api` 是 http(s)）。
  final int externalCodeSites;

  bool get usable =>
      kind == VodConfigKind.contract || kind == VodConfigKind.cmsSites;
}

/// 把第三方接口返回的文本识别成可接入形态。
///
/// [sourceId] 用于给条目 id 加前缀，避免与内置片库或另一个第三方源撞 id
/// （撞 id 会让续播记录串到别的片子上）。
///
/// [allowExternalCode] 打开后，`type:3` 且带 http(s) `api` 的插件型站点
/// 也会进入探测池（用同一条纯数据 CMS 协议取数，不在本机运行 jar / JS）。
VodConfigScan scanVodConfigText(
  String text, {
  required String sourceId,
  bool allowExternalCode = true,
}) {
  if (text.trim().isEmpty) {
    return const VodConfigScan(
        kind: VodConfigKind.malformed, reason: '配置内容为空');
  }
  if (text.length > kMaxThirdPartyConfigBytes) {
    return const VodConfigScan(
        kind: VodConfigKind.malformed,
        reason: '配置超过 256 KB 上限，已中止解析');
  }
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    return const VodConfigScan(
      kind: VodConfigKind.malformed,
      reason: '不是合法 JSON：该地址返回的可能是 HTML 页面或接口分发站，'
          '不是点播数据 / 源配置',
    );
  }
  if (decoded is! Map) {
    return const VodConfigScan(
        kind: VodConfigKind.malformed, reason: '配置顶层不是 JSON 对象');
  }
  final m = Map<String, dynamic>.from(decoded);
  final name = _clip(_asText(m['name']), 80);

  if (m['items'] is List) {
    return _parseContract(m, sourceId, name);
  }
  if (m['sites'] is List) {
    return _scanSites(m, name, allowExternalCode: allowExternalCode);
  }
  if (m.containsKey('spider')) {
    return VodConfigScan(
      kind: VodConfigKind.pluginOnly,
      reason: '该配置只声明了 spider jar，没有可接入的纯数据站点；'
          '本客户端不运行外部代码（无 JVM / JS 引擎），无法从这条配置里取出影片数据',
      name: name,
    );
  }
  return const VodConfigScan(
    kind: VodConfigKind.malformed,
    reason: '配置既不含 items 也不含 sites，无法解析为点播数据',
  );
}

VodConfigScan _parseContract(
    Map<String, dynamic> m, String sourceId, String name) {
  final raw = m['items'] as List;
  final headers = safePlaybackHeaders(m['headers']);
  final items = <VodItem>[];
  for (final r in raw) {
    if (items.length >= kMaxThirdPartyItems) break;
    if (r is! Map) continue;
    final e = Map<String, dynamic>.from(r);
    final id = _asText(e['id']);
    final title = _clip(_asText(e['title']), 80);
    if (id.isEmpty || title.isEmpty) continue;
    final rawEpisodes = e['episodes'];
    if (rawEpisodes is! List) continue;
    final episodes = <VodEpisode>[];
    for (final x in rawEpisodes) {
      if (episodes.length >= kMaxThirdPartyEpisodes) break;
      if (x is! Map) continue;
      final em = Map<String, dynamic>.from(x);
      final url = _asText(em['url']);
      if (!safeMediaUrl(url)) continue;
      final rawNumber = em['number'];
      final number = rawNumber is int && rawNumber > 0
          ? rawNumber
          : episodes.length + 1;
      episodes.add(VodEpisode(
        number: number,
        title: _clip(_asText(em['title']).isEmpty
            ? '第 $number 集'
            : _asText(em['title']), 80),
        url: url,
      ));
    }
    if (episodes.isEmpty) continue;
    items.add(VodItem(
      id: '$sourceId:$id',
      title: title,
      subtitle: _clip(_asText(e['subtitle']), 100),
      description: _clip(_stripTags(_asText(e['description'])), 400),
      license: _clip(_asText(e['license']).isEmpty
          ? kThirdPartyLicense
          : _asText(e['license']), 160),
      section: sectionFromName(_asText(e['section'])),
      episodes: List<VodEpisode>.unmodifiable(episodes),
      accentSeed: items.length % 8,
      sourceId: sourceId,
      headers: headers,
      posterUrl: resolvePosterUrl(_asText(e['poster']).isEmpty
          ? (_asText(e['pic']).isEmpty
              ? _asText(e['cover'])
              : _asText(e['pic']))
          : _asText(e['poster'])),
      // 本地检索记录的四个基本维度：契约 JSON 里给什么就存什么，
      // 没给就是空串（不编造「未知」），本地记录与检索结果因此同源。
      typeName: _clip(_asText(e['type']).isEmpty
          ? _asText(e['typeName'])
          : _asText(e['type']), 40),
      area: _clip(_asText(e['area']), 40),
      year: _clip(_asText(e['year']), 12),
      genre: _clip(_asText(e['genre']).isEmpty
          ? _asText(e['class'])
          : _asText(e['genre']), 60),
    ));
  }
  if (items.isEmpty) {
    return const VodConfigScan(
      kind: VodConfigKind.malformed,
      reason: 'items 中没有一条带可播放地址（仅支持 http/https 的媒体地址）',
    );
  }
  return VodConfigScan(
    kind: VodConfigKind.contract,
    reason: '点播数据契约：解析出 ${items.length} 部可播放条目',
    contractItems: List<VodItem>.unmodifiable(items),
    headers: headers,
    name: name,
  );
}

VodConfigScan _scanSites(
  Map<String, dynamic> m,
  String name, {
  required bool allowExternalCode,
}) {
  final raw = m['sites'] as List;
  final sites = <CmsSite>[];
  var plugin = 0;
  var external = 0;
  final seen = <String>{};
  for (final r in raw) {
    if (r is! Map) {
      plugin++;
      continue;
    }
    final s = Map<String, dynamic>.from(r);
    final api = _asText(s['api']);
    final type = s['type'];
    final key = _clip(_asText(s['key']), 60);
    // api 必须是可直接请求的 http(s) 地址：`csp_xxx` 是脚本名不是地址。
    final apiIsUrl = (api.startsWith('http://') || api.startsWith('https://')) &&
        safeMediaUrl(api);
    final isCms = type == 1 || type == '1';
    final isPlugin = type == 3 ||
        type == '3' ||
        key.startsWith('csp_') ||
        api.startsWith('csp_');
    if (!apiIsUrl || seen.contains(api)) {
      plugin++;
      continue;
    }
    if (isCms) {
      seen.add(api);
      sites.add(CmsSite(key: key, name: _clip(_asText(s['name']), 60), api: api));
      continue;
    }
    if (isPlugin && allowExternalCode) {
      // 允许外部代码：这类站点只是被标成插件型，api 本身还是采集地址，
      // 用普通 CMS 协议就能取到列表与详情，本机不运行任何 jar / JS。
      seen.add(api);
      external++;
      sites.add(CmsSite(
        key: key,
        name: _clip(_asText(s['name']), 60),
        api: api,
        plugin: true,
      ));
      continue;
    }
    plugin++;
  }
  if (sites.isEmpty) {
    return VodConfigScan(
      kind: VodConfigKind.pluginOnly,
      reason: '共 ${raw.length} 个站点，没有一条可直接请求的采集地址'
          '（全是 csp_ / spider 脚本名，必须执行外部 JS / jar 才能取数）；'
          '本客户端不运行外部代码，请改填返回点播数据契约 JSON '
          '或含 http(s) api 的采集站配置。',
      name: name,
      totalSites: raw.length,
      pluginSites: plugin,
    );
  }
  return VodConfigScan(
    kind: VodConfigKind.cmsSites,
    reason: '识别到 ${sites.length} 个可直接取数的采集站'
        '${external > 0 ? '（其中 $external 个是插件型站点，已用其 HTTP 接口尝试）' : ''}'
        '${plugin > 0 ? '，另有 $plugin 个站点需执行脚本 / 没有可用 api，已跳过' : ''}',
    sites: List<CmsSite>.unmodifiable(sites),
    name: name,
    totalSites: raw.length,
    pluginSites: plugin,
    externalCodeSites: external,
  );
}

/// 拼接 CMS 采集参数：原地址已带 `ac=` 就替换，否则按有无 query 追加。
String _withAc(String api, String ac, {String extra = ''}) {
  final q = Uri.tryParse(api)?.query ?? '';
  final params = <String, String>{};
  for (final part in q.split('&')) {
    if (part.isEmpty) continue;
    final i = part.indexOf('=');
    if (i <= 0) continue;
    params[part.substring(0, i)] = part.substring(i + 1);
  }
  params['ac'] = ac;
  if (extra.isNotEmpty) {
    final i = extra.indexOf('=');
    params[extra.substring(0, i)] = extra.substring(i + 1);
  }
  final base = api.split('?').first;
  // ids 是逗号分隔的数字串，不能编码成 %2C —— 部分 CMS 实现只认裸逗号。
  final query = params.entries
      .map((e) => e.key == 'ids'
          ? 'ids=${e.value}'
          : '${e.key}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');
  return '$base?$query';
}

/// 解析 `?ac=list` 返回的影片列表（只取条目，兼容老调用方）。
///
/// [baseUrl] 用于把 `/upload/vod/xxx.jpg` 这类**相对海报地址**解析成绝对地址：
/// 采集站的 `vod_pic` 有近一半是相对路径，直接拿去请求必然 404，
/// 表现就是「图片全都加载不出来」。
List<CmsEntry> parseCmsList(
  String text, {
  int maxItems = 20,
  String baseUrl = '',
}) =>
    parseCmsListing(text, maxItems: maxItems, baseUrl: baseUrl).entries;

/// 解析一页列表，连同分页元信息（`page` / `pagecount` / `total` / `limit`）。
CmsListing parseCmsListing(  String text, {
  int maxItems = 20,
  String baseUrl = '',
}) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    return const CmsListing(entries: <CmsEntry>[]);
  }
  if (decoded is! Map) return const CmsListing(entries: <CmsEntry>[]);
  final list = decoded['list'];
  if (list is! List) return const CmsListing(entries: <CmsEntry>[]);
  final out = <CmsEntry>[];
  for (final r in list) {
    if (out.length >= maxItems) break;
    if (r is! Map) continue;
    final m = Map<String, dynamic>.from(r);
    final id = _asText(m['vod_id']);
    final title = _clip(_asText(m['vod_name']), 80);
    if (id.isEmpty || title.isEmpty) continue;
    final pic = _asText(m['vod_pic']).isEmpty
        ? _asText(m['vod_pic_slide'])
        : _asText(m['vod_pic']);
    out.add(CmsEntry(
      id: id,
      title: title,
      typeName: _asText(m['type_name']),
      remarks: _asText(m['vod_remarks']),
      year: _asText(m['vod_year']),
      area: _asText(m['vod_area']),
      pic: resolvePosterUrl(pic, base: baseUrl),
      typeId: _asText(m['type_id']),
      genre: _clip(_asText(m['vod_class']), 60),
    ));
  }
  return CmsListing(
    entries: List<CmsEntry>.unmodifiable(out),
    // 有的站把 `page` 写成字符串、有的写成数字，统一按 int 读。
    page: _asInt(decoded['page'], fallback: 1),
    pageCount: _asInt(decoded['pagecount']),
    total: _asInt(decoded['total']),
    limit: _asInt(decoded['limit']),
    categories: _categoriesFrom(decoded['class']),
  );
}

/// 解析 `?ac=detail&pg=N` 的一页：一次拿到元数据 **和** 每部的 `vod_play_url`。
///
/// 与 [parseCmsListing] + [parseCmsDetails] 组合等价，但只需要一个请求。
/// 站点不支持合并接口时（返回里没有 `vod_play_url`），调用方回落成
/// 「列表 + 分批详情」的老路径。
CmsDetailPage parseCmsDetailPage(
  String text, {
  int maxItems = 20,
  String baseUrl = '',
}) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    return const CmsDetailPage(entries: <CmsEntry>[], details: <String, CmsDetail>{});
  }
  if (decoded is! Map) {
    return const CmsDetailPage(entries: <CmsEntry>[], details: <String, CmsDetail>{});
  }
  final list = decoded['list'];
  if (list is! List) {
    return const CmsDetailPage(entries: <CmsEntry>[], details: <String, CmsDetail>{});
  }
  final entries = <CmsEntry>[];
  final details = <String, CmsDetail>{};
  for (final r in list) {
    if (entries.length >= maxItems) break;
    if (r is! Map) continue;
    final m = Map<String, dynamic>.from(r);
    final id = _asText(m['vod_id']);
    final title = _clip(_asText(m['vod_name']), 80);
    if (id.isEmpty || title.isEmpty) continue;
    final pic = _asText(m['vod_pic']).isEmpty
        ? _asText(m['vod_pic_slide'])
        : _asText(m['vod_pic']);
    final poster = resolvePosterUrl(pic, base: baseUrl);
    entries.add(CmsEntry(
      id: id,
      title: title,
      typeName: _asText(m['type_name']),
      remarks: _asText(m['vod_remarks']),
      year: _asText(m['vod_year']),
      area: _asText(m['vod_area']),
      pic: poster,
      typeId: _asText(m['type_id']),
      genre: _clip(_asText(m['vod_class']), 60),
    ));
    details[id] = CmsDetail(
      content: _clip(_stripTags(_asText(m['vod_content'])), 400),
      episodes: parseVodPlayUrl(_asText(m['vod_play_url'])),
      poster: poster,
    );
  }
  return CmsDetailPage(
    entries: List<CmsEntry>.unmodifiable(entries),
    details: Map<String, CmsDetail>.unmodifiable(details),
    page: _asInt(decoded['page'], fallback: 1),
    pageCount: _asInt(decoded['pagecount']),
    total: _asInt(decoded['total']),
    limit: _asInt(decoded['limit']),
    categories: _categoriesFrom(decoded['class']),
  );
}

/// 解析 `?ac=detail&ids=` 返回的正文（详情接口同样带 `vod_pic`，
/// 列表里没给海报时用它兜底）。

/// 解析 `?ac=detail&ids=` 返回的详情，按 vod_id 建索引。
Map<String, CmsDetail> parseCmsDetails(String text, {String baseUrl = ''}) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    return const <String, CmsDetail>{};
  }
  if (decoded is! Map) return const <String, CmsDetail>{};
  final list = decoded['list'];
  if (list is! List) return const <String, CmsDetail>{};
  final out = <String, CmsDetail>{};
  for (final r in list) {
    if (r is! Map) continue;
    final m = Map<String, dynamic>.from(r);
    final id = _asText(m['vod_id']);
    if (id.isEmpty) continue;
    final episodes = parseVodPlayUrl(_asText(m['vod_play_url']));
    final pic = _asText(m['vod_pic']).isEmpty
        ? _asText(m['vod_pic_slide'])
        : _asText(m['vod_pic']);
    out[id] = CmsDetail(
      content: _clip(_stripTags(_asText(m['vod_content'])), 400),
      episodes: episodes,
      poster: resolvePosterUrl(pic, base: baseUrl),
      genre: _clip(_asText(m['vod_class']), 60),
    );
  }
  return Map<String, CmsDetail>.unmodifiable(out);
}

/// 解析苹果 CMS 的 `vod_play_url`。
///
/// 典型格式：`第1集$https://…/1.m3u8#第2集$https://…/2.m3u8$$$备用源…`
/// `$$$` 分隔**播放源**、`#` 分隔集、`$` 分隔「集标题 / 地址 / 备注」。
///
/// 1.0.5 第三次修（重要）：原来只取第一个源（`split('$$$').first`），
/// 于是「首源是 `/share/<hash>` 网页、次源才是真 m3u8」的站点被整站判死 ——
/// 实测电影天堂的 `vod_play_url` 就是
/// `…/share/67c34b96…#…$$$第01集$https://vip.dytt-tvs.com/20261007/40184_67c34b96/index.m3u8#…`：
/// 第一个源全是 HTML 跳转页，第二个源是干净直链。现在**逐源打分**，
/// 取「直链数最多的那个源」，同分取靠前的。
List<VodEpisode> parseVodPlayUrl(String raw) {
  if (raw.trim().isEmpty) return const <VodEpisode>[];
  final sources = raw.split(r'$$$');
  var best = const <VodEpisode>[];
  var bestScore = -1;
  for (final source in sources) {
    final eps = _parsePlaySource(source);
    if (eps.isEmpty) continue;
    final score = eps.where((e) => looksLikeDirectMedia(e.url)).length;
    if (score > bestScore) {
      best = eps;
      bestScore = score;
    }
    // 全直链就已经是最优解，不必再看后面的备用源。
    if (score > 0 && score == eps.length) break;
  }
  return best.isEmpty ? const <VodEpisode>[] : List<VodEpisode>.unmodifiable(best);
}

List<VodEpisode> _parsePlaySource(String source) {
  final out = <VodEpisode>[];
  for (final part in source.split('#')) {
    if (out.length >= kMaxThirdPartyEpisodes) break;
    final pieces = part
        .split(r'$')
        .map((x) => x.trim())
        .where((x) => x.isNotEmpty)
        .toList(growable: false);
    var url = '';
    var title = '';
    for (var i = 0; i < pieces.length; i++) {
      if (_looksLikeUrl(pieces[i])) {
        url = pieces[i];
        if (i > 0) title = pieces[i - 1];
        break;
      }
    }
    if (!safeMediaUrl(url)) continue;
    final number = out.length + 1;
    out.add(VodEpisode(
      number: number,
      title: _clip(title.isEmpty ? '第 $number 集' : title, 80),
      url: url,
    ));
  }
  return out;
}

/// 把列表元数据与详情合并成可直接进栏目、可起播的 [VodItem]。
List<VodItem> buildCmsItems({
  required List<CmsEntry> entries,
  required Map<String, CmsDetail> details,
  required String sourceId,
  Map<String, String> headers = const <String, String>{},
  // 多个采集站的 vod_id 都是从 1 开始的数字，加站点前缀才不会串片 /
  // 串续播记录；条目仍共用同一个 sourceId（一个适配器管全部站点）。
  String idScope = '',
  CmsCategoryTable categories = CmsCategoryTable.empty,
}) {
  final out = <VodItem>[];
  for (final e in entries) {
    if (out.length >= kMaxThirdPartyItems) break;
    final d = details[e.id];
    if (d == null || d.episodes.isEmpty) continue;
    final bits = <String>[
      if (e.year.isNotEmpty) e.year,
      if (e.area.isNotEmpty) e.area,
      if (e.remarks.isNotEmpty) e.remarks,
    ];
    out.add(VodItem(
      id: '$sourceId:${idScope.isEmpty ? '' : '$idScope:'}${e.id}',
      title: e.title,
      subtitle: _clip(bits.isEmpty ? e.typeName : bits.join(' · '), 100),
      description: d.content.isEmpty
          ? '由第三方采集接口提供的点播条目；分类：${e.typeName}。'
          : d.content,
      license: kThirdPartyLicense,
      section: sectionFromCms(
        typeName: e.typeName,
        typeId: e.typeId,
        categories: categories,
      ),
      episodes: d.episodes,
      accentSeed: out.length % 8,
      sourceId: sourceId,
      headers: headers,
      // 列表的海报优先（同一张图，少一次空值判断）；列表没给就用详情的。
      posterUrl: e.pic.isNotEmpty ? e.pic : d.poster,
      // 结构化筛选维度：原样透传，空就是空（不编造「其他」）。
      typeName: _clip(e.typeName, 40),
      area: _clip(e.area, 40),
      year: _clip(e.year, 12),
      genre: _clip(e.genre, 60),
    ));
  }
  return List<VodItem>.unmodifiable(out);
}

/// CMS 条目的栏目归类：短视频优先，再看类目父链，最后才是动漫 / 纪录片 /
/// 剧集 / 电影。
///
/// 顺序不能换：`短剧大全`、`AI短剧` 都含「剧」字，走老的剧集分支就会
/// 把短视频塞进电视剧栏目。动漫排在短视频之后：`AI漫剧` 这类既像短剧
/// 又像动漫的类目，按用户口径归短视频（它是竖屏短剧形态），
/// 其余动漫类目（`动漫` / `动画片` / `动漫电影` / `国产动漫`…）归动漫。
VodSection sectionFromCms({
  required String typeName,
  String typeId = '',
  CmsCategoryTable categories = CmsCategoryTable.empty,
}) {
  if (isShortVideoText(typeName)) return VodSection.shortVideo;
  if (typeId.isNotEmpty && categories.isShortVideo(typeId)) {
    return VodSection.shortVideo;
  }
  if (typeId.isNotEmpty && categories.isAnime(typeId)) {
    return VodSection.anime;
  }
  return sectionFromName(typeName);
}

/// 栏目归类：短视频 → 动漫 → 纪录片 → 剧集 → 电影 → 其他。
/// 也接受契约里的英文枚举值。
///
/// 1.0.5 第十一次修：老实现最后一行是 `return VodSection.movies`，等于把
/// 「认不出来的类目」全兜底成电影。真实数据因此把 64 条大陆综艺、52 条足球、
/// 46 条日韩综艺、9 条记录片、61 条短剧子类目塞进了电影栏目。现在认不出来
/// 就归 [VodSection.other]（留在本地检索记录里，但不进任何栏目）。
VodSection sectionFromName(String raw) {
  final s = raw.toLowerCase().trim();
  // 契约 JSON 的英文枚举优先，避免 'movies' 被词表当成证据不足。
  switch (s) {
    case 'shortvideo':
    case 'short_video':
    case 'short':
    case 'shorts':
      return VodSection.shortVideo;
    case 'anime':
    case 'animation':
    case 'cartoon':
      return VodSection.anime;
    case 'documentaries':
    case 'documentary':
      return VodSection.documentaries;
    case 'series':
    case 'tv':
    case 'tvseries':
      return VodSection.series;
    case 'movies':
    case 'movie':
    case 'film':
      return VodSection.movies;
    case 'other':
    case 'others':
      return VodSection.other;
  }
  return vodSectionFromText(s) ?? VodSection.other;
}

/// 判断地址是否像**可直接交给播放器**的媒体文件。
///
/// 实测教训：部分采集站的 `vod_play_url` 指向 `/share/<hash>` 这类 HTML
/// 跳转页（Range 请求返回 `text/html` 206），把它当成 m3u8 喂给播放器只会黑屏。
/// 这里只做形态判定（零网络请求），服务层据此跳过整批不是媒体的站点。
bool looksLikeDirectMedia(String raw) {
  final u = raw.trim().toLowerCase();
  if (!safeMediaUrl(raw)) return false;
  final path = (Uri.tryParse(u)?.path ?? u).toLowerCase();
  const mediaSuffixes = <String>[
    '.m3u8',
    '.mp4',
    '.ts',
    '.flv',
    '.m4v',
    '.mkv',
    '.avi',
    '.mpd',
  ];
  return mediaSuffixes.any(path.endsWith);
}

/// 从「播放页」派生直链，派生不出来返回 null。
///
/// 实测口径（2026-11-11，20 个采集站）：一部分站点在 `vod_play_url` 里给的是
/// `/play/<id>` 播放页而不是媒体地址。这类页面追加 `/index.m3u8` 就能拿到
/// `200 + application/vnd.apple.mpegurl + #EXTM3U`（xluuss / jisuzyv / huyall
/// 三站全部成立）；而 `/share/<hash>` 型（ukubf3 / dytt-tvs / lzcdn27）不成立，
/// 返回 404 或另一张网页 —— 所以只对 `/play/` 派生。
///
/// **派生只是「猜一个地址」，调用方必须先真发一次请求验证再整站采用**，
/// 不能凭形式改写 URL：对端改版后这会让整站变成点开全黑。
String? deriveDirectMediaUrl(String raw) {
  final u = raw.trim();
  if (!safeMediaUrl(u)) return null;
  if (looksLikeDirectMedia(u)) return null;
  final uri = Uri.tryParse(u);
  if (uri == null) return null;
  final path = uri.path;
  if (!path.toLowerCase().contains('/play/')) return null;
  if (path.endsWith('/')) return null;
  final last = path.split('/').last;
  if (last.contains('.')) return null;
  return uri.replace(path: '$path/index.m3u8').toString();
}

/// 海报地址规范化：补协议、拼相对路径、去非法字符。
///
/// 实测采集站的 `vod_pic` 有三种坑：`//cdn/x.jpg` 省协议、`/upload/vod/x.jpg`
/// 相对路径、以及带空格 / 中文且**没有**做百分号编码。前两种按站点 host 补齐，
/// 第三种只做一次 `Uri.encodeFull` 再校验——校验不过就当作没有海报，
/// 卡片回落色块，绝不把一条必 404 的地址塞给 Image 组件反复重试。
String resolvePosterUrl(String raw, {String base = ''}) {
  var t = raw.trim();
  if (t.isEmpty || t.length > kMaxThirdPartyPosterLength) return '';
  // 去掉 HTML 实体残渣；**不删中间的空格**——文件名里真有空格，
  // 删掉会变成另一张不存在的图（下面统一按 %20 编码）。
  t = t.replaceAll('&amp;', '&').trim();
  if (t.startsWith('//')) {
    t = 'http:$t';
  } else if (!t.startsWith('http://') && !t.startsWith('https://')) {
    if (base.isEmpty) return '';
    final b = Uri.tryParse(base);
    if (b == null || b.host.isEmpty) return '';
    try {
      t = b.resolve(t).toString();
    } catch (_) {
      return '';
    }
  }
  if (!t.startsWith('http://') && !t.startsWith('https://')) return '';
  if (t.codeUnits.any((c) => c < 0x20 || c == 0x7f)) return '';
  // 中文 / 空格路径：逐字符百分号编码（只动非可打印 ASCII，保留已有的 %XX）。
  if (t.codeUnits.any((c) => c > 0x7e || c == 0x20)) {
    t = t.replaceAllMapped(
        RegExp(r'[^\x21-\x7E]'), (m) => Uri.encodeComponent(m[0]!));
  }
  final uri = Uri.tryParse(t);
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) return '';
  if (uri.scheme != 'http' && uri.scheme != 'https') return '';
  return t.length > kMaxThirdPartyPosterLength ? '' : t;
}

/// 把一个「大块 JSON」的解析挪出主 isolate。
///
/// 为什么需要：一次导入要解析上百个 `ac=list` / `ac=detail` 响应，
/// 单个详情响应常有 100–400 KB。全部在主 isolate 上 `jsonDecode`，
/// 用户看到的就是「栏目切换卡住、页面像在重新加载」——实测这才是卡顿主因，
/// 而不是条目多。小响应仍走同步解析，省掉 isolate 的启动开销。
Future<List<CmsEntry>> parseCmsListAsync(
  String text, {
  int maxItems = 20,
  String baseUrl = '',
}) async {
  if (text.length < 48 * 1024) {
    return parseCmsList(text, maxItems: maxItems, baseUrl: baseUrl);
  }
  return Isolate.run(
      () => parseCmsList(text, maxItems: maxItems, baseUrl: baseUrl));
}

/// 一页列表的异步解析版本（大响应移出主 isolate），语义与 [parseCmsListing] 一致。
Future<CmsListing> parseCmsListingAsync(
  String text, {
  int maxItems = 20,
  String baseUrl = '',
}) async {
  if (text.length < 48 * 1024) {
    return parseCmsListing(text, maxItems: maxItems, baseUrl: baseUrl);
  }
  return Isolate.run(
      () => parseCmsListing(text, maxItems: maxItems, baseUrl: baseUrl));
}

/// 详情列表页的异步解析（500 KB 级响应必须离开主 isolate）。
Future<CmsDetailPage> parseCmsDetailPageAsync(
  String text, {
  int maxItems = 20,
  String baseUrl = '',
}) async {
  if (text.length < 48 * 1024) {
    return parseCmsDetailPage(text, maxItems: maxItems, baseUrl: baseUrl);
  }
  return Isolate.run(
      () => parseCmsDetailPage(text, maxItems: maxItems, baseUrl: baseUrl));
}

/// 详情解析的异步版本（大响应移出主 isolate），语义与 [parseCmsDetails] 一致。
Future<Map<String, CmsDetail>> parseCmsDetailsAsync(
  String text, {
  String baseUrl = '',
}) async {
  if (text.length < 48 * 1024) {
    return parseCmsDetails(text, baseUrl: baseUrl);
  }
  return Isolate.run(() => parseCmsDetails(text, baseUrl: baseUrl));
}

/// 媒体 / 采集地址安全校验：只允许 http(s)，拒内嵌账密与控制字符。
bool safeMediaUrl(String raw) {
  final u = raw.trim();
  if (u.isEmpty || u.length > kMaxThirdPartyUrlLength) return false;
  if (u.codeUnits.any((c) => c < 0x20 || c == 0x7f)) return false;
  if (u.contains(' ')) return false;
  final uri = Uri.tryParse(u);
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  if (uri.host.isEmpty || uri.userInfo.isNotEmpty) return false;
  return true;
}

/// 只保留反盗链常用头，其余（含 Cookie / Authorization / Host）一律丢弃。
Map<String, String> safePlaybackHeaders(Object? raw) {
  if (raw is! Map) return const <String, String>{};
  const canonical = <String, String>{
    'referer': 'Referer',
    'user-agent': 'User-Agent',
    'origin': 'Origin',
  };
  final out = <String, String>{};
  raw.forEach((k, v) {
    final key = k.toString().trim().toLowerCase();
    if (!kAllowedPlaybackHeaderNames.contains(key)) return;
    final value = v.toString().trim();
    if (value.isEmpty || value.length > 512) return;
    if (value.codeUnits.any((c) => c < 0x20 || c == 0x7f)) return;
    out[canonical[key]!] = value;
  });
  return Map<String, String>.unmodifiable(out);
}

bool _looksLikeUrl(String s) =>
    s.startsWith('http://') || s.startsWith('https://');

String _asText(Object? v) => v == null ? '' : v.toString().trim();

/// 宽容地把 `page` / `pagecount` 这类字段读成整数。
///
/// 实测同一批采集站里，`page` 有写 `1` 的、也有写 `"1"` 的，还有缺字段的；
/// 只要读错一个，分页就会「永远第一页」或者「第一页就认为到结尾」。
int _asInt(Object? v, {int fallback = 0}) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? fallback;
  return fallback;
}

String _clip(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…';

String _stripTags(String s) => s
    .replaceAll(RegExp(r'<[^>]*>'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
