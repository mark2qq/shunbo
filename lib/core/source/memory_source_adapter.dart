import 'source_adapter.dart';
import 'source_profile.dart';

/// 内存示例源适配器（MVP 演示 / 单元测试用，不联网）。
///
/// 用于验证 [SourceAdapter] 契约与换源调度链路，不依赖真实爬虫或 libmpv。
/// 真实实现（Android jar / QuickJS、桌面 Dart 解析子集）将在 E2 落地阶段替换。
class MemorySourceAdapter implements SourceAdapter {
  /// 1.0.5：第三方点播源可携带 Referer / UA 等头；默认空集合，
  /// 内置片库与 1.0.4 的所有构造点行为不变。
  @override
  final Map<String, String> playbackHeaders;

  @override
  final String id;

  @override
  final Set<SourcePlatform> supportedPlatforms;

  @override
  final SourceProfile profile;

  @override
  final int qualityRank;

  final Map<String, List<EpisodeInfo>> _episodes;
  final Map<String, List<PlayUrl>> _urls;

  MemorySourceAdapter({
    required this.id,
    required this.profile,
    this.qualityRank = 0,
    this.supportedPlatforms = const {
      SourcePlatform.android,
      SourcePlatform.desktop,
      SourcePlatform.tv,
    },
    Map<String, List<EpisodeInfo>>? episodes,
    Map<String, List<PlayUrl>>? urls,
    Map<String, String> playbackHeaders = const <String, String>{},
  })  : playbackHeaders = Map<String, String>.unmodifiable(playbackHeaders),
        _episodes = episodes ?? <String, List<EpisodeInfo>>{},
        _urls = urls ?? <String, List<PlayUrl>>{};

  @override
  Future<List<MediaSearchResult>> search(String keyword) async {
    final matched =
        _episodes.keys.where((m) => m.toLowerCase().contains(keyword.toLowerCase())).toList();
    return matched.map((m) => MediaSearchResult(mediaId: m, title: m)).toList();
  }

  @override
  Future<List<EpisodeInfo>> getEpisodes(String mediaId) async {
    return List.unmodifiable(_episodes[mediaId] ?? const <EpisodeInfo>[]);
  }

  @override
  Future<List<PlayUrl>> resolvePlayUrl(String mediaId, int episode) async {
    return List.unmodifiable(_urls['$mediaId#$episode'] ?? const <PlayUrl>[]);
  }
}
