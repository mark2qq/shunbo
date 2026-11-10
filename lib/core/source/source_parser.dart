import 'source_adapter.dart';

/// 解析器契约（E2 真实适配器的解析内核）。
///
/// 输入「站点响应文本」(HTML/JSON)，输出结构化数据。纯 Dart 逻辑、不接触网络，
/// 因此既能在桌面/TV（Dart 子集）运行，也能在 Android（jar 内或 Dart 内）运行，
/// 是跨端复用的核心。网络获取由 [SourceFetcher] 负责。
///
/// 方法定义为异步，以兼容 Android jar 经 MethodChannel 的异步解析实现。
abstract class SourceParser {
  /// 解析搜索结果页。
  Future<List<MediaSearchResult>> parseSearch(String html);

  /// 解析详情页，返回剧集引用（含取播放地址所需的相对路径）。
  Future<List<EpisodeRef>> parseEpisodes(String detailHtml);

  /// 解析播放页，返回播放地址候选。
  Future<List<PlayUrl>> parsePlayUrls(String playPageHtml);
}

/// 剧集引用：详情页解析产物，记录取播放地址所需的相对路径 [playPagePath]。
class EpisodeRef {
  final int episode;
  final String playPagePath;

  const EpisodeRef({required this.episode, required this.playPagePath});
}
