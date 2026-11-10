import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/services.dart';
import '../../app/theme.dart';
import '../../data/onboarding/source_config_url.dart';
import '../../data/onboarding/source_trust.dart';
import '../../features/live/carrier_playlist_importer.dart';
import '../../features/live/channel_settings.dart';
import '../../features/live/live_channel.dart';
import '../../features/live/network_channel.dart';

/// 设置页「网络与通道」分组（研发方案 F9 / N6 / 14.8）。
///
/// 产品口径写死在这里，避免 UI 与策略层各说一套：
/// * 本户实测是**档位 C**（OTT 单播、无 电视专网、局域网无 udpxy），
///   所以组播默认关闭、默认无任何地址表，界面不引导用户去配一个不存在的网关；
/// * 运营商由 App 自动识别，只在识别不出来时才让用户手动覆盖；
/// * 内网 / 组播地址表只能由用户自行导入或订阅，安装包里一条都没有。
class ChannelSettingsSection extends StatefulWidget {
  const ChannelSettingsSection({super.key, required this.services});

  final ShunboServices services;

  @override
  State<ChannelSettingsSection> createState() => _ChannelSettingsSectionState();
}

class _ChannelSettingsSectionState extends State<ChannelSettingsSection> {
  late ChannelSettings _settings;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _subscription;
  late final TextEditingController _trustSecret;

  LiveChannelType _importType = LiveChannelType.carrierNet;
  Carrier _importCarrier = Carrier.unknown;
  AddressTableFormat _importFormat = AddressTableFormat.m3u;
  AddressTableSnapshot? _table;
  bool _busy = false;
  String? _note;
  String? _trustWarning;

  @override
  void initState() {
    super.initState();
    _settings = widget.services.live.channelPolicy.settings;
    _host = TextEditingController(text: _settings.udpxyHost);
    _port = TextEditingController(text: '${_settings.udpxyPort}');
    _subscription = TextEditingController(text: _settings.subscriptionUrl);
    _trustSecret = TextEditingController();
    unawaited(_loadTable());
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _subscription.dispose();
    _trustSecret.dispose();
    super.dispose();
  }

  Future<void> _loadTable() async {
    final t = await widget.services.channelStore.loadTable();
    if (!mounted) return;
    setState(() => _table = t);
  }

  Future<void> _run(Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      await body();
    } catch (e) {
      if (mounted) setState(() => _note = '操作失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(ChannelSettings next) async {
    final carrierChanged = next.carrierOverride != _settings.carrierOverride;
    _settings = next;
    widget.services.live.applyChannelSettings(next);
    await widget.services.channelStore.save(next);
    // 改了手动覆盖就立刻重判，让「当前识别为」与用户的选择同步；
    // 只改网关/端口时不做这一步，避免为一次端口编辑平白发一次归属请求。
    if (carrierChanged) await widget.services.live.refreshNetwork();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final live = widget.services.live;
    final diag = live.channelDiagnostics;
    final rows = diag.rows();
    return _Card(
      title: '网络与通道',
      children: [
        const _Hint(
          '本户为普通宽带 OTT 单播环境（无 电视专网口、局域网无组播转单播服务），'
          '因此组播默认关闭、不内置任何运营商地址表。开启前需路由器支持 '
          'udpxy / msd_lite 并自行导入地址表；不开启时播放行为与普通版完全一致。',
        ),
        const SizedBox(height: 10),
        for (final r in rows) _InfoRow(label: r.$1, value: r.$2),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('手动覆盖', style: TextStyle(fontSize: 13)),
            const SizedBox(width: 12),
            DropdownButton<Carrier>(
              value: _settings.carrierOverride,
              isDense: true,
              style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
              items: <Carrier>[
                Carrier.unknown,
                Carrier.chinaMobile,
                Carrier.chinaTelecom,
                Carrier.chinaUnicom,
              ]
                  .map((c) => DropdownMenuItem<Carrier>(
                        value: c,
                        child: Text(c == Carrier.unknown
                            ? '自动识别（推荐）'
                            : ChannelSettings.carrierLabel(c)),
                      ))
                  .toList(),
              onChanged: _busy
                  ? null
                  : (v) => _run(() => _save(_settings.copyWith(
                        carrierOverride: v ?? Carrier.unknown,
                      ))),
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        await live.refreshNetwork();
                        if (mounted) setState(() => _note = '已重新检测当前网络出口');
                      }),
              icon: _busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.network_check_rounded, size: 18),
              label: const Text('重新检测'),
            ),
          ],
        ),
        const Divider(height: 22),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _settings.multicastEnabled,
          onChanged: _busy
              ? null
              : (v) => _run(() => _save(_settings.copyWith(
                    multicastEnabled: v,
                    udpxyHost: _host.text.trim(),
                    udpxyPort: int.tryParse(_port.text.trim()) ?? 4022,
                  ))),
          title: const Text('电视组播通道', style: TextStyle(fontSize: 14)),
          subtitle: const Text(
            '仅在路由器已开启组播转单播时启用；默认关闭，不发起任何组播探测。',
            style: TextStyle(fontSize: 11, color: AppTheme.textTertiary),
          ),
        ),
        if (_settings.multicastEnabled) ...<Widget>[
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _host,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'udpxy 主机（仅局域网地址）',
                    hintText: '192.168.5.1',
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 1,
                child: TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '端口',
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                          final host = _host.text.trim();
                          final port = int.tryParse(_port.text.trim()) ?? 0;
                          if (!ChannelSettings.isValidUdpxyHost(host) ||
                              !_settings.copyWith(
                                      udpxyHost: host, udpxyPort: port)
                                  .multicastConfigured) {
                            setState(() => _note = '请填写合法的局域网网关地址与端口');
                            return;
                          }
                          await _save(_settings.copyWith(
                            multicastEnabled: true,
                            udpxyHost: host,
                            udpxyPort: port,
                          ));
                          await _checkMulticast(host, port);
                        }),
                icon: const Icon(Icons.router_rounded, size: 18),
                label: const Text('一键检测'),
              ),
              const _Hint('300ms 内主机响应 + 1.5s 内首包，两项都过才算可用。'),
            ],
          ),
        ],
        const Divider(height: 22),
        const Text('地址表（不内置，需自行导入或订阅）',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('类型', style: TextStyle(fontSize: 12)),
            DropdownButton<LiveChannelType>(
              value: _importType,
              isDense: true,
              style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
              items: const <DropdownMenuItem<LiveChannelType>>[
                DropdownMenuItem<LiveChannelType>(
                  value: LiveChannelType.carrierNet,
                  child: Text('运营商内网 CDN'),
                ),
                DropdownMenuItem<LiveChannelType>(
                  value: LiveChannelType.multicast,
                  child: Text('电视组播'),
                ),
              ],
              onChanged: (v) =>
                  setState(() => _importType = v ?? LiveChannelType.carrierNet),
            ),
            DropdownButton<AddressTableFormat>(
              value: _importFormat,
              isDense: true,
              style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
              items: const <DropdownMenuItem<AddressTableFormat>>[
                DropdownMenuItem<AddressTableFormat>(
                  value: AddressTableFormat.m3u,
                  child: Text('m3u'),
                ),
                DropdownMenuItem<AddressTableFormat>(
                  value: AddressTableFormat.nameUrl,
                  child: Text('两列文本'),
                ),
              ],
              onChanged: (v) => setState(
                  () => _importFormat = v ?? AddressTableFormat.m3u),
            ),
            if (_importType == LiveChannelType.carrierNet)
              DropdownButton<Carrier>(
                value: _importCarrier,
                isDense: true,
                style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
                items: <Carrier>[
                  Carrier.chinaMobile,
                  Carrier.chinaTelecom,
                  Carrier.chinaUnicom,
                ]
                    .map((c) => DropdownMenuItem<Carrier>(
                          value: c,
                          child: Text(ChannelSettings.carrierLabel(c)),
                        ))
                    .toList(),
                onChanged: (v) => setState(
                    () => _importCarrier = v ?? Carrier.chinaMobile),
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _subscription,
          decoration: const InputDecoration(
            isDense: true,
            labelText: '订阅地址（可选，公开 m3u）',
            hintText: 'https://…/江苏-移动.m3u',
            border: OutlineInputBorder(),
          ),
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _trustSecret,
          obscureText: true,
          decoration: const InputDecoration(
            isDense: true,
            labelText: '来源签名密钥（可选，发布者提供）',
            hintText: '填写后内容更新可凭签名自动放行；留空则每次变更需确认',
            border: OutlineInputBorder(),
          ),
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 6),
        _InfoRow(
          label: '订阅来源',
          value: widget.services.sourceTrust.statusOf(_subscription.text),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _run(_pasteImport),
              icon: const Icon(Icons.paste_rounded, size: 18),
              label: const Text('粘贴导入地址表'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _run(_fetchSubscription),
              icon: const Icon(Icons.cloud_download_rounded, size: 18),
              label: const Text('从订阅地址拉取'),
            ),
            if (_table?.hasPrevious ?? false)
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _run(_rollback),
                icon: const Icon(Icons.undo_rounded, size: 18),
                label: const Text('回滚上一版'),
              ),
          ],
        ),
        const SizedBox(height: 6),
        _InfoRow(
          label: '当前版本',
          value: (_table?.version.isEmpty ?? true)
              ? '尚未导入'
              : '${_table!.version}（${_table!.updatedAt}）',
        ),
        const _Hint(
          '地址表按「省 × 运营商」自行订阅；仅在自家网络内自用，不分享、不公开发布、'
          '不用于任何商业用途。识别失败或异网时这些线路自动不进候选，也不产生失败请求。',
        ),
        if (_note != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(_note!,
              style: const TextStyle(fontSize: 12, color: AppTheme.warn)),
        ],
      ],
    );
  }

  Future<void> _pasteImport() async {
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController();
        return AlertDialog(
          title: const Text('粘贴地址表'),
          content: SizedBox(
            width: 520,
            child: TextField(
              controller: ctrl,
              maxLines: 12,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '#EXTM3U\n#EXTINF:-1,CCTV-1 综合\nhttp://…',
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text),
              child: const Text('导入'),
            ),
          ],
        );
      },
    );
    if (text == null || text.trim().isEmpty) return;
    await _importText(text, source: '粘贴导入');
  }

  Future<bool> _confirmTrust(String reason) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('确认订阅来源'),
        content: Text(
          '$reason\n\n'
          '只在你信任该发布者、并确认这份地址表是你预期的清单时再继续。\n'
          '确认后 App 会固定内容摘要；以后内容变化会再次询问，'
          '除非发布者用你填写的密钥签名。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('确认并固定摘要'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _fetchSubscription() async {
    final url = _subscription.text.trim();
    if (!ChannelSettings.isValidSubscriptionUrl(url) || url.isEmpty) {
      setState(() => _note = '订阅地址不合法（只允许 http/https 且不含账号密码）');
      return;
    }
    final trust = widget.services.sourceTrust;
    final origin = sourceOriginOf(url);
    // 密钥只在用户本次真的填了才改写；留空时保留上次配置，避免误清空。
    if (origin != null && _trustSecret.text.trim().isNotEmpty) {
      await trust.setSecret(origin, _trustSecret.text);
      _trustSecret.clear();
    }
    final result = await fetchSourceConfigUrl(url);
    if (!result.ok || result.text == null) {
      setState(() => _note = '订阅下载失败：${result.message}');
      return;
    }
    // 下载成功 ≠ 内容可信：与源配置 URL 导入共用同一份信任库。
    final decision = await trust.check(
      url: url,
      text: result.text!,
      headers: result.headers,
    );
    if (decision.rejected) {
      setState(() => _note = '订阅未导入：${decision.reason}');
      return;
    }
    if (decision.needsApproval) {
      if (!await _confirmTrust(decision.reason)) {
        setState(() => _note = '已取消：来源未获确认');
        return;
      }
      final applied = await trust.approve(
        url: url,
        text: result.text!,
        headers: result.headers,
      );
      if (applied.rejected) {
        setState(() => _note = '订阅未导入：${applied.reason}');
        return;
      }
      if (!applied.persisted) {
        _trustWarning = '（信任记录未能落盘，重启后需重新确认）';
      }
    }
    await _save(_settings.copyWith(subscriptionUrl: url));
    await _importText(result.text!, source: '订阅 ${result.originLabel ?? ''}');
    if (_trustWarning != null && mounted) {
      setState(() => _note = '${_note ?? ''} $_trustWarning');
      _trustWarning = null;
    }
  }

  Future<void> _importText(String text, {required String source}) async {
    final result = CarrierPlaylistImporter().import(
      text: text,
      type: _importType,
      settings: _settings,
      carrier: _importCarrier,
      format: _importFormat,
    );
    if (!result.ok) {
      setState(() => _note = '导入失败：${result.error}');
      return;
    }
    final message = widget.services.live.importAddressTable(
      result.channels,
      label: source,
    );
    final version = DateTime.now().toIso8601String().split('T').first;
    final snapshot = (_table ?? const AddressTableSnapshot(
          text: '',
          version: '',
          updatedAt: '',
          previousText: '',
          previousVersion: '',
        ))
        .next(text, version, version);
    await widget.services.channelStore.saveTable(snapshot);
    await _save(_settings.copyWith(tableVersion: version));
    _table = snapshot;
    if (!mounted) return;
    setState(() => _note = '$message · ${result.summary}');
  }

  Future<void> _rollback() async {
    final previous = await widget.services.channelStore.rollback();
    if (previous == null) {
      setState(() => _note = '没有可回滚的上一版');
      return;
    }
    _table = previous;
    final result = CarrierPlaylistImporter().import(
      text: previous.text,
      type: _importType,
      settings: _settings,
      carrier: _importCarrier,
      format: _importFormat,
    );
    if (!result.ok) {
      setState(() => _note = '回滚的上一版无法解析：${result.error}');
      return;
    }
    final message = widget.services.live.importAddressTable(result.channels,
        label: '回滚 ${previous.version}');
    setState(() => _note = '$message，当前版本 ${previous.version}');
  }

  Future<void> _checkMulticast(String host, int port) async {
    final live = widget.services.live;
    final candidates = <LiveStream>[
      for (final c in live.channels)
        for (final s in c.streams)
          if (s.channelType == LiveChannelType.multicast) s,
    ];
    final result = await live.channelPolicy.checkMulticast(
      connect: () => _probeHost(host, port),
      firstPacket: () => candidates.isEmpty
          ? Future<bool>.value(false)
          : _probeFirstPacket(live.channelPolicy.rewriteIfNeeded(candidates.first)),
      candidates: candidates,
    );
    if (!mounted) return;
    final reason = live.channelDiagnostics.udpxyReason;
    setState(() => _note = result == ChannelUsable.usable
        ? '组播通道可用（连通 ${live.channelDiagnostics.udpxyMs}ms · '
            '首包 ${live.channelDiagnostics.firstPacketMs}ms）'
        : '组播通道${ChannelDiagnostics.usableLabel(result)}：$reason');
  }

  /// udpxy 主机连通性：只取 HTTP 状态，不读响应体（udpxy 根路径可能持续吐数据）。
  Future<bool> _probeHost(String host, int port) async {
    if (!ChannelSettings.isValidUdpxyHost(host)) return false;
    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = const Duration(milliseconds: 300)
        ..findProxy = (_) => 'DIRECT';
      final req = await client
          .getUrl(Uri.parse('http://$host:$port/'))
          .timeout(const Duration(milliseconds: 300));
      req.followRedirects = false;
      final resp = await req.close().timeout(const Duration(milliseconds: 300));
      return resp.statusCode > 0;
    } catch (_) {
      return false;
    } finally {
      // 强制关掉：拿到首包就断流，同一时刻只保留一路组播拉流，
      // 低端路由器被两路并发压垮是方案里点名的风险。
      client?.close(force: true);
    }
  }

  Future<bool> _probeFirstPacket(LiveStream stream) async {
    final uri = Uri.tryParse(stream.url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return false;
    }
    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = const Duration(milliseconds: 1500)
        ..findProxy = (_) => 'DIRECT';
      final req = await client.getUrl(uri);
      req.followRedirects = false;
      for (final entry in stream.headers.entries) {
        // 逐跳头由 HttpClient 自己管：让外部清单覆盖 Host/Content-Length
        // 既会抛异常，也可能把请求打到清单里伪造的另一台主机上。
        const hopByHop = <String>{
          'host',
          'range',
          'content-length',
          'connection',
          'proxy-authorization',
        };
        if (hopByHop.contains(entry.key.toLowerCase())) continue;
        try {
          req.headers.set(entry.key, entry.value);
        } catch (_) {
          // 单个畸形头不该让整次检测失败（清单是不可信输入）。
        }
      }
      final resp = await req.close().timeout(const Duration(milliseconds: 1500));
      final first = await resp.first.timeout(const Duration(milliseconds: 1500));
      return first.isNotEmpty;
    } catch (_) {
      return false;
    } finally {
      client?.close(force: true);
    }
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 8),
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(AppTheme.radius),
              border: Border.all(color: AppTheme.divider, width: 0.8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textTertiary)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 13, height: 1.4, color: AppTheme.textPrimary)),
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
          fontSize: 11, height: 1.6, color: AppTheme.textTertiary),
    );
  }
}
