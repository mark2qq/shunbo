import '../../core/source/memory_source_adapter.dart';
import '../../core/source/source_adapter.dart';
import '../../core/source/source_profile.dart';

/// 点播栏目。与侧栏一一对应（直播不在其中，直播有自己的播放模型）。
enum VodSection {
  movies('电影'),
  series('电视剧'),
  documentaries('纪录片');

  const VodSection(this.label);
  final String label;
}

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

  const VodItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.license,
    required this.section,
    required this.episodes,
    this.accentSeed = 0,
  });

  int get episodeCount => episodes.length;
  bool get isSeries => episodes.length > 1;
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
