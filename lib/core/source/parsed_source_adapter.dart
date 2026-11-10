import 'source_adapter.dart';
import 'source_fetcher.dart';
import 'source_parser.dart';
import 'source_profile.dart';

/// 组合式真实源适配器（E2）：[SourceParser] 解析 + [SourceFetcher] 取数。
///
/// 替换原先的 [MemorySourceAdapter]（仅内存演示）。真实源 = 一个 parser + 一个 fetcher
/// （桌面用 Dart 子集；Android 用 jar 后端），由平台工厂 [createAdapterForPlatform] 决定。
class ParsedSourceAdapter implements SourceAdapter {
  @override
  final String id;
  @override
  final SourceProfile profile;
  @override
  final Set<SourcePlatform> supportedPlatforms;
  @override
  final int qualityRank;

  final SourceParser parser;
  final SourceFetcher fetcher;

  /// 播放同一源地址时要带的请求头（与取数用的一致）。
  @override
  final Map<String, String> playbackHeaders;

  /// mediaId -> (episode -> 取播放地址的相对路径)，由 [getEpisodes] 填充。
  final Map<String, Map<int, String>> _epPaths = {};

  ParsedSourceAdapter({
    required this.id,
    required this.profile,
    required this.parser,
    required this.fetcher,
    required this.supportedPlatforms,
    this.qualityRank = 0,
    this.playbackHeaders = const <String, String>{},
  });

  /// 取数/解析边界：把底层技术异常带上 sourceId，交给编排层翻译成
  /// E7 可恢复失效。解析层自身的坏数据降级仍按空集处理，不在这里改变语义。
  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on SourceAdapterException {
      rethrow; // 内层（如 getEpisodes）已包装，避免重复套壳
    } on SourceFetchException catch (e) {
      throw SourceAdapterException(
        sourceId: id,
        reason: e.reason,
        message: e.toString(),
      );
    }
  }

  @override
  Future<List<MediaSearchResult>> search(String keyword) => _guard(() async {
        final html = await fetcher.fetchSearch(keyword);
        return parser.parseSearch(html);
      });

  @override
  Future<List<EpisodeInfo>> getEpisodes(String mediaId) => _guard(() async {
        final html = await fetcher.fetchDetail(mediaId);
        final refs = await parser.parseEpisodes(html);
        final map = <int, String>{};
        final list = <EpisodeInfo>[];
        for (final r in refs) {
          map[r.episode] = r.playPagePath;
          list.add(EpisodeInfo(episode: r.episode, title: '第${r.episode}集'));
        }
        _epPaths[mediaId] = map;
        return list;
      });

  @override
  Future<List<PlayUrl>> resolvePlayUrl(String mediaId, int episode) =>
      _guard(() async {
        // 自愈：编排层 startPlayback / 跨端续播可能直接取地址（未先调 getEpisodes），
        // 此处缓存未命中时补拉一次详情页，消除对调用顺序的隐藏依赖。
        var paths = _epPaths[mediaId];
        if (paths == null) {
          await getEpisodes(mediaId);
          paths = _epPaths[mediaId];
        }
        final path = paths?[episode];
        if (path == null) return const <PlayUrl>[];
        final html = await fetcher.fetchPlayPage(mediaId, path);
        return parser.parsePlayUrls(html);
      });
}
