import '../player/player_controller.dart';
import '../../data/resume_record.dart';
import '../../data/resume_store.dart';
import '../source/source_adapter.dart';
import '../source/source_fetcher.dart';
import '../source/source_profile.dart';
import '../source/source_registry.dart';
import 'alignment.dart';
import 'playback_failure.dart';
import 'progress_reporting.dart';
import 'source_catalog.dart';

/// 一次播放的快照（含派生内容坐标，便于 UI 直观展示对齐效果）。
class PlaybackSession {
  final String mediaId;
  final String mediaTitle;
  final String sourceId;
  final int rawEpisode;
  final double rawSeconds;

  /// 实际交给播放器的物理地址（解析结果的最高画质那条）。
  ///
  /// 投屏必须复用**这一个**地址：电视要自己拉流，另编一个地址等于换了个资源。
  /// 之前 session 不携带它，UI 投屏只能用 `https://cast/...` 这种假地址，
  /// 投屏「成功」了却播不出来 —— 属于典型的假成功。
  final String playUrl;

  /// 派生：去广告后的规范内容坐标（由 [rawToContent] 计算）。
  final int contentEpisode;
  final double contentSeconds;

  /// 拉这条流必须携带的请求头（`Referer` / `User-Agent` 等）。
  ///
  /// 投屏要它，是因为**电视补不了这些头**：直推给电视的地址拿不到图中的
  /// 原因往往就是源站校验 `Referer`。串流中继拿这份头去拉流，才能绕开 403。
  /// 与 [playUrl] 一样，它是「本次真正生效的播放参数」的一部分，
  /// 不能到投屏时再去源里重查一遍（那时可能已经换源了）。
  final Map<String, String> headers;

  PlaybackSession._from(
    this.mediaId,
    this.mediaTitle,
    this.sourceId,
    this.rawEpisode,
    this.rawSeconds,
    this.playUrl,
    this.contentEpisode,
    this.contentSeconds,
    this.headers,
  );

  /// 由原始坐标 + 源画像构造，并同步计算内容坐标。
  factory PlaybackSession.fromRaw({
    required String mediaId,
    required String mediaTitle,
    required String sourceId,
    required SourceProfile profile,
    required int rawEpisode,
    required double rawSeconds,
    required String playUrl,
    Map<String, String> headers = const <String, String>{},
  }) {
    final c = rawToContent(profile, rawEpisode, rawSeconds);
    return PlaybackSession._from(
      mediaId,
      mediaTitle,
      sourceId,
      rawEpisode,
      rawSeconds,
      playUrl,
      c.$1,
      c.$2,
      headers,
    );
  }
}

/// 搜索命中：来自哪个源 + 该源的搜索结果。
class SearchHit {
  final String sourceId;
  final MediaSearchResult result;

  /// 来源配置的源级优先级，供 UI 标注 / 上层做二次排序（越大越优先）。
  final int qualityRank;

  const SearchHit({
    required this.sourceId,
    required this.result,
    this.qualityRank = 0,
  });
}

/// 换源对齐结果（MVP 核心：演示 #1 暗坑）。
class SwitchResult {
  final String toSourceId;
  final int alignedRawEpisode;
  final double alignedRawSeconds;
  final PlayUrl playUrl;
  final PlaybackSession session;

  const SwitchResult({
    required this.toSourceId,
    required this.alignedRawEpisode,
    required this.alignedRawSeconds,
    required this.playUrl,
    required this.session,
  });
}

/// 播放编排层：把「搜索→选源→解析→对齐→载入」串成连贯链路。
///
/// 依赖 [SourceRegistry]（适配器，按平台裁剪）+ [SourceCatalog]（画像，换源对齐权威）
/// + [PlayerController]（播放内核抽象）+ [ResumeStore]（E6 跨端续播落库）。
/// 换源决策的唯一权威是业务能力层，本类只负责执行对齐与载入，不自行决定业务目标源。
///
/// 失效语义（E7）：解析不到可播放地址属**可恢复的播放失效**，统一抛
/// [PlaybackFailureException] 交由自动换源处理；源未注册/画像缺失属程序员错误，
/// 仍抛 [StateError]。两者刻意区分，避免把配置错误误判成「换个源就好」。
class PlaybackOrchestrator {
  final SourceRegistry registry;
  final SourceCatalog catalog;
  final PlayerController player;
  final ResumeStore resumeStore;

  /// 播放中进度上报（可选）：传入后每次成功载入即切换锚点，
  /// 让「续播记录」从「载入点」变成「真实观看位置」。
  final ProgressReporter? progress;

  PlaybackOrchestrator({
    required this.registry,
    required this.catalog,
    required this.player,
    required this.resumeStore,
    this.progress,
  });

  /// 每次载入后落盘续播进度（只存规范内容坐标，详见 [ResumeRecord]）。
  Future<void> _saveResume(PlaybackSession s) async {
    await resumeStore.save(ResumeRecord(
      mediaId: s.mediaId,
      title: s.mediaTitle,
      sourceId: s.sourceId,
      canonicalEpisode: s.contentEpisode,
      canonicalSeconds: s.contentSeconds,
      updatedAt: DateTime.now(),
    ));
  }

  /// 查询某媒体是否有续播进度。
  Future<ResumeRecord?> resumeFor(String mediaId) => resumeStore.load(mediaId);

  /// 把会话交给进度上报器：此后采样到的物理位置会用**该源**画像换算成内容坐标。
  ProgressAnchor _anchorOf(PlaybackSession s, SourceProfile p) => ProgressAnchor(
        mediaId: s.mediaId,
        title: s.mediaTitle,
        sourceId: s.sourceId,
        profile: p,
        rawEpisode: s.rawEpisode,
        rawSeconds: s.rawSeconds,
      );

  /// 「技术异常 → 领域失效」的唯一转换点。
  ///
  /// 真实联网后，取数层抛的是 SourceAdapterException；若让它裸奔到 UI，
  /// UI 的 `on PlaybackFailureException` 抓不到，E7 自动换源就等于没接上。
  /// 这里按失败类别归一：编码/体积问题归 decodeError，其余归 networkError。
  Future<T> _fromAdapter<T>(String sourceId, Future<T> Function() action) async {
    try {
      return await action();
    } on PlaybackFailureException {
      rethrow;
    } on SourceAdapterException catch (e) {
      final reason = (e.reason == SourceFetchFailure.decode ||
              e.reason == SourceFetchFailure.tooLarge)
          ? PlaybackFailureReason.decodeError
          : PlaybackFailureReason.networkError;
      throw PlaybackFailureException(
        reason: reason,
        sourceId: sourceId,
        message: e.message,
      );
    }
  }

  /// 跨当前平台可用适配器搜索，聚合命中结果。
  ///
  /// 多源聚合语义：单个源网络失败时跳过该源继续聚合，不让一次 404
  /// 把整次搜索归零（真实站点临时不可用是常态）。
  Future<List<SearchHit>> search(String keyword, SourcePlatform platform) async {
    final hits = <SearchHit>[];
    for (final a in registry.availableOn(platform)) {
      final List<MediaSearchResult> results;
      try {
        results = await _fromAdapter(a.id, () => a.search(keyword));
      } on PlaybackFailureException {
        continue;
      }
      for (final r in results) {
        hits.add(SearchHit(
            sourceId: a.id, result: r, qualityRank: a.qualityRank));
      }
    }
    // 源级优先级降序；相同 rank 保持注册表原有顺序（Dart 的 List.sort 不稳定，
    // 必须显式带原序号，否则未配置 rank 的源顺序会随机漂移、破坏既有行为）。
    final order = Map<SearchHit, int>.identity();
    for (var i = 0; i < hits.length; i++) {
      order[hits[i]] = i;
    }
    hits.sort((x, y) {
      final byRank = y.qualityRank.compareTo(x.qualityRank);
      return byRank != 0 ? byRank : order[x]!.compareTo(order[y]!);
    });
    return hits;
  }

  /// 初始播放：给定规范内容坐标（集+内容秒），转化为所选源的「原始坐标」后载入。
  Future<PlaybackSession> startPlayback({
    required String sourceId,
    required String mediaId,
    required String mediaTitle,
    required int canonicalEpisode,
    required double canonicalSeconds,
  }) async {
    final adapter = registry.get(sourceId);
    final profile = catalog.get(sourceId);
    if (adapter == null || profile == null) {
      throw StateError('源未注册：$sourceId');
    }
    // 开播前先把上一个会话的进度按**旧锚点**落盘；之后写新记录才不会被旧位置盖掉。
    await progress?.flush();
    final raw = contentToRaw(profile, canonicalEpisode, canonicalSeconds);
    final urls = await _fromAdapter(
        sourceId, () => adapter.resolvePlayUrl(mediaId, raw.$1));
    if (urls.isEmpty) {
      throw PlaybackFailureException(
        reason: PlaybackFailureReason.emptyPlayUrl,
        sourceId: sourceId,
        message: '无可用播放地址：$sourceId#$mediaId#${raw.$1}',
      );
    }
    final best = urls.reduce((a, b) => a.qualityRank >= b.qualityRank ? a : b);
    await player.load(best.url, raw.$1, raw.$2,
        headers: adapter.playbackHeaders);
    await player.play();
    final session = PlaybackSession.fromRaw(
      mediaId: mediaId,
      mediaTitle: mediaTitle,
      sourceId: sourceId,
      profile: profile,
      rawEpisode: raw.$1,
      rawSeconds: raw.$2,
      playUrl: best.url,
      headers: adapter.playbackHeaders,
    );
    await _saveResume(session);
    // 载入即切换进度锚点：之后播放中采样会持续刷新同一份续播记录。
    // 入口已 flush 过，这里不能再兜底 flush（否则会用旧源坐标覆盖刚写的记录）。
    await progress?.begin(_anchorOf(session, profile), flushPrevious: false);
    return session;
  }

  /// 换源（对齐核心）：用户在 from 源的原始位置，切换到 to 源。
  ///
  /// 步骤：from 原始 → [rawToContent] → to 原始（[contentToRaw]），确保落在「同一内容位置」。
  /// 随后按对齐后的原始集解析 to 源地址并载入。
  ///
  /// 只有真正拿到播放地址才算成功：否则抛 [PlaybackFailureException]，
  /// **不载入、不落盘续播、不返回假成功会话**（E7 修复的静默失败缺陷）。
  Future<SwitchResult> switchSourceAligned({
    required String fromSourceId,
    required String toSourceId,
    required String mediaId,
    required String mediaTitle,
    required int fromRawEpisode,
    required double fromRawSeconds,
  }) async {
    final fromP = catalog.get(fromSourceId);
    final toP = catalog.get(toSourceId);
    if (fromP == null || toP == null) {
      throw StateError('换源失败：缺失画像 $fromSourceId/$toSourceId');
    }
    // 换源前先按旧源把当前位置写盘：换源失败时这次观看进度也不会丢，
    // 且能保证旧会话的迟到写入不会覆盖新源的记录。
    await progress?.flush();
    final aligned = switchSource(fromP, toP, fromRawEpisode, fromRawSeconds);
    final adapter = registry.get(toSourceId);
    if (adapter == null) throw StateError('换源失败：缺失适配器 $toSourceId');
    final urls = await _fromAdapter(
        toSourceId, () => adapter.resolvePlayUrl(mediaId, aligned.$1));
    if (urls.isEmpty) {
      throw PlaybackFailureException(
        reason: PlaybackFailureReason.emptyPlayUrl,
        sourceId: toSourceId,
        message: '换源失败，无可用播放地址：$toSourceId#$mediaId#${aligned.$1}',
      );
    }
    final best = urls.reduce((a, b) => a.qualityRank >= b.qualityRank ? a : b);
    await player.load(best.url, aligned.$1, aligned.$2,
        headers: adapter.playbackHeaders);
    await player.play();
    final session = PlaybackSession.fromRaw(
      mediaId: mediaId,
      mediaTitle: mediaTitle,
      sourceId: toSourceId,
      profile: toP,
      rawEpisode: aligned.$1,
      rawSeconds: aligned.$2,
      playUrl: best.url,
      headers: adapter.playbackHeaders,
    );
    await _saveResume(session);
    await progress?.begin(_anchorOf(session, toP), flushPrevious: false);
    return SwitchResult(
      toSourceId: toSourceId,
      alignedRawEpisode: aligned.$1,
      alignedRawSeconds: aligned.$2,
      playUrl: best,
      session: session,
    );
  }
}
