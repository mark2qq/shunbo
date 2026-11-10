/// 直播选台与线路排序策略（纯 Dart，无 Flutter 依赖）。
///
/// 抽出来的原因不是「好看」，而是**这段逻辑错了界面上只表现为黑屏**：
/// * 首屏选了哪条线路 → 决定用户等 3 秒还是 30 秒才看到画面；
/// * 失效记录怎么算 → 决定「一个镜像整站挂掉」时会不会把整屏频道全部判死；
/// * 探测分批 → 决定死链占满探测窗口时还能不能找到能播的台。
///
/// 这些判断在没有 Flutter 引擎时也必须能验证，所以这里连 `ChangeNotifier`
/// 都不碰，全部是纯函数 / 纯数据结构。
library;

import 'live_channel.dart';
import 'live_health.dart';
import 'network_channel.dart';

/// 失效线路登记簿。
///
/// 记两件事：**单个地址**失效、**整台主机**失效。后者是必要的——
/// 一个 IPTV 镜像域名下线时，指向它的几十个台会一起挂（本项目实测：
/// 31 个内置央视/卫视台共用一个域名，一次全灭）。只按地址记的话，
/// 换到下一个台还要把超时重走一遍，用户会连续看到十几个「正在连接」。
class DeadStreamRegistry {
  DeadStreamRegistry({
    this.ttl = const Duration(minutes: 10),
    this.maxEntries = 200,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// 失效记录的有效期。
  ///
  /// **必须有过期**：公开信号会恢复（镜像复活、用户换网络），
  /// 永久拉黑意味着用户不重启 App 就永远回不到那条线路。
  /// 10 分钟是个折中：足够避开「反复试同一个死地址」的等待，
  /// 又不至于让恢复的信号长时间不可用。
  final Duration ttl;

  /// 记录条数上限，防止长时间使用后无限增长。
  final int maxEntries;

  final DateTime Function() _clock;

  final Map<String, DateTime> _streams = <String, DateTime>{};
  final Map<String, DateTime> _hosts = <String, DateTime>{};

  /// 每个主机「已经失败过几条不同的线路」。
  ///
  /// 与 [_hosts] 分开：计数是「同一个主机上陆续发现几条死线路」，
  /// 而 [_hosts] 是「这个主机已经确定整站不可用」。
  final Map<String, int> _hostFailures = <String, int>{};
  final Map<String, DateTime> _hostFailureAt = <String, DateTime>{};

  /// 同一主机累计几条独立线路失败，才把整台主机判死。
  ///
  /// **设为 3 而不是 1**：公开镜像普遍存在约 10% 的瞬时抖动——实测 119 条
  /// 央视/卫视线路里有 12 条「首次探测超时、重试 2.0~4.7 秒成功」。
  /// 单条抖动就把整站拉黑 10 分钟，会把同一镜像上本来能播的台一起拖下水，
  /// 用户看到的是「好几个台同时点不开」，而它们只是共用了一个会抖的源。
  ///
  /// **从 2 提到 3 是「央视全部不能播」的直接修复**：主索引给 CCTV-1..17 的
  /// 线路有 13 条落在同一个主机（74.91.26.218）上。阈值 2 意味着用户只要在
  /// **任意两个**央视台上各撞一次超时，这一个主机就被整体封禁 10 分钟，
  /// 而它承载的 13 个央视台会同时变成「一条候选都没有」——
  /// [_firstCandidate] 返回 null，界面直接跳过整组央视台。
  /// 3 次仍在「整站真死」时的一轮内累积完成，不会让真故障变慢。
  static const int hostFailureThreshold = 3;

  int get streamCount => _streams.length;

  int get hostCount => _hosts.length;

  /// 某个主机已经累积的失败线路数（诊断与回归用）。
  int hostFailuresOf(String url) => _hostFailures[hostOf(url)] ?? 0;

  static String hostOf(String url) => Uri.tryParse(url)?.host ?? '';

  /// 记一条失效线路（同时累积它的主机失败数）。
  void mark(String url) {
    final now = _clock();
    _prune(now, incoming: url);
    _streams[url] = now;
    final host = hostOf(url);
    if (host.isEmpty) return;
    final failures = (_hostFailures[host] ?? 0) + 1;
    _hostFailures[host] = failures;
    _hostFailureAt[host] = now;
    if (failures >= hostFailureThreshold) _hosts[host] = now;
  }

  bool isDeadUrl(String url) => _isDead(_streams, url);

  bool isDeadHost(String url) => _isDead(_hosts, hostOf(url));

  /// 该地址是否应视为可疑（地址失效或整台主机失效）。
  ///
  /// **只用于排序**（把可疑线路挪到最后先试别的），**不用于判定「这个台还能不能试」**
  /// ——见 [LiveSelection._firstCandidate] 的注释。
  bool isDead(String url) => isDeadUrl(url) || isDeadHost(url);

  /// 这条线路刚刚**真的出过画面**：撤掉它的失效记录，并解除主机的连坐封禁。
  ///
  /// 为什么必须实现：主机连坐是「推测」（这个镜像好像挂了），而线路成功是
  /// 「事实」。只记失败不记成功，会让一次抖动留下 10 分钟的阴影——
  /// 期间同一个主机上明明已经恢复的台仍被当作不可用。
  void noteSuccess(String url) {
    _streams.remove(url);
    final host = hostOf(url);
    if (host.isEmpty) return;
    _hosts.remove(host);
    _hostFailures.remove(host);
    _hostFailureAt.remove(host);
  }

  void clear() {
    _streams.clear();
    _hosts.clear();
    _hostFailures.clear();
    _hostFailureAt.clear();
  }

  /// 查一条记录，顺手做过期清理（懒清理，不需要定时器）。
  bool _isDead(Map<String, DateTime> marks, String key) {
    final at = marks[key];
    if (at == null) return false;
    if (_clock().difference(at) > ttl) {
      marks.remove(key);
      return false;
    }
    return true;
  }

  /// 写入前清一遍：先删过期项，仍超上限就丢最旧的。
  ///
  /// 早期实现是「超过上限直接全清」，这样一次误判就会把所有已知失效记录清掉，
  /// 首屏立刻退回「挨个试死链」的状态。现在改成保留最近的记录。
  void _prune(DateTime now, {required String incoming}) {
    _streams.removeWhere((key, at) => now.difference(at) > ttl);
    _hosts.removeWhere((key, at) => now.difference(at) > ttl);
    // 主机失败计数同样要过期：否则「今天抖过两次」会让这台主机此后
    // 只要再失败一次就被立刻判死，等于阈值退化成 1。
    _hostFailureAt.removeWhere((host, at) {
      final expired = now.difference(at) > ttl;
      if (expired) _hostFailures.remove(host);
      return expired;
    });
    if (_streams.length + 1 <= maxEntries) return;

    final ordered = _streams.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final excess = _streams.length + 1 - maxEntries;
    for (var i = 0; i < excess && i < ordered.length; i++) {
      _streams.remove(ordered[i].key);
    }
    // incoming 自身可能被误删（极老记录场景），mark() 随后会重新写入。
  }
}

/// 线路排序 + 选台。
abstract final class LiveSelection {
  /// 把一条频道的线路排成实际尝试顺序。
  ///
  /// [policy] 在排序**之前**先做通道准入过滤：当前网络不可达的组播 /
  /// 异网运营商内网线路整批消失，连一次失败记录都不产生（方案 F4 / N5）。
  /// 传 null 表示不做通道筛选（所有既有回归与纯公网场景的行为完全不变）。
  ///
  /// 排序键依次是：
  /// 1. **没失效的在前**（失效 = 刚才试过打不开，10 分钟后自动解封）；
  /// 2. **高清线路在前**（[preferHd]，用户明确要求「加载频道首先加载高清线路」）；
  /// 3. **健康分高的在前**（[StreamHealthBoard.scoreOf]：探测快、起播快、成功多）；
  /// 4. 画质高的在前（同档内 1080p > 720p）；
  /// 5. 原始顺序（保证稳定，不会每次刷新都换一条）。
  ///
  /// 为什么高清档要排在健康分之前：健康分是**历史经验**，而「先看高清」是
  /// 用户当下明确表达的偏好。旧排序会让一条实测很快的标清线路永远压住
  /// 没测过的 1080p 线路，用户看到的就是「高清源明明有，却从来不播」。
  /// 失效线路仍排最后——已知打不开的高清线路优先也没有意义。
  ///
  /// 注意只做**排到最后**而不是**直接删除**失效线路：公开信号随时可能恢复，
  /// 彻底删掉会让用户永远回不到那条线路。
  static List<LiveStream> rankStreams(
    LiveChannel channel,
    DeadStreamRegistry dead, {
    StreamHealthBoard? health,
    bool preferHd = true,

    /// 运行时解码门禁判定为「加扰 / 花屏」的地址。
    ///
    /// 与 [DeadStreamRegistry] 分开记：网络失效 10 分钟后可能自愈，
    /// 而加扰是源站属性（CCTV cdrm 那类），同样 10 分钟内不该被反复重试。
    /// 只影响排序，不取消候选资格——否则整台只剩一条时又会出现「无候选」。
    Set<String> decodeBad = const <String>{},

    /// 通道准入（组播 / 运营商内网）。为 null 时不过滤。
    NetworkChannelPolicy? policy,
  }) {
    final ordered = policy == null
        ? channel.orderedStreams
        : policy.eligible(channel.orderedStreams);
    // policy 非空时不能走这条捷径：组播可用时还要把专网线路提到公网之前，
    // 直接返回 `orderedStreams`（只按画质排）会把 F5 的通道优先整个跳过。
    if (policy == null &&
        dead.streamCount == 0 &&
        dead.hostCount == 0 &&
        health == null &&
        decodeBad.isEmpty) {
      // 无失效、无健康数据时 `orderedStreams` 就是画质降序（高清自然在最前），
      // 直接返回即可；排序路径只在有失效/健康数据需要穿插时才走。
      return ordered;
    }
    final indexed = ordered.indexed.toList()
      ..sort((a, b) {
        final aDead = dead.isDead(a.$2.url);
        final bDead = dead.isDead(b.$2.url);
        if (aDead != bDead) return aDead ? 1 : -1;
        final aDecodeBad = decodeBad.contains(a.$2.url);
        final bDecodeBad = decodeBad.contains(b.$2.url);
        if (aDecodeBad != bDecodeBad) return aDecodeBad ? 1 : -1;
        // F5：组播**已判定可用**时同清晰度优先（码率恒定、换台快）。
        // carrier_net 刻意不加这个特权——N3 要求它与公网同榜，由首帧时间与
        // 健康分自然决定顺序，识别对了也不该压过一条实测更快的公网线路。
        if (policy != null && policy.multicastState == ChannelUsable.usable) {
          final aMulti = a.$2.channelType == LiveChannelType.multicast;
          final bMulti = b.$2.channelType == LiveChannelType.multicast;
          if (aMulti != bMulti) return aMulti ? -1 : 1;
        }
        // 解码实测优先于画质猜测：与 `LiveChannel.orderedStreams` 同一条规则，
        // 差别只在于这里还要穿插失效与健康度。少这一条的话，一旦有任意失效
        // 记录（几乎必然），排序就会把加扰的「4K」重新顶到已验证线路前面。
        if (a.$2.decodeVerified != b.$2.decodeVerified) {
          return a.$2.decodeVerified ? -1 : 1;
        }
        if (preferHd && a.$2.isHd != b.$2.isHd) {
          return a.$2.isHd ? -1 : 1;
        }
        if (!aDead) {
          final sa = health?.scoreOf(a.$2.url) ?? _neutralScore;
          final sb = health?.scoreOf(b.$2.url) ?? _neutralScore;
          if (sa != sb) return sb.compareTo(sa);
        }
        final byQuality = b.$2.qualityRank.compareTo(a.$2.qualityRank);
        if (byQuality != 0) return byQuality;
        return a.$1.compareTo(b.$1);
      });
    return indexed.map((e) => e.$2).toList(growable: false);
  }

  /// 没有健康数据时的默认分。与 [StreamHealthBoard.scoreOf] 的未知分支保持一致。
  static const double _neutralScore = 55;

  /// 挑第一个「还有可用线路」的台。
  ///
  /// 判定看 [_firstCandidate] 是否为空：全都可疑的台直接跳过。
  /// 这是首屏自救的核心——内置清单往往整站失效，而远端索引里总有能播的台。
  ///
  /// 全部台都可疑时退回第一个台：总比什么都不做强，用户还能手动切，
  /// 而且线路 TTL 过期后会自动恢复重试。
  static LiveChannel? pickPlayable(
    List<LiveChannel> channels,
    DeadStreamRegistry dead, {
    StreamHealthBoard? health,
    NetworkChannelPolicy? policy,
  }) {
    if (channels.isEmpty) return null;
    for (final c in channels) {
      if (_firstCandidate(c, dead, health, policy) != null) return c;
    }
    return channels.first;
  }

  /// 并发探测：**一轮一批，命中即止；全灭就换下一批**。
  ///
  /// 为什么必须分批而不是只探一批：频道表最前面往往是同一批「听起来最该能播」的台，
  /// 而它们的线路很可能共用同一个已经关停的镜像。只探一批的话，探测窗口会被
  /// 这整批死链占满，后面明明能播的台一条都轮不到 —— 首屏必然黑屏。
  ///
  /// 分批后是自愈的：第一轮把死主机记进 [dead]，第二轮自动跳过这些主机，
  /// 直接探到真正可用的台。代价是最坏情况多等一个探测周期（约 3 秒）。
  ///
  /// 并发而不是串行：串行 8 个台 × 3 秒超时会把首屏拖到 24 秒。
  ///
  /// [probe] 只回答「这条地址能不能取到数据」，**不能证明码流可解码**，
  /// 所以调用方拿到结果后仍要允许起播失败并重选（见 `LiveController.bootstrap`）。
  /// [probe] 接受整条 [LiveStream] 而不是裸 URL：线路自带 `Referer` /
  /// `User-Agent`（防盗链源站），探测必须与播放用同一套请求头。早期签名只传
  /// URL，探测一律裸发，带防盗链的央视频道/卫视会在这一步被判死、
  /// 连 `player.load` 都走不到。
  static Future<LiveChannel?> pickProbed({
    required List<LiveChannel> channels,
    required DeadStreamRegistry dead,
    required Future<bool> Function(LiveStream stream) probe,
    StreamHealthBoard? health,
    NetworkChannelPolicy? policy,
    int batch = 8,
    int rounds = 4,
    void Function(String message)? log,
  }) async {
    for (var round = 0; round < rounds; round++) {
      final candidates = <(LiveChannel, LiveStream)>[];
      for (final c in channels) {
        if (candidates.length >= batch) break;
        final s = _firstCandidate(c, dead, health, policy);
        // 一条都挑不出来就整台跳过，否则会在同一批里反复探同一个死主机，白等一轮。
        if (s != null) candidates.add((c, s));
      }
      if (candidates.isEmpty) return null;

      final results = await Future.wait(candidates.map((entry) async {
        final ok = await probe(entry.$2);
        if (!ok) {
          // 通道级失效只由 policy 记冷却；地址级失效仍走原有登记簿。
          // 被 policy 筛掉的线路根本不会到这里，因此不会污染健康分。
          if (policy == null || policy.isEligible(entry.$2)) {
            dead.mark(entry.$2.url);
          }
          policy?.noteFailure(entry.$2);
        } else {
          policy?.noteSuccess(entry.$2);
        }
        return ok ? entry.$1 : null;
      }));
      for (final r in results) {
        if (r != null) return r;
      }
      log?.call('第 ${round + 1} 轮探测全灭（${candidates.length} 条），'
          '已记下 ${dead.hostCount} 个失效主机，换下一批');
    }
    return null;
  }

  /// 这个台是否还有「没被判失效」的线路。
  ///
  /// 自动切台用它跳过整台已死的频道：否则全表故障时挨个台把 10 条死线路
  /// 全试一遍，用户会看到连续几十次「正在连接」，而不是顺畅跳到能播的台。
  static bool hasLiveStream(
    LiveChannel channel,
    DeadStreamRegistry dead, {
    StreamHealthBoard? health,
    NetworkChannelPolicy? policy,
  }) =>
      _firstCandidate(channel, dead, health, policy) != null;

  /// 这个台「第一条还没被判定失效」的线路；全都可疑时返回 null。
  ///
  /// **判定只看地址级失效（[DeadStreamRegistry.isDeadUrl]），不看主机连坐**。
  /// 早期实现用的是 [DeadStreamRegistry.isDead]（含主机连坐），代价是一个
  /// 承载 13 个央视台的主机被连坐后，这 13 个台的 [_firstCandidate] 全部返回
  /// null → `hasLiveStream` 为 false → 自动切台把它们整组跳过 →
  /// 用户看到的现象就是「央视频道都不能播放」。
  ///
  /// 语义拆分：地址级失效代表「这条地址刚刚真的打不开」，可以不再当候选；
  /// 主机连坐只是「这个镜像好像不太稳」的推测，应当只影响**尝试顺序**
  /// （[rankStreams] 已经把可疑线路排到最后），不该把整台频道判死。
  static LiveStream? _firstCandidate(
    LiveChannel channel,
    DeadStreamRegistry dead,
    StreamHealthBoard? health,
    NetworkChannelPolicy? policy,
  ) {
    for (final s in rankStreams(channel, dead, health: health, policy: policy)) {
      if (!dead.isDeadUrl(s.url)) return s;
    }
    return null;
  }
}
