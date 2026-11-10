/// 通道地址表导入（研发方案 M1 / F11 / N6）。
///
/// 支持标准的 m3u（`#EXTINF` + `group-title`）与国内聚合表常见的
/// `台名,地址` 两列文本（`,#genre#` 分节）。导入时按清单归属给每条线路
/// 打上通道标记；组播地址会先经 [UdpxyRewriter] 转成 HTTP 单播再交给
/// `LiveCatalogService.parseM3U` —— **复用线上同一套台名归一 / 分组推断 /
/// 画质分级**，避免导入器自己猜一遍、和频道表算出两个 id。
///
/// 安装包内不含任何组播或运营商内网地址表（方案 14.5），只提供解析能力。
library;

import 'dart:convert';

import 'channel_settings.dart';
import 'live_catalog.dart';
import 'live_channel.dart';
import 'network_channel.dart';

enum AddressTableFormat { m3u, nameUrl }

/// 一次导入的结果（方案 4.2 `AddressTableImporter.import`）。
class CarrierImportResult {
  const CarrierImportResult({
    required this.channels,
    required this.multicastCount,
    required this.carrierNetCount,
    required this.publicCount,
    required this.skipped,
    required this.duplicates,
    required this.error,
  });

  final List<LiveChannel> channels;
  final int multicastCount;
  final int carrierNetCount;
  final int publicCount;
  final int skipped;
  final int duplicates;
  final String? error;

  bool get ok => error == null && channels.isNotEmpty;

  String get summary => error ??
      '${channels.length} 个频道 · 组播 $multicastCount 条 · '
      '内网 $carrierNetCount 条 · 公网 $publicCount 条'
      '${duplicates > 0 ? ' · 去重 $duplicates 条' : ''}'
      '${skipped > 0 ? ' · 跳过 $skipped 条无效地址' : ''}';
}

/// 用户导入的地址表快照（版本 + 日期 + 上一版，用于回滚）。
class AddressTableSnapshot {
  const AddressTableSnapshot({
    required this.text,
    required this.version,
    required this.updatedAt,
    required this.previousText,
    required this.previousVersion,
  });

  final String text;
  final String version;
  final String updatedAt;
  final String previousText;
  final String previousVersion;

  static const int maxTextBytes = 512 * 1024;

  bool get hasPrevious => previousText.isNotEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
        'text': text,
        'version': version,
        'updatedAt': updatedAt,
        'previousText': previousText,
        'previousVersion': previousVersion,
      };

  static AddressTableSnapshot? fromJson(Map<String, dynamic> raw) {
    final text = raw['text'];
    if (text is! String || text.isEmpty || text.length > maxTextBytes) return null;
    String s(Object? v) => v is String && v.length <= 256 ? v : '';
    return AddressTableSnapshot(
      text: text,
      version: s(raw['version']),
      updatedAt: s(raw['updatedAt']),
      previousText: s(raw['previousText']),
      previousVersion: s(raw['previousVersion']),
    );
  }

  /// 保存新一版时把当前版本降为「上一版」。
  AddressTableSnapshot next(String newText, String newVersion, String date) =>
      AddressTableSnapshot(
        text: newText,
        version: newVersion,
        updatedAt: date,
        previousText: text,
        previousVersion: version,
      );

  AddressTableSnapshot rollback() => AddressTableSnapshot(
        text: previousText,
        version: previousVersion,
        updatedAt: updatedAt,
        previousText: '',
        previousVersion: '',
      );
}

class CarrierPlaylistImporter {
  const CarrierPlaylistImporter();

  static const int maxInputBytes = 512 * 1024;
  static const int maxLines = 20000;

  CarrierImportResult import({
    required String text,
    required LiveChannelType type,
    required ChannelSettings settings,
    Carrier carrier = Carrier.unknown,
    AddressTableFormat format = AddressTableFormat.m3u,
    String version = '',
  }) {
    if (text.trim().isEmpty) {
      return const CarrierImportResult(
        channels: <LiveChannel>[],
        multicastCount: 0,
        carrierNetCount: 0,
        publicCount: 0,
        skipped: 0,
        duplicates: 0,
        error: '地址表为空',
      );
    }
    if (text.length > maxInputBytes) {
      return const CarrierImportResult(
        channels: <LiveChannel>[],
        multicastCount: 0,
        carrierNetCount: 0,
        publicCount: 0,
        skipped: 0,
        duplicates: 0,
        error: '地址表超过 512KB 上限',
      );
    }

    final rewriter = UdpxyRewriter(
      host: settings.udpxyHost,
      port: settings.udpxyPort,
    );
    final rawByUrl = <String, (String, String)>{};
    var skipped = 0;
    var duplicates = 0;

    // 只重写「地址行」：#EXTINF / #genre# / 注释一律原样保留，
    // 否则 m3u 的属性和分组会被破坏。
    String rewriteLine(String line) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) return line;
      final addr = format == AddressTableFormat.nameUrl
          ? (trimmed.contains(',') ? trimmed.split(',').last.trim() : '')
          : trimmed;
      if (addr.isEmpty) return line;
      final parsed = UdpxyRewriter.parseMulticast(addr);
      if (parsed == null) {
        // 非组播地址：carrier_net 清单里的 http(s) 地址合法，原样保留；
        // multicast 清单里出现 http 说明用户选错了清单类型，跳过并计数。
        if (type == LiveChannelType.multicast &&
            !LiveCatalogService.isAcceptableStreamUrl(addr)) {
          skipped++;
          return '';
        }
        return line;
      }
      if (type != LiveChannelType.multicast) return line;
      final url = rewriter.rewriteRaw(addr);
      if (url == null) {
        skipped++;
        return '';
      }
      rawByUrl.putIfAbsent(url, () => (addr, parsed.$1));
      return format == AddressTableFormat.nameUrl
          ? line.replaceAll(addr, url)
          : url;
    }

    final rewritten = const LineSplitter().convert(text).take(maxLines).map(rewriteLine).join('\n');
    final parsed = format == AddressTableFormat.m3u
        ? LiveCatalogService.parseM3U(rewritten, scanLines: maxLines)
        : LiveCatalogService.parseNameUrl(rewritten, scanLines: maxLines);

    final out = <LiveChannel>[];
    var multicastCount = 0;
    var carrierCount = 0;
    var publicCount = 0;
    final seen = <String>{};

    for (final c in parsed) {
      final streams = <LiveStream>[];
      for (final s in c.streams) {
        final key = '${c.id}|${s.url}';
        if (!seen.add(key)) {
          duplicates++;
          continue;
        }
        final raw = rawByUrl[s.url];
        final effectiveType = type == LiveChannelType.multicast && raw == null
            ? LiveChannelType.public
            : type;
        LiveStream tagged = s;
        if (effectiveType != LiveChannelType.public || raw != null) {
          tagged = LiveStream(
            url: s.url,
            label: s.label,
            qualityRank: s.qualityRank,
            headers: s.headers,
            decodeVerified: s.decodeVerified,
            resolverUrl: s.resolverUrl,
            channelType: effectiveType,
            carrier: effectiveType == LiveChannelType.carrierNet
                ? carrier
                : Carrier.unknown,
            rawAddr: raw?.$1,
            transport: raw?.$2,
          );
        }
        switch (tagged.channelType) {
          case LiveChannelType.multicast:
            multicastCount++;
          case LiveChannelType.carrierNet:
            carrierCount++;
          case LiveChannelType.public:
            publicCount++;
        }
        streams.add(tagged);
      }
      if (streams.isEmpty) continue;
      out.add(LiveChannel(
        id: c.id,
        name: c.name,
        group: c.group,
        badge: c.badge,
        categories: c.categories,
        tvgId: c.tvgId,
        streams: streams,
      ));
    }

    // 选了「组播清单」却一条组播线路都没解析出来，必须明确报错。
    // 否则用户遇到的是「导入显示成功、列表里却只有一条公网线路」——
    // 网关没配 / 地址表选错类型时不能静默降级成一个看似成功的结果。
    if (out.isEmpty || (type == LiveChannelType.multicast && multicastCount == 0)) {
      return CarrierImportResult(
        channels: <LiveChannel>[],
        multicastCount: multicastCount,
        carrierNetCount: carrierCount,
        publicCount: publicCount,
        skipped: skipped,
        duplicates: duplicates,
        error: type == LiveChannelType.multicast && !rewriter.isValid
            ? '未配置合法的局域网 udpxy 主机与端口，无法重写组播地址'
            : type == LiveChannelType.multicast
                ? '清单中没有有效组播地址（检查是否选错了清单类型）'
                : '没有解析出可用频道（检查清单格式与地址）',
      );
    }
    return CarrierImportResult(
      channels: out,
      multicastCount: multicastCount,
      carrierNetCount: carrierCount,
      publicCount: publicCount,
      skipped: skipped,
      duplicates: duplicates,
      error: null,
    );
  }
}
