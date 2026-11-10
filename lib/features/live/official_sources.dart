/// 官方源解析：把「聚合表里的中转地址」还原成广电平台自己的 CDN 地址。
///
/// 为什么必须做这一步（2026-11-07 实测）：
///  1. 4K/卫视聚合表里绝大多数地址是 `live.php?id=xxx` 这类**解析器**，
///     它用 302 指到咪咕 / 芒果 / 浙江广电 / 百视通等官方 CDN；
///  2. 这些官方地址普遍带**时效令牌**（`txSecret` / `txTime` / 一次性 uuid 路径），
///     把 302 结果硬编码进包里，几小时后必然变成 403 —— 稳定性无从谈起；
///  3. 反过来，直接把解析器地址交给播放内核也不稳：它要求特定 `User-Agent`，
///     且部分内核对「带查询串的 302 → m3u8」处理不一致（实测 23 条中转地址
///     在 libmpv 里只有 4 条能建起解码链，而解析后的官方直连 30/35 能播）。
///
/// 所以正确做法是**在起播前用 Dart 解析一次**：拿到当次有效的官方直连地址，
/// 校验主机在白名单内，再交给播放内核；解析失败则退回线路表里那条静态地址，
/// 由既有的换线链路兜底，绝不因为一个新能力让原本能播的台变黑屏。
library;

import 'dart:async';
import 'dart:io';

/// 广电 / 持牌平台自有 CDN 的域后缀白名单。
///
/// 只认后缀而不认完整域名，是因为同一家平台会按业务分出很多子域
/// （`ali-xwl.cztv.com` / `ali-m-l.cztv.com`、`hlsal-ldvt.qing.mgtv.com` …）。
/// **IP 字面量一律不接受**：解析器是不可信输入，不能让它把播放请求指到
/// 内网或任意第三方主机（SSRF）。
const Set<String> kOfficialCdnSuffixes = <String>{
  // 央视 / 总台
  'cctv.com',
  'cntv.cn',
  'cctv.cn',
  'cgtn.com',
  // 省级广电 / 新媒体平台
  'miguvideo.com', // 咪咕（央视与多数卫视的公网分发）
  'mgtv.com', // 芒果 TV（湖南）
  'cztv.com', // 浙江广电
  'bestv.cn', // 百视通（东方 / 五星体育）
  'sztv.com.cn', // 深圳广电
  'jstv.com', // 江苏广电（荔枝）
  'hebtv.com', // 河北广电
  'kan0512.com', // 苏州广电
  '5gtv.com.cn', // 歌华有线
  'hljtv.com', // 黑龙江广电
  'jlntv.cn', // 吉林广电
  'ahtv.cn', // 安徽广电
  'gstv.com.cn', // 甘肃广电
  'gzstv.com', // 贵州广电
  'sdetv.com.cn', // 山东教育台
  'gxrb.com.cn', // 广西广电
  'lnshw.com.cn',
  'hndyjyfw.gov.cn',
  'ybtvyun.com',
  'ssws.tv',
  'itouchtv.cn',
};

/// 跨 origin 时允许带过去的头。
///
/// 与配置层的凭据隔离同一条规则：**Cookie / Authorization 绝不跟随 302
/// 去往另一个域**，否则聚合表作者能用一条 Location 把用户凭据收走。
/// Referer 不是凭据，但多家官方 CDN（江苏、四川）明确校验它，所以放行。
const Set<String> kResolveCrossOriginSafeHeaders = <String>{
  'user-agent',
  'accept',
  'accept-language',
  'referer',
};

/// 已知的「能解码但不是频道」的占位 / 反盗链主机。
///
/// 2026-11-07 实测踩到：`live.264788.xyz/channel/sichuanweishi4k` 会 302 到
/// `static.tv.darwinchow.com/status/error_account_pirated.mp4`。这段 MP4
/// 有完整 1920x1080 视频轨、解码器零报错，libmpv 判定「可播」，但用户看到的
/// 是一段反盗链提示片，不是四川卫视。**解码门禁只能证伪「花屏」，证不了
/// 「内容对不对」**，所以这类主机必须在地址层直接拉黑。
const Set<String> kPlaceholderMediaHosts = <String>{
  'live.264788.xyz',
  'static.tv.darwinchow.com',
};

/// 3xx Location 里的占位 / 反盗链特征。
const Set<String> kPlaceholderLocationMarkers = <String>{
  'error_account_pirated',
  'account_pirated',
  '/status/',
};

/// Location 是不是「上游没有这条线路」的占位响应。
///
/// 聚合解析器常见的偷懒写法是 `Location: 1`（本轮山东/广东/四川 4K 共 6 条），
/// 或者干脆回一段反盗链提示片。两者都不能交给播放内核。
bool isPlaceholderLocation(String location) {
  final s = location.trim().toLowerCase();
  if (s.isEmpty || s == '1' || s == '0' || s == 'null' || s == 'none') {
    return true;
  }
  return kPlaceholderLocationMarkers.any(s.contains);
}

/// 地址是否落在已知占位 / 反盗链主机上。
bool isPlaceholderMediaUrl(String url) {
  final u = Uri.tryParse(url);
  if (u == null) return false;
  final h = u.host.toLowerCase();
  return kPlaceholderMediaHosts.contains(h) ||
      kPlaceholderMediaHosts.any((p) => h.endsWith('.$p'));
}

/// 单条线路解析结果。
class OfficialResolveResult {
  const OfficialResolveResult({
    required this.ok,
    required this.url,
    required this.host,
    required this.reason,
    this.hops = 0,
  });

  final bool ok;

  /// 可以交给播放内核的地址。失败时等于传入的原始地址（供退回用）。
  final String url;

  final String host;
  final String reason;
  final int hops;

  factory OfficialResolveResult.failure(String fallback, String reason) =>
      OfficialResolveResult(
        ok: false,
        url: fallback,
        host: '',
        reason: reason,
      );
}

/// 官方源解析器。
class OfficialSourceResolver {
  OfficialSourceResolver({
    this.timeout = const Duration(seconds: 6),
    this.maxHops = 2,
    Set<String> allowedHostSuffixes = kOfficialCdnSuffixes,
    this.useSystemProxy = false,
  }) : _allowed = allowedHostSuffixes;

  final Duration timeout;
  final int maxHops;
  final Set<String> _allowed;
  final bool useSystemProxy;

  /// 主机是否属于官方 CDN 白名单。
  bool isOfficialHost(String host) {
    final h = host.toLowerCase();
    if (h.isEmpty || InternetAddress.tryParse(h) != null) return false;
    for (final s in _allowed) {
      if (h == s || h.endsWith('.$s')) return true;
    }
    return false;
  }

  /// 解析 [url]：跟随最多 [maxHops] 次 302，返回最后一条官方直连地址。
  ///
  /// 返回值 `ok=false` 时调用方**必须**退回原线路地址，而不是把失败当致命错误。
  Future<OfficialResolveResult> resolve(
    String url, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    final first = Uri.tryParse(url);
    if (first == null || !_acceptableUri(first)) {
      return OfficialResolveResult.failure(url, '地址不合法');
    }
    if (isPlaceholderMediaUrl(url)) {
      return OfficialResolveResult.failure(url, '已知占位/反盗链源');
    }

    final client = HttpClient();
    // 与播放内核保持一致：桌面端 libmpv 显式关掉了系统代理
    // （`http-proxy=no`），解析层若走系统代理会出现「解析成功但播放 502」。
    if (!useSystemProxy) client.findProxy = (Uri _) => 'DIRECT';
    client.connectionTimeout = timeout;

    var current = first;
    // 同源判定按 scheme + host + **port**：端口不同同样是跨 origin，
    // 不能只看主机名（浏览器同源策略也是这个口径）。
    final origin = first.origin;
    try {
      for (var hop = 0; hop <= maxHops; hop++) {
        if (!_acceptableUri(current)) {
          return OfficialResolveResult.failure(url, '第 $hop 跳地址不合法');
        }
        final req = await client.openUrl('GET', current).timeout(timeout);
        req.followRedirects = false;
        for (final e in headers.entries) {
          final key = e.key.toLowerCase();
          if (key == 'host' || key == 'range' || key == 'content-length') continue;
          if (e.value.contains('\n') || e.value.contains('\r')) continue;
          // 跨 origin 只放行安全头。
          if (current.origin != origin &&
              !kResolveCrossOriginSafeHeaders.contains(key)) {
            continue;
          }
          req.headers.set(e.key, e.value);
        }
        final resp = await req.close().timeout(timeout);
        // 只关心状态行；把 body 排空以便连接复用，同时限制读取量。
        await resp.drain<void>();
        final code = resp.statusCode;
        if (code >= 300 && code < 400) {
          final loc = resp.headers.value('location');
          if (loc == null || loc.isEmpty) {
            return OfficialResolveResult.failure(url, '302 缺 Location');
          }
          if (isPlaceholderLocation(loc)) {
            return OfficialResolveResult.failure(url, '302 占位 Location');
          }
          final next = current.resolve(loc);
          if (!_acceptableUri(next) || isPlaceholderMediaUrl(next.toString())) {
            return OfficialResolveResult.failure(url, 'Location 越界');
          }
          current = next;
          continue;
        }
        if (code < 200 || code >= 300) {
          return OfficialResolveResult.failure(url, 'HTTP $code');
        }
        // 200：只有落在官方白名单里才算「解析到官方源」。
        // 中转站偶尔直接回一段文本（实测回 `1` 表示「该台无线路」），
        // 那种不能交给播放内核。
        if (!isOfficialHost(current.host)) {
          return OfficialResolveResult.failure(
            url,
            '终点非官方 CDN：${current.host}',
          );
        }
        return OfficialResolveResult(
          ok: true,
          url: current.toString(),
          host: current.host,
          reason: '官方直连',
          hops: hop,
        );
      }
      return OfficialResolveResult.failure(url, '重定向超过 $maxHops 跳');
    } on TimeoutException {
      return OfficialResolveResult.failure(url, '解析超时');
    } catch (e) {
      return OfficialResolveResult.failure(url, '解析异常：${e.runtimeType}');
    } finally {
      client.close(force: true);
    }
  }

  static bool _acceptableUri(Uri u) {
    if (u.scheme != 'http' && u.scheme != 'https') return false;
    if (u.userInfo.isNotEmpty) return false;
    return u.host.isNotEmpty;
  }
}
