// 本地样本站点（多个验证脚本 / UI 演示服务共用）。
//
// 一个实例 = 一个「源站」，独立端口、独立 origin，可模拟不同站点结构与故障路径。
// 只依赖 dart:io，不引入 package:flutter，裸 dart run 可直接执行。
import 'dart:convert';
import 'dart:io';

/// 本地样本站点。三类结构各自一个独立端口，模拟「不同源站」。
class FixtureSite {
  final String kind;
  HttpServer? _server;
  final Map<String, int> hits = <String, int>{};

  /// 供「越权主机」用例注入的外部站点地址。
  String? outsideOrigin;

  /// 跨主机取址页前缀：详情页把剧集 href 指向另一台样本站点（模拟 CDN 子域）。
  String? cdnOrigin;

  /// 跨主机重定向目标（302 Location）。
  String? redirectOrigin;

  /// 每个路径最近一次请求观察到的头，用于验证「跨 origin 不泄漏凭据头」。
  final Map<String, Map<String, String>> headersByPath =
      <String, Map<String, String>>{};

  Map<String, String> headersFor(String path) =>
      headersByPath[path] ?? const <String, String>{};

  /// 需要校验的请求头（小写键 → 期望值）。[headerGuard] 为 true 时
  /// 不匹配直接 403，用于验证配置里的 UA / Referer 是否真的发出。
  final Map<String, String> requiredHeaders;
  final bool headerGuard;

  /// 最近一次请求观察到的请求头（小写键）。
  Map<String, String> lastHeaders = <String, String>{};

  FixtureSite(
    this.kind, {
    this.requiredHeaders = const <String, String>{},
    this.headerGuard = false,
  });

  int get port => _server!.port;
  String get origin => 'http://127.0.0.1:$port';

  /// [port] 传 0 由系统分配；演示服务可指定固定端口，便于 App 内示例配置直连。
  Future<void> start({int port = 0}) async {
    _server = await HttpServer.bind('127.0.0.1', port);
    _server!.listen(_handle);
  }

  Future<void> close() async => _server!.close(force: true);

  int hitCount(String path) => hits[path] ?? 0;

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    hits[path] = hitCount(path) + 1;
    final observed = <String, String>{};
    req.headers.forEach((name, values) {
      observed[name.toLowerCase()] = values.join(',');
    });
    lastHeaders = observed;
    headersByPath[path] = observed;
    // 媒体/CDN 地址由播放器直接取，不带业务请求头，故不参与校验。
    if (headerGuard && !path.startsWith('/media/')) {
      for (final e in requiredHeaders.entries) {
        if (observed[e.key] != e.value) {
          await _text(req, 403, 'missing/invalid header ${e.key}');
          return;
        }
      }
    }
    try {
      if (path.startsWith('/fault/')) {
        await _fault(req, path);
        return;
      }
      if (path.startsWith('/media/')) {
        await _text(req, 200,
            '#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:10.0,\nseg.ts\n',
            contentType: 'application/vnd.apple.mpegurl');
        return;
      }
      final seg = req.uri.pathSegments;
      final endpoint = seg.isEmpty ? '' : seg[0];
      // 自定义路径模板端点：验证配置里的 searchPath / playPath 是否真正生效。
      if (endpoint == 'v1') {
        final sub = seg.length > 1 ? seg[1] : '';
        if (sub == 'find') {
          await _text(req, 200, _searchBody);
          return;
        }
        if (sub == 'info') {
          await _text(req, 200, _detailBody);
          return;
        }
      }
      switch (endpoint) {
        case 'search':
          await _text(req, 200, _searchBody);
        case 'detail':
          await _text(req, 200, _detailBody);
        case 'detail-cdn':
          // 运行期详情页把取址页指向别的 origin，用于验证 allowedOrigins 放行/拒绝。
          await _text(req, 200, _crossDetailBody);
        case 'play':
          await _text(req, 200, _playBody);
        case 'play-abs':
          // 播放地址用绝对 URL 指向本站点，便于验证播放器拿到的地址真实可取。
          await _text(req, 200, _playAbsBody);
        default:
          await _text(req, 404, 'not found');
      }
    } catch (e) {
      // 客户端超时后连接已断，写响应会抛；样本服务不应因此崩掉。
      if (e is! HttpException && e is! SocketException) {
        stderr.writeln('[fixture:$kind] $path -> $e');
      }
    }
  }

  Future<void> _text(HttpRequest req, int status, String body,
      {String contentType = 'text/html; charset=utf-8'}) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.parse(contentType);
    req.response.write(body);
    await req.response.close();
  }

  String get _searchBody => switch (kind) {
        'legacy' => '''
<div class="item" data-id="m1"><a href="/detail/m1">测试剧 &amp; A</a></div>
<div class="item" data-id="m2"><a href="/detail/m2">测试剧 B</a></div>
''',
        'vod' => '''
<ul><li data-id="101"><h3>测试剧 C</h3></li></ul>
''',
        'json' => jsonEncode(<String, dynamic>{
          'data': {
            'list': <Map<String, String>>[
              {'vod_id': 'j1', 'vod_name': '测试剧 D'},
            ]
          }
        }),
        _ => '<div class="item" data-id="x"><a>x</a></div>',
      };

  String get _detailBody => switch (kind) {
        'legacy' => '''
<a class="ep" data-ep="2" href="/play/2">第2集</a>
<a class="ep" data-ep="1" href="/play/1">第1集</a>
<a class="ep" data-ep="1" href="/play/1">重复集</a>
''',
        'vod' => '''
<select><option value="/play/1">第1集</option><option value="/play/2">第2集</option></select>
''',
        'json' => jsonEncode(<String, dynamic>{
          'data': {
            'episodes': <Map<String, Object>>[
              {'ep': 2, 'url': '/play/2'},
              {'ep': 1, 'url': '/play/1'},
            ]
          }
        }),
        _ => '<a class="ep" data-ep="1" href="/play/1">1</a>',
      };

  String get _playBody => switch (kind) {
        'legacy' => '''
<video src="/media/720.m3u8"></video>
<a class="q" data-rank="9" href="/media/1080.m3u8">1080P</a>
<a class="q" data-rank="9" href="/media/1080.m3u8">重复</a>
<a class="q" data-rank="99" href="javascript:alert(1)">危险</a>
''',
        'vod' => '''
<script>var p = {"url":"http:\/\/127.0.0.1:$port\/media\/vod-720.m3u8"};</script>
<div>http://127.0.0.1:$port/media/vod-480.m3u8</div>
<a href="file:///etc/passwd">危险</a>
''',
        'json' => jsonEncode(<String, dynamic>{
          'data': {
            'urls': <Map<String, Object>>[
              {'play_url': '/media/j720.m3u8', 'rank': 3},
              {'play_url': '/media/j1080.m3u8', 'rank': 9},
              {'play_url': 'file:///etc/passwd', 'rank': 99},
            ]
          }
        }),
        _ => '<video src="/media/720.m3u8"></video>',
      };

  /// 详情页里的剧集链接指向另一台样本站点（跨主机取址页）。
  String get _crossDetailBody => '''
<a class="ep" data-ep="1" href="${cdnOrigin ?? ''}/play-abs">第1集</a>
''';

  /// 播放页返回指向本站点的绝对媒体地址（播放器不经 fetcher，直接 GET 验证）。
  String get _playAbsBody => '''
<video src="http://127.0.0.1:$port/media/720.m3u8"></video>
<a class="q" data-rank="9" href="http://127.0.0.1:$port/media/1080.m3u8">1080P</a>
''';

  Future<void> _fault(HttpRequest req, String path) async {
    // 路径模板会带 mediaId 尾段，故前缀匹配而不是全等匹配。
    if (path.startsWith('/fault/redirect-cross')) {
      req.response.statusCode = 302;
      req.response.headers
          .add(HttpHeaders.locationHeader, '$redirectOrigin/play-abs');
      await req.response.close();
      return;
    }
    if (path.startsWith('/fault/detail-cdn-redirect')) {
      req.response.statusCode = 302;
      req.response.headers.add(HttpHeaders.locationHeader, '/detail-cdn');
      await req.response.close();
      return;
    }
    switch (path) {
      case '/fault/404':
        // 错误页里故意放一条合法搜索结果：若把 404 当 200 解析就会「假成功」。
        await _text(req, 404,
            '<div class="item" data-id="ghost"><a>错误页伪装结果</a></div>');
      case '/fault/slow':
        await Future<void>.delayed(const Duration(seconds: 4));
        await _text(
            req, 200, '<div class="item" data-id="slow"><a>慢响应</a></div>');
      case '/fault/big':
        await _text(req, 200, List.filled(3 * 1024 * 1024, 'x').join());
      case '/fault/badjson':
        await _text(req, 200, '{oops', contentType: 'application/json');
      case '/fault/latin1':
        // 0xE4 不是合法 UTF-8 起始序列，utf8.decoder 会抛 FormatException。
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.text;
        req.response.add(<int>[0x3C, 0xE4, 0x3E]);
        await req.response.close();
      case '/fault/redirect':
        req.response.statusCode = 302;
        req.response.headers
            .add(HttpHeaders.locationHeader, '/search?q=redirected');
        await req.response.close();
      case '/fault/evil-detail':
        // 运行期响应把取址页指向「另一个源站」，模拟 SSRF / 越权跳转。
        await _text(req, 200,
            '<a class="ep" data-ep="1" href="$outsideOrigin/play/1">越权</a>');
      case '/fault/danger':
        await _text(req, 200, '''
<video src="javascript:alert(1)"></video>
<a class="q" data-rank="9" href="file:///etc/passwd">x</a>
<a class="q" data-rank="5" href="/media/720.m3u8">ok</a>
''');
      default:
        await _text(req, 404, 'unknown fault');
    }
  }
}

/// 一次调用的观测结果：是否抛异常、异常类型、耗时、返回值。
class Probe {
  final Object? error;
  final String? value;
  final int elapsedMs;

  const Probe(this.error, this.value, this.elapsedMs);

  bool get threw => error != null;
  String get errorType => error?.runtimeType.toString() ?? '';
}

Future<Probe> probe(Future<String> Function() fn) async {
  final sw = Stopwatch()..start();
  try {
    final v = await fn();
    return Probe(null, v, sw.elapsedMilliseconds);
  } catch (e) {
    return Probe(e, null, sw.elapsedMilliseconds);
  }
}
