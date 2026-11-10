// 生成原生兼容分支（legacy/）与单包原生界面的频道清单 assets/channels.json。
//
// 数据源有两种，优先级从高到低：
//   ① legacy/assets/unified_channels.json —— 由 tooling/dump_live_catalog.dart 从
//      主程序 **运行时** 的那份频道表导出（内置实测 441 台 + 官方卫星源 + 城市补充
//      + 全网发现 + streams.json 备用线路，已过滤购物台）。这是「电视上看到的台 =
//      手机上看到的台」的唯一保证；数量随网络源浮动（实测 1046 台 / 1895 条）。
//   ② lib/features/live/verified_channels.g.dart —— 兜底：没有导出文件时退回
//      内置的 441 台 / 516 条（全部经 libmpv 解码门禁实测）。
//
// 用法：dart run tooling/gen_legacy_catalog.dart
//       dart run tooling/gen_legacy_catalog.dart <输出路径>
//
// 另外两件事也在这一步落地：
//   ① 频道名的拼音索引（py / pyi），供遥控器 26 字母键盘按首字母检索；
//      拼音来自 legacy/tools/pinyin_initials.json（一次性离线生成，构建期零依赖）。
//   ② 可播台账（legacy/assets/probe_ledger.json）注入与线路重排：实测可达的
//      线路排前面、死线沉底。死线**不删除**——本机探测与电视网络可能有差异，
//      删了就是永久失去兜底；沉底意味着「只有全部活线都失败才会轮到它」。
//
// 注意：官方源里带 `resolver` 的线路（令牌按小时过期）**保留但原样标记**，
// 原生端 `PlaybackController` 遇到 resolver 会直接跳过——不跳的话必然 403 播不出。

import 'dart:convert';
import 'dart:io';

import '../lib/features/live/live_channel.dart';
import '../lib/features/live/live_region.dart';
import '../lib/features/live/verified_channels.g.dart';

const String kPinyinPath = 'legacy/tools/pinyin_initials.json';
const String kLedgerPath = 'legacy/assets/probe_ledger.json';
const String kUnifiedPath = 'legacy/assets/unified_channels.json';
const String kMirrorsPath = 'legacy/assets/plaintext_mirrors.json';
/// collect_extra_streams.dart 实测通过的扩展线路（常用频道补线用）。
const String kExtraPath = 'legacy/assets/extra_streams.json';

/// 默认地区：本机用户在苏州，开机只显示苏州的地方台，其它地区地方台
/// 通过「地区」面板按省 / 按市加载。写进清单而不是写死在 Java 里，
/// 是为了让「同一套频道数据」连地区口径都同源（回归可直接断言 JSON）。
const String kDefaultProvince = '江苏';
const String kDefaultCity = '苏州';
const String kDefaultRegionMode = 'city';
const String kOtherRegion = '其它';

class _Region {
  final String province;
  final String city;
  const _Region(this.province, this.city);
}

/// 地方台的省 / 市归属。非地方组不参与地区过滤，返回空串。
///
/// 优先级：台名开头的省名（`江苏体育` 这类省级台没有城市）→
/// `inferCity` 得到的城市反查行政区代码 → 都拿不到就归「其它城市」。
/// 绝不把省份名当城市（主程序 CityDirectory 明确刻意不收省份别名）。
_Region _regionOf(String name, String group) {
  if (group != '地方频道') return const _Region('', '');
  final city = CityDirectory.inferCity(name) ?? '';
  var province = CityDirectory.provinceOfName(name) ??
      CityDirectory.provinceOfCity(city) ??
      '';
  // 极少数别名城市不在 cityCodes 里（敦煌 / 和政 / 潜江…）：
  // 挂到「其它」省下仍可按市切换，不会凭空消失。
  if (province.isEmpty && city.isNotEmpty) province = kOtherRegion;
  return _Region(province, city);
}

/// 4K / 超高清 / UHD 台。只用于**列表置顶**，不参与台号与线路排序。
/// 判定规则直接复用主程序纯逻辑层，手机与电视不会出现两套 4K 名单。
bool _is4K(String name) => ChannelQuality.is4K(name);

/// 央视频道的「主流电视顺序」。
///
/// 主程序导出的顺序把「中国教育1台」插在 CCTV-1 与 CCTV-2 之间，
/// 于是 CCTV-2 的台号变成 3（用户截图红标）。台号必须跟着大众记忆走：
/// CCTV-1=1 … CCTV-17=17，画质变体 / 海外版 / CGTN / 教育台依次靠后。
int _cctvRank(String name) {
  final n = name.toUpperCase().trim();
  final pure = RegExp(r'^CCTV-(\d{1,2})$').firstMatch(n);
  if (pure != null) return int.parse(pure.group(1)!);
  if (n == 'CCTV-4K') return 100;
  if (n == 'CCTV-8K') return 101;
  if (RegExp(r'^CCTV-\d').hasMatch(n)) return 140; // CCTV-7国防军事等带后缀
  if (n.startsWith('CCTV-5+')) return 120;
  if (n.startsWith('CCTV+')) return 130;
  if (n.startsWith('CGTN')) return 200;
  if (n.startsWith('中国教育')) {
    final m = RegExp(r'(\d+)').firstMatch(n);
    return 300 + (m == null ? 0 : int.parse(m.group(1)!));
  }
  if (n.startsWith('CHC')) return 400;
  return 500;
}

/// 只重排央视频道组，其它分组保持导出时的原顺序；央视台仍然占据
/// 原来所有「央视位置」，因此整表分组不会被打散。稳定排序（原序号兜底）。
List<_RawChannel> _reorderChannels(List<_RawChannel> src) {
  final cctv = <MapEntry<int, MapEntry<int, _RawChannel>>>[];
  for (var i = 0; i < src.length; i++) {
    if (src[i].group == '央视频道') {
      cctv.add(MapEntry(_cctvRank(src[i].name), MapEntry(i, src[i])));
    }
  }
  cctv.sort((a, b) {
    final r = a.key.compareTo(b.key);
    return r != 0 ? r : a.value.key.compareTo(b.value.key);
  });
  var at = 0;
  final out = <_RawChannel>[];
  for (final c in src) {
    out.add(c.group == '央视频道' ? cctv[at++].value.value : c);
  }
  return out;
}

/// 归一后的线路：两种来源都映射到这一个结构，后面的过滤/排序只认它。
class _RawStream {
  final String url;
  final String label;
  final int rank;
  final bool verified;
  final Map<String, String> headers;
  final String? resolver;
  final bool isPublic;
  const _RawStream({
    required this.url,
    required this.label,
    required this.rank,
    required this.verified,
    required this.headers,
    required this.resolver,
    required this.isPublic,
  });
}

class _RawChannel {
  final String id;
  final String name;
  final String group;
  final String badge;
  final List<_RawStream> streams;
  const _RawChannel({
    required this.id,
    required this.name,
    required this.group,
    required this.badge,
    required this.streams,
  });
}

class _Loaded {
  final List<_RawChannel> channels;
  final String kind;
  final String describe;
  final String at;
  final String builtIn;
  const _Loaded(this.channels, this.kind, this.describe, this.at, this.builtIn);
}

void main(List<String> args) {
  final outPath = args.isEmpty ? 'legacy/assets/channels.json' : args[0];

  final pyMap = _loadPinyinMap();
  final probe = _loadProbe();
  final mirrors = _loadPlaintextMirrors();
  final extra = _loadExtraStreams();
  final loaded = _loadSource();
  stdout.writeln('来源: ${loaded.kind} —— ${loaded.describe}');
  if (extra.isNotEmpty) {
    final n = extra.values.fold<int>(0, (sum, list) => sum + list.length);
    stdout.writeln('扩展线路: $n 条实测通过，覆盖 ${extra.length} 台');
  }
  if (mirrors.map.isNotEmpty) {
    stdout.writeln('明文镜像: ${mirrors.map.length} 条实测通过 '
        '(${mirrors.probedAt})');
  }

  final channels = <Map<String, Object?>>[];
  final stats = <String, int>{
    'channelsTotal': loaded.channels.length,
    'channelsKept': 0,
    'streamsTotal': 0,
    'streamsKept': 0,
    'streamsFilteredNonPublic': 0,
    'streamsFilteredEmptyUrl': 0,
    'streamsFilteredNonHttp': 0,
    'streamsHttps': 0,
    'streamsWithHeaders': 0,
    'streamsWithResolver': 0,
    'streamsDecodeVerified': 0,
    'streamsProbeAlive': 0,
    'streamsProbeDead': 0,
    'streamsProbeUnknown': 0,
    'channelsAllDead': 0,
    'channelsNoPinyin': 0,
    'channels4K': 0,
    'channelsWithCity': 0,
    'channelsWithProvince': 0,
    'channelsOtherRegion': 0,
    'streamsPlaintextMirror': 0,
    'channelsWithPlaintextMirror': 0,
    'streamsExtra': 0,
    'channelsWithExtra': 0,
  };
  final schemes = <String, int>{};
  final suffixes = <String, int>{};
  final provinceCounts = <String, int>{};
  final cityCounts = <String, Map<String, int>>{};

  var number = 0;
  for (final c in _reorderChannels(loaded.channels)) {
    final streams = <Map<String, Object?>>[];
    for (final s in c.streams) {
      stats['streamsTotal'] = stats['streamsTotal']! + 1;

      // 组播 / 运营商内网线路需要 udpxy 重写与运营商识别，原生端未实现，
      // 留在清单里只会变成「能选、永远播不出画面」的死项。
      if (!s.isPublic) {
        stats['streamsFilteredNonPublic'] = stats['streamsFilteredNonPublic']! + 1;
        continue;
      }
      final url = s.url.trim();
      if (url.isEmpty) {
        stats['streamsFilteredEmptyUrl'] = stats['streamsFilteredEmptyUrl']! + 1;
        continue;
      }
      final uri = Uri.tryParse(url);
      final scheme = uri?.scheme.toLowerCase() ?? 'unknown';
      schemes[scheme] = (schemes[scheme] ?? 0) + 1;
      // https 线路**保留**（ijkplayer 0.8.8 的 libijkffmpeg.so 内含
      // ff_tls_init / gnutls / openssl，native 侧能协商 TLS，不受 Java 层
      // 「API 18 默认不启用 TLS 1.2」影响）。但 Android 4.3 上的 TLS
      // 协商未经真机验证，因此排序时 http 优先、https 兜底；运行中若
      // https 连续失败，PlaybackController 会整体跳过剩余 https 线路。
      if (scheme == 'https') {
        stats['streamsHttps'] = stats['streamsHttps']! + 1;
      } else if (scheme != 'http') {
        stats['streamsFilteredNonHttp'] = stats['streamsFilteredNonHttp']! + 1;
        continue;
      }
      final path = (uri?.path ?? '').toLowerCase();
      final suffix = path.endsWith('.m3u8')
          ? 'm3u8'
          : path.endsWith('.ts')
              ? 'ts'
              : path.endsWith('.mp4')
                  ? 'mp4'
                  : path.endsWith('.flv')
                      ? 'flv'
                      : path.contains('.m3u8')
                          ? 'm3u8-query'
                          : 'other';
      suffixes[suffix] = (suffixes[suffix] ?? 0) + 1;

      if (s.headers.isNotEmpty) {
        stats['streamsWithHeaders'] = stats['streamsWithHeaders']! + 1;
      }
      if (s.resolver != null && s.resolver!.isNotEmpty) {
        stats['streamsWithResolver'] = stats['streamsWithResolver']! + 1;
      }
      if (s.verified) {
        stats['streamsDecodeVerified'] = stats['streamsDecodeVerified']! + 1;
      }

      final hit = probe[url];
      if (hit == null) {
        stats['streamsProbeUnknown'] = stats['streamsProbeUnknown']! + 1;
      } else if (hit.ok) {
        stats['streamsProbeAlive'] = stats['streamsProbeAlive']! + 1;
      } else {
        stats['streamsProbeDead'] = stats['streamsProbeDead']! + 1;
      }

      streams.add(<String, Object?>{
        'url': url,
        'label': s.label.isEmpty ? '线路 ${streams.length + 1}' : s.label,
        'rank': s.rank,
        'verified': s.verified,
        'https': scheme == 'https',
        'quality': _qualityOf(s.label, url),
        if (s.headers.isNotEmpty) 'headers': s.headers,
        if (s.resolver != null && s.resolver!.isNotEmpty) 'resolver': s.resolver,
        if (hit != null) 'probeOk': hit.ok,
        if (hit != null) 'probeMs': hit.ms,
      });
    }

    // ---- 明文镜像：只给「一条 http 线路都没有」的频道补 ----
    //
    // 真机（API 18 / ijkplayer 0.8.8）反馈：苏州 7 个地方台全部
    // 「全部 1 条线路不可用」。这些台的线路清一色是 https：
    //   · live-auth.51kandianshi.com —— TLS 1.3 + TrustAsia 2024 新链，
    //     老 OpenSSL 协商不了；
    //   · tylive.kan0512.com —— 本机 https 就握手失败，同路径 http 200。
    // 一旦 PlaybackController 因连续 https 失败把加密线路降级，这类台
    // 就再也拿不到任何可试线路。补一条**实测可达**的同路径明文线路后，
    // 明文优先排序会先试它，https 仍保留作兜底，不改动任何频道/台号。
    if (streams.isNotEmpty && streams.every((s) => s['https'] == true)) {
      final extras = <Map<String, Object?>>[];
      for (final s in List<Map<String, Object?>>.from(streams)) {
        if (s['resolver'] != null) continue; // 令牌线路换 scheme 也救不了
        final m = mirrors.map['${s['url']}'];
        if (m == null) continue; // 没通过实测就不凭空造
        extras.add(<String, Object?>{
          'url': m['httpUrl'],
          'label': '明文·${s['label']}',
          'rank': s['rank'],
          // 同源同内容、只换传输层：解码实测标记沿用；另用 mirror=true
          // 明确区分「镜像线路」，报告和回归都据此统计。
          'verified': s['verified'],
          'https': false,
          'mirror': true,
          'quality': (s['quality'] as int?) ?? 0,
          if (s['headers'] != null) 'headers': s['headers'],
          'probeOk': true,
          'probeMs': m['probeMs'],
        });
      }
      if (extras.isNotEmpty) {
        streams.addAll(extras);
        stats['streamsPlaintextMirror'] =
            stats['streamsPlaintextMirror']! + extras.length;
        stats['channelsWithPlaintextMirror'] =
            stats['channelsWithPlaintextMirror']! + 1;
      }
    }

    // 没有候选线路的台置灰没有意义，兼容分支直接跳过。
    if (streams.isEmpty) continue;
    number += 1;

    // ---- 扩展线路：collect_extra_streams.dart 实测通过的候选 ----
    // 只按最终台号注入、URL 去重、每条都带 probeOk/probeMs/quality/extra，
    // 与镜像线路一样可回溯；没通过实测的一条都不会出现在这里。
    final extraList = extra[number];
    if (extraList != null) {
      var added = 0;
      for (final e in extraList) {
        final u = '${e['url']}';
        if (streams.any((s) => s['url'] == u)) continue;
        streams.add(<String, Object?>{
          'url': u,
          'label': e['label'],
          'rank': 60,
          'verified': false,
          'https': e['https'] == true,
          'extra': true,
          'quality': (e['quality'] as int?) ?? 0,
          'probeOk': true,
          'probeMs': (e['probeMs'] as int?) ?? 9999,
          if (e['headers'] != null) 'headers': e['headers'],
        });
        added++;
      }
      if (added > 0) {
        stats['streamsExtra'] = stats['streamsExtra']! + added;
        stats['channelsWithExtra'] = stats['channelsWithExtra']! + 1;
      }
    }

    stats['channelsKept'] = stats['channelsKept']! + 1;
    stats['streamsKept'] = stats['streamsKept']! + streams.length;

    // 排序六层：台账可达 > 探测耗时 > 解码实测 > 画质 rank > 明文 http > 原序号。
    // 原序号作末级键，避免不稳定排序打乱同分线路的顺序。
    final indexed = <MapEntry<int, Map<String, Object?>>>[
      for (var i = 0; i < streams.length; i++) MapEntry(i, streams[i]),
    ];
    indexed.sort((a, b) {
      // 台账优先级最高：可达的排前面，可达之间按耗时升序；未知（未探测）
      // 夹在中间，死线沉底。死线只影响尝试顺序，不从清单里删掉。
      final pa = a.value['probeOk'] as bool?;
      final pb = b.value['probeOk'] as bool?;
      final ka = pa == true ? 0 : (pa == null ? 1 : 2);
      final kb = pb == true ? 0 : (pb == null ? 1 : 2);
      if (ka != kb) return ka.compareTo(kb);
      // 扩展线路是 PC 侧新实测的补充线，内容与电视端解码未复核：
      // 排在「原有可达线路」之后、死线之前，既不抢首播也不沉底失效。
      if (ka == 0) {
        final ea = a.value['extra'] == true ? 1 : 0;
        final eb = b.value['extra'] == true ? 1 : 0;
        if (ea != eb) return ea.compareTo(eb);
      }
      if (ka == 0) {
        final ma = (a.value['probeMs'] as int?) ?? 1 << 30;
        final mb = (b.value['probeMs'] as int?) ?? 1 << 30;
        if (ma != mb) return ma.compareTo(mb);
      }
      final va = (a.value['verified'] as bool?) ?? false;
      final vb = (b.value['verified'] as bool?) ?? false;
      if (va != vb) return va ? -1 : 1;
      final ra = (a.value['rank'] as int?) ?? 0;
      final rb = (b.value['rank'] as int?) ?? 0;
      if (ra != rb) return rb.compareTo(ra);
      final ha = (a.value['https'] as bool?) ?? false;
      final hb = (b.value['https'] as bool?) ?? false;
      if (ha != hb) return ha ? 1 : -1;
      return a.key.compareTo(b.key);
    });

    final ordered = <Map<String, Object?>>[for (final e in indexed) e.value];
    final alive = ordered.where((s) => s['probeOk'] == true).length;
    if (alive == 0 && ordered.every((s) => s['probeOk'] != null)) {
      stats['channelsAllDead'] = stats['channelsAllDead']! + 1;
    }
    final pyi = _initials(c.name, pyMap);
    final py = _fullPinyin(c.name, pyMap);
    if (pyi.isEmpty) stats['channelsNoPinyin'] = stats['channelsNoPinyin']! + 1;

    final is4K = _is4K(c.name);
    final region = _regionOf(c.name, c.group);
    if (is4K) stats['channels4K'] = stats['channels4K']! + 1;
    if (c.group == '地方频道') {
      if (region.city.isNotEmpty) {
        stats['channelsWithCity'] = stats['channelsWithCity']! + 1;
      }
      if (region.province.isNotEmpty) {
        stats['channelsWithProvince'] = stats['channelsWithProvince']! + 1;
      }
      if (region.province.isEmpty && region.city.isEmpty) {
        stats['channelsOtherRegion'] = stats['channelsOtherRegion']! + 1;
      } else {
        provinceCounts[region.province] =
            (provinceCounts[region.province] ?? 0) + 1;
        if (region.city.isNotEmpty) {
          final cities = cityCounts.putIfAbsent(
              region.province, () => <String, int>{});
          cities[region.city] = (cities[region.city] ?? 0) + 1;
        }
      }
    }

    channels.add(<String, Object?>{
      'num': number,
      'id': c.id,
      'name': c.name,
      'group': c.group,
      'badge': c.badge,
      // 列表展示层用：4K 归集置顶（与台号 / 线路排序完全无关）。
      'is4K': is4K,
      // 地区过滤层用：空串 = 非地方台（始终可见）或推断不出归属。
      'province': region.province,
      'city': region.city,
      // 遥控器 26 字母检索用：pyi = 首字母串（cctv1 / zjws），py = 全拼串。
      'pyi': pyi,
      'py': py,
      if (alive > 0) 'reachable': alive,
      'streams': ordered,
    });
  }

  // 省 / 市选项由数据层给出，Java 端只渲染，不在老机器上重算一遍归属。
  final provinceOrder = <String>[
    ...kProvinces.where(provinceCounts.containsKey),
    ...provinceCounts.keys
        .where((p) => !kProvinces.contains(p) && p != kOtherRegion)
        .toList()
      ..sort(),
    if (provinceCounts.containsKey(kOtherRegion)) kOtherRegion,
  ];
  final regions = <String, Object?>{
    'defaultProvince': kDefaultProvince,
    'defaultCity': kDefaultCity,
    'defaultMode': kDefaultRegionMode,
    'otherCount': stats['channelsOtherRegion'],
    'provinces': <Map<String, Object?>>[
      for (final p in provinceOrder)
        <String, Object?>{'name': p, 'count': provinceCounts[p]},
    ],
    'cities': <String, Object?>{
      for (final p in provinceOrder)
        p: <Map<String, Object?>>[
          for (final e in (cityCounts[p] ?? <String, int>{}).entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key)))
            <String, Object?>{'name': e.key, 'count': e.value},
        ],
    },
  };

  final payload = <String, Object?>{
    'format': 'shunbo-legacy-catalog/1',
    'verifiedAt': loaded.at,
    'sourceKind': loaded.kind,
    'source': loaded.describe,
    'builtIn': loaded.builtIn,
    if (probeAt != null) 'probeAt': probeAt,
    if (probeAt != null) 'probeMethod': 'm3u8 + first segment reachability (PC side)',
    'pinyinSource': 'legacy/tools/pinyin_initials.json',
    'plaintextMirrorCount': stats['streamsPlaintextMirror'],
    'plaintextMirrorChannels': stats['channelsWithPlaintextMirror'],
    'extraStreamCount': stats['streamsExtra'],
    'extraStreamChannels': stats['channelsWithExtra'],
    if (mirrors.probedAt.isNotEmpty)
      'plaintextMirrorProbedAt': mirrors.probedAt,
    if (mirrors.probedAt.isNotEmpty)
      'plaintextMirrorCoverage': <String, Object?>{
        'candidateChannels': mirrors.candidateChannels,
        'verifiedUrls': mirrors.verifiedUrls,
      },
    'channelCount': channels.length,
    'streamCount': stats['streamsKept'],
    'fourKCount': stats['channels4K'],
    'regions': regions,
    'channels': channels,
  };

  final file = File(outPath);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(payload),
    flush: true,
  );

  stdout.writeln('输出: ${file.absolute.path} (${file.lengthSync()} B)');
  stdout.writeln('统计: ${jsonEncode(stats)}');
  stdout.writeln('scheme: ${jsonEncode(schemes)}');
  stdout.writeln('后缀: ${jsonEncode(suffixes)}');
}

// ---------------------------------------------------------------- 来源

/// 优先用主程序运行时导出（「同一套」），缺失时退回内置实测清单。
_Loaded _loadSource() {
  final f = File(kUnifiedPath);
  if (f.existsSync()) {
    try {
      final root = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      final out = <_RawChannel>[];
      for (final c in (root['channels'] as List).cast<Map<String, Object?>>()) {
        final streams = <_RawStream>[];
        for (final s in (c['streams'] as List).cast<Map<String, Object?>>()) {
          final headers = <String, String>{};
          final rawHeaders = s['headers'];
          if (rawHeaders is Map) {
            for (final e in rawHeaders.entries) {
              headers['${e.key}'] = '${e.value}';
            }
          }
          streams.add(_RawStream(
            url: '${s['url'] ?? ''}',
            label: '${s['label'] ?? ''}',
            rank: (s['rank'] as int?) ?? 0,
            verified: s['verified'] == true,
            headers: headers,
            resolver: s['resolver'] == null ? null : '${s['resolver']}',
            isPublic: true,
          ));
        }
        out.add(_RawChannel(
          id: '${c['id'] ?? ''}',
          name: '${c['name'] ?? ''}',
          group: '${c['group'] ?? ''}',
          badge: '${c['badge'] ?? ''}',
          streams: streams,
        ));
      }
      return _Loaded(
        out,
        'unified_channels.json',
        '主程序运行时同一套（内置实测 + 官方卫星 + 城市补充 + 全网发现 + 备用线路）：'
            '${root['channelCount']} 台 / ${root['streamCount']} 线路，'
            '导出 ${root['exportedAt']}',
        '${root['exportedAt'] ?? ''}',
        'verified_channels.g.dart ${root['builtInVerifiedAt'] ?? ''}',
      );
    } catch (e) {
      stderr.writeln('$kUnifiedPath 解析失败，退回内置清单: $e');
    }
  }
  final out = <_RawChannel>[];
  for (final c in kVerifiedLiveChannels) {
    out.add(_RawChannel(
      id: c.id,
      name: c.name,
      group: c.group,
      badge: c.badge,
      streams: <_RawStream>[
        for (final s in c.streams)
          _RawStream(
            url: s.url,
            label: s.label,
            rank: s.qualityRank,
            verified: s.decodeVerified,
            headers: s.headers,
            resolver: s.resolverUrl,
            isPublic: s.channelType == LiveChannelType.public,
          ),
      ],
    ));
  }
  return _Loaded(
    out,
    'verified_channels.g.dart',
    '内置实测清单（libmpv 解码零错误）：${out.length} 台',
    kVerifiedLiveAt,
    'verified_channels.g.dart $kVerifiedLiveAt',
  );
}

// ---------------------------------------------------------------- 辅助

/// 台账探测时间；仅在读到台账时非空，缺省则不写入 payload。
String? probeAt;

/// 拼音映射：汉字 → 无声调全拼。文件由 pinyin 包一次性离线生成。
Map<String, String> _loadPinyinMap() {
  final f = File(kPinyinPath);
  if (!f.existsSync()) {
    stderr.writeln('缺少 $kPinyinPath，检索索引会为空（不影响播放）');
    return const <String, String>{};
  }
  final root = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
  final map = (root['map'] as Map).cast<String, Object?>();
  return <String, String>{
    for (final e in map.entries) e.key: '${e.value}',
  };
}

class _Hit {
  final bool ok;
  final int ms;
  const _Hit(this.ok, this.ms);
}

/// 台账：url → 是否可达 + 耗时。缺失或损坏时整体降级为「未探测」，
/// 不阻断清单生成（宁可少一层排序信息，也不能让构建挂掉）。
Map<String, _Hit> _loadProbe() {
  final f = File(kLedgerPath);
  if (!f.existsSync()) return const <String, _Hit>{};
  try {
    final root = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    probeAt = '${root['probedAt'] ?? ''}';
    final out = <String, _Hit>{};
    for (final s in (root['streams'] as List).cast<Map<String, Object?>>()) {
      final url = '${s['url'] ?? ''}';
      if (url.isEmpty) continue;
      out[url] = _Hit(s['ok'] == true, (s['ms'] as int?) ?? 0);
    }
    return out;
  } catch (e) {
    stderr.writeln('台账解析失败，按未探测处理: $e');
    return const <String, _Hit>{};
  }
}

class _Mirrors {
  /// 原 https URL → {httpUrl, probeMs}。只含 m3u8 与首分片都实测通过的记录。
  final Map<String, Map<String, Object?>> map;
  final String probedAt;
  final int candidateChannels;
  final int verifiedUrls;
  const _Mirrors(this.map, this.probedAt, this.candidateChannels,
      this.verifiedUrls);
}

/// 明文镜像白名单由 tooling/probe_plaintext_mirrors.dart 实测产出。
/// 文件缺失时静默降级（不补镜像），绝不阻断清单生成。
_Mirrors _loadPlaintextMirrors() {
  final f = File(kMirrorsPath);
  if (!f.existsSync()) {
    return const _Mirrors(<String, Map<String, Object?>>{}, '', 0, 0);
  }
  try {
    final root = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    if (root['format'] != 'shunbo-plaintext-mirrors/1') {
      return const _Mirrors(<String, Map<String, Object?>>{}, '', 0, 0);
    }
    final out = <String, Map<String, Object?>>{};
    for (final e in (root['mirrors'] as List).cast<Map<String, Object?>>()) {
      final httpsUrl = '${e['httpsUrl'] ?? ''}';
      final httpUrl = '${e['httpUrl'] ?? ''}';
      if (!httpsUrl.startsWith('https://') || !httpUrl.startsWith('http://')) {
        continue;
      }
      out[httpsUrl] = <String, Object?>{
        'httpUrl': httpUrl,
        'probeMs': (e['probeMs'] as int?) ?? 9999,
      };
    }
    return _Mirrors(
      out,
      '${root['probedAt'] ?? ''}',
      (root['candidateChannels'] as int?) ?? 0,
      (root['verifiedCount'] as int?) ?? 0,
    );
  } catch (e) {
    stderr.writeln('明文镜像解析失败，按无镜像处理: $e');
    return const _Mirrors(<String, Map<String, Object?>>{}, '', 0, 0);
  }
}

bool _isHan(int r) => r >= 0x4E00 && r <= 0x9FFF;

/// 首字母串：汉字取拼音首字母（浙江卫视 → zjws），ASCII 字母数字原样小写，
/// 标点与空格跳过。用未收录的字（城市名长尾）直接略过，宁可短也不塞占位符。
String _initials(String name, Map<String, String> map) {
  final out = StringBuffer();
  for (final r in name.runes) {
    if (_isHan(r)) {
      final py = map[String.fromCharCode(r)];
      if (py != null && py.isNotEmpty) out.write(py[0]);
      continue;
    }
    final ch = String.fromCharCode(r);
    if (RegExp(r'[A-Za-z0-9]').hasMatch(ch)) out.write(ch.toLowerCase());
  }
  return out.toString();
}

/// 全拼串：汉字补全拼（浙江卫视 → zhejiangweishi），其余同 [_initials]。
String _fullPinyin(String name, Map<String, String> map) {
  final out = StringBuffer();
  for (final r in name.runes) {
    if (_isHan(r)) {
      final py = map[String.fromCharCode(r)];
      if (py != null && py.isNotEmpty) out.write(py);
      continue;
    }
    final ch = String.fromCharCode(r);
    if (RegExp(r'[A-Za-z0-9]').hasMatch(ch)) out.write(ch.toLowerCase());
  }
  return out.toString();
}

// ---------------------------------------------------------------- 扩展线路

/// 台号 → 实测通过的扩展线路。文件缺失 / 格式不对时静默降级为「不补线」，
/// 绝不阻断清单生成（与明文镜像同一策略）。
Map<int, List<Map<String, Object?>>> _loadExtraStreams() {
  final f = File(kExtraPath);
  if (!f.existsSync()) return <int, List<Map<String, Object?>>>{};
  try {
    final root = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    if (root['format'] != 'shunbo-extra-streams/1') {
      return <int, List<Map<String, Object?>>>{};
    }
    final out = <int, List<Map<String, Object?>>>{};
    for (final s in (root['streams'] as List).cast<Map<String, Object?>>()) {
      final num = (s['num'] as int?) ?? 0;
      final url = '${s['url'] ?? ''}';
      if (num <= 0 || !url.startsWith('http')) continue;
      out.putIfAbsent(num, () => <Map<String, Object?>>[]).add(s);
    }
    return out;
  } catch (e) {
    stderr.writeln('扩展线路解析失败，按无扩展处理: $e');
    return <int, List<Map<String, Object?>>>{};
  }
}

/// 从线路标签 / URL 推断标称清晰度，供「优先清晰度」设置排序用。
/// 与 collect_extra_streams.dart 的 _qualityOf 同口径。
int _qualityOf(String label, String url) {
  final s = '$label $url'.toLowerCase();
  if (s.contains('2160') || s.contains('4k') || s.contains('uhd') ||
      s.contains('超高清')) return 2160;
  if (s.contains('1080')) return 1080;
  if (s.contains('720')) return 720;
  if (s.contains('576') || s.contains('480') || s.contains('标清')) return 576;
  return 0;
}
