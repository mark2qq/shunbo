/// 三网运营商自动识别（对应研发方案 14.8 / N2）。
///
/// 设计原则只有一条：**宁可识别不出来，也不能猜错**。
/// 认错运营商会把一批只在别家内网可达的地址放进候选，用户看到的是换台卡顿、
/// 无效请求与可能的风控；认不出来则只是继续用公网源，体验不劣于现状。
///
/// 因此：蜂窝零网络请求、归属服务失败按 public、字段互相矛盾按 public、
/// 复核不一致按 public、任何异常都不抛出、不阻塞开播、不弹错误框。
/// 识别结果按「网络键」（SSID / 有线 / 蜂窝）缓存 1 小时，网络切换立即失效。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'channel_settings.dart';
import 'live_channel.dart';

/// 当前网络类型。
enum NetworkKind {
  wifi,
  ethernet,
  cellular,

  /// 拿不到系统信息（桌面 / 权限受限 / 探测异常）。
  unknown,
}

/// 一次网络状态快照。
class NetworkState {
  const NetworkState({
    required this.kind,
    required this.key,
    this.carrierHint,
  });

  final NetworkKind kind;

  /// 缓存键：SSID / `ethernet` / `cellular:<运营商>` / `unknown`。
  /// 相同 SSID 换到不同宽带（极少见）由 1 小时 TTL 兜底。
  final String key;

  /// 系统直接给出的运营商（仅蜂窝路径使用，零网络请求）。
  final Carrier? carrierHint;

  bool get isCellular => kind == NetworkKind.cellular;
}

/// 网络状态来源。平台层可注入 Android ConnectivityManager 的实现；
/// 默认实现只用 `dart:io`，在任何一端都不会因为缺插件而崩。
abstract interface class NetworkStateProvider {
  Future<NetworkState> current();
}

/// 默认网络状态：按本机网络接口名推断，取不到就返回 unknown。
///
/// 这是**保守兜底**而非精确判定：Android 上接口名常被虚拟化，Windows 上
/// 中文接口名（「以太网」「WLAN」）也能覆盖。真正需要精确蜂窝判定时，
/// 由平台层注入带 ConnectivityManager 的实现即可，本文件不用改。
class DefaultNetworkStateProvider implements NetworkStateProvider {
  @override
  Future<NetworkState> current() async {
    try {
      final list = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
      );
      var cellular = false;
      var wifi = false;
      var ethernet = false;
      for (final i in list) {
        final n = i.name.toLowerCase();
        if (n.contains('rmnet') || n.contains('ccmni') || n.contains('wwan') ||
            n.contains('cellular') || n.contains('pdp')) {
          cellular = true;
        } else if (n.contains('wlan') || n.contains('wi-fi') ||
            n.contains('wifi') || n.contains('wireless') || n.contains('wlan')) {
          wifi = true;
        } else if (n.contains('eth') || n.contains('以太网') ||
            n.contains('lan')) {
          ethernet = true;
        }
      }
      if (cellular) {
        return const NetworkState(kind: NetworkKind.cellular, key: 'cellular');
      }
      if (wifi) return const NetworkState(kind: NetworkKind.wifi, key: 'wifi');
      if (ethernet) {
        return const NetworkState(kind: NetworkKind.ethernet, key: 'ethernet');
      }
    } catch (_) {
      // 探测权限 / 平台差异都按未知处理，绝不因为拿不到接口表就不开播。
    }
    return const NetworkState(kind: NetworkKind.unknown, key: 'unknown');
  }
}

/// 公网 IP 归属服务的原始响应。返回 null 表示该端点不可用。
abstract interface class IpLookup {
  Future<String?> lookup();
}

/// 默认归属服务：与「地方频道 IP 定位」共用同一批端点，避免两套网络策略。
///
/// 安全边界：强制直连（系统代理会把局域网/归属查询变成 502）、体积上限、
/// 超时、响应按字节截断、用完 `close()`。任何失败返回 null。
class DefaultIpLookup implements IpLookup {
  DefaultIpLookup({
    this.endpoints = const <String>[
      'https://whois.pconline.com.cn/ipJson.jsp?json=true',
      'https://ipinfo.io/json',
    ],
    this.timeout = const Duration(seconds: 3),
    this.maxResponseBytes = 64 * 1024,
  });

  final List<String> endpoints;
  final Duration timeout;
  final int maxResponseBytes;

  @override
  Future<String?> lookup() async {
    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = timeout
        ..findProxy = (_) => 'DIRECT';
      for (final endpoint in endpoints) {
        final uri = Uri.tryParse(endpoint);
        if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
          continue;
        }
        try {
          final req = await client.getUrl(uri).timeout(timeout);
          req.followRedirects = false;
          final resp = await req.close().timeout(timeout);
          if (resp.statusCode < 200 || resp.statusCode >= 300) {
            await resp.drain<void>();
            continue;
          }
          final bytes = await _readBounded(resp);
          if (bytes.isEmpty || bytes.length > maxResponseBytes) continue;
          final text = utf8.decode(bytes, allowMalformed: true);
          if (text.trim().isEmpty) continue;
          return text;
        } catch (_) {
          // 单个端点失败就换下一个，最后一个也失败由调用方按 public 兜底。
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  Future<List<int>> _readBounded(HttpClientResponse resp) async {
    final out = <int>[];
    await for (final chunk in resp) {
      out.addAll(chunk);
      if (out.length > maxResponseBytes) return out.sublist(0, maxResponseBytes);
    }
    return out;
  }
}

/// 一次识别结果（含诊断明细）。
class CarrierDetection {
  const CarrierDetection({
    required this.carrier,
    required this.source,
    required this.reason,
    required this.network,
    this.elapsedMs = 0,
    this.checkedAt,
    this.verified = false,
  });

  final Carrier carrier;
  final String source;
  final String reason;
  final NetworkState network;
  final int elapsedMs;

  /// 为空表示「没有有效结论」（尚未检测 / 缓存已失效）。
  final DateTime? checkedAt;

  /// 是否经过内网特征地址复核通过。
  final bool verified;

  bool get isUsable => carrier != Carrier.unknown;

  static CarrierDetection unknown(NetworkState network, String reason) =>
      CarrierDetection(
        carrier: Carrier.unknown,
        source: '兜底',
        reason: reason,
        network: network,
      );

  String get summary =>
      '${ChannelSettings.carrierLabel(carrier)} · $source · $reason';
}

/// 运营商自动识别器。
class CarrierDetector {
  CarrierDetector({
    IpLookup? lookup,
    NetworkStateProvider? networkProvider,
    this.featureProbe,
    this.ttl = const Duration(hours: 1),
    DateTime Function()? clock,
  })  : _lookup = lookup ?? DefaultIpLookup(),
        _networkProvider = networkProvider ?? DefaultNetworkStateProvider(),
        _clock = clock ?? DateTime.now;

  final IpLookup _lookup;
  final NetworkStateProvider _networkProvider;
  final Duration ttl;
  final DateTime Function() _clock;

  /// 内网特征地址复核（14.8 c）。
  ///
  /// 参数只给「识别到的运营商」，具体地址由调用方从**用户订阅清单**里取——
  /// 本文件不内置任何运营商特征地址（方案 14.5）。返回 null 表示未配置、
  /// 跳过复核；返回 false 表示不一致，一律回落 public。
  final Future<bool?> Function(Carrier carrier)? featureProbe;

  CarrierDetection? _cached;
  String _cachedKey = '';

  /// 最近一次结论（诊断页直接读，不会触发新的网络请求）。
  CarrierDetection? get last => _cached;

  /// 网络切换 / 用户点「重新检测」时调用。
  void invalidate() {
    _cached = null;
    _cachedKey = '';
  }

  /// 识别当前出口运营商。[settings] 只提供手动覆盖与订阅开关。
  Future<CarrierDetection> detect(
    ChannelSettings settings, {
    NetworkState? state,
    bool force = false,
  }) async {
    final sw = Stopwatch()..start();
    final network = state ?? await _networkProvider.current();
    if (force) invalidate();

    final hit = _cached;
    if (hit != null &&
        hit.checkedAt != null &&
        _cachedKey == network.key &&
        _clock().difference(hit.checkedAt!) < ttl) {
      return hit;
    }

    // a) 蜂窝：零网络请求。系统若给了运营商信息就直接采信；没给就 public。
    //    蜂窝下即使识别为移动，也**不启用** carrier_net（家宽内网 CDN 在
    //    蜂窝出口不可达），这一点由 NetworkChannelPolicy 再兜一层。
    if (network.isCellular) {
      final hint = network.carrierHint ?? settings.carrierOverride;
      final result = hint != Carrier.unknown
          ? CarrierDetection(
              carrier: hint,
              source: '系统运营商信息',
              reason: '蜂窝网络：仅记录归属，不启用内网源',
              network: network,
              elapsedMs: sw.elapsedMilliseconds,
              checkedAt: _clock(),
            )
          : CarrierDetection.unknown(network, '蜂窝网络不启用运营商内网源');
      return _store(network.key, result);
    }

    // b) 手动覆盖：归属服务不可用时的兜底入口，不再要求用户「必须选一个」。
    if (settings.carrierOverride != Carrier.unknown) {
      final result = CarrierDetection(
        carrier: settings.carrierOverride,
        source: '手动指定',
        reason: '跳过自动识别（归属服务不可用时使用）',
        network: network,
        elapsedMs: sw.elapsedMilliseconds,
        checkedAt: _clock(),
      );
      return _store(network.key, result);
    }

    // c) 公网 IP 归属服务。
    final raw = await _lookup.lookup();
    if (raw == null || raw.trim().isEmpty) {
      return _store(network.key,
          CarrierDetection.unknown(network, '归属服务不可用，按公网源处理'));
    }
    final carrier = parseCarrierText(raw);
    if (carrier == Carrier.unknown) {
      return _store(network.key,
          CarrierDetection.unknown(network, '归属字段缺失或互相矛盾，按公网源处理'));
    }

    // d) 复核：用用户订阅清单里的该家内网地址做一次 300ms 校验。
    //    未配置订阅 / 未注入探针时跳过，不因为「没东西可复核」就否决识别结论。
    var verified = false;
    if (featureProbe != null) {
      try {
        // 超时单独用 TimeoutException 处理，而不是 `onTimeout: () => null`：
        // `Future<bool>` 上返回 null 会在运行时撞上非空类型检查，把真正的
        // 探针异常掩盖成一个看似无关的 TypeError。
        final bool? ok = await featureProbe!(carrier)
            .timeout(const Duration(milliseconds: 300));
        if (ok == false) {
          return _store(network.key,
              CarrierDetection.unknown(network, '内网特征复核不一致，按公网源处理'));
        }
        verified = ok == true;
      } on TimeoutException {
        return _store(network.key,
            CarrierDetection.unknown(network, '内网特征复核超时，按公网源处理'));
      } catch (_) {
        return _store(network.key,
            CarrierDetection.unknown(network, '内网特征复核失败，按公网源处理'));
      }
    }

    final result = CarrierDetection(
      carrier: carrier,
      source: '公网 IP 归属',
      reason: verified ? '归属 + 内网特征复核通过' : '归属识别成功（未配置特征复核）',
      network: network,
      elapsedMs: sw.elapsedMilliseconds,
      checkedAt: _clock(),
      verified: verified,
    );
    return _store(network.key, result);
  }

  CarrierDetection _store(String key, CarrierDetection result) {
    _cached = result;
    _cachedKey = key;
    return result;
  }

  /// 从归属服务响应里判运营商。
  ///
  /// 覆盖 pconline（`addr` 含「移动」、可能有 `isp`）与 ipinfo（`org` 含
  /// `China Mobile` / ASN）两类写法。把所有字段拼起来找关键字；**同时命中
  /// 两家以上一律返回 unknown**——猜错的代价远大于认不出来。
  static Carrier parseCarrierText(String raw) {
    String text;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final buf = StringBuffer();
        decoded.forEach((k, v) {
          if (v is String || v is num) buf.write(' $k=$v');
        });
        text = buf.toString();
      } else {
        text = raw;
      }
    } catch (_) {
      text = raw;
    }
    final s = text.toLowerCase();
    final hits = <Carrier>{};
    if (s.contains('china mobile') || s.contains('chinamobile') ||
        s.contains('cmcc') || s.contains('as9808') ||
        s.contains('as24400') || s.contains('中国移动') ||
        RegExp(r'(^|[^a-z])mobile([^a-z]|$)').hasMatch(s) ||
        s.contains('移动')) {
      hits.add(Carrier.chinaMobile);
    }
    if (s.contains('china telecom') || s.contains('chinatelecom') ||
        s.contains('chinanet') || s.contains('as4134') ||
        s.contains('as4809') || s.contains('中国电信') ||
        s.contains('电信')) {
      hits.add(Carrier.chinaTelecom);
    }
    if (s.contains('china unicom') || s.contains('chinaunicom') ||
        s.contains('cncnet') || s.contains('as4837') ||
        s.contains('as9929') || s.contains('中国联通') ||
        s.contains('联通')) {
      hits.add(Carrier.chinaUnicom);
    }
    return hits.length == 1 ? hits.single : Carrier.unknown;
  }
}
