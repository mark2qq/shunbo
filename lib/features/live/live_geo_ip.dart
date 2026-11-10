/// 依据公网 IP 推断当前城市（用于「地方频道默认显示本市」）。
///
/// 只用纯 Dart：定位是启动阶段的**增强项**，失败一律返回 null，
/// 由 UI 退回「用户上次选择 → 全部城市」，绝不能拖住开播、更不能弹错误框。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'live_region.dart';

class IpCityLocator {
  /// 端点按优先级排列，前一个拿不到可用城市才试下一个。
  ///
  /// - pconline：国内库，给 `cityCode`（GB/T 2260，纯 ASCII 数字），
  ///   实测本机返回 `320500` = 苏州市；它的中文字段是 GBK，不能直接当文本用。
  /// - ipinfo.io：UTF-8 英文市名（`Jiaxing`），作为备用。
  /// 二者可能给出不同结果（运营商出口与定位库差异），以国内库优先。
  static const List<String> defaultEndpoints = <String>[
    'https://whois.pconline.com.cn/ipJson.jsp?json=true',
    'https://ipinfo.io/json',
  ];

  /// 响应体积上限：定位接口是小 JSON，给 64 KiB 已经很宽松；
  /// 超限直接截断（外部输入，不设界就等于让对端决定内存占用）。
  static const int maxResponseBytes = 64 * 1024;

  static const Duration defaultTimeout = Duration(seconds: 3);

  IpCityLocator({
    this.endpoints = defaultEndpoints,
    this.timeout = defaultTimeout,
    this.httpClientFactory,
  });

  final List<String> endpoints;

  final Duration timeout;

  /// 回归脚本注入本机 HttpServer 的客户端；为空则用系统默认。
  final HttpClient Function()? httpClientFactory;

  /// 返回标准中文市名（如「苏州」）；任何失败都返回 null。
  Future<String?> locate() async {
    for (final url in endpoints) {
      final bytes = await _fetch(url);
      if (bytes == null) continue;
      final city = parseCityBytes(bytes);
      if (city != null && CityDirectory.isKnown(city)) return city;
    }
    return null;
  }

  static String? parseCityBytes(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maxResponseBytes) return null;

    // Latin-1 是字节的 1:1 视图：GBK 中文变成乱码字符，但 JSON 的引号、
    // 逗号与数字都是 ASCII，结构不会破。所以城市代码总能先抠出来——
    // 这比硬解 GBK 简单得多，也避开了 GBK 第二字节含 `\`(0x5C)
    // 把 JSON 字符串错误转义、导致整个响应解析失败的老问题。
    final latin = const Latin1Codec().decode(bytes);
    final code = RegExp(r'"(?:cityCode|cid)"\s*:\s*"?(\d{6})"?')
        .firstMatch(latin);
    if (code != null) {
      final city = CityDirectory.cityOfCode(code.group(1)!);
      if (city != null) return city;
    }

    // UTF-8 端点（ipinfo.io）从这里拿到 `city` / `cname`。
    return parseCityText(utf8.decode(bytes, allowMalformed: true));
  }

  /// 解析定位响应正文（纯文本入口，回归脚本直接用它测各种形态）。
  ///
  /// 只采纳 [CityDirectory.isKnown] 认可的城市：定位接口返回的任意字符串
  /// 不会流进 UI 标题或落盘文件，脏数据最多让功能退回「全部城市」。
  static String? parseCityText(String text) {
    if (text.isEmpty || text.length > maxResponseBytes) return null;
    final trimmed = text.trim();
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      // `var returnCitySN = {...};` 这类 JSONP：只抠花括号里的对象。
      final start = trimmed.indexOf('{');
      final end = trimmed.lastIndexOf('}');
      if (start < 0 || end <= start) return null;
      try {
        decoded = jsonDecode(trimmed.substring(start, end + 1));
      } catch (_) {
        return null;
      }
    }
    if (decoded is! Map) return null;
    for (final key in const <String>['cityCode', 'cid', 'city', 'cname', 'region']) {
      final value = decoded[key];
      if (value is! String || value.isEmpty || value.length > 64) continue;
      final city = (key == 'cityCode' || key == 'cid')
          ? CityDirectory.cityOfCode(value)
          : CityDirectory.cityOfName(value);
      if (city != null && CityDirectory.isKnown(city)) return city;
    }
    return null;
  }

  Future<List<int>?> _fetch(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    final client = httpClientFactory?.call() ??
        (HttpClient()..findProxy = HttpClient.findProxyFromEnvironment);
    client.connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'shunbo/1.0');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > maxResponseBytes) break;
      }
      if (bytes.length > maxResponseBytes) {
        return bytes.sublist(0, maxResponseBytes);
      }
      return bytes;
    } catch (_) {
      return null;
    } finally {
      // HttpClient 必须关：残留连接会挂住 Dart 进程。
      client.close(force: true);
    }
  }
}
