/// 1.0.5 点播源地址配置（G1 开放接口；G2+G3 为默认组合）。
///
/// 设计约束（直接关系到「1.0.4 行为不受影响」）：
/// * 默认「内置片库 + 外部地址关闭」⇒ 启动时不拉取任何外部地址、不注册任何外部源，
///   播放链路与 1.0.4 逐字节一致；
/// * 是否启用、用哪个地址，完全由用户决定。候选地址只是**可选项数据**，
///   不随包请求、不随包注册、不代表已获授权；
/// * 地址校验与 `source_config_url.dart` 的传输层策略同口径：仅 https，
///   明文 http 只对 loopback 放开，拒绝内嵌账密与非 http(s) 协议；
/// * 客户端只接受 E9 纯数据规则配置（dart / regex / json），
///   **不执行外部 jar / QuickJS**。这是 1.0.4 已有的安全基线，本版不放宽。
library;

import 'source_config_url.dart';
import 'vod_update_cadence.dart';

/// 默认组合标识。G1 未启用时生效的是 G2（合规片库 + 纯数据规则源）+ G3（点播体验）。
const String kVodDefaultPolicy = 'G2+G3';

/// 内置片库在候选列表里的值：空串表示「不请求外部地址」。
const String kVodBuiltInSourceUrl = '';
const String kVodBuiltInSourceLabel = '内置片库（默认 · G2+G3）';

const int kMaxVodCustomUrls = 12;
const int kMaxVodAddressLength = 2048;

/// 默认加载源（1.0.5 第三次修）。
///
/// 五个候选地址全部实测后的胜出项：20 个 type:1 采集站里 9 个能给出直链，
/// 站内片量合计 119.7 万，均高于其余四条（次优 82.4 万 / 6 站）。
/// 另外两条（:16/8888、:55316/9981）的站点**全部**是 type:3 插件型，
/// 本客户端不执行外部 JS / jar，放行也出不来影片；:924/924 的两个采集站
/// 一个返回网页、一个只给分享页，导不出可播条目。
///
/// 它只在用户**打开开关**时生效：开关关闭时仍是 G2+G3 内置片库，
/// 1.0.4 行为不变。
const String kVodDefaultSourceUrl = 'http://47.96.82.41:5188/config.json';

/// 默认源的展示名（`sourceId` 前缀沿用主机名，避免同名影片串进度）。
const String kVodDefaultSourceLabel = '默认源 · 47.96.82.41';

/// 一个候选接口地址。`thirdParty=true` 表示第三方自备接口，需用户自行确认授权。
class VodSourceCandidate {
  const VodSourceCandidate({
    required this.id,
    required this.label,
    required this.url,
    required this.note,
    this.thirdParty = true,
    this.availability = VodAvailability.usable,
  });

  final String id;
  final String label;
  final String url;
  final String note;
  final bool thirdParty;

  /// **实测**可用性。与「格式是否合规」是两件事：一条 https 地址可以格式
  /// 完全合规，却返回网页或只含插件站点，永远导不进任何影片。
  final VodAvailability availability;

  /// 已知不可用时的原因（给用户看的一句话）；可用时为 null。
  String? get unavailableReason => switch (availability) {
        VodAvailability.usable => null,
        VodAvailability.htmlPage => '实测返回网页而不是接口数据，无法导入',
        VodAvailability.pluginOnly =>
          '实测全是插件型站点；打开「允许执行外部代码」后会用其 HTTP 接口再试一次，'
              '仍可能导不出（本机不运行 jar / JS）',
        VodAvailability.noPlayable =>
          '实测采集站只给出网页跳转 / 分享页，导不出可直接播放的条目',
      };

  bool get canProduceItems => availability == VodAvailability.usable;

  /// 是否默认加载源（打开开关即用它）。
  bool get isDefaultSource => url == kVodDefaultSourceUrl;
}

/// 候选的实测可用性。
///
/// 这个区分是 1.0.5 第二次修 UI 时补的：上一版只按「格式是否合规」决定能否
/// 选中，结果变成 —— 唯一 https 合规的候选（影视仓官方入口）是**实测必然失败**
/// 的网页，而实测能出片的采集站全是明文 http、被锁成灰的。用户陷入一个
/// 闭合的失败回路：点得动的必然失败，能成的一个都点不动。
enum VodAvailability {
  /// 实测能出片，或随包内置不发起外网请求。
  usable,

  /// 需要执行外部 JS / jar 的插件型配置：即使放行明文也出不来影片。
  pluginOnly,

  /// 返回网页（HTML）而不是接口数据：无论怎么放行都不可能导入成功。
  htmlPage,

  /// 有 `type:1` 采集站，但实测只返回网页跳转 / 分享页，
  /// 没有任何可直接播放的媒体地址。与「插件型」是两件事：
  /// 一个是不能执行，一个是执行了也没有可用数据。
  noPlayable,
}

/// 候选地址清单。取自《播放接口.txt》的点播侧条目，只作为**可选项**展示；
/// 其中明文 http 地址在当前传输策略下会被拒绝，界面会如实标出原因。
///
/// 1.0.5 第三次修：五条第三方地址**全部逐个实测**（2026-11-11 19:20），
/// 结论写在各自 note 里 —— 其中两条根本没有可接入的影片数据，
/// 一条的采集站只给分享页。默认源排在内置片库之后，避免用户还要自己挑。
const List<VodSourceCandidate> kVodSourceCandidates = <VodSourceCandidate>[
  VodSourceCandidate(
    id: 'built-in',
    label: kVodBuiltInSourceLabel,
    url: kVodBuiltInSourceUrl,
    note: '随包分发的公开授权片库，不发起外部请求；关闭外部地址时始终走这一项',
    thirdParty: false,
  ),
  VodSourceCandidate(
    id: 'tvbox-config',
    label: '默认源 · 47.96.82.41/config.json',
    url: kVodDefaultSourceUrl,
    note: '实测最优：21 个站点（20 个 type:1 采集站 + 1 插件站），'
        '其中 9 个能给出 .m3u8 直链，站内片量合计 119.7 万；'
        '打开开关即用它',
  ),
  VodSourceCandidate(
    id: 'tvbox-pps',
    label: 'TVBox 配置 · :20271/pps.bmp',
    url: 'http://124.223.214.31:20271/pps.bmp',
    note: '实测次优：实为 JSON（伪装成 BMP、带 30 天缓存），151 个站点里 14 个采集站，'
        '6 个有直链，站内片量合计 82.4 万',
  ),
  VodSourceCandidate(
    id: 'tvbox-924',
    label: 'TVBox 配置 · :924/924',
    url: 'http://124.223.214.31:924/924',
    note: '105 个站点里只有 2 个采集站，实测一个返回网页、一个只给 /share/ 分享页，'
        '导不出可播条目',
    availability: VodAvailability.noPlayable,
  ),
  VodSourceCandidate(
    id: 'tvbox-9981',
    label: 'TVBox 配置 · :55316/9981',
    url: 'http://124.223.214.31:55316/9981',
    note: '实测 117 个站点全部 type:3（csp_ 脚本 + spider jar），配置本身不含影片数据',
    availability: VodAvailability.pluginOnly,
  ),
  VodSourceCandidate(
    id: 'tvbox-8888',
    label: 'TVBox 配置 · :16/8888',
    url: 'http://124.223.214.31:16/8888',
    note: '实测 27 个站点全部 type:3（csp_ 脚本 + spider jar），只是插件注册表，'
        '配置本身不含影片数据',
    availability: VodAvailability.pluginOnly,
  ),
  VodSourceCandidate(
    id: 'starlink-official',
    label: '影视仓官方入口',
    url: 'https://api.starlink.fan/index.php',
    note: '接口分发站，实测返回 277 KB 网页（HTML）而非配置 JSON；需登录与影豆，'
        '无书面授权条款',
    availability: VodAvailability.htmlPage,
  ),
];

/// 默认加载源在清单里的那一项。
VodSourceCandidate get kVodDefaultSourceCandidate =>
    kVodSourceCandidates.firstWhere((c) => c.url == kVodDefaultSourceUrl);

/// 该地址是否是**已知不可用**的候选（返回网页 / 只给分享页）。
///
/// 用户自己手输的地址不走这个判断 —— 只有清单里已实测过的才算「已知」。
///
/// 1.0.5 第四次修：插件型（`pluginOnly`）**不再**算已知不可用。开启
/// 「允许执行外部代码」后，这类站点会用自身的 HTTP 接口再试一次，
/// 有真实出片的可能；把它钉成「不可用」会让用户连试都试不了。
bool isKnownUnusableSource(String url) {
  final t = url.trim();
  if (t.isEmpty) return false;
  for (final c in kVodSourceCandidates) {
    if (c.url == t) {
      return c.availability == VodAvailability.htmlPage ||
          c.availability == VodAvailability.noPlayable;
    }
  }
  return false;
}

/// 地址校验结论。
enum VodAddressVerdict {
  /// 空地址 = 内置片库，不是错误。
  builtIn,

  /// 可交给现有 E9 导入链尝试（不代表内容一定合规或一定能解析）。
  acceptable,

  /// 明文 http 且非 loopback：传输层策略拒绝。
  plainHttp,

  /// 格式非法（协议、主机名、账密、控制字符、长度）。
  malformed,
}

class VodAddressCheck {
  const VodAddressCheck(this.verdict, this.reason);

  final VodAddressVerdict verdict;
  final String reason;

  /// 是否允许「保存为自定义地址 / 交给导入链」。
  bool get acceptable => verdict == VodAddressVerdict.acceptable;

  /// 是否允许展示（内置片库与可导入地址都算正常状态）。
  bool get ok =>
      verdict == VodAddressVerdict.builtIn ||
      verdict == VodAddressVerdict.acceptable;
}

/// 与 `fetchSourceConfigUrl` 的传输层策略同口径的**纯函数**校验。
/// 不发请求，可在裸 `dart run` 下回归。
VodAddressCheck validateVodSourceAddress(String raw,
    {bool allowInsecureHttp = false}) {
  final s = raw.trim();
  if (s.isEmpty) {
    return const VodAddressCheck(
        VodAddressVerdict.builtIn, '内置片库：不请求外部地址');
  }
  if (s.length > kMaxVodAddressLength) {
    return VodAddressCheck(
        VodAddressVerdict.malformed, '地址过长（上限 $kMaxVodAddressLength 字符）');
  }
  if (s.contains('\n') || s.contains('\r') || s.contains('\t')) {
    return const VodAddressCheck(
        VodAddressVerdict.malformed, '地址含控制字符，已拒绝');
  }
  final uri = Uri.tryParse(s);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
    return const VodAddressCheck(
        VodAddressVerdict.malformed, '仅支持 https 链接（本地自测可用 loopback http）');
  }
  if (uri.host.isEmpty) {
    return const VodAddressCheck(
        VodAddressVerdict.malformed, '链接缺少主机名');
  }
  if (uri.userInfo.isNotEmpty) {
    return const VodAddressCheck(
        VodAddressVerdict.malformed, '链接不得内嵌账号密码');
  }
  final isPlain = uri.scheme == 'http' && !isLoopbackHost(uri.host);
  if (isPlain && !allowInsecureHttp) {
    return const VodAddressCheck(
      VodAddressVerdict.plainHttp,
      '明文 http 且非 loopback：传输层策略拒绝，请改用 https、'
      '打开「允许明文 http」，或改为本地文件导入',
    );
  }
  return VodAddressCheck(
    VodAddressVerdict.acceptable,
    isPlain
        ? '明文 http 已由你显式放行；仍会经过内容校验与来源确认，存在被篡改风险'
        : '格式符合传输策略；导入时仍会经过内容校验与来源确认',
  );
}

/// 用户可配置的地址设置。不可变对象，所有变更返回新实例。
class VodSourceAddressSettings {
  const VodSourceAddressSettings({
    this.enabled = false,
    this.selectedUrl = kVodBuiltInSourceUrl,
    this.customUrls = const <String>[],
    this.allowInsecureHttp = false,
    this.allowExternalCode = true,
    this.updateIntervalDays = 1,
  });

  /// 默认：**关闭**外部地址 + **关闭**明文 http 放行。这是保证 1.0.4 行为不变的开关。
  static const VodSourceAddressSettings defaults = VodSourceAddressSettings();

  final bool enabled;
  final String selectedUrl;
  final List<String> customUrls;

  /// 1.0.5：用户显式接受中间人风险后才允许非 loopback 的明文 http。
  /// 仅作用于 G1 点播源这条链路，1.0.4 的 E9 导入仍默认拒绝。
  final bool allowInsecureHttp;

  /// 1.0.5（第四次修）：「允许执行外部代码」。
  ///
  /// 精确语义：**放行插件型站点**（`type:3` / `csp_`）里那些 `api` 本身就是
  /// http(s) 采集地址的站点，用同一条纯数据 CMS 协议取列表与详情。
  ///
  /// 本机仍然**不运行** jar / JS（客户端没有 JVM、也没有 JS 引擎，做不到）。
  /// `api` 写成 `csp_xxx` 脚本名的站点照旧跳过并如实计数。默认打开是因为
  /// 实测这类站点占了配置里的大多数，「片源没全部加载」的缺口主要在这里。
  final bool allowExternalCode;

  /// 1.0.5 第二十四次修：片源索引的**自动更新间隔**（天）。
  ///
  /// 界面给七档（一天 / 三天 / 一周 / 一月 / 一季度 / 半年 / 一年），
  /// 这里只存天数；读回来时由 `VodUpdateCadence.fromDays()` 做容错，
  /// 落盘值不在七档里就回落一天 —— 不认识的数字不该变成「永不更新」，
  /// 也不该被静默放行成「半小时一次」。
  final int updateIntervalDays;

  /// 关闭开关或选了内置片库时，都走 G2+G3 默认组合。
  bool get usesBuiltIn => !enabled || selectedUrl.trim().isEmpty;

  String get effectiveUrl => usesBuiltIn ? kVodBuiltInSourceUrl : selectedUrl.trim();

  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabled': enabled,
        'selectedUrl': selectedUrl,
        'customUrls': List<String>.from(customUrls),
        'allowInsecureHttp': allowInsecureHttp,
        'allowExternalCode': allowExternalCode,
        'vodUpdateIntervalDays': updateIntervalDays,
      };

  /// 容错反序列化：任何坏数据都回落到默认（关闭），避免损坏的配置
  /// 在升级后悄悄把外部源打开。`enabled` 只认字面 true。
  factory VodSourceAddressSettings.fromJson(Object? raw) {
    if (raw is! Map) return defaults;
    final m = Map<String, dynamic>.from(raw);
    final enabled = m['enabled'] == true;
    final insecure = m['allowInsecureHttp'] == true;
    // 自动更新间隔：只认七档（1/3/7/30/90/180/365），其余回落一天。
    // 放在最前面解析，下面几条「坏配置回默认」的早退也不会把它丢掉。
    final intervalDays =
        VodUpdateCadence.tryParse(m['vodUpdateIntervalDays'])?.days ?? 1;
    VodSourceAddressSettings fallback() =>
        VodSourceAddressSettings(updateIntervalDays: intervalDays);
    final selected = m['selectedUrl'] is String
        ? (m['selectedUrl'] as String).trim()
        : kVodBuiltInSourceUrl;
    if (selected.length > kMaxVodAddressLength) return fallback();
    // 明文 http 或非法地址都不允许在重启后成为「当前选中项」，
    // 除非用户显式打开过明文放行（否则界面会停在一个永远点不动的按钮上）。
    if (selected.isNotEmpty &&
        !validateVodSourceAddress(selected,
                allowInsecureHttp: insecure)
            .ok) {
      return fallback();
    }
    // 已知不可用的候选（返回网页 / 纯插件型）不能成为重启后的选中项：
    // 否则用户每次进设置都停在一个「点了必然失败」的地址上，
    // 而真正能用的明文候选又被锁着 —— 这正是上一版截图里的死锁。
    final safeSelected = isKnownUnusableSource(selected)
        ? kVodBuiltInSourceUrl
        : selected;
    final custom = <String>[];
    final list = m['customUrls'];
    if (list is List) {
      for (final x in list) {
        if (x is! String) continue;
        final t = x.trim();
        if (t.isEmpty || t.length > kMaxVodAddressLength) continue;
        // 落盘内容可能被外部改动：反序列化时复用同一套地址校验，
        // 不合法/明文 http 的条目直接丢弃，避免坏配置混进候选列表。
        if (!validateVodSourceAddress(t, allowInsecureHttp: insecure)
            .acceptable) continue;
        if (!custom.contains(t)) custom.add(t);
        if (custom.length >= kMaxVodCustomUrls) break;
      }
    }
    return VodSourceAddressSettings(
      enabled: enabled,
      selectedUrl: safeSelected,
      customUrls: List<String>.unmodifiable(custom),
      allowInsecureHttp: insecure,
      // 缺省 true：1.0.5 第四次修之前落盘的配置没有这个键，
      // 读回来应当是「允许插件站点的 HTTP 接口」，否则升级后片源会变少。
      allowExternalCode: m.containsKey('allowExternalCode')
          ? m['allowExternalCode'] == true
          : true,
      updateIntervalDays: intervalDays,
    );
  }

  VodSourceAddressSettings copyWith({
    bool? enabled,
    String? selectedUrl,
    List<String>? customUrls,
    bool? allowInsecureHttp,
    bool? allowExternalCode,
    int? updateIntervalDays,
  }) =>
      VodSourceAddressSettings(
        enabled: enabled ?? this.enabled,
        selectedUrl: selectedUrl ?? this.selectedUrl,
        customUrls: customUrls ?? this.customUrls,
        allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
        allowExternalCode: allowExternalCode ?? this.allowExternalCode,
        updateIntervalDays: updateIntervalDays ?? this.updateIntervalDays,
      );

  /// 新增自定义地址并立即选中；超过上限时丢弃最旧的一条。
  VodSourceAddressSettings addCustom(String raw) {
    final t = raw.trim();
    if (t.isEmpty ||
        !validateVodSourceAddress(t,
                allowInsecureHttp: allowInsecureHttp)
            .acceptable) return this;
    final next = <String>[
      for (final x in customUrls)
        if (x != t) x,
      t,
    ];
    while (next.length > kMaxVodCustomUrls) {
      next.removeAt(0);
    }
    return copyWith(
      enabled: true,
      selectedUrl: t,
      customUrls: List<String>.unmodifiable(next),
    );
  }

  VodSourceAddressSettings removeCustom(String raw) {
    final t = raw.trim();
    final next = <String>[for (final x in customUrls) if (x != t) x];
    return copyWith(
      selectedUrl: selectedUrl == t ? kVodBuiltInSourceUrl : selectedUrl,
      customUrls: List<String>.unmodifiable(next),
    );
  }
}
