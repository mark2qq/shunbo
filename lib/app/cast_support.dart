/// 投屏能力的共用装配（R12b/R12c）。
///
/// 点播投屏与直播投屏都要三样同样的东西：**起中继**、**无鉴权头探测**、
/// **模式记忆**。这两条路径各自写一份的结果必然是漂移 —— 比如探测超时一处
/// 改成 2 秒、另一处还是 4 秒，同一次换台在点播里「秒开」在直播里「卡住」，
/// 而排查的人根本想不到原因在超时常量上。所以集中在这里，只此一份。
library;

import 'dart:io';

import '../core/cast/cast_mode.dart';
import '../core/cast/relay/cast_relay_server.dart';
import '../core/cast/relay/relay_session.dart';
import '../data/app_paths.dart';
import '../data/cast_mode_store.dart';

/// 起一个串流中继；本机没有可用的局域网地址时返回 null。
///
/// 不复用旧实例：中继在启动时把鉴权头固定注入，复用会让上一路的
/// `Referer` 发给新源站（轻则 403，重则串到别人的授权内容）。
Future<CastRelaySession?> startCastRelay(Map<String, String> headers) async {
  final server = CastRelayServer();
  try {
    await server.start(headers: headers);
    return server;
  } catch (_) {
    await server.stop();
    return null;
  }
}

/// 「不带任何鉴权头取一次」只看状态码。
///
/// 2 秒上限：这只是决定走哪条路的前置判断，不能让它自己变成新的等待。
/// 拿不到结果（超时 / 网络错误）返回 null —— 由首帧兜底去判断，
/// 而不是据此把一个源永久记成「必须串流」。
Future<int?> probeCastUrlStatus(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2)
    // 系统代理会把局域网/内网源请求接管成 502，投屏探测必须直连。
    ..findProxy = ((_) => 'DIRECT');
  try {
    final req = await client.getUrl(uri).timeout(const Duration(seconds: 2));
    req.headers.set(HttpHeaders.userAgentHeader, 'shunbo/1.0');
    req.headers.set(HttpHeaders.connectionHeader, 'close');
    final resp = await req.close().timeout(const Duration(seconds: 2));
    final code = resp.statusCode;
    // 不读正文：视频源的正文可能是几百 MB。
    await resp.drain<void>();
    return code;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// 投屏模式记忆（`cast-mode.json`）：记住「这个源该直推还是该串流」。
class CastModeMemory {
  CastModeMemory({CastModeStore? store})
      : _store = store ??
            CastModeStore.at(AppPaths.file(AppPaths.castModeFile));

  final CastModeStore _store;

  Future<CastMode?> read(String key) async {
    final all = await _store.load();
    return all[key];
  }

  Future<void> write(String key, CastMode mode) => _store.put(key, mode);
}
