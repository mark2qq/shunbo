import '../../features/vod/third_party_vod.dart';
import '../../features/vod/vod_catalog.dart';
import '../../features/vod/vod_pager.dart';
import 'source_config_url.dart';

/// 一次「应用当前地址」的可读结果。设置页直接显示 [message]。
class VodImportReport {
  const VodImportReport({
    required this.ok,
    required this.message,
    this.items = const <VodItem>[],
    this.sourceId = '',
    this.sourceName = '',
    this.headers = const <String, String>{},
    this.loadedSites = 0,
    this.skippedSites = 0,
    this.totalAvailable = 0,
    this.sitesTotal = 0,
    this.hasMore = false,
  });

  final bool ok;
  final String message;
  final List<VodItem> items;
  final String sourceId;
  final String sourceName;
  final Map<String, String> headers;
  final int loadedSites;
  final int skippedSites;

  /// 接口自己统计的总片量（分页元信息累加；0 表示接口没给）。
  final int totalAvailable;
  final int sitesTotal;

  /// 是否还有下一页没取（调用方据此显示「加载更多」）。
  final bool hasMore;
}

/// 分段进度：每拉完一批（若干站各一页）回传一次。
///
/// 用处是「边加载边显示」——默认源最多探测 100 个站点，等全跑完再一次性
/// 刷出卡片，用户会觉得栏目切换像卡死；分批入库能让新卡片一路冒出来。
class VodImportPartial {
  const VodImportPartial({
    required this.items,
    required this.loadedSites,
    required this.failedSites,
    required this.probedSites,
    required this.totalSites,
    this.totalAvailable = 0,
    this.done = false,
  });

  final List<VodItem> items;
  final int loadedSites;
  final int failedSites;
  final int probedSites;
  final int totalSites;

  /// 接口统计的总片量（用于「已加载 M / 共 N 部」）。
  final int totalAvailable;

  /// 是否已翻完全部分页。
  final bool done;
}

/// 可注入的取数函数，便于门禁 / 回归脚本用本地 HttpServer 替身做端到端验证。
typedef VodTextFetcher = Future<SourceConfigUrlResult> Function(
  String url, {
  bool allowInsecureHttp,
});

/// `open()` 的结果：识别成功时带一个**分页器**，识别失败时带可读原因。
class VodSessionStart {
  const VodSessionStart({
    required this.ok,
    required this.message,
    this.pager,
    this.contractItems = const <VodItem>[],
    this.sourceId = '',
    this.sourceName = '',
    this.headers = const <String, String>{},
    this.skippedSites = 0,
  });

  final bool ok;
  final String message;

  /// 采集站分页器（契约 JSON 没有分页，为 null）。
  final VodSourcePager? pager;
  final List<VodItem> contractItems;
  final String sourceId;
  final String sourceName;
  final Map<String, String> headers;
  final int skippedSites;
}

/// 1.0.5 G1：把第三方接口真正变成「点播数据 + 可播放地址」。
///
/// 复用 `fetchSourceConfigUrl` 的传输净化（字节上限、重定向主机一致、
/// NUL 检查、超时），因此没有第二条下载路径；新增的只是**内容层协议适配**。
/// 全程不发任何可执行代码，也不加载 jar / JS。
///
/// 1.0.5 第三次修：改为**分页**。接口统计的百万级片量不可能一次装进内存，
/// 所以对外暴露 [open]（拿分页器）+ [import]（按预算跑若干页）两种口径，
/// 栏目页用分页器实现「滚到底继续加载」。
class ThirdPartyVodService {
  ThirdPartyVodService({VodTextFetcher? fetcher})
      : _fetcher = fetcher ?? _defaultFetcher;

  final VodTextFetcher _fetcher;

  /// 本机实测：Dart 的 HttpClient 走系统代理访问这些采集站会挂住 / 失败，
  /// 而 `findProxy = DIRECT` 能稳定返回 JSON（Python 用的是环境变量代理，
  /// 两者行为不同）。因此**直连优先**，失败再用短超时回退代理，
  /// 兼顾「只能走代理出网」的环境；失败时返回直连的可读错误。
  static Future<SourceConfigUrlResult> _defaultFetcher(
    String url, {
    bool allowInsecureHttp = false,
  }) async {
    // rejectHtml: true —— 点播源要的是接口 JSON，网页一律当场判定，
    // 不再拖到字节上限才报「超过 256 KB」（实测 starlink 277 KB HTML）。
    final direct = await fetchSourceConfigUrl(
      url,
      allowInsecureHttp: allowInsecureHttp,
      useSystemProxy: false,
      timeout: const Duration(seconds: 6),
      rejectHtml: true,
    );
    if (direct.ok) return direct;
    // 已能确定「这是网页 / 这站根本不应答」就不必再走代理重试：
    // 实测每个超时站都要多等 5 秒，一轮导入里这种站点占一半，
    // 白等的 5 秒 × 十几个站就是「点播页加载很慢」的重要来源。
    if (direct.failure == SourceConfigUrlFailure.htmlPage ||
        direct.failure == SourceConfigUrlFailure.timeout) {
      return direct;
    }
    final viaProxy = await fetchSourceConfigUrl(
      url,
      allowInsecureHttp: allowInsecureHttp,
      useSystemProxy: true,
      timeout: const Duration(seconds: 4),
      rejectHtml: true,
    );
    return viaProxy.ok ? viaProxy : direct;
  }

  /// 源 id 由配置地址决定：同一地址多次应用会复用同一份续播记录；
  /// 换到另一个接口时前缀不同，不会把 A 站的进度串到 B 站的同名影片上。
  static String sourceIdFor(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return '外部点播·${host.isEmpty ? '自定义' : host}';
  }

  /// 只做「识别 + 建分页器」，不发任何采集请求。
  ///
  /// 说明：本方法**不运行任何外部代码**（没有 JVM / JS 引擎）。当
  /// [allowExternalCode] 为 true 时，`type:3` 里那些 `api` 本身就是 http(s)
  /// 采集地址的站点也会进入探测池，用同一条纯数据协议取数 —— 这类站点占了
  /// 插件型站点的绝大多数，是「片源没全部加载」的主要缺口。
  Future<VodSessionStart> open({
    required String url,
    required bool allowInsecureHttp,
    int maxSites = kMaxThirdPartySites,
    bool allowExternalCode = true,
    int itemsPerPage = kVodItemsPerSitePage,
    int sitesPerBatch = kVodSitesPerBatch,
  }) async {
    final sourceId = sourceIdFor(url);
    final SourceConfigUrlResult config;
    try {
      config = await _fetcher(url, allowInsecureHttp: allowInsecureHttp);
    } catch (e) {
      return VodSessionStart(
          ok: false, message: '链接导入失败：下载时发生异常（$e）');
    }
    if (!config.ok || config.text == null) {
      return VodSessionStart(
          ok: false, message: '链接导入失败：${config.message}');
    }
    final scan = scanVodConfigText(
      config.text!,
      sourceId: sourceId,
      allowExternalCode: allowExternalCode,
    );
    switch (scan.kind) {
      case VodConfigKind.contract:
        return VodSessionStart(
          ok: true,
          message: '${scan.reason}；已加入点播栏目，可直接播放',
          contractItems: scan.contractItems,
          sourceId: sourceId,
          sourceName: scan.name.isEmpty ? '自定义点播数据' : scan.name,
          headers: scan.headers,
        );

      case VodConfigKind.pluginOnly:
      case VodConfigKind.malformed:
        return VodSessionStart(
          ok: false,
          message: scan.reason,
          skippedSites: scan.pluginSites,
        );

      case VodConfigKind.cmsSites:
        // 站点上限只截断「进池的顺序」，不再截断条目：分页会一直翻到该站结尾。
        final pool = scan.sites.take(maxSites).toList(growable: false);
        return VodSessionStart(
          ok: true,
          message: '识别到 ${scan.sites.length} 个采集站'
              '${scan.pluginSites > 0 ? '（另有 ${scan.pluginSites} 个需脚本 / 无可用 api，已跳过）' : ''}',
          pager: VodSourcePager(
            sites: pool,
            sourceId: sourceId,
            fetcher: _fetcher,
            headers: scan.headers,
            allowInsecureHttp: allowInsecureHttp,
            itemsPerPage: itemsPerPage,
            sitesPerBatch: sitesPerBatch,
          ),
          sourceId: sourceId,
          sourceName: scan.name.isEmpty ? '采集接口' : scan.name,
          headers: scan.headers,
          skippedSites: scan.pluginSites,
        );
    }
  }

  /// 一次性导入：在 [budget] 内尽量多翻几页（设置页「导入」按钮用这条）。
  ///
  /// 千页级的完整目录**不该**在一次点击里拉完：实测单站单页（1 次列表 + 5 次详情）
  /// 要 300–800 ms，百万条就是几小时。这里按预算收工，剩下的交给栏目页
  /// 「加载更多」继续翻。
  Future<VodImportReport> import({
    required String url,
    required bool allowInsecureHttp,
    int maxSites = kMaxThirdPartySites,
    int itemsPerSite = kVodItemsPerSitePage,
    bool allowExternalCode = true,
    void Function(VodImportPartial partial)? onProgress,
    Duration budget = const Duration(seconds: 60),
    // 一批 5 个站 → 20 批正好覆盖站点上限 100。真正兜底的是 budget：
    // 慢站会把每批拖到 6 秒，预算一到就收工，已拿到的条目照常入库。
    int maxBatches = 20,
  }) async {
    final start = await open(
      url: url,
      allowInsecureHttp: allowInsecureHttp,
      maxSites: maxSites,
      allowExternalCode: allowExternalCode,
      itemsPerPage: itemsPerSite,
    );
    if (!start.ok) {
      return VodImportReport(
          ok: false, message: start.message, skippedSites: start.skippedSites);
    }
    final pager = start.pager;
    if (pager == null) {
      return VodImportReport(
        ok: true,
        message: start.message,
        items: start.contractItems,
        sourceId: start.sourceId,
        sourceName: start.sourceName,
        headers: start.headers,
        totalAvailable: start.contractItems.length,
      );
    }

    final items = <VodItem>[];
    final watch = Stopwatch()..start();
    var batches = 0;
    while (!pager.done &&
        batches < maxBatches &&
        watch.elapsed < budget &&
        items.length < kMaxThirdPartyItems) {
      final batch = await pager.next();
      batches++;
      items.addAll(batch.items);
      onProgress?.call(VodImportPartial(
        items: List<VodItem>.unmodifiable(items),
        loadedSites: pager.loadedSites,
        failedSites: pager.finishedSites - pager.loadedSites,
        probedSites: pager.finishedSites,
        totalSites: pager.siteCount,
        totalAvailable: pager.discoveredTotal,
        done: pager.done,
      ));
      // 一整批一条都没取到（全是失败页）就收工，别把预算耗在死站上。
      if (batch.fetched == 0) break;
    }

    if (items.isEmpty) {
      return VodImportReport(
        ok: false,
        message: '已识别 ${pager.siteCount} 个采集站，但没有拿到带播放地址的影片。'
            '请换一个地址，或检查网络 / 是否只允许直连。',
        skippedSites: start.skippedSites,
        sitesTotal: pager.siteCount,
      );
    }
    final limited = items.take(kMaxThirdPartyItems).toList(growable: false);
    return VodImportReport(
      ok: true,
      message: '已接入 ${start.sourceName}：'
          '${pager.loadedSites} 个站点 / ${limited.length} 部可播放条目，'
          '已加入点播栏目'
          '${pager.discoveredTotal > 0 ? '（接口统计共 ${pager.discoveredTotal} 部）' : ''}'
          '${pager.done ? '' : '，还有更多可继续加载'}',
      items: limited,
      sourceId: start.sourceId,
      sourceName: start.sourceName,
      headers: start.headers,
      loadedSites: pager.loadedSites,
      skippedSites: start.skippedSites,
      totalAvailable: pager.discoveredTotal,
      sitesTotal: pager.siteCount,
      hasMore: !pager.done,
    );
  }
}
