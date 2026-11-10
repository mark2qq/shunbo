import 'source_fetcher.dart';
import 'source_profile.dart';

/// 源适配层（E2）抽象与数据模型。
///
/// 设计稿核心诉求：多源解析（爬虫协议兼容 / jar 类加载 / QuickJS 脚本）+ 换源调度。
///
/// 重要约束（原评估已登记为落差）：jar 爬虫不可跨端，桌面/TV 端源覆盖明显少于 Android。
/// 因此本抽象刻意把「适配器能否用于当前平台」作为一等约束暴露出来，
/// 由 [SourceCatalog] 在注册时按平台裁剪，避免「桌面端列出 Android 专属源」的体验陷阱。
enum SourcePlatform { android, desktop, tv }

/// 搜索结果条目。
class MediaSearchResult {
  final String mediaId;
  final String title;
  final String? coverUrl;

  const MediaSearchResult({
    required this.mediaId,
    required this.title,
    this.coverUrl,
  });
}

/// 单集元信息。
class EpisodeInfo {
  final int episode;
  final String title;

  const EpisodeInfo({required this.episode, required this.title});
}

/// 一条可播放地址候选。
///
/// [qualityRank] 越大越清晰；换源调度在「对齐内容位置」后，从同内容多候选中择优。
class PlayUrl {
  final String url;
  final int qualityRank;

  const PlayUrl({required this.url, this.qualityRank = 0});
}

/// 源适配器统一契约。
///
/// 实现方：Android 端可用 jar/QuickJS 解析；桌面/TV 端可能仅支持纯 Dart 解析子集。
/// 所有适配器都必须暴露 [profile]（与 [SourceProfile.name] 对齐），供调度层做内容对齐。
abstract class SourceAdapter {
  /// 源标识，须与 [SourceProfile.name] 一致，供 [SourceCatalog] 与调度层定位。
  String get id;

  /// 该适配器可运行的平台集合；空集合表示未声明（默认不跨端）。
  Set<SourcePlatform> get supportedPlatforms;

  /// 搜索媒体。
  Future<List<MediaSearchResult>> search(String keyword);

  /// 获取某媒体的剧集列表（按 episode 升序）。
  Future<List<EpisodeInfo>> getEpisodes(String mediaId);

  /// 解析某集播放地址候选（可多个，供换源调度择优）。
  Future<List<PlayUrl>> resolvePlayUrl(String mediaId, int episode);

  /// 该源的对齐画像，供 [SourceCatalog] 注册。
  SourceProfile get profile;

  /// **源级优先级**（越大越优先）：多源聚合时同名结果按此排序，供用户先看到
  /// 质量更好的源。与 [PlayUrl.qualityRank] 的区别：后者是「同一源内多个播放地址」
  /// 的清晰度择优，这里是「源与源之间」的排序权重。
  ///
  /// 默认 0，因此未配置该字段的源保持原有聚合顺序（排序实现是稳定的）。
  int get qualityRank => 0;

  /// 播放该源地址时需要携带的请求头（Referer / User-Agent 等）。
  ///
  /// 为什么必须交给播放器：源站普遍校验 Referer，取数时带了、播放时不带，
  /// 结果就是「能搜到、能拿到地址、一播就 403」。这些头属于**同一个源配置**，
  /// 不该在播放层再配一遍（两份配置迟早不一致）。
  ///
  /// 默认空集合：不依赖请求头的源（本地样本站点、公开 CDN）无需改动。
  Map<String, String> get playbackHeaders => const <String, String>{};
}

/// 适配器边界异常：把「取数层技术异常」带上 sourceId，供编排层翻译成
/// E7 的一等播放失效（[SourceFetchFailure] 决定失效原因分流）。
///
/// 之所以不直接在适配器里抛 `PlaybackFailureException`，是为了避免
/// core/source 反向依赖更上层的 core/scheduler，保持分层单向。
class SourceAdapterException implements Exception {
  final String sourceId;
  final SourceFetchFailure reason;
  final String message;

  const SourceAdapterException({
    required this.sourceId,
    required this.reason,
    required this.message,
  });

  @override
  String toString() => 'SourceAdapterException($sourceId/${reason.name}): $message';
}
