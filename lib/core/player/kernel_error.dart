/// 播放内核错误文本的分类。
///
/// 为什么要单独一个文件、且**不引入任何 Flutter/FFI 依赖**：
/// 这段判断决定「换线路还是再等等」，是直播容错策略里最容易写错、
/// 也最难在真机上复现的一环（错误文本只有跑起来才看得到）。
/// 放进纯 Dart 文件后，`tooling/verify_*.dart` 可以用 `dart run` 直接钉住它，
/// 不必等 Flutter 引擎。
///
/// 分类只有两档，因为**只有两档是可判定的**：
/// * 终态错误——内核已经放弃这条流，等下去毫无意义，必须立刻换线；
/// * 其余一律当「还在重试」——宁可多等，也不要踢掉一条其实能播的线路。
library;

/// 内核错误文本的终态判定。
abstract final class KernelErrorClassifier {
  /// 是否属于「这条流已经确定播不出来」的终态错误。
  ///
  /// 只认**终态**。像 `tcp: Connection to ... failed` 这种是重试过程中的中间态，
  /// 内核还会换地址再试，不能据此判死——本项目实测：一条能播的公共 1080p HLS 线路，
  /// 前二十秒日志全是 `tcp: Connection ... failed`，之后画面正常出来。
  /// 早期版本把 tcp 失败也当终态，结果把这条线路踢掉，界面显示「暂无信号」，
  /// 而内核其实已经把它放起来了。
  static bool isFatal(String message) {
    final m = message.toLowerCase();
    return m.contains('failed to open') ||
        m.contains('failed to recognize file format') ||
        m.contains('invalid data found') ||
        m.contains('failed to resolve hostname') ||
        // http 4xx/5xx：源站拒绝或网关错误，重试也不会变好。
        // 注意这里必须带 `\d\d`：只有 `http error` 前缀不算数，
        // 有些非致命提示也会带这个前缀。
        RegExp(r'http error (4|5)\d\d').hasMatch(m);
  }

  /// 是否属于「还在重试」的中间态（仅用于日志分级与调试，不参与决策）。
  static bool isTransient(String message) {
    final m = message.toLowerCase();
    return m.contains('tcp: connection') ||
        m.contains('timed out') ||
        m.contains('broken pipe');
  }

  /// 是否属于 **TLS 证书 / 握手失败**。
  ///
  /// 单独拎出来的原因来自现场：乐视（EUI）、部分老盒子、以及若干国产电视的
  /// 系统根证书多年未更新，访问 HTTPS 采集站会直接握手失败。这类失败的
  /// 表现和「网络不通」一模一样（黑屏、转圈、最终超时），但**处理方式完全不同**：
  /// 换个网络、重启路由都没用，只能换源或升级系统证书。
  ///
  /// 如果把它归到「网络错误」里，用户只会看到「暂时无信号」，然后一遍遍重试，
  /// 永远不知道该干什么。所以这里必须认出来，并给出可执行的提示。
  static bool isTlsFailure(String message) {
    final m = message.toLowerCase();
    if (m.isEmpty) return false;
    return m.contains('certificate') ||
        m.contains('certificate_verify_failed') ||
        m.contains('handshake') ||
        m.contains('tlsv1') ||
        m.contains('ssl_error') ||
        m.contains('sslv3') ||
        m.contains('unknown ca') ||
        m.contains('self signed') ||
        m.contains('unable to get local issuer') ||
        m.contains('no alternative certificate');
  }

  /// TLS 失败时给用户看的话：说清「为什么」和「怎么办」，不要只说「失败」。
  static const String tlsUserHint =
      '该源需要较新证书：本机系统证书过旧，无法完成 HTTPS 握手。'
      '请换一个源，或升级电视系统；换网络、重启路由器对此无效。';
}
