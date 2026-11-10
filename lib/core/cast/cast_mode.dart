/// 投屏双模式（R12b）：**直推优先，首帧 5 秒未出图自动改串流，并记住该源**。
///
/// 为什么需要两种模式：
/// * **直推（direct）** 是把源地址原样交给电视，电视自己去拉流。省掉手机带宽与
///   一次转发，延迟最低，是绝大多数公开源的正确路径。
/// * **串流（relay）** 是手机先拉流、再在自己的局域网地址上重新提供出去。带防盗链
///   的源（校验 `Referer` / `User-Agent` / `Cookie`）电视直推必定 403 —— 电视侧
///   没有「替你补请求头」的能力，只有手机能补。
///
/// 判定顺序（[CastModePolicy.decide]）：
/// 1. **有记忆** → 直接按记忆走。这是「记住该源，下次直接走串流」的落点；
/// 2. **无头探测显示需要鉴权**（403/401）→ 直接串流，不必先浪费 5 秒；
/// 3. 其余 → 先直推，交给「5 秒首帧未确认」这条兜底改串流。
///
/// 第 2 条不是对 R12b 的替代，而是补充：R12b 要求的是「没出图要能自动改串流」，
/// 而「明知会 403 还硬推 5 秒」只是让用户多等。两条路径最终都收敛到同一个
/// 「确认失败 → 改串流 → 记住」的结果，行为一致。
library;

/// 投屏传输模式。
enum CastMode {
  /// 把源地址原样交给设备，由设备直接拉流。
  direct,

  /// 手机做中继：本机拉流后重新提供局域网地址给设备。
  relay,
}

/// 判定依据。写进诊断与 UI，用户/我们排查时不用靠猜。
enum CastModeReason {
  /// 该源此前记录为「串流有效」，直接走串流。
  rememberedRelay,

  /// 该源此前直推成功，本次仍先直推。
  rememberedDirect,

  /// 无鉴权头访问被拒（403/401/407）：电视直推必然失败，直接串流。
  requiresAuthHeaders,

  /// 无鉴权头可访问：先直推。
  probeOk,

  /// 直推后 5 秒未确认出图，改串流。
  firstFrameTimeout,

  /// 串流后确认出图。
  relayConfirmed,
}

class CastModeDecision {
  const CastModeDecision(this.mode, this.reason);

  final CastMode mode;
  final CastModeReason reason;

  @override
  String toString() => '${mode.name}(${reason.name})';
}

/// 该源是否必须靠中继才能被电视拉到。
///
/// 判的是「不带任何额外请求头能不能取到」：
/// * `401` / `403` / `407` —— 明确的鉴权拒绝，电视直推必然失败；
/// * 其它状态一律视为可直推（`200` 当然可以；`404` 之类是地址本身失效，
///   换串流也救不回来，交给上层按起播失败降级，不该在这里误判成「需要串流」）。
bool statusRequiresAuthHeaders(int? statusCode) {
  return statusCode == 401 || statusCode == 403 || statusCode == 407;
}

/// 投屏模式的记忆键：**按源站**而不是按单个地址。
///
/// 同一个源站下的不同频道、不同集数用的是同一套防盗链规则，按地址记忆会造成
/// 「这个频道记住了、换一集又要重新试 5 秒」。取 `host` 恰好等于「同一套规则」。
///
/// [sourceId] 参与拼接的原因：两个不同的源适配器可能共用同一个 CDN 主机，
/// 但它们的鉴权方式未必相同，混在一起会把 A 源的结论套到 B 源上。
String castModeKey({required String sourceId, required String url}) {
  final host = _hostOf(url);
  final id = sourceId.trim();
  if (host.isEmpty) return id;
  return id.isEmpty ? host : '$id|$host';
}

/// 只取 `host[:port]`，不带 scheme / 路径 / 查询串。
///
/// 不用 `Uri.host` 而自己解析：投屏地址可能来自用户手填的源配置，
/// 存在 `Uri.parse` 抛异常或把整串当 path 的情况，这里只做「尽量取到主机」。
String _hostOf(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return '';
  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.host.isNotEmpty) {
    return uri.hasPort ? '${uri.host.toLowerCase()}:${uri.port}' : uri.host.toLowerCase();
  }
  return '';
}

/// 模式判定策略。
class CastModePolicy {
  const CastModePolicy();

  /// 发起投屏时决定先走哪条路。
  ///
  /// [remembered] 来自 [castModeKey] 的持久化记忆（null = 这个源没投过）。
  /// [probeStatus] 是「不带鉴权头取一次」的 HTTP 状态码（null = 探测本身失败，
  /// 例如超时 —— 此时**不**据此判串流，仍按直推处理，让 5 秒兜底去做决定，
  /// 否则一次网络抖动就会把所有源永久记成 relay）。
  CastModeDecision decideInitial({
    CastMode? remembered,
    int? probeStatus,
  }) {
    if (remembered == CastMode.relay) {
      return const CastModeDecision(CastMode.relay, CastModeReason.rememberedRelay);
    }
    if (statusRequiresAuthHeaders(probeStatus)) {
      return const CastModeDecision(
          CastMode.relay, CastModeReason.requiresAuthHeaders);
    }
    if (remembered == CastMode.direct) {
      // 记忆为直推仍然要过 5 秒兜底：源站可能刚加了防盗链，记忆不该变成死路。
      return const CastModeDecision(CastMode.direct, CastModeReason.rememberedDirect);
    }
    return const CastModeDecision(CastMode.direct, CastModeReason.probeOk);
  }

  /// 直推未确认出图后是否改串流。
  ///
  /// 恒为 true —— 这正是 R12b 的硬性要求。写成方法是为了让「将来若要做
  /// 用户级开关（例如关闭中继省电）」有一个不改调用点的落点。
  bool shouldFallbackToRelay(CastMode attempted, {required bool firstFrameConfirmed}) {
    if (firstFrameConfirmed) return false;
    return attempted == CastMode.direct;
  }

  /// 本次结果应记住的模式。
  ///
  /// **只记「验证过的事实」**：
  /// * 串流确认出图 → 记 relay（下次直接串流，不再浪费 5 秒）；
  /// * 直推确认出图 → 记 direct（下次仍直推，避免无谓转发）；
  /// * 都没确认出图 → 不记（null），这个源的问题不是模式问题，乱记会让下次
  ///   直接走串流而绕开真正的原因。
  CastMode? rememberAfter({
    required CastMode attempted,
    required bool firstFrameConfirmed,
  }) {
    if (!firstFrameConfirmed) return null;
    return attempted;
  }
}
