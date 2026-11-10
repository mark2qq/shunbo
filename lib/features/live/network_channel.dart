/// 按网络可达性筛选候选（研发方案 14.4 的「共用框架」）。
///
/// 组播通道与运营商内网 CDN 通道在这里共用一套判定模型，只是探测对象不同：
/// * 组播：udpxy 主机连通 + 任取一条地址的首包；
/// * 内网 CDN：出口运营商识别 + 该家源在当前网络下的首帧预算。
///
/// 二者都是**筛掉当前网络根本不该试的线路**，而不是给它们单独写一套播放逻辑。
/// 被筛掉的线路既不进候选，也不产生失败记录、不污染健康分（F4 / N5）。
/// 公网源恒在候选里——这是「识别失败时体验不劣于现状」的兑现方式。
library;

import 'carrier_detector.dart';
import 'channel_settings.dart';
import 'live_channel.dart';

/// 组播原始地址 → udpxy / msd_lite 单播地址。
///
/// 客户端**不做 IGMP**：Android 普通应用与电视第三方 App 都没有组播入会权限，
/// 转换必须由家庭路由器完成。这里只负责把用户导入的 `udp://`/`rtp://`
/// 改写成 `http://<网关>:<端口>/udp|rtp/<组播IP>:<端口>`，并保留原始地址，
/// 让用户改端口后不必重新导入（方案 F2 / M1）。
class UdpxyRewriter {
  const UdpxyRewriter({required this.host, required this.port});

  final String host;
  final int port;

  bool get isValid => ChannelSettings.isValidUdpxyHost(host) &&
      port >= ChannelSettings.minPort &&
      port <= ChannelSettings.maxPort;

  /// 把一条组播线路重写为当前网关地址；不合法时返回原线路（不让它变黑屏）。
  LiveStream rewrite(LiveStream stream) {
    final raw = stream.rawAddr;
    if (raw == null) return stream;
    final url = rewriteRaw(raw);
    if (url == null) return stream;
    return stream.withAddress(url);
  }

  /// 返回单播地址；输入不是合法组播地址时返回 null。
  String? rewriteRaw(String raw) {
    if (!isValid) return null;
    final parsed = parseMulticast(raw);
    if (parsed == null) return null;
    final (transport, target) = parsed;
    return 'http://${host.trim()}:$port/$transport/$target';
  }

  /// 解析 `udp://239.49.1.2:5000` / `rtp://@239.49.1.2:5000` / 裸 `IP:PORT`。
  /// 返回 `(transport, ip:port)`。
  static (String, String)? parseMulticast(String raw) {
    var s = raw.trim();
    if (s.isEmpty || s.length > 256) return null;
    if (s.contains('\n') || s.contains('\r') || s.contains('\u0000')) {
      return null;
    }
    var transport = 'udp';
    final schemeAt = s.indexOf('://');
    if (schemeAt > 0) {
      final scheme = s.substring(0, schemeAt).toLowerCase();
      if (scheme != 'udp' && scheme != 'rtp') return null;
      transport = scheme;
      s = s.substring(schemeAt + 3);
    }
    if (s.startsWith('@')) s = s.substring(1);
    if (s.contains('/') || s.contains('?') || s.contains('#') ||
        s.contains('@')) {
      return null;
    }
    final colon = s.lastIndexOf(':');
    if (colon <= 0 || colon == s.length - 1) return null;
    final ip = s.substring(0, colon);
    final portText = s.substring(colon + 1);
    final p = int.tryParse(portText);
    if (p == null || p < 1 || p > 65535) return null;

    // 只接受 IPv4 组播段 224.0.0.0/4。写 192.168.x 或公网 IP 都说明地址表
    // 不是组播表，直接拒绝，避免把任意内网主机变成被请求的靶子。
    final parts = ip.split('.');
    if (parts.length != 4) return null;
    final octets = <int>[];
    for (final part in parts) {
      if (part.isEmpty || part.length > 3) return null;
      final n = int.tryParse(part);
      if (n == null || n < 0 || n > 255) return null;
      octets.add(n);
    }
    if (octets[0] < 224 || octets[0] > 239) return null;
    return (transport, '$ip:$p');
  }
}

/// 通道可达性的三态（方案 4.2 `NetworkCapability.isMulticastUsable()`）。
enum ChannelUsable { usable, unusable, unconfigured }

/// 诊断页的三项结果 + 失败原因（F3 / 14.8 末段）。
class ChannelDiagnostics {
  const ChannelDiagnostics({
    required this.networkType,
    required this.carrier,
    required this.carrierSource,
    required this.carrierReason,
    required this.detectMs,
    required this.udpxyMs,
    required this.firstPacketMs,
    required this.multicast,
    required this.carrierNet,
    required this.udpxyReason,
  });

  final String networkType;
  final String carrier;
  final String carrierSource;
  final String carrierReason;
  final int detectMs;
  final int udpxyMs;
  final int firstPacketMs;
  final ChannelUsable multicast;
  final ChannelUsable carrierNet;
  final String udpxyReason;

  /// 失败时能定位「主机不通」还是「首包超时」，而不是只给一句「不可用」。
  List<(String, String)> rows() => <(String, String)>[
        ('网络类型', networkType),
        ('出口识别', '$carrier · $carrierSource'),
        ('识别耗时', '$detectMs ms'),
        ('识别说明', carrierReason),
        ('udpxy 连通', udpxyMs > 0 ? '$udpxyMs ms' : '未检测'),
        ('组播首包', firstPacketMs > 0 ? '$firstPacketMs ms' : '未检测'),
        ('组播通道', usableLabel(multicast)),
        ('内网通道', usableLabel(carrierNet)),
        if (udpxyReason.isNotEmpty) ('失败定位', udpxyReason),
      ];

  static String usableLabel(ChannelUsable u) => switch (u) {
        ChannelUsable.usable => '可用',
        ChannelUsable.unusable => '不可用',
        ChannelUsable.unconfigured => '未配置',
      };
}

/// 候选准入 + 失败冷却 + 诊断。
/// 诊断页里表示「网络受限导致通道暂停」的固定文案，refresh 后据此清除。
const String kNetworkSuspendReason = '网络断开或受限，仅使用公网源';

class NetworkChannelPolicy {
  NetworkChannelPolicy({
    CarrierDetector? detector,
    ChannelSettings settings = const ChannelSettings(),
    this.cooldown = const Duration(minutes: 5),
    DateTime Function()? clock,
  })  : detector = detector ?? CarrierDetector(),
        _settings = settings,
        _clock = clock ?? DateTime.now;

  final CarrierDetector detector;

  /// 失败线路的冷却时长（N4：超时冷却 5 分钟）。
  final Duration cooldown;

  final DateTime Function() _clock;

  ChannelSettings _settings;
  final Map<String, DateTime> _cooldown = <String, DateTime>{};

  /// 组播一键检测的结果。默认「未配置」——没开关没主机就绝不发起探测。
  ChannelUsable _multicast = ChannelUsable.unconfigured;
  int _udpxyMs = 0;
  int _firstPacketMs = 0;
  String _udpxyReason = '';
  bool _suspended = false;

  ChannelSettings get settings => _settings;

  /// 改设置后调用：清空结论与冷却，让下一次选源立刻用新配置（F2 端口变更）。
  void updateSettings(ChannelSettings next) {
    _settings = next;
    _multicast = next.multicastConfigured
        ? ChannelUsable.unusable
        : ChannelUsable.unconfigured;
    _udpxyMs = 0;
    _firstPacketMs = 0;
    _udpxyReason = '';
    _cooldown.clear();
    detector.invalidate();
  }

  /// 网络断开 / VPN / 未知传输时调用：**零网络请求**地暂停非公网通道。
  ///
  /// 不能走 [refresh]：那会触发一次公网 IP 归属探测，在离线或 VPN 出口下
  /// 既浪费请求，又可能拿到 VPN 出口的归属而错误启用家宽内网源。
  /// 正确做法是让识别结论失效 + 组播结论失效，等网络回来再重新识别。
  void suspend({String reason = kNetworkSuspendReason}) {
    detector.invalidate();
    _cooldown.clear();
    _suspended = true;
    _udpxyMs = 0;
    _firstPacketMs = 0;
    _udpxyReason = reason;
    if (_settings.multicastConfigured) {
      _multicast = ChannelUsable.unusable;
    }
  }

  CarrierDetection? get detection => detector.last;

  ChannelUsable get multicastState => _multicast;

  int get cooldownCount => _cooldown.length;

  /// 开机 / 网络切换 / 用户点「重新检测」时调用。
  /// 失败一律内部消化：识别不出来就走公网，不阻塞开播。
  Future<CarrierDetection> refresh({NetworkState? state, bool force = false}) async {
    final result = await detector.detect(_settings, state: state, force: force);
    if (_suspended && _udpxyReason == kNetworkSuspendReason) {
      _udpxyReason = '';
    }
    _suspended = false;
    _cooldown.clear();
    if (_settings.multicastConfigured && _multicast == ChannelUsable.usable) {
      // 网关可能随网络一起变（换 Wi-Fi 就换了一段局域网），之前判过可用
      // 也不能沿用，必须重新一键检测。
      _multicast = ChannelUsable.unusable;
      _udpxyReason = '网络已变化，组播需重新检测';
    }
    return result;
  }

  /// 组播一键检测（F3）。
  ///
  /// [connect] 判 udpxy 主机是否在 300ms 内响应；[firstPacket] 判任取一条
  /// 已启用组播地址能否在 1.5s 内拿到首包。两个探针由调用方注入，
  /// 本类不内置任何地址、也不偷偷发网络请求。
  Future<ChannelUsable> checkMulticast({
    required Future<bool> Function() connect,
    required Future<bool> Function() firstPacket,
    required List<LiveStream> candidates,
  }) async {
    if (!_settings.multicastConfigured) {
      _multicast = ChannelUsable.unconfigured;
      _udpxyReason = '组播未启用或未填写合法的局域网网关地址';
      return _multicast;
    }
    if (candidates.isEmpty) {
      _multicast = ChannelUsable.unusable;
      _udpxyReason = '未导入任何组播地址表';
      return _multicast;
    }
    final hostSw = Stopwatch()..start();
    bool hostOk;
    try {
      hostOk = await connect().timeout(
        const Duration(milliseconds: 300),
        onTimeout: () => false,
      );
    } catch (_) {
      hostOk = false;
    }
    hostSw.stop();
    _udpxyMs = hostSw.elapsedMilliseconds;
    if (!hostOk) {
      _multicast = ChannelUsable.unusable;
      _firstPacketMs = 0;
      _udpxyReason = 'udpxy 主机 300ms 内无响应（检查网关地址、端口与路由器插件）';
      return _multicast;
    }
    final packetSw = Stopwatch()..start();
    bool packetOk;
    try {
      packetOk = await firstPacket().timeout(
        const Duration(milliseconds: 1500),
        onTimeout: () => false,
      );
    } catch (_) {
      packetOk = false;
    }
    packetSw.stop();
    _firstPacketMs = packetSw.elapsedMilliseconds;
    _multicast = packetOk ? ChannelUsable.usable : ChannelUsable.unusable;
    _udpxyReason = packetOk ? '' : '主机可连但 1.5s 内无首包（检查组播地址表或 VLAN）';
    return _multicast;
  }

  /// 这条线路**现在**能不能进候选。
  ///
  /// 注意这是「通道级」判断，与 `DeadStreamRegistry`（地址级失效）互补：
  /// 通道不可达时整批线路直接消失，连一次失败记录都不产生。
  bool isEligible(LiveStream stream) {
    if (!_typeEnabled(stream)) return false;
    final marked = _cooldown[stream.url];
    if (marked != null && _clock().difference(marked) < cooldown) return false;
    _cooldown.remove(stream.url);
    return true;
  }

  bool _typeEnabled(LiveStream stream) => switch (stream.channelType) {
        LiveChannelType.public => true,
        LiveChannelType.carrierNet => _carrierNetEnabled(stream),
        LiveChannelType.multicast => _multicast == ChannelUsable.usable,
      };

  bool _carrierNetEnabled(LiveStream stream) {
    final d = detector.last;
    if (d == null || !d.isUsable) return false;
    if (d.network.isCellular) return false;
    return stream.carrier != Carrier.unknown && stream.carrier == d.carrier;
  }

  /// 过滤后的候选（保持原顺序，排序仍由 `LiveSelection` 全权负责）。
  List<LiveStream> eligible(Iterable<LiveStream> streams) =>
      streams.where(isEligible).toList(growable: false);

  /// 记一次失败。**只管非公网通道**：公网源的失败仍由 `DeadStreamRegistry`
  /// 按既有语义处理（排到最后、整台判死时仍留一条验证恢复）。
  /// 异网 / 未配置的线路也一律不记——它们根本不该被尝试。
  ///
  /// 少这一条会破坏「不劣于现状」：公网线路若被通道策略整批筛掉，
  /// 用户反复点一个暂时全灭的台时会连一次重试都不发生。
  void noteFailure(LiveStream stream) {
    if (stream.channelType == LiveChannelType.public) return;
    if (!_typeEnabled(stream)) return;
    _cooldown[stream.url] = _clock();
  }

  void noteSuccess(LiveStream stream) => _cooldown.remove(stream.url);

  void clearCooldown() => _cooldown.clear();

  /// 起播前按当前网关重写组播地址：改了端口/主机后不重新导入也能生效。
  LiveStream rewriteIfNeeded(LiveStream stream) {
    if (stream.channelType != LiveChannelType.multicast) return stream;
    return UdpxyRewriter(host: _settings.udpxyHost, port: _settings.udpxyPort)
        .rewrite(stream);
  }

  ChannelDiagnostics diagnostics() {
    final d = detector.last;
    return ChannelDiagnostics(
      networkType: _networkLabel(d?.network.kind),
      carrier: ChannelSettings.carrierLabel(d?.carrier ?? Carrier.unknown),
      carrierSource: d?.source ?? '尚未检测',
      carrierReason: d?.reason ?? '开机或网络切换后自动识别',
      detectMs: d?.elapsedMs ?? 0,
      udpxyMs: _udpxyMs,
      firstPacketMs: _firstPacketMs,
      multicast: _multicast,
      carrierNet: d == null
          ? (_suspended ? ChannelUsable.unusable : ChannelUsable.unconfigured)
          : (d.isUsable && !d.network.isCellular
              ? ChannelUsable.usable
              : ChannelUsable.unusable),
      udpxyReason: _udpxyReason,
    );
  }

  static String _networkLabel(NetworkKind? k) => switch (k) {
        NetworkKind.wifi => 'Wi-Fi',
        NetworkKind.ethernet => '有线网络',
        NetworkKind.cellular => '蜂窝数据',
        _ => '未知（按公网处理）',
      };
}
