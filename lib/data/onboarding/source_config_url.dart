// 从 URL 下载源配置的**唯一网络 IO 边界**（对标 source_config_file.dart）。
//
// 为什么不直接复用 `DartHttpFetcher`：那个类是「播放取页」的边界，它的判断标准是
// 「这页能不能当站点页面解析」；下载配置的判断标准完全不同——一次下载就是一次
// **不可信代码/数据的引入**，任何多余的宽容都会变成攻击面。两者混用会让任一侧的
// 策略调整都影响另一侧的安全假设，因此这里重写而不是复用。
//
// 与文件导入一致：本文件只负责「拿到一段文本」，**不做任何信任背书**。
// 拿到的文本必须再过一遍 E9 白名单（`loadSourceConfig` + `validateSourceConfig`），
// 且调用方必须先过免责声明门禁。
//
// 刻意收紧的七条（每条都有回归用例）：
// 1. **仅 https**；http 只对 loopback 放开，用于本地自测/内网直连，且明确提示明文风险；
// 2. **禁止 URL 内联凭据**（`user:pass@host`）——它会被原样写进日志、剪贴板和分享链接；
// 3. **逐跳复检重定向**，且只允许同 host（跨 host 跳转等于把「用户指定的来源」换掉）；
// 4. **拒绝 https → http 降级**；
// 5. **字节上限** 与文件导入同值（256 KB），流式累计超限即中断，不先读进内存再判断；
// 6. **拒绝二进制**（含 NUL 字节）与非法 UTF-8——配置文件是纯文本，混进可执行载荷
//    说明来源根本不是配置；
// 7. **单次总超时**：慢速灌包（slowloris 式）不能挂住引导流程。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 单次 URL 导入允许的最大字节数（与 [kMaxImportTextLength] 同值，按字节算更严格）。
const int kMaxSourceConfigBytes = 256 * 1024;

/// URL 导入允许跟随的重定向次数。
const int kMaxConfigRedirects = 2;

/// 发布者可选的分离签名头（`sha256=<HMAC-SHA256 hex>`）。
const String kSourceSignatureHeader = 'x-shunbo-signature';

/// 签名密钥标识（可选，便于发布者轮换密钥）。
const String kSourceKeyIdHeader = 'x-shunbo-key-id';

/// 失败原因（UI 需要据此给出可执行提示，而不是一句「导入失败」）。
enum SourceConfigUrlFailure {
  /// 地址为空。
  emptyUrl,

  /// 不是合法 URL（缺 scheme / host）。
  malformed,

  /// scheme 不是 http/https（file://、ftp://、data: 等一律拒绝）。
  unsupportedScheme,

  /// 明文 http 且目标不是 loopback。
  insecureTransport,

  /// URL 里带了 usename/password。
  userInfo,

  /// 重定向到别的主机、降级为 http、或超过跳数上限。
  redirect,

  /// 非 2xx（错误页不能当配置用）。
  httpStatus,

  /// 超过字节上限。
  tooLarge,

  /// 内容含 NUL 字节（二进制 / 压缩包 / 可执行文件）。
  binary,

  /// 不是合法 UTF-8。
  notUtf8,

  /// 连接或读取超时。
  timeout,

  /// 连接失败（域名解析/DNS/TLS/网络不可达）。
  connection,
}

/// 下载结果：要么带文本，要么带可解释的失败原因。
class SourceConfigUrlResult {
  final bool ok;
  final String? text;

  /// 来源标签，只保留 `host[:port]`（**不回显完整 URL**：query 里可能有私有 token）。
  final String? originLabel;
  final SourceConfigUrlFailure? failure;
  final String message;
  final int bytes;

  /// 只有签名相关的两个响应头会被回显给上层（E9 来源可信度）。
  ///
  /// **不**把整份响应头透出去：Set-Cookie / Authorization / 自定义鉴权头
  /// 一旦进入导入链路就可能被写进诊断日志或配置备份。值仅允许可打印 ASCII、
  /// 长度 ≤256，且只在最终 2xx 响应上采集（重定向头不采）。
  final Map<String, String> headers;

  const SourceConfigUrlResult.ok({
    required this.text,
    required this.originLabel,
    required this.bytes,
    this.headers = const <String, String>{},
  })  : ok = true,
        failure = null,
        message = '配置下载完成';

  const SourceConfigUrlResult.fail(
    SourceConfigUrlFailure failure,
    String message, {
    String? originLabel,
  })  : ok = false,
        text = null,
        originLabel = originLabel,
        failure = failure,
        message = message,
        bytes = 0,
        headers = const <String, String>{};

  @override
  String toString() =>
      ok ? 'SourceConfigUrlResult.ok($originLabel, ${bytes}B)' : 'SourceConfigUrlResult.fail(${failure?.name}: $message)';
}

/// loopback 判定：只有这些主机才允许用明文 http。
bool isLoopbackHost(String host) {
  final h = host.toLowerCase();
  return h == 'localhost' ||
      h == '127.0.0.1' ||
      h == '::1' ||
      h == '[::1]' ||
      h.startsWith('127.');
}

/// 下载并返回源配置文本。
///
/// [client] 仅用于回归注入；不注入时内部自建并在结束时关闭（残留连接会挂住进程）。
/// [timeout] 覆盖「连接 + 每跳响应 + 读体」整条链路。
Future<SourceConfigUrlResult> fetchSourceConfigUrl(
  String rawUrl, {
  HttpClient? client,
  Duration timeout = const Duration(seconds: 10),
  int maxBytes = kMaxSourceConfigBytes,
  bool useSystemProxy = true,
}) async {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) {
    return const SourceConfigUrlResult.fail(
        SourceConfigUrlFailure.emptyUrl, '请先填写配置链接');
  }

  final parsed = Uri.tryParse(trimmed);
  if (parsed == null || !parsed.hasScheme) {
    return const SourceConfigUrlResult.fail(
        SourceConfigUrlFailure.malformed, '链接格式不正确（需要完整地址，如 https://…/sources.json）');
  }
  if (parsed.scheme != 'https' && parsed.scheme != 'http') {
    return SourceConfigUrlResult.fail(SourceConfigUrlFailure.unsupportedScheme,
        '仅支持 https 链接（当前为 ${parsed.scheme}://）');
  }
  if (parsed.host.isEmpty) {
    return const SourceConfigUrlResult.fail(
        SourceConfigUrlFailure.malformed, '链接缺少主机名（需要形如 https://host/path）');
  }
  if (parsed.userInfo.isNotEmpty) {
    return const SourceConfigUrlResult.fail(
        SourceConfigUrlFailure.userInfo, '链接不能内联账号密码，请改用公开地址');
  }
  if (parsed.scheme == 'http' && !isLoopbackHost(parsed.host)) {
    return SourceConfigUrlResult.fail(SourceConfigUrlFailure.insecureTransport,
        '拒绝明文 http 下载源配置（会被中间人替换）；请使用 https，或改为本地文件导入');
  }

  final own = client == null;
  final c = client ?? HttpClient();
  if (!useSystemProxy) c.findProxy = (_) => 'DIRECT';
  c.connectionTimeout = timeout;

  final deadline = Stopwatch()..start();
  try {
    return await _get(c, parsed, parsed, maxBytes, timeout, deadline, 0);
  } on TimeoutException {
    return SourceConfigUrlResult.fail(SourceConfigUrlFailure.timeout,
        '下载超时（${timeout.inSeconds}s），请检查网络或改用文件导入',
        originLabel: _label(parsed));
  } on SocketException catch (e) {
    return SourceConfigUrlResult.fail(SourceConfigUrlFailure.connection,
        '连接失败：${e.osError?.message ?? e.message}',
        originLabel: _label(parsed));
  } on HandshakeException catch (e) {
    return SourceConfigUrlResult.fail(
        SourceConfigUrlFailure.connection, 'TLS 握手失败：${e.message}',
        originLabel: _label(parsed));
  } on HttpException catch (e) {
    return SourceConfigUrlResult.fail(
        SourceConfigUrlFailure.connection, 'HTTP 异常：${e.message}',
        originLabel: _label(parsed));
  } finally {
    if (own) c.close(force: true);
  }
}

String _label(Uri u) => u.hasPort ? '${u.host}:${u.port}' : u.host;

Future<SourceConfigUrlResult> _get(
  HttpClient client,
  Uri uri,
  Uri first,
  int maxBytes,
  Duration timeout,
  Stopwatch deadline,
  int hops,
) async {
  Duration left() {
    final rest = timeout - deadline.elapsed;
    return rest.isNegative ? Duration.zero : rest;
  }

  final req = await client.getUrl(uri).timeout(left(),
      onTimeout: () => throw TimeoutException('连接超时', timeout));
  // 手工跟随：自动跟随会绕过下面的逐跳复检。
  req.followRedirects = false;
  req.headers.set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*');
  req.headers.set(HttpHeaders.userAgentHeader, 'shunbo-config/1.0');
  final resp = await req.close().timeout(left(),
      onTimeout: () => throw TimeoutException('等待响应头超时', timeout));

  if (resp.isRedirect) {
    await _drain(resp);
    final location = resp.headers.value(HttpHeaders.locationHeader);
    if (location == null || location.isEmpty) {
      return SourceConfigUrlResult.fail(SourceConfigUrlFailure.redirect,
          '重定向缺少 Location', originLabel: _label(first));
    }
    if (hops >= kMaxConfigRedirects) {
      return SourceConfigUrlResult.fail(SourceConfigUrlFailure.redirect,
          '重定向次数超过 $kMaxConfigRedirects 次', originLabel: _label(first));
    }
    final next = Uri.tryParse(location);
    final resolved = next == null
        ? null
        : (next.hasScheme ? next : uri.resolveUri(next));
    if (resolved == null || resolved.host.isEmpty) {
      return SourceConfigUrlResult.fail(SourceConfigUrlFailure.redirect,
          '重定向目标无法解析', originLabel: _label(first));
    }
    if (resolved.host.toLowerCase() != first.host.toLowerCase() ||
        resolved.port != first.port) {
      return SourceConfigUrlResult.fail(SourceConfigUrlFailure.redirect,
          '重定向到了其他主机（${resolved.host}），已拒绝',
          originLabel: _label(first));
    }
    if (uri.scheme == 'https' && resolved.scheme != 'https') {
      return SourceConfigUrlResult.fail(SourceConfigUrlFailure.redirect,
          '重定向把 https 降级为 ${resolved.scheme}，已拒绝',
          originLabel: _label(first));
    }
    return _get(client, resolved, first, maxBytes, timeout, deadline, hops + 1);
  }

  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    await _drain(resp);
    return SourceConfigUrlResult.fail(SourceConfigUrlFailure.httpStatus,
        '服务器返回 ${resp.statusCode}，无法作为配置来源',
        originLabel: _label(first));
  }

  // 只在最终 2xx 上采集签名相关响应头；重定向响应头一律不采，
  // 避免「中间跳给一个签名、终点内容却是别的」这类混淆。
  final signatureHeaders = <String, String>{};
  resp.headers.forEach((name, values) {
    final key = name.toLowerCase();
    if (key != kSourceSignatureHeader && key != kSourceKeyIdHeader) return;
    if (values.isEmpty) return;
    final value = values.first.trim();
    if (value.isEmpty || value.length > 256) return;
    if (value.codeUnits.any((c) => c < 0x20 || c > 0x7e)) return;
    signatureHeaders[key] = value;
  });

  final bytes = <int>[];
  var total = 0;
  await for (final chunk in resp.timeout(left())) {
    total += chunk.length;
    if (total > maxBytes) {
      await _drain(resp);
      return SourceConfigUrlResult.fail(SourceConfigUrlFailure.tooLarge,
          '配置超过 ${maxBytes ~/ 1024} KB 上限，已中止下载',
          originLabel: _label(first));
    }
    bytes.addAll(chunk);
  }

  // NUL 字节：JSON 里不可能出现，出现即说明下发的不是文本（压缩包/可执行文件）。
  for (final b in bytes) {
    if (b == 0) {
      return SourceConfigUrlResult.fail(SourceConfigUrlFailure.binary,
          '下载内容含二进制数据，已拒绝（配置文件必须是纯文本 JSON）',
          originLabel: _label(first));
    }
  }

  String text;
  try {
    // allowMalformed: false —— 配置文本必须是合法 UTF-8（JSON 规范），
    // 用替换字符蒙混过去会让后续解析在别处以更难懂的方式失败。
    text = utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    return SourceConfigUrlResult.fail(SourceConfigUrlFailure.notUtf8,
        '下载内容不是 UTF-8 文本，已拒绝', originLabel: _label(first));
  }
  if (text.startsWith('\uFEFF')) text = text.substring(1);

  if (text.trim().isEmpty) {
    return SourceConfigUrlResult.fail(SourceConfigUrlFailure.binary,
        '下载内容为空', originLabel: _label(first));
  }
  return SourceConfigUrlResult.ok(
    text: text,
    originLabel: _label(first),
    bytes: total,
    headers: signatureHeaders,
  );
}

Future<void> _drain(HttpClientResponse resp) async {
  try {
    await resp.drain<void>();
  } catch (_) {
    // 只为释放连接，失败无需上报。
  }
}
