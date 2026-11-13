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

/// 判断响应内容是网页而非接口数据。纯函数，便于门禁直接回归。
///
/// 存在的理由：点播源要的是 JSON。实测「影视仓官方入口」返回 277 KB HTML，
/// 走原路径会先撞 256 KB 字节上限，报一句「配置超过 256 KB 上限」——
/// 用户会以为换个地址就行，真实原因却是这条地址压根不是接口。
/// 先看 Content-Type，再看正文首字符（有些站点把网页写成 text/plain）。
/// **正文优先，Content-Type 只作兜底**。苹果 CMS 采集站实测大量返回
/// `Content-Type: text/html;charset=utf-8`，正文却是合法 JSON（老 PHP 站点的
/// 默认头）；只看头会把 12 个能用的站点全判成网页直接跳过。
bool isHtmlLikePayload({String? contentType, String? bodyPrefix}) {
  var head = (bodyPrefix ?? '');
  if (head.startsWith('\uFEFF')) head = head.substring(1);
  head = head.trimLeft();
  if (head.isNotEmpty) {
    // JSON 的顶层只可能是 `{` / `[`；出现 `<` 就是 HTML / XML 说明页。
    if (head.startsWith('<')) return true;
    // 正文已经明确是 JSON ⇒ 无论头写什么都不是网页。
    if (head.startsWith('{') || head.startsWith('[')) return false;
  }
  final ct = (contentType ?? '').toLowerCase();
  return ct.contains('text/html') || ct.contains('application/xhtml');
}

/// 取正文里第一个「有意义的」字节（跳过 UTF-8 BOM 与空白），没有则返回 null。
///
/// 只用于流式早期判定网页：读满 256 KB 才发现是 HTML 的话，报错就成了
/// 「超过上限」而不是「这是网页」，用户会以为换个地址就行。
int? firstSignificantByte(List<int> bytes) {
  var i = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    i = 3;
  }
  for (; i < bytes.length; i++) {
    final b = bytes[i];
    if (b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D) continue;
    return b;
  }
  return null;
}

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

  /// 服务器返回的是网页（HTML），不是接口数据。
  ///
  /// 只在调用方显式要求「必须是 JSON」时才会出现（1.0.5 点播源链路）。
  /// 1.0.4 的 E9 导入不受影响：那边仍按原逻辑下载后再由内容校验器判定。
  htmlPage,

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
  // 1.0.5 G1：仅当用户在点播源设置里显式打开「允许明文 http」时才为 true。
  // 默认 false ⇒ 1.0.4 的 E9 链接导入策略逐字不变。
  bool allowInsecureHttp = false,
  // 1.0.5 G1：点播源要的是**接口 JSON**，不是网页。为 true 时，响应头写着
  // text/html 或正文以 `<` 开头就立刻判定「这是网页」并给出准确原因，
  // 而不是让 277 KB 的网页撑到字节上限、报一句「超过 256 KB 上限」。
  // 默认 false ⇒ 1.0.4 的 E9 链路完全不受影响。
  bool rejectHtml = false,
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
  if (parsed.scheme == 'http' &&
      !isLoopbackHost(parsed.host) &&
      !allowInsecureHttp) {
    return SourceConfigUrlResult.fail(SourceConfigUrlFailure.insecureTransport,
        '拒绝明文 http 下载源配置（会被中间人替换）；请使用 https，'
        '或在「点播源」里显式打开允许明文 http，或改为本地文件导入');
  }

  final own = client == null;
  final c = client ?? HttpClient();
  if (!useSystemProxy) c.findProxy = (_) => 'DIRECT';
  c.connectionTimeout = timeout;

  final deadline = Stopwatch()..start();
  try {
    return await _get(c, parsed, parsed, maxBytes, timeout, deadline, 0,
        rejectHtml);
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
  bool rejectHtml,
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
    return _get(client, resolved, first, maxBytes, timeout, deadline, hops + 1,
        rejectHtml);
  }

  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    await _drain(resp);
    return SourceConfigUrlResult.fail(SourceConfigUrlFailure.httpStatus,
        '服务器返回 ${resp.statusCode}，无法作为配置来源',
        originLabel: _label(first));
  }

  // 网页判定放到正文里做（见下方读取循环），**不能只看响应头**：
  // 采集站普遍返回 `Content-Type: text/html` 却给的是 JSON，
  // 只看头会把可用站点全部误杀。也不再等整页读完才判 —— 首块到达就判，
  // 277 KB 的说明页因此不会先撞 256 KB 字节上限报错。

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
  var firstByteChecked = false;
  await for (final chunk in resp.timeout(left())) {
    total += chunk.length;
    // 首块到达就判「是不是网页」，不看 Content-Type（采集站会写错）。
    if (rejectHtml && !firstByteChecked) {
      final lead = firstSignificantByte(<int>[...bytes, ...chunk]);
      if (lead != null) {
        firstByteChecked = true;
        if (lead == 0x3C /* '<' */) {
          await _drain(resp);
          return SourceConfigUrlResult.fail(SourceConfigUrlFailure.htmlPage,
              '服务器返回的是网页（HTML），不是点播接口数据；'
              '这条地址更像接口分发站 / 说明页，请改用返回 JSON 的采集接口地址',
              originLabel: _label(first));
        }
      }
    }
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
  // 兜底：有些站点把网页的 Content-Type 写成 text/plain 甚至不给。JSON 的
  // 顶层只可能是 `{` / `[`，出现 `<` 就一定是 HTML / XML 说明页。
  if (rejectHtml && isHtmlLikePayload(bodyPrefix: text)) {
    return SourceConfigUrlResult.fail(SourceConfigUrlFailure.htmlPage,
        '服务器返回的是网页 / XML（正文以 `<` 开头），不是点播接口数据；'
        '请改用返回 JSON 的采集接口地址',
        originLabel: _label(first));
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
