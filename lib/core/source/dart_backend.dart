import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'source_adapter.dart';
import 'source_fetcher.dart';
import 'source_parser.dart';

/// 桌面/TV Dart 解析后端（E2 真实适配器子集）。
///
/// 覆盖「直链 / 简单 m3u8」类源；纯 Dart 实现，可在桌面/TV/Android 运行。
/// 注意：覆盖范围小于 Android jar（jar 不可跨端），此子集只解析约定结构。
class DartSourceParser implements SourceParser {
  @override
  Future<List<MediaSearchResult>> parseSearch(String html) async {
    final results = <MediaSearchResult>[];
    final re = RegExp(
      r'<div class="item" data-id="([^"]+)">\s*<a[^>]*>([^<]+)</a>',
      dotAll: true,
    );
    for (final m in re.allMatches(html)) {
      results.add(MediaSearchResult(mediaId: m.group(1)!, title: m.group(2)!));
    }
    return results;
  }

  @override
  Future<List<EpisodeRef>> parseEpisodes(String detailHtml) async {
    final refs = <EpisodeRef>[];
    final re = RegExp(
      r'<a class="ep" data-ep="(\d+)" href="([^"]+)">',
      dotAll: true,
    );
    for (final m in re.allMatches(detailHtml)) {
      refs.add(EpisodeRef(
        episode: int.parse(m.group(1)!),
        playPagePath: m.group(2)!,
      ));
    }
    return refs;
  }

  @override
  Future<List<PlayUrl>> parsePlayUrls(String playPageHtml) async {
    final urls = <PlayUrl>[];
    final video =
        RegExp(r'<video[^>]*src="([^"]+)"', dotAll: true).firstMatch(playPageHtml);
    if (video != null) urls.add(PlayUrl(url: video.group(1)!, qualityRank: 1));
    for (final m in RegExp(
      r'<a class="q" data-rank="(\d+)" href="([^"]+)"',
      dotAll: true,
    ).allMatches(playPageHtml)) {
      urls.add(PlayUrl(
        url: m.group(2)!,
        qualityRank: int.parse(m.group(1)!),
      ));
    }
    return urls;
  }
}

/// 桌面/TV 真实 fetcher：用 dart:io HttpClient 联网获取页面。
///
/// 真实联网边界（由 `tooling/verify_live_http.dart` 回归覆盖）：
/// - **非 2xx 一律当失败**：错误页里常有看似合法的 HTML，若当正常内容解析会造成
///   「404 假成功」，并且会把网络故障误判成 `emptyPlayUrl`，污染诊断与换源策略；
/// - **连接 / 响应双超时**：慢源不会拖死整条播放链路；
/// - **响应体字节上限**：防止超大页面放大内存与外部正则的回溯开销；
/// - **手工跟随重定向**：HttpClient 自动跟随会绕过 origin 校验，因此每跳都重跑白名单；
/// - **编码容错**：按 Content-Type 声明处理，非法 UTF-8 降级而非抛 FormatException；
/// - **运行期 SSRF 防线**：站点响应里给出的绝对取址页必须落在允许的源站 origin 内。
///   注意这里限制的是「取页面请求」，解析出的播放地址交给播放器、不经过 fetcher，
///   因此不会误伤真实站点常见的 CDN 直链。
/// 跨 origin 请求允许携带的配置头白名单（**默认拒绝**）。
///
/// 配置为 baseUrl 定制的头（尤其 Cookie / Authorization / X-Api-Key / Referer）
/// 绝不能自动发给另一个主机：一旦站点被劫持、把取址页指向攻击者的 origin，
/// 这些凭据就会被直接带走。跨主机时只放行与身份无关、且 CDN 常需的少数头。
const Set<String> kCrossOriginSafeHeaders = <String>{
  'user-agent',
  'accept',
  'accept-language',
};

class DartHttpFetcher implements SourceFetcher {
  final String baseUrl;
  final HttpClient _client;
  final Duration connectTimeout;
  final Duration requestTimeout;
  final int maxResponseBytes;
  final int maxRedirects;

  /// 允许取页面的源站 origin（`scheme://host:port`）。默认只放行 baseUrl 自身，
  /// 需要跨 CDN 取页面时由调用方显式扩展（默认拒绝，避免静默扩大攻击面）。
  final Set<String> allowedOrigins;
  final Uri _base;

  DartHttpFetcher(
    this.baseUrl, {
    HttpClient? client,
    this.connectTimeout = const Duration(seconds: 5),
    this.requestTimeout = const Duration(seconds: 8),
    this.maxResponseBytes = 2 * 1024 * 1024,
    this.maxRedirects = 3,
    Set<String>? allowedOrigins,
    this.useSystemProxy = true,
    this.headers = const <String, String>{},
    this.searchPath = 'search?q={keyword}',
    this.detailPath = 'detail/{mediaId}',
  })  : _client = client ?? HttpClient(),
        _base = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/'),
        allowedOrigins = allowedOrigins ?? _defaultOrigins(baseUrl) {
    // Dart HttpClient 默认按环境变量走系统代理。某些 Windows 环境会把
    // localhost 请求也交给代理，返回 502 之类与源站无关的响应。
    // 本地源 / 回归场景可显式直连，判定才确定。
    if (!useSystemProxy) {
      _client.findProxy = (_) => 'DIRECT';
    }
  }

  /// 是否遵循系统代理（生产默认 true；局域网/本地源可设 false）。
  final bool useSystemProxy;

  /// 附加请求头（真实站点常需 UA / Referer / Cookie 才返回内容）。
  /// 头名与值由 `SourceConfigLoader` 做注入校验后才允许传入。
  final Map<String, String> headers;

  /// 搜索 / 详情路径模板。真实站点的端点不统一（`/search?q=`、`/vod/search/`、`/api/v1/...`），
  /// 因此把 E9 白名单里早已定义、但此前未被消费的 `searchPath` / `playPath` 字段真正接上。
  /// 占位符：`{keyword}` / `{mediaId}`，会被 URL 编码后替换。
  final String searchPath;
  final String detailPath;

  static Set<String> _defaultOrigins(String baseUrl) {
    final u = Uri.tryParse(baseUrl);
    return <String>{
      if (u != null && u.hasScheme && u.host.isNotEmpty) u.origin
    };
  }

  /// 释放底层连接池。源退役 / 页面关闭时必须调用，否则失败连接会残留
  /// 并阻止 Dart 进程退出（真实联网回归里踩到过）。
  void close({bool force = true}) => _client.close(force: force);

  /// 统一 URL 决议：绝对地址/相对地址都在这里过 scheme 与 origin 白名单。
  Uri _u(String path) {
    final parsed = Uri.tryParse(path);
    if (parsed == null) {
      throw SourceFetchException(
          reason: SourceFetchFailure.invalidUrl,
          uri: _base,
          message: 'URL 无法解析：$path');
    }
    final uri = parsed.hasScheme ? parsed : _base.resolve(path);
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw SourceFetchException(
          reason: SourceFetchFailure.invalidUrl,
          uri: uri,
          message: '仅允许 http/https：$uri');
    }
    if (uri.host.isEmpty || !allowedOrigins.contains(uri.origin)) {
      throw SourceFetchException(
          reason: SourceFetchFailure.invalidUrl,
          uri: uri,
          message: '取地址越过允许的源站 origin：${uri.origin}');
    }
    return uri;
  }

  @override
  Future<String> fetchSearch(String keyword) async => _get(_u(searchPath
      .replaceAll('{keyword}', Uri.encodeComponent(keyword))));

  @override
  Future<String> fetchDetail(String mediaId) async => _get(_u(detailPath
      .replaceAll('{mediaId}', Uri.encodeComponent(mediaId))));

  @override
  Future<String> fetchPlayPage(String mediaId, String playPagePath) async =>
      _get(_u(playPagePath));

  Future<String> _get(Uri uri, [int hops = 0]) async {
    try {
      final req = await _client.getUrl(uri).timeout(
            connectTimeout,
            onTimeout: () => throw SourceFetchException(
                reason: SourceFetchFailure.timeout,
                uri: uri,
                message: '连接超时'),
          );
      // 手工跟随：自动跟随会让 302 直接跳到未授权 origin。
      req.followRedirects = false;
      // 每一跳独立判定：302 落到别的 origin 时立即剥离凭据类头。
      final crossOrigin = uri.origin != _base.origin;
      headers.forEach((k, v) {
        if (!crossOrigin || kCrossOriginSafeHeaders.contains(k.toLowerCase())) {
          req.headers.set(k, v);
        }
      });
      final resp = await req.close().timeout(
            requestTimeout,
            onTimeout: () => throw SourceFetchException(
                reason: SourceFetchFailure.timeout,
                uri: uri,
                message: '等待响应头超时'),
          );

      if (resp.isRedirect) {
        await _drain(resp);
        final location = resp.headers.value(HttpHeaders.locationHeader);
        if (location == null || location.isEmpty || hops >= maxRedirects) {
          throw SourceFetchException(
              reason: SourceFetchFailure.redirect,
              uri: uri,
              statusCode: resp.statusCode,
              message: '重定向缺少 Location 或次数超限');
        }
        return await _get(_u(location), hops + 1);
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        await _drain(resp);
        throw SourceFetchException(
            reason: SourceFetchFailure.httpStatus,
            uri: uri,
            statusCode: resp.statusCode,
            message: '源站返回非成功状态，拒绝把错误页当内容解析');
      }

      final bytes = await _collect(resp, uri).timeout(
            requestTimeout,
            onTimeout: () => throw SourceFetchException(
                reason: SourceFetchFailure.timeout,
                uri: uri,
                message: '响应体读取超时'),
          );
      return _decode(bytes, resp.headers.contentType);
    } on SourceFetchException {
      rethrow;
    } on TimeoutException catch (e) {
      throw SourceFetchException(
          reason: SourceFetchFailure.timeout, uri: uri, message: '$e');
    } on SocketException catch (e) {
      throw SourceFetchException(
          reason: SourceFetchFailure.connection, uri: uri, message: '$e');
    } on HttpException catch (e) {
      throw SourceFetchException(
          reason: SourceFetchFailure.connection, uri: uri, message: '$e');
    } on HandshakeException catch (e) {
      throw SourceFetchException(
          reason: SourceFetchFailure.connection, uri: uri, message: '$e');
    } catch (e) {
      throw SourceFetchException(
          reason: SourceFetchFailure.connection,
          uri: uri,
          message: '未预期的取数失败：$e');
    }
  }

  Future<List<int>> _collect(HttpClientResponse resp, Uri uri) async {
    final out = <int>[];
    var total = 0;
    await for (final chunk in resp) {
      total += chunk.length;
      if (total > maxResponseBytes) {
        throw SourceFetchException(
            reason: SourceFetchFailure.tooLarge,
            uri: uri,
            message: '响应体超过 $maxResponseBytes 字节上限');
      }
      out.addAll(chunk);
    }
    return out;
  }

  String _decode(List<int> bytes, ContentType? contentType) {
    final charset = contentType?.charset?.toLowerCase();
    // Dart 标准库没有 GBK 解码器：声明为单字节/GB 系编码时用 latin1 保证「不崩」
    // （中文会乱码，属已知落差，后续可引入 charset 转换包或由站点规则声明 utf-8）。
    if (charset != null &&
        charset != 'utf-8' &&
        charset != 'utf8' &&
        (charset.contains('8859') ||
            charset == 'latin1' ||
            charset == 'gbk' ||
            charset == 'gb2312')) {
      return latin1.decode(bytes, allowInvalid: true);
    }
    // allowMalformed：真实站点常有夹带非法字节的脏页面，不能让整条链路崩掉。
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<void> _drain(HttpClientResponse resp) async {
    try {
      await resp.drain<void>();
    } catch (_) {
      // 客户端已断开时 drain 会抛；此处只需要释放连接，不需要向外传播。
    }
  }
}
