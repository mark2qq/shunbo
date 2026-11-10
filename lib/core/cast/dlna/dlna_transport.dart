/// DLNA / UPnP AVTransport 投屏传输（替换 E5 阶段的 [FakeCastTransport] 占位）。
///
/// 为什么值得单独一个文件：投屏把**源站物理 URL**交给局域网里的陌生设备，同时
/// 客户端会按对方给的地址发起 HTTP 请求 —— 这是一条天然的 SSRF + 隐私外泄通道。
/// 所以这里把「从 UDP 收到的每一条字符串」都当成不可信输入处理：
///
/// 1. **只认私网**：SSDP 应答里的 `LOCATION` 若指向公网地址一律丢弃（除非显式
///    打开 [DlnaConfig.allowPublicAddresses]），避免恶意应答把本机变成打公网的跳板，
///    也避免把带签名的播放地址发给外部主机；域名要先解析，解析结果必须**全部**落在私网。
/// 2. **只认 http**：DLNA 规范内就是明文 http，出现其它 scheme 一律拒绝，
///    防止 `file://` / `ftp://` 之类被当作播放地址喂给设备。
/// 3. **controlURL 必须同 origin**：设备描述里可以写任意 URL，若允许跨 origin，
///    一张描述就能指使客户端把 SOAP 发给第三方。相对路径按 `LOCATION` 解析后比对
///    scheme/host/port，不一致即拒绝该设备。
/// 4. **体积与条数上限**：SSDP 报文、设备描述、SOAP 应答都限长；设备数、重发次数、
///    超时都有上界 —— 局域网里的一台坏设备不该把 App 拖死。
/// 5. **不走系统代理**：`findProxy` 直接 `DIRECT`。上次回归已踩过：Windows 系统代理会
///    接管本机 HTTP 请求并返回 502，局域网设备同样会被拦。
///
/// 语义分工（沿用 [CastTransport] 契约）：这里只负责「把 URL 和**源原始秒数**送到
/// 设备」并读回设备侧的物理位置，**不做任何内容坐标换算**，换算归调度层。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../cast_fallback.dart';

/// DLNA 边界参数。全部可注入，回归脚本靠它把组播地址指向本机 UDP 端口。
class DlnaConfig {
  /// SSDP 组播地址（测试时改 `127.0.0.1`）。
  final String multicastAddress;

  /// SSDP 端口（测试时为模拟设备的实际端口）。
  final int multicastPort;

  /// 收集 SSDP 应答的总时长（同时决定 M-SEARCH 的 `MX`）。
  final Duration discoverTimeout;

  /// 单次 HTTP（描述 / SOAP）请求超时。
  final Duration requestTimeout;

  /// M-SEARCH 重发次数（UDP 会丢包，规范建议重发）。
  final int resendCount;

  /// 重发间隔。
  final Duration resendInterval;

  /// 单台设备可服务的设备数上限（也是发现阶段提前结束的阈值）。
  final int maxDevices;

  /// 单条 SSDP 报文上限（正常应答 < 1KB）。
  final int maxDiscoveryDatagramBytes;

  /// 设备描述 XML 上限。
  final int maxDescriptionBytes;

  /// SOAP 应答上限。
  final int maxSoapResponseBytes;

  /// 是否允许公网地址。默认 false —— 打开等于放弃 SSRF 防护，只应在调试时使用。
  final bool allowPublicAddresses;

  const DlnaConfig({
    this.multicastAddress = '239.255.255.250',
    this.multicastPort = 1900,
    this.discoverTimeout = const Duration(seconds: 3),
    this.requestTimeout = const Duration(seconds: 5),
    this.resendCount = 2,
    this.resendInterval = const Duration(milliseconds: 400),
    this.maxDevices = 32,
    this.maxDiscoveryDatagramBytes = 4096,
    this.maxDescriptionBytes = 256 * 1024,
    this.maxSoapResponseBytes = 64 * 1024,
    this.allowPublicAddresses = false,
  });

  /// 测试用：把组播目标指向本机某个 UDP 端口。
  DlnaConfig copyWith({
    String? multicastAddress,
    int? multicastPort,
    Duration? discoverTimeout,
    Duration? requestTimeout,
    int? resendCount,
    Duration? resendInterval,
    int? maxDevices,
    int? maxDiscoveryDatagramBytes,
    int? maxDescriptionBytes,
    int? maxSoapResponseBytes,
    bool? allowPublicAddresses,
  }) =>
      DlnaConfig(
        multicastAddress: multicastAddress ?? this.multicastAddress,
        multicastPort: multicastPort ?? this.multicastPort,
        discoverTimeout: discoverTimeout ?? this.discoverTimeout,
        requestTimeout: requestTimeout ?? this.requestTimeout,
        resendCount: resendCount ?? this.resendCount,
        resendInterval: resendInterval ?? this.resendInterval,
        maxDevices: maxDevices ?? this.maxDevices,
        maxDiscoveryDatagramBytes:
            maxDiscoveryDatagramBytes ?? this.maxDiscoveryDatagramBytes,
        maxDescriptionBytes: maxDescriptionBytes ?? this.maxDescriptionBytes,
        maxSoapResponseBytes: maxSoapResponseBytes ?? this.maxSoapResponseBytes,
        allowPublicAddresses: allowPublicAddresses ?? this.allowPublicAddresses,
      );
}

/// 投屏失败原因（比 [CastFailureReason] 更细，便于诊断定位到底是哪一跳坏了）。
enum DlnaFailure {
  /// UDP 套接字绑定失败（端口被占 / 无网络权限）。
  socketBindFailed,

  /// LOCATION 不是合法的 http 地址。
  badLocation,

  /// LOCATION 指向公网（默认策略下拒绝）。
  publicLocation,

  /// 设备描述拉取失败 / 超限 / 非 UTF-8。
  badDescription,

  /// 描述里没有 AVTransport 服务，或 controlURL 缺失。
  noAvTransport,

  /// controlURL 与 LOCATION 不同 origin。
  crossOriginControl,

  /// SOAP 请求失败（网络 / 非 200 / Fault）。
  soapFailed,

  /// 设备当前没有可读的位置。
  positionUnavailable,

  /// 未知设备（没走过 discover，或 discover 后设备已下线）。
  unknownDevice,
}

class DlnaCastException implements Exception {
  final DlnaFailure reason;
  final String message;
  final Object? cause;

  const DlnaCastException(this.reason, this.message, [this.cause]);

  @override
  String toString() => 'DlnaCastException(${reason.name}): $message'
      '${cause == null ? '' : ' <- $cause'}';
}

/// 已解析的投屏目标。
class _Endpoint {
  final String udn;
  final String friendlyName;
  final String location;
  final String controlUrl;
  final String serviceType;

  const _Endpoint({
    required this.udn,
    required this.friendlyName,
    required this.location,
    required this.controlUrl,
    required this.serviceType,
  });

  String get origin {
    final u = Uri.parse(location);
    return '${u.scheme}://${u.host.toLowerCase()}:${u.port}';
  }
}

const _avTransportService = 'urn:schemas-upnp-org:service:AVTransport:1';

/// DLNA 投屏传输。[discover] 每次重建端点表 —— 设备 IP 会变，不能长期缓存。
class DlnaCastTransport implements CastTransport {
  final DlnaConfig config;

  /// 每次 discover 的可读说明（为什么某台设备被拒），供 UI/诊断展示。
  final List<String> discoveryNotes = <String>[];

  final Map<String, _Endpoint> _endpoints = <String, _Endpoint>{};
  String? _connectedId;

  DlnaCastTransport({this.config = const DlnaConfig()});

  /// 最近一次 discover 发现的端点（只读，调试用）。
  Map<String, CastDevice> get discovered => <String, CastDevice>{
        for (final e in _endpoints.values)
          e.udn: CastDevice(id: e.udn, name: e.friendlyName),
      };

  @override
  Future<List<CastDevice>> discover() async {
    discoveryNotes.clear();
    _endpoints.clear();
    _connectedId = null;

    final locations = await _collectLocations();
    if (locations.isEmpty) return const <CastDevice>[];

    final client = HttpClient()
      ..connectionTimeout = config.requestTimeout
      // 局域网直连：系统代理会把设备请求接管成 502（已实测）。
      ..findProxy = ((_) => 'DIRECT')
      ..userAgent = 'shunbo-dlna/0.1 UPnP/1.1';

    try {
      final resolved = await Future.wait(
        locations.values.map((loc) => _resolveEndpoint(client, loc)),
      );
      final devices = <CastDevice>[];
      for (final e in resolved) {
        if (e == null) continue;
        _endpoints[e.udn] = e;
        devices.add(CastDevice(id: e.udn, name: e.friendlyName));
      }
      return devices;
    } finally {
      client.close(force: true);
    }
  }

  /// 发 M-SEARCH 并收集应答里的 `LOCATION`（已去重）。
  Future<Map<String, String>> _collectLocations() async {
    RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } catch (e) {
      throw DlnaCastException(
          DlnaFailure.socketBindFailed, 'SSDP 套接字绑定失败', e);
    }

    final locations = <String, String>{};
    final done = Completer<void>();
    var datagrams = 0;

    void handle(Datagram dg) {
      // 已达上限或已收尾：`complete()` 只是交出 future，事件循环里排队的事件仍会继续
      // 派发，不在这里挡住就会多收几台、多打几个描述请求（上限形同虚设）。
      if (done.isCompleted || locations.length >= config.maxDevices) return;
      datagrams++;
      // 洪水防护：条数上限之外再丢超长包（不解析）。
      if (datagrams > config.maxDevices * 8) return;
      // 超长包与非法 UTF-8 一律丢弃：SSDP 应答是网络来的，不能信。
      if (dg.data.length > config.maxDiscoveryDatagramBytes) return;
      String text;
      try {
        text = utf8.decode(dg.data, allowMalformed: false);
      } catch (_) {
        return;
      }
      final loc = _header(text, 'location');
      if (loc == null) return;
      final trimmed = loc.trim();
      if (trimmed.isEmpty) return;
      final key = _normalizeForDedup(trimmed);
      if (locations.containsKey(key)) return;
      locations[key] = trimmed;
      if (locations.length >= config.maxDevices && !done.isCompleted) {
        done.complete();
      }
    }

    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = socket.receive();
      if (dg != null) handle(dg);
    });

    final timer = Timer(config.discoverTimeout, () {
      // 定时器回调可能**先于**已排队的 read 事件执行：若不在这里把内核缓冲里
      // 已经到达的包取干净就收尾，同一台设备的两条应答会随机丢一条（实测首次
      // discover 少发现一台设备，第二次才正常）。这类竞态在单测里表现为偶发失败，
      // 在真机上表现为「电视出现在列表里时有时无」。
      for (Datagram? dg = socket.receive(); dg != null; dg = socket.receive()) {
        handle(dg);
      }
      if (!done.isCompleted) done.complete();
    });

    try {
      final target = InternetAddress.tryParse(config.multicastAddress);
      if (target == null) {
        throw DlnaCastException(DlnaFailure.socketBindFailed,
            '组播地址不是合法 IP：${config.multicastAddress}');
      }
      final request = utf8.encode(_msearchDatagram());
      for (var i = 0; i < config.resendCount; i++) {
        if (done.isCompleted) break;
        try {
          socket.send(request, target, config.multicastPort);
        } catch (_) {
          // 单次发送失败（网卡未就绪）不应让整次发现失败，靠重发兜。
        }
        if (i < config.resendCount - 1) {
          await Future<void>.delayed(config.resendInterval);
        }
      }
      await done.future;
    } finally {
      timer.cancel();
      await sub.cancel();
      socket.close();
    }
    return locations;
  }

  String _msearchDatagram() =>
      'M-SEARCH * HTTP/1.1\r\n'
      'HOST: ${config.multicastAddress}:${config.multicastPort}\r\n'
      'MAN: "ssdp:discover"\r\n'
      'MX: ${config.discoverTimeout.inSeconds.clamp(1, 5)}\r\n'
      'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
      '\r\n';

  /// 拉设备描述并解析出 AVTransport 控制地址。任何一步不合规都返回 null（并记录原因）。
  Future<_Endpoint?> _resolveEndpoint(HttpClient client, String location) async {
    final uri = _validateLocation(location);
    if (uri == null) return null;

    String xml;
    try {
      xml = await _httpGet(client, uri, config.maxDescriptionBytes);
    } catch (e) {
      discoveryNotes.add('$location 描述拉取失败：$e');
      return null;
    }

    final friendly = _unescape(_firstTag(xml, 'friendlyName') ?? '');
    final udn = _firstTag(xml, 'UDN')?.trim() ?? '';
    final controlPath = _avTransportControlUrl(xml);
    if (controlPath == null) {
      discoveryNotes.add('${friendly.isEmpty ? location : friendly} 未提供 AVTransport 服务');
      return null;
    }

    final controlUrl = uri.resolve(controlPath.trim());
    final sameOrigin = controlUrl.scheme == uri.scheme &&
        controlUrl.host.toLowerCase() == uri.host.toLowerCase() &&
        controlUrl.port == uri.port;
    if (!sameOrigin) {
      discoveryNotes.add('$location 的 controlURL 跨 origin（${controlUrl.origin}），已拒绝');
      return null;
    }

    final name = friendly.trim().isEmpty ? uri.host : friendly.trim();
    return _Endpoint(
      udn: udn.isEmpty ? location : udn,
      friendlyName: name,
      location: location,
      controlUrl: controlUrl.toString(),
      serviceType: _avTransportService,
    );
  }

  /// LOCATION 校验：scheme / 私网 / 合法端口。
  Uri? _validateLocation(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      discoveryNotes.add('$raw 不是合法地址，已丢弃');
      return null;
    }
    // 禁止 URL 内联凭据：它会随 SOAP/描述请求一起发出去，且常被日志带出。
    if (uri.userInfo.isNotEmpty) {
      discoveryNotes.add('${uri.host} 的 LOCATION 含内联凭据，已丢弃');
      return null;
    }
    if (uri.scheme != 'http') {
      discoveryNotes.add('${uri.host} 的 LOCATION scheme=${uri.scheme}，非 http，已丢弃');
      return null;
    }
    if (!config.allowPublicAddresses) {
      final addr = InternetAddress.tryParse(uri.host);
      if (addr != null && !_isPrivateAddress(addr)) {
        discoveryNotes.add('${uri.host} 是公网地址，已丢弃（防 SSRF / 播放地址外泄）');
        return null;
      }
      // 域名只放行 mDNS 保留域（`localhost` / `*.local`）：这些名字不会被公网 DNS
      // 解析，等价于「局域网内」；其它域名一律丢弃，避免 DNS 重绑定把请求引到公网。
      // 之所以不做主动解析：解析要阻塞在 DNS 上（局域网 DNS 超时可达数秒），
      // 而 DLNA 设备实际几乎都直接给 IP 字面量。
      if (addr == null && !_isLocalHostname(uri.host)) {
        discoveryNotes.add('${uri.host} 无法确认属于局域网，已丢弃');
        return null;
      }
    }
    if (uri.port != 80 && (uri.port < 1 || uri.port > 65535)) {
      discoveryNotes.add('${uri.host} 端口非法，已丢弃');
      return null;
    }
    return uri;
  }

  bool _isLocalHostname(String host) {
    final h = host.toLowerCase();
    return h == 'localhost' || h.endsWith('.local');
  }

  /// 设备还没有连接概念，[connect] 用 `GetTransportInfo` 做一次真实探活：
  /// 能返回 `CurrentTransportState` 才算「这台设备现在还活着」。
  @override
  Future<bool> connect(String deviceId) async {
    final e = _endpoints[deviceId];
    if (e == null) {
      discoveryNotes.add('未发现的设备 $deviceId');
      return false;
    }
    try {
      final body = await _soap(e, 'GetTransportInfo',
          '<InstanceID>0</InstanceID>');
      if (!body.contains('CurrentTransportState')) {
        discoveryNotes.add('${e.friendlyName} 探活应答异常');
        return false;
      }
      _connectedId = deviceId;
      return true;
    } catch (err) {
      discoveryNotes.add('${e.friendlyName} 探活失败：$err');
      return false;
    }
  }

  /// 起播：SetAVTransportURI → Play → Seek。
  ///
  /// 顺序有讲究：先 `SetAVTransportURI` 建立资源，`Play` 让它真正跑起来，
  /// 再 `Seek` 跳到续播位置。只有部分设备允许在 STOPPED 状态 Seek，
  /// 所以 seek 失败时退化成 `Pause → Seek → Play` 再试一次；
  /// 两次都失败就返回 false 交给上层降级 —— 「投屏从 0 秒开始播」比投屏失败更糟，
  /// 用户会以为进度丢了。
  @override
  Future<bool> play({required String url, required double positionSeconds}) async {
    final e = _endpoints[_connectedId];
    if (e == null) return false;

    try {
      await _soap(
        e,
        'SetAVTransportURI',
        '<InstanceID>0</InstanceID>'
        '<CurrentURI>${_escapeXml(url)}</CurrentURI>'
        '<CurrentURIMetaData></CurrentURIMetaData>',
      );
      await _soap(e, 'Play', '<InstanceID>0</InstanceID><Speed>1</Speed>');
    } catch (err) {
      discoveryNotes.add('${e.friendlyName} 起播失败：$err');
      return false;
    }

    if (positionSeconds <= 0.5) return true;

    final target = _formatTime(positionSeconds);
    if (await _trySeek(e, target)) return true;

    // 退化路径：暂停后 seek，再恢复播放。
    try {
      await _soap(e, 'Pause', '<InstanceID>0</InstanceID>');
    } catch (_) {
      // 有的设备不支持 Pause，继续试 Seek 即可。
    }
    if (await _trySeek(e, target)) {
      try {
        await _soap(e, 'Play', '<InstanceID>0</InstanceID><Speed>1</Speed>');
        return true;
      } catch (err) {
        discoveryNotes.add('${e.friendlyName} 续播恢复失败：$err');
        return false;
      }
    }
    discoveryNotes.add('${e.friendlyName} 不支持定位到 $target，已放弃投屏');
    return false;
  }

  Future<bool> _trySeek(_Endpoint e, String target) async {
    try {
      await _soap(
        e,
        'Seek',
        '<InstanceID>0</InstanceID><Unit>REL_TIME</Unit>'
        '<Target>$target</Target>',
      );
      return true;
    } catch (err) {
      discoveryNotes.add('${e.friendlyName} Seek($target) 失败：$err');
      return false;
    }
  }

  @override
  Future<double> currentPositionSeconds() async {
    final e = _endpoints[_connectedId];
    if (e == null) {
      throw const DlnaCastException(
          DlnaFailure.unknownDevice, '没有已连接的投屏设备');
    }
    final body =
        await _soap(e, 'GetPositionInfo', '<InstanceID>0</InstanceID>');
    final raw = _firstTag(body, 'RelTime');
    final seconds = _parseTime(raw);
    if (seconds == null) {
      throw DlnaCastException(DlnaFailure.positionUnavailable,
          '设备未提供可读位置（RelTime=${raw ?? 'null'}）');
    }
    return seconds;
  }

  /// 起播确认（R12b 的「首帧」判定）。
  ///
  /// 证据优先级：
  /// 1. **位置前进 ≥ 0.5s** —— 最强证据，说明设备真的在推进时间轴；
  /// 2. **状态由非播放跃迁为 PLAYING** —— 设备明确表示开始播放，且位置可读时
  ///    即可确认；位置读不出来时只给「未验证」，不冒充确认；
  /// 3. **起播后落回 STOPPED / NO_MEDIA_PRESENT** —— 明确失败。
  ///    防盗链源的典型表现就在这里：`Play` 回 200，设备拉流被 403，
  ///    状态随即退回停止，屏幕一直是黑的。
  ///
  /// 为什么不把「一直在 PLAYING」当确认：那正是我们要抓的假成功。
  @override
  Future<CastStartSignal> awaitStartSignal({
    Duration timeout = const Duration(seconds: 5),
    Duration pollInterval = const Duration(milliseconds: 300),
  }) async {
    final e = _endpoints[_connectedId];
    if (e == null) return CastStartSignal.failed;

    final watch = Stopwatch()..start();
    double? baseline;
    try {
      baseline = await currentPositionSeconds();
    } catch (_) {
      baseline = null;
    }
    String? prevState = await _transportState(e);
    var sawPlaying = false;
    var sawStoppedAfterStart = false;

    while (watch.elapsed < timeout) {
      await Future<void>.delayed(pollInterval);
      final state = await _transportState(e);
      double? pos;
      try {
        pos = await currentPositionSeconds();
      } catch (_) {
        pos = null;
      }
      if (baseline != null && pos != null && pos - baseline >= 0.5) {
        return CastStartSignal.confirmed;
      }
      final playing = state == 'PLAYING' || state == 'PLAYING_REVERSE';
      if (playing) {
        sawPlaying = true;
        final wasPlaying = prevState == 'PLAYING' || prevState == 'PLAYING_REVERSE';
        if (!wasPlaying && pos != null) {
          // 真实的非播放 → 播放跃迁，且时间轴可读：确认起播。
          return CastStartSignal.confirmed;
        }
      }
      if ((state == 'STOPPED' || state == 'NO_MEDIA_PRESENT') &&
          watch.elapsed.inMilliseconds > 800) {
        sawStoppedAfterStart = true;
      }
      prevState = state;
    }

    if (sawStoppedAfterStart && !sawPlaying) return CastStartSignal.failed;
    if (sawPlaying) return CastStartSignal.playingUnverified;
    return CastStartSignal.failed;
  }

  /// 读设备当前传输状态（读不到返回 null，不抛）。
  Future<String?> _transportState(_Endpoint e) async {
    try {
      final body =
          await _soap(e, 'GetTransportInfo', '<InstanceID>0</InstanceID>');
      return _firstTag(body, 'CurrentTransportState');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> disconnect() async {
    final e = _endpoints[_connectedId];
    _connectedId = null;
    if (e == null) return;
    try {
      await _soap(e, 'Stop', '<InstanceID>0</InstanceID>');
    } catch (_) {
      // 设备已离线/断电：停止失败不影响本机续播。
    }
  }

  // ---------------------------------------------------------------------------
  // HTTP / SOAP
  // ---------------------------------------------------------------------------

  Future<String> _httpGet(HttpClient client, Uri uri, int maxBytes) async {
    final req = await client.getUrl(uri).timeout(config.requestTimeout);
    req.headers.set(HttpHeaders.connectionHeader, 'close');
    final resp = await req.close().timeout(config.requestTimeout);
    if (resp.statusCode != HttpStatus.ok) {
      await resp.drain<void>();
      throw DlnaCastException(
          DlnaFailure.badDescription, 'HTTP ${resp.statusCode}');
    }
    return _readCapped(resp, maxBytes, DlnaFailure.badDescription);
  }

  Future<String> _soap(_Endpoint e, String action, String inner) async {
    final body = '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$action xmlns:u="${e.serviceType}">$inner</u:$action>'
        '</s:Body></s:Envelope>';

    final client = HttpClient()
      ..connectionTimeout = config.requestTimeout
      ..findProxy = ((_) => 'DIRECT')
      ..userAgent = 'shunbo-dlna/0.1 UPnP/1.1';
    try {
      final req = await client
          .postUrl(Uri.parse(e.controlUrl))
          .timeout(config.requestTimeout);
      req.headers.set('SOAPACTION', '"${e.serviceType}#$action"');
      req.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
      req.headers.set(HttpHeaders.connectionHeader, 'close');
      req.add(utf8.encode(body));

      final resp = await req.close().timeout(config.requestTimeout);
      final text =
          await _readCapped(resp, config.maxSoapResponseBytes, DlnaFailure.soapFailed);
      if (resp.statusCode != HttpStatus.ok) {
        throw DlnaCastException(
            DlnaFailure.soapFailed, '$action → HTTP ${resp.statusCode}', text);
      }
      // UPnP 的错误是 HTTP 500 + `<UPnPError><errorCode>`，要把它当成失败而不是「空应答」。
      if (text.contains('<UPnPError') || text.contains(':Fault>')) {
        throw DlnaCastException(
            DlnaFailure.soapFailed, '$action 返回 UPnP Fault', text);
      }
      return text;
    } finally {
      client.close(force: true);
    }
  }

  /// 读响应并限长：设备可能吐无限流，不能先 `readAsString` 再判断。
  Future<String> _readCapped(
      HttpClientResponse resp, int maxBytes, DlnaFailure reason) async {
    final buf = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      buf.add(chunk);
      if (buf.length > maxBytes) {
        throw DlnaCastException(
            reason, '应答超过 $maxBytes 字节上限，已中断');
      }
    }
    try {
      return utf8.decode(buf.takeBytes(), allowMalformed: false);
    } catch (e) {
      throw DlnaCastException(reason, '应答不是合法 UTF-8', e);
    }
  }
}

// -----------------------------------------------------------------------------
// 纯函数：SSDP / XML / 时间解析（逻辑集中在此，便于逐条回归）
// -----------------------------------------------------------------------------

/// 从 SSDP 报文里取某个头（大小写不敏感）。
String? _header(String text, String name) {
  for (final line in const LineSplitter().convert(text)) {
    final idx = line.indexOf(':');
    if (idx <= 0) continue;
    if (line.substring(0, idx).trim().toLowerCase() == name) {
      return line.substring(idx + 1).trim();
    }
  }
  return null;
}

/// 去重键：scheme/host 小写、去默认端口。同一台设备常回多条不同 `USN`，靠 LOCATION 归一。
String _normalizeForDedup(String location) {
  final u = Uri.tryParse(location);
  if (u == null) return location.toLowerCase();
  return '${u.scheme}://${u.host.toLowerCase()}:${u.port}${u.path}';
}

String? _firstTag(String xml, String tag) {
  final re = RegExp('<$tag[^>]*>(.*?)</$tag>', dotAll: true);
  final m = re.firstMatch(xml);
  return m?.group(1);
}

/// 找 AVTransport 服务的 controlURL。
///
/// 不用完整 XML 解析器（不引依赖），改为「按 `<service>` 切块再匹配」：
/// `.*?` 只在一个 service 块内匹配，块数由描述体积上限兜住，不存在灾难性回溯。
String? _avTransportControlUrl(String xml) {
  final blocks = RegExp('<service>(.*?)</service>', dotAll: true).allMatches(xml);
  for (final b in blocks) {
    final body = b.group(1) ?? '';
    final type = _firstTag(body, 'serviceType')?.trim();
    if (type == null) continue;
    if (!type.contains('AVTransport')) continue;
    final control = _firstTag(body, 'controlURL')?.trim();
    if (control == null || control.isEmpty) return null;
    return _unescape(control);
  }
  return null;
}

String _unescape(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

String _escapeXml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// `HH:MM:SS` / `H:MM:SS.mmm` → 秒。`NOT_IMPLEMENTED`、空串、乱码 → null。
double? _parseTime(String? raw) {
  if (raw == null) return null;
  final t = raw.trim();
  if (t.isEmpty) return null;
  final m = RegExp(r'^(\d+):(\d{1,2}):(\d{1,2})(?:\.(\d+))?$').firstMatch(t);
  if (m == null) return null;
  final h = int.parse(m.group(1)!);
  final mi = int.parse(m.group(2)!);
  final s = int.parse(m.group(3)!);
  if (mi > 59 || s > 60) return null;
  final ms = m.group(4) == null ? 0.0 : double.parse('0.${m.group(4)}');
  return h * 3600 + mi * 60 + s + ms;
}

String _formatTime(double seconds) {
  final total = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  return '${h.toString().padLeft(2, '0')}:'
      '${m.toString().padLeft(2, '0')}:'
      '${s.toString().padLeft(2, '0')}';
}

/// 私网判定：10/8、172.16/12、192.168/16、127/8、169.254/16、fc00::/7、fe80::/10、::1。
bool _isPrivateAddress(InternetAddress a) {
  final raw = a.rawAddress;
  if (raw.length == 4) {
    final b0 = raw[0];
    final b1 = raw[1];
    if (b0 == 10) return true;
    if (b0 == 127) return true;
    if (b0 == 192 && b1 == 168) return true;
    if (b0 == 172 && b1 >= 16 && b1 <= 31) return true;
    if (b0 == 169 && b1 == 254) return true;
    return false;
  }
  if (raw.length == 16) {
    var loop = true;
    for (var i = 0; i < 15; i++) {
      if (raw[i] != 0) {
        loop = false;
        break;
      }
    }
    if (loop && raw[15] == 1) return true;
    if ((raw[0] & 0xFE) == 0xFC) return true;
    if (raw[0] == 0xFE && (raw[1] & 0xC0) == 0x80) return true;
    // IPv4-mapped ::ffff:a.b.c.d
    var mapped = true;
    for (var i = 0; i < 10; i++) {
      if (raw[i] != 0) {
        mapped = false;
        break;
      }
    }
    if (mapped && raw[10] == 0xFF && raw[11] == 0xFF) {
      return _isPrivateAddress(InternetAddress.fromRawAddress(raw.sublist(12)));
    }
  }
  return false;
}
