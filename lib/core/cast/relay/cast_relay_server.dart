/// 投屏串流中继（R12b 的「串流」一端）。
///
/// 解决的问题很具体：**带防盗链的源，电视直推必定失败**。
/// 这类源在服务端校验 `Referer` / `User-Agent`，有的还要 `Cookie`；
/// 电视只按 DLNA 的 `SetAVTransportURI` 拉地址，没有任何补请求头的能力，
/// 于是拿到 403 —— 而 DLNA 的 `Play` 应答照样是 200，看起来「投屏成功了」，
/// 屏幕上却一直黑着。手机中继把这一段补上：本机带齐请求头去拉，再把字节
/// 重新提供给电视。
///
/// 边界（按不可信输入处理，和 DLNA 传输层同一套纪律）：
/// * 只监听、只服务**私网与回环**来源地址。本机在酒店/公司 Wi-Fi 上时，
///   一个无鉴权的中继等于开放代理，别人可以拿它当跳板；
/// * 一个随机的 **token** 前缀：局域网内其它设备不知道 token 就取不到流；
/// * 上游只允许 `http` / `https`，禁 userinfo，地址长度有上限；
/// * HLS 播放列表要**改写**：分片与子列表的 URI 也要指回中继，
///   否则电视拿到原始分片地址后仍然 403（防盗链通常对分片一样校验）；
/// * 播放列表最多读 2 MiB，超限直接拒绝，避免一个大列表把内存吃满。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'relay_session.dart';

/// 一个中继会话的结束原因（写进诊断，便于现场判断是网络还是源的问题）。
enum RelayFailure {
  /// 本机没有可供局域网访问的私网地址（例如只连了移动数据）。
  noLanAddress,

  /// 端口绑定失败。
  bindFailed,

  /// 上游拒绝（403/401）：说明连手机自己都拉不到，中继也无解。
  upstreamDenied,

  /// 上游不可达 / 超时。
  upstreamUnreachable,
}

class RelayException implements Exception {
  RelayException(this.reason, this.message);

  final RelayFailure reason;
  final String message;

  @override
  String toString() => 'RelayException(${reason.name}): $message';
}

/// 本机局域网中继服务器。
///
/// 生命周期：`start()` → 多次 `relayUrlFor()` → `stop()`。
/// 一个投屏会话一个实例，不复用 —— 复用会让 token 与请求头在不同源之间串味。
class CastRelayServer implements CastRelaySession {
  CastRelayServer({
    HttpClient Function()? clientFactory,
    this.maxPlaylistBytes = 2 * 1024 * 1024,
    this.maxUpstreamUrlLength = 4096,
    this.connectTimeout = const Duration(seconds: 8),
    this.responseTimeout = const Duration(seconds: 15),
    this.overrideHost,
    Random? random,
  })  : _clientFactory = clientFactory,
        _random = random ?? Random.secure();

  final HttpClient Function()? _clientFactory;
  final Random _random;

  /// 播放列表读取上限（分片是流式透传，不受此限制）。
  final int maxPlaylistBytes;

  /// 单个上游地址长度上限。
  final int maxUpstreamUrlLength;

  final Duration connectTimeout;
  final Duration responseTimeout;

  /// 仅供回归注入：强制用指定主机名对外发布。
  ///
  /// 本机可能有多张网卡（虚拟机、VPN、Docker），回归想要一个**确定**的地址；
  /// 生产路径必须留 null，由 [pickLanAddress] 自己挑 —— 写死地址正是
  /// 「换台电视就连不上」的经典成因。
  final String? overrideHost;

  HttpServer? _server;
  HttpClient? _client;
  String _token = '';
  Uri? _baseUri;
  bool _stopped = false;

  /// 提供给设备的基地址（含 token）。未启动时为 null。
  @override
  Uri? get baseUri => _baseUri;

  /// 成功转发的请求数（诊断展示用：0 说明设备根本没来拉）。
  int get requestCount => _requestCount;
  int _requestCount = 0;

  /// 上游请求被拒的次数（403/401）——这类要如实告诉用户「源站不让电视看」。
  int get upstreamDeniedCount => _upstreamDeniedCount;
  int _upstreamDeniedCount = 0;

  /// 启动服务器并返回给设备的基地址。
  ///
  /// [headers] 是中继发往上游时要补的请求头（`Referer` / `User-Agent` 等），
  /// 来自源适配器的 `playbackHeaders`。**只在本机出口加**，不会回传给设备。
  Future<Uri> start({required Map<String, String> headers}) async {
    if (_baseUri != null) return _baseUri!;
    final address = overrideHost ?? await pickLanAddress();
    if (address == null) {
      throw RelayException(RelayFailure.noLanAddress,
          '本机没有可供局域网访问的私网地址（请确认已连上与电视同一个 Wi-Fi）');
    }
    try {
      // 绑到 anyIPv4 才能被同网段设备访问；但下面每个请求都会校验来源地址。
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0, shared: false);
    } catch (err) {
      throw RelayException(RelayFailure.bindFailed, '中继端口绑定失败：$err');
    }
    _server!.autoCompress = false;
    _server!.idleTimeout = const Duration(seconds: 60);
    _token = _randomToken();
    _baseUri = Uri(
      scheme: 'http',
      host: address,
      port: _server!.port,
      path: '/t/$_token',
    );
    _client = (_clientFactory?.call() ?? HttpClient())
      ..connectionTimeout = connectTimeout
      // 局域网内的上游多为公网 CDN，允许走系统代理与否都不影响本机监听；
      // 这里用 DIRECT，避免系统代理把大流量转发拖死。
      ..findProxy = ((_) => 'DIRECT')
      ..autoUncompress = true;
    _headers = Map<String, String>.from(headers);
    unawaited(_serve(_server!));
    return _baseUri!;
  }

  Map<String, String> _headers = const <String, String>{};

  @override
  Future<void> stop() async {
    _stopped = true;
    final s = _server;
    _server = null;
    _baseUri = null;
    _token = '';
    _client?.close(force: true);
    _client = null;
    try {
      await s?.close(force: true);
    } catch (_) {
      // 关停失败不影响本机续播。
    }
  }

  /// 把上游地址包装成中继地址。地址不合法时返回 null。
  ///
  /// 用 base64url 而不是查询串：分片地址常自带很长的查询串，
  /// 再套一层查询串会被某些设备的 URL 解析截断。
  @override
  String? relayUrlFor(String upstreamUrl) {
    final base = _baseUri;
    if (base == null || _stopped) return null;
    final trimmed = upstreamUrl.trim();
    if (trimmed.isEmpty || trimmed.length > maxUpstreamUrlLength) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    // 带 userinfo 的地址会把凭据写进播放器日志与电视端历史，一律拒绝。
    if (uri.userInfo.isNotEmpty) return null;
    final encoded = base64Url.encode(utf8.encode(trimmed)).replaceAll('=', '');
    return '${base.toString()}/r/$encoded';
  }

  String _randomToken() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      // 单个请求的异常绝不能把整个监听循环打断。
      unawaited(_handle(request).catchError((Object _) async {
        try {
          request.response.statusCode = HttpStatus.badGateway;
          await request.response.close();
        } catch (_) {
          // 已经关掉了。
        }
      }));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (_stopped) {
      response.statusCode = HttpStatus.serviceUnavailable;
      await response.close();
      return;
    }
    // 只服务私网来源：见文件头的「开放代理」说明。
    final remote = request.connectionInfo?.remoteAddress;
    if (remote != null && !isPrivateAddress(remote)) {
      response.statusCode = HttpStatus.forbidden;
      await response.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      await response.close();
      return;
    }

    final upstream = _upstreamFor(request.uri.path);
    if (upstream == null) {
      // token 不对就是 404：不给探测者「这里有个中继」的信息。
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    final client = _client;
    if (client == null) {
      response.statusCode = HttpStatus.serviceUnavailable;
      await response.close();
      return;
    }

    _requestCount++;
    HttpClientResponse? up;
    try {
      final req = await client
          .openUrl(request.method == 'HEAD' ? 'HEAD' : 'GET', upstream)
          .timeout(connectTimeout);
      // 顺序有意义：先注入源站要求的那几个头，再补 Range/连接控制，
      // 但 **不** 转发设备发来的其它头（设备可能带自己的 UA，会把防盗链弄坏）。
      _headers.forEach(req.headers.set);
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      req.headers.set(HttpHeaders.connectionHeader, 'close');
      up = await req.close().timeout(responseTimeout);
    } on TimeoutException {
      response.statusCode = HttpStatus.gatewayTimeout;
      await response.close();
      return;
    } catch (_) {
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }

    if (up.statusCode == 401 || up.statusCode == 403 || up.statusCode == 407) {
      _upstreamDeniedCount++;
      // 原样回给设备：让它的错误处理（以及我们的首帧判定）看到真实原因。
      response.statusCode = up.statusCode;
      await up.drain<void>();
      await response.close();
      return;
    }

    final contentType = up.headers.contentType?.mimeType ?? '';
    final isPlaylist = _looksLikePlaylist(upstream, contentType);
    try {
      if (isPlaylist && request.method == 'GET') {
        await _pipePlaylist(up, response, upstream);
      } else {
        await _pipeBinary(up, response, headOnly: request.method == 'HEAD');
      }
    } catch (_) {
      // 客户端中途断开（电视取消投屏）会走到这里，属正常路径。
      try {
        await response.close();
      } catch (_) {}
    } finally {
      try {
        await up.drain<void>();
      } catch (_) {}
    }
  }

  /// `/t/<token>/r/<b64url>` → 上游 Uri。token 不符或解码失败返回 null。
  Uri? _upstreamFor(String path) {
    final prefix = '/t/$_token/r/';
    if (!path.startsWith(prefix)) return null;
    final encoded = path.substring(prefix.length);
    if (encoded.isEmpty) return null;
    try {
      // 补回 base64 的 padding：relayUrlFor 刻意去了 '='。
      final padded = encoded.padRight((encoded.length + 3) & ~3, '=');
      final text = utf8.decode(base64Url.decode(padded));
      if (text.length > maxUpstreamUrlLength) return null;
      final uri = Uri.tryParse(text);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return null;
      }
      if (uri.userInfo.isNotEmpty) return null;
      return uri;
    } catch (_) {
      return null;
    }
  }

  bool _looksLikePlaylist(Uri upstream, String mimeType) {
    if (mimeType.contains('mpegurl')) return true;
    final p = upstream.path.toLowerCase();
    return p.endsWith('.m3u8') || p.endsWith('.m3u');
  }

  /// 播放列表：读成文本 → 改写 URI → 以 HLS 类型返回。
  ///
  /// [upstream] 是这块播放列表的真实地址，用来解析相对分片路径。
  /// 不能用请求里那层中继地址去解析：那是 base64 编码后的产物，
  /// 相对路径拼上去会得到一条谁都不认识的地址。
  Future<void> _pipePlaylist(
    HttpClientResponse up,
    HttpResponse response,
    Uri upstream,
  ) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in up) {
      total += chunk.length;
      if (total > maxPlaylistBytes) {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
        return;
      }
      builder.add(chunk);
    }
    final text = utf8.decode(builder.takeBytes(), allowMalformed: true);
    // 上游可能 302 到另一个地址（CDN 调度）：相对分片要以**最终地址**为基准，
    // 否则会把分片解析到跳转前的主机上，拿到的还是 403。
    var effective = upstream;
    for (final r in up.redirects) {
      final next = resolveUri(effective, r.location.toString());
      if (next != null) effective = next;
    }
    final rewritten = rewritePlaylist(
      text,
      baseUrl: effective,
      resolve: (raw) {
        final absolute = resolveUri(effective, raw);
        return absolute == null ? null : relayUrlFor(absolute.toString());
      },
    );
    final body = utf8.encode(rewritten);
    response.statusCode = HttpStatus.ok;
    response.headers.contentType =
        ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
    response.headers.contentLength = body.length;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.add(body);
    await response.close();
  }

  /// 二进制：保留状态码 / 类型 / 长度 / Range 相关头，边收边发。
  ///
  /// 不能整块缓冲：一集电视剧动辄几百 MB，缓冲会把手机内存打爆。
  Future<void> _pipeBinary(
    HttpClientResponse up,
    HttpResponse response, {
    required bool headOnly,
  }) async {
    response.statusCode = up.statusCode;
    _copyHeader(up, response, HttpHeaders.contentTypeHeader);
    _copyHeader(up, response, HttpHeaders.contentLengthHeader);
    _copyHeader(up, response, HttpHeaders.contentRangeHeader);
    _copyHeader(up, response, HttpHeaders.acceptRangesHeader);
    _copyHeader(up, response, HttpHeaders.etagHeader);
    _copyHeader(up, response, HttpHeaders.lastModifiedHeader);
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (headOnly) {
      await response.close();
      return;
    }
    await response.addStream(up);
    await response.close();
  }

  void _copyHeader(HttpClientResponse from, HttpResponse to, String name) {
    final v = from.headers.value(name);
    if (v != null && v.isNotEmpty) to.headers.set(name, v);
  }
}

/// 把播放列表里的 URI 改写成中继地址。
///
/// * 以 `#` 开头的行是标签：只改写其中的 `URI="..."` 属性
///   （`EXT-X-KEY` 的密钥、`EXT-X-MAP` 的初始化段、`EXT-X-MEDIA` 的音轨、
///   `EXT-X-I-FRAME-STREAM-INF` 的 I 帧列表都必须走中继，否则同样 403）；
/// * 其它非空行是分片或子播放列表地址。
///
/// [resolve] 负责「相对地址 + 基准 → 中继地址」，返回 null 表示放弃改写该行
/// （地址不合法时保留原样，让设备自己报错，好过发一条坏地址）。
String rewritePlaylist(
  String text, {
  required String? Function(String raw) resolve,
  Uri? baseUrl,
}) {
  final lines = const LineSplitter().convert(text);
  final out = <String>[];
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      out.add(line);
      continue;
    }
    if (trimmed.startsWith('#')) {
      out.add(_rewriteTagUris(line, resolve));
      continue;
    }
    final replaced = resolve(trimmed);
    out.add(replaced ?? line);
  }
  // 保留原文件末尾换行语义：HLS 播放器不要求，但保持一致更安全。
  final joined = out.join('\n');
  return text.endsWith('\n') ? '$joined\n' : joined;
}

/// 改写标签行里的 `URI="..."`（可能一行多个）。
String _rewriteTagUris(String line, String? Function(String raw) resolve) {
  final pattern = RegExp(r'URI="([^"]*)"');
  return line.replaceAllMapped(pattern, (m) {
    final raw = m.group(1);
    if (raw == null || raw.isEmpty) return m.group(0)!;
    final replaced = resolve(raw);
    return replaced == null ? m.group(0)! : 'URI="$replaced"';
  });
}

/// 相对地址解析（HLS 允许相对分片）。
Uri? resolveUri(Uri? base, String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final direct = Uri.tryParse(trimmed);
  if (direct == null) return null;
  if (direct.hasScheme) return direct;
  if (base == null) return null;
  try {
    return base.resolveUri(direct);
  } catch (_) {
    return null;
  }
}

/// 是否私网 / 回环地址。
///
/// 用途是**限制中继只服务局域网**，不是做安全边界以外的事：
/// 判定从严，宁可把一台电视判成「不合法」（表现为投屏失败并给出提示），
/// 也不要把本机变成任何 Wi-Fi 上都能用的开放代理。
bool isPrivateAddress(InternetAddress address) {
  if (address.isLoopback) return true;
  final raw = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    if (raw.length != 4) return false;
    final a = raw[0], b = raw[1];
    if (a == 10) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    // 链路本地（169.254/16）：部分电视在拿到 DHCP 之前只会走它。
    if (a == 169 && b == 254) return true;
    return false;
  }
  if (address.type == InternetAddressType.IPv6) {
    if (raw.length != 16) return false;
    // fc00::/7 唯一本地地址。
    if ((raw[0] & 0xfe) == 0xfc) return true;
    // fe80::/10 链路本地。
    if (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80) return true;
    return false;
  }
  return false;
}

/// 选一个本机可被局域网访问的 IPv4 地址。
///
/// 优先私网地址（10/172/192），其次链路本地。选不到就返回 null ——
/// 宁可不投屏也不要给设备一个它根本连不上的地址（那会表现为「一直转圈」，
/// 比明确报错更难排查）。
Future<String?> pickLanAddress({List<NetworkInterface>? interfaces}) async {
  List<NetworkInterface> list;
  try {
    list = interfaces ?? await NetworkInterface.list(type: InternetAddressType.IPv4);
  } catch (_) {
    return null;
  }
  String? fallback;
  for (final ni in list) {
    for (final addr in ni.addresses) {
      if (addr.type != InternetAddressType.IPv4 || addr.isLoopback) continue;
      if (!isPrivateAddress(addr)) continue;
      final raw = addr.rawAddress;
      if (raw.length == 4 && raw[0] == 169) {
        fallback ??= addr.address;
        continue;
      }
      return addr.address;
    }
  }
  return fallback;
}
