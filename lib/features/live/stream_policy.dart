/// 线路准入收口：**候选层**的「能不能用」与「要不要补请求头」。
///
/// 为什么要有这一层：`official_sources.dart` 里的 `isPlaceholderMediaUrl` 只在
/// 「官方源解析器」这条路径上生效，而聚合索引/内置清单里的线路是**直接进候选表**
/// 的。于是同一类坏源在两处命运不同：
///
/// * 经过解析器 → 被拦下，退回原线路；
/// * 不经过解析器（绝大多数索引线路）→ 直接交给内核播放。
///
/// 实测踩到的两个后果（2026-11-07）：
///
/// 1. `贵州卫视` 首条候选 `live.264788.xyz` 302 到
///    `static.tv.darwinchow.com/status/error_account_pirated.mp4`。这段 MP4 有完整
///    1080p 视频轨、解码器零报错，解码门禁判「可播」，用户看到的是反盗链提示片。
/// 2. `河南卫视` 唯一可解码线路 `media.hndyjyfw.gov.cn` 不带 `Referer` 直接 403；
///    带上站点自己的 Referer 就 200 且分片正常。这不是死链，是**清单缺请求头**。
///
/// 与 `decode_gate` 的分工：解码门禁管「解不解得开」，这一层管「该不该给它解」，
/// 两者都不负责「画面是不是这个台」（那是内容抽样的边界）。
library;

import 'live_channel.dart';
import 'official_sources.dart';

/// 站点强制要求的请求头：线路自身没声明时由这一层补齐。
///
/// 只放**实测过「缺少即 403、补齐即 200」**的站点，不做通用猜测：
/// 乱加 Referer 会让本来正常的 CDN 进入防盗链分支。
const Map<String, Map<String, String>> kSiteRequiredHeaders =
    <String, Map<String, String>>{
  // 河南卫视：裸请求 403，带本站 Referer 200（分片 0x47，解码 720x480 通过）。
  'media.hndyjyfw.gov.cn': <String, String>{
    'Referer': 'http://media.hndyjyfw.gov.cn/',
  },
};

/// 单条线路的准入判定与归一。
abstract final class StreamPolicy {
  /// 这条线路是否**从候选里删掉**。
  ///
  /// 只拦「已知会骗过解码门禁的占位内容」：已知反盗链主机、以及解析器地址本身
  /// 落在该主机上。其余一律保留——公开信号随时可能恢复，删掉等于永远回不来。
  static bool isBlocked(LiveStream s) {
    if (isPlaceholderMediaUrl(s.url)) return true;
    final resolver = s.resolverUrl;
    if (resolver != null && isPlaceholderMediaUrl(resolver)) return true;
    return false;
  }

  /// 补站点强制请求头。线路自带的同名头优先（大小写不敏感）。
  static LiveStream withSiteHeaders(LiveStream s) {
    final rule = _ruleFor(s.url);
    if (rule == null || rule.isEmpty) return s;
    final present = s.headers.keys.map((k) => k.toLowerCase()).toSet();
    final missing = <String, String>{
      for (final e in rule.entries)
        if (!present.contains(e.key.toLowerCase())) e.key: e.value,
    };
    if (missing.isEmpty) return s;
    return LiveStream(
      url: s.url,
      label: s.label,
      qualityRank: s.qualityRank,
      headers: <String, String>{...missing, ...s.headers},
      decodeVerified: s.decodeVerified,
      resolverUrl: s.resolverUrl,
      channelType: s.channelType,
      carrier: s.carrier,
      rawAddr: s.rawAddr,
      transport: s.transport,
    );
  }

  /// 对整张频道表跑一遍：删占位线路、补站点请求头、丢掉被删空的台。
  ///
  /// 返回原对象（引用不变）当且仅当什么都没改，避免无谓的重建破坏
  /// 「内置台优先」的引用比较。
  static List<LiveChannel> apply(Iterable<LiveChannel> channels) {
    final out = <LiveChannel>[];
    for (final c in channels) {
      var changed = false;
      final kept = <LiveStream>[];
      for (final s in c.streams) {
        if (isBlocked(s)) {
          changed = true;
          continue;
        }
        final fixed = withSiteHeaders(s);
        if (!identical(fixed, s)) changed = true;
        kept.add(fixed);
      }
      if (kept.isEmpty) continue;
      out.add(changed
          ? LiveChannel(
              id: c.id,
              name: c.name,
              group: c.group,
              badge: c.badge,
              categories: c.categories,
              tvgId: c.tvgId,
              streams: kept,
            )
          : c);
    }
    return out;
  }

  static Map<String, String>? _ruleFor(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase();
    if (host == null || host.isEmpty) return null;
    final direct = kSiteRequiredHeaders[host];
    if (direct != null) return direct;
    for (final e in kSiteRequiredHeaders.entries) {
      if (host.endsWith('.${e.key}')) return e.value;
    }
    return null;
  }
}
