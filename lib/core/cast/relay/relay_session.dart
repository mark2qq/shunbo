/// 串流中继的会话契约。
///
/// 单独抽一个接口，是为了让投屏状态机**不直接依赖 socket**：
/// 状态机的回归测试要能在几十毫秒内跑完，不能每次起一个真实 HttpServer。
/// 真实实现见 `relay/cast_relay_server.dart`。
library;

abstract class CastRelaySession {
  /// 提供给设备的基地址（`http://<本机私网IP>:<port>/t/<token>`）。
  /// 未启动时为 null。
  Uri? get baseUri;

  /// 把上游地址包成中继地址；地址不合法时返回 null。
  String? relayUrlFor(String upstreamUrl);

  Future<void> stop();
}

/// 起一个中继会话；本机没有可用局域网地址时返回 null（调用方据此报错）。
///
/// [headers] 是要补到上游请求上的鉴权头（`Referer` / `User-Agent` / `Cookie`）。
typedef CastRelayFactory = Future<CastRelaySession?> Function(
    Map<String, String> headers);
