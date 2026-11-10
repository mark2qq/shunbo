/// 网络获取契约（E2）。与 [SourceParser] 解耦：网络交给 fetcher，解析交给 parser。
///
/// 真实实现：桌面/TV 用 [DartHttpFetcher]（dart:io）；Android 用 [JarFetcher]（jar）。
/// 测试/MVP 用 [MockFetcher]（注入响应，不联网）。
/// 取数失败类别（跨端统一枚举：Dart 后端与 Android jar 后端都映射到它）。
///
/// 真实联网前，网络异常会以 SocketException / FormatException / HttpException
/// 等裸异常穿透到 UI；E7 的自动换源只认 `PlaybackFailureException`，
/// 因此必须在「取数 → 适配器 → 编排层」边界完成归一化（见下方异常类型）。
enum SourceFetchFailure {
  /// DNS / 连接被拒 / TLS 握手失败。
  connection,

  /// 连接或读取超时。
  timeout,

  /// 非 2xx 响应。错误页里常有看似合法的 HTML，绝不能当正常内容解析。
  httpStatus,

  /// 响应体超过上限（防内存放大）。
  tooLarge,

  /// URL 非法、scheme 不允许，或越过允许的源站 origin（SSRF 防线）。
  invalidUrl,

  /// 重定向被拒（跨站 / 次数过多 / 缺 Location）。
  redirect,

  /// 响应编码不可解析。
  decode,
}

/// 取数层统一异常。所有后端实现抛出的网络错误都必须是这个类型，
/// 上层才能按 [SourceFetchFailure] 做策略分流，而不是靠异常类名猜。
class SourceFetchException implements Exception {
  final SourceFetchFailure reason;
  final Uri uri;
  final String message;
  final int? statusCode;

  const SourceFetchException({
    required this.reason,
    required this.uri,
    required this.message,
    this.statusCode,
  });

  @override
  String toString() => 'SourceFetchException(${reason.name}/$uri): $message'
      '${statusCode == null ? '' : ' [HTTP $statusCode]'}';
}

abstract class SourceFetcher {
  Future<String> fetchSearch(String keyword);
  Future<String> fetchDetail(String mediaId);
  Future<String> fetchPlayPage(String mediaId, String playPagePath);
}

/// 注入式 fetcher：测试 / MVP 用，预置响应文本，不联网。
///
/// 约定键：
/// - `search:<keyword>`        搜索页响应
/// - `detail:<mediaId>`        详情页响应（含剧集）
/// - `play:<mediaId>:<path>`   某集播放页响应（含地址）
class MockFetcher implements SourceFetcher {
  final Map<String, String> _responses;

  MockFetcher([Map<String, String>? responses])
      : _responses = responses ?? const {};

  void set(String key, String html) => _responses[key] = html;

  @override
  Future<String> fetchSearch(String keyword) =>
      Future.value(_responses['search:$keyword'] ?? '');

  @override
  Future<String> fetchDetail(String mediaId) =>
      Future.value(_responses['detail:$mediaId'] ?? '');

  @override
  Future<String> fetchPlayPage(String mediaId, String playPagePath) =>
      Future.value(_responses['play:$mediaId:$playPagePath'] ?? '');
}
