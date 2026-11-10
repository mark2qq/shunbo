/// 网络通道的用户配置（对应研发方案 F9 / N6 / M5）。
///
/// 三条硬边界，写在这里是为了让后来改代码的人一眼看到：
/// 1. **组播默认关闭**。本户实测为档位 C（OTT 单播，无 电视专网口、
///    局域网无 4022/7088 端口），开启前不得发起任何组播探测。
/// 2. **不内置任何运营商组播 / 内网地址表**。订阅地址由用户自行填写公开清单，
///    安装包里只有字段和解析器，没有一条现成地址（方案 14.5）。
/// 3. **识别失败 / 异网 / 蜂窝一律回落到 public**，不改用户正在看的画面。
///
/// 纯 Dart：设置页、`LiveController` 与裸 `dart run` 回归共用同一份反序列化规则。
library;

import 'live_channel.dart';

class ChannelSettings {
  const ChannelSettings({
    this.multicastEnabled = false,
    this.udpxyHost = '',
    this.udpxyPort = 4022,
    this.province = '江苏',
    this.carrierOverride = Carrier.unknown,
    this.subscriptionUrl = '',
    this.tableVersion = '',
  });

  /// 是否启用组播通道。默认 false（档位 C）。
  final bool multicastEnabled;

  /// udpxy / msd_lite 主机。只允许私网 IPv4、localhost 或 *.local，
  /// 校验见 [isValidUdpxyHost]——把公网域名填进来等于让 App 去请求陌生主机。
  final String udpxyHost;

  /// udpxy 端口。常见 4022（udpxy）/ 7088（msd_lite）。
  final int udpxyPort;

  /// 省份，仅用于「省 × 运营商」订阅的展示与命名，不参与地址推导。
  final String province;

  /// 手动覆盖运营商识别。为 [Carrier.unknown] 时走自动识别（14.8 默认）。
  final Carrier carrierOverride;

  /// 用户自行填写的「省 × 运营商」公开 m3u 订阅地址；空表示未订阅。
  final String subscriptionUrl;

  /// 最近一次导入的地址表版本 / 日期，用于更新提示与回滚。
  final String tableVersion;

  static const int minPort = 1;
  static const int maxPort = 65535;
  static const int maxTextLength = 512;

  /// 组播是否具备最基本的启用条件：开关已开 + 主机合法 + 端口合法。
  bool get multicastConfigured =>
      multicastEnabled && isValidUdpxyHost(udpxyHost) && _validPort(udpxyPort);

  bool _validPort(int p) => p >= minPort && p <= maxPort;

  /// 主机白名单：只接受私网 IPv4 / loopback / *.local。
  ///
  /// 为什么不接受域名：家庭网关的 udpxy 一定在局域网里，公网域名既没有
  /// 使用场景，又会把「用户填错地址」变成一次对外网任意主机的请求。
  static bool isValidUdpxyHost(String raw) {
    final host = raw.trim().toLowerCase();
    if (host.isEmpty || host.length > 253) return false;
    if (host == 'localhost' || host.endsWith('.local')) return true;
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final octets = <int>[];
    for (final p in parts) {
      if (p.isEmpty || p.length > 3) return false;
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return false;
      octets.add(n);
    }
    // 10/8、172.16/12、192.168/16、127/8、169.254/16（链路本地）。
    if (octets[0] == 10 || octets[0] == 127) return true;
    if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) return true;
    if (octets[0] == 192 && octets[1] == 168) return true;
    if (octets[0] == 169 && octets[1] == 254) return true;
    return false;
  }

  /// 订阅地址是否可接受：http/https、无 userinfo、无控制字符、长度有界。
  static bool isValidSubscriptionUrl(String raw) {
    if (raw.isEmpty) return true;
    if (raw.length > maxTextLength) return false;
    final u = Uri.tryParse(raw.trim());
    if (u == null) return false;
    if (u.scheme != 'http' && u.scheme != 'https') return false;
    if (u.host.isEmpty || u.userInfo.isNotEmpty) return false;
    if (raw.contains('\n') || raw.contains('\r') || raw.contains('\u0000')) {
      return false;
    }
    return true;
  }

  ChannelSettings copyWith({
    bool? multicastEnabled,
    String? udpxyHost,
    int? udpxyPort,
    String? province,
    Carrier? carrierOverride,
    String? subscriptionUrl,
    String? tableVersion,
  }) =>
      ChannelSettings(
        multicastEnabled: multicastEnabled ?? this.multicastEnabled,
        udpxyHost: udpxyHost ?? this.udpxyHost,
        udpxyPort: udpxyPort ?? this.udpxyPort,
        province: province ?? this.province,
        carrierOverride: carrierOverride ?? this.carrierOverride,
        subscriptionUrl: subscriptionUrl ?? this.subscriptionUrl,
        tableVersion: tableVersion ?? this.tableVersion,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'multicastEnabled': multicastEnabled,
        'udpxyHost': udpxyHost,
        'udpxyPort': udpxyPort,
        'province': province,
        'carrierOverride': carrierKey(carrierOverride),
        'subscriptionUrl': subscriptionUrl,
        'tableVersion': tableVersion,
      };

  /// 反序列化必须**宽容**：老版本 / 人为改坏 / 半写入的配置绝不能让 App 起不来，
  /// 任何异常字段直接取默认值（默认值恰好就是最保守的「纯公网」形态）。
  static ChannelSettings fromJson(Map<String, dynamic> raw) {
    bool? flag(String key) {
      final v = raw[key];
      return v is bool ? v : null;
    }

    String text(String key, String fallback) {
      final v = raw[key];
      return v is String && v.length <= maxTextLength ? v : fallback;
    }

    int number(String key, int fallback) {
      final v = raw[key];
      return v is int && v >= minPort && v <= maxPort ? v : fallback;
    }

    final host = text('udpxyHost', '');
    final url = text('subscriptionUrl', '');
    return ChannelSettings(
      multicastEnabled: flag('multicastEnabled') ?? false,
      udpxyHost: host.isEmpty || isValidUdpxyHost(host) ? host : '',
      udpxyPort: number('udpxyPort', 4022),
      province: text('province', '江苏'),
      carrierOverride: parseCarrier(raw['carrierOverride']),
      subscriptionUrl: isValidSubscriptionUrl(url) ? url : '',
      tableVersion: text('tableVersion', ''),
    );
  }

  static String carrierKey(Carrier c) => switch (c) {
        Carrier.unknown => 'unknown',
        Carrier.chinaMobile => 'mobile',
        Carrier.chinaTelecom => 'telecom',
        Carrier.chinaUnicom => 'unicom',
      };

  static Carrier parseCarrier(Object? raw) => switch (raw) {
        'mobile' || 'chinaMobile' || '移动' => Carrier.chinaMobile,
        'telecom' || 'chinaTelecom' || '电信' => Carrier.chinaTelecom,
        'unicom' || 'chinaUnicom' || '联通' => Carrier.chinaUnicom,
        _ => Carrier.unknown,
      };

  static String carrierLabel(Carrier c) => switch (c) {
        Carrier.unknown => '未知',
        Carrier.chinaMobile => '中国移动',
        Carrier.chinaTelecom => '中国电信',
        Carrier.chinaUnicom => '中国联通',
      };
}
