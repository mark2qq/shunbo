import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/form_factor.dart';
import '../../app/services.dart';
import '../../app/startup_trace.dart';
import '../../app/theme.dart';
import '../../core/player/player_bootstrap.dart';
import '../../platform/version_compat.dart';
import 'channel_section.dart';
import '../../features/vod/vod_catalog.dart';

/// 设置页。
///
/// 定位：**所有手动配置都收在这里，主流程一次都不打断**。
/// 频道表、片库、播放内核全部已内置并自动就绪，用户不进来也能正常看；
/// 进来的人通常只有两类——想换源的进阶用户，和来找问题原因的。
///
/// [advancedBuilder] 是原开发调试面板的入口（换源模拟、投屏、进度演示等）。
/// 用 builder 透传而不是直接 import，是为了让本页不依赖 `main.dart` 的装配细节，
/// 也避免出现「设置页 ↔ 首页」的循环引用。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.services,
    this.advancedBuilder,
  });

  final ShunboServices services;
  final WidgetBuilder? advancedBuilder;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _reloading = false;
  bool _syncing = false;
  String? _note;

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    final live = s.live;
    final ff = s.formFactor;
    final build = s.buildInfo;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          // R1：形态判定结果 + 三个手动选项。放在最上面，因为「遥控器点不动」
          // 是第一现场问题，用户被误导到别的设置项里只会更困惑。
          _Section(
            title: '屏幕形态',
            children: [
              _InfoRow(
                label: '当前形态',
                value: ff.report.effective.form.label +
                    (ff.report.overridden ? '（已手动指定）' : '（自动判定）'),
              ),
              _InfoRow(label: '判定依据', value: ff.report.effective.rule.label),
              _InfoRow(
                label: '探测信号',
                value: 'uiMode 电视=${ff.report.signal.uiModeTelevision ? '是' : '否'} · '
                    '触摸屏=${ff.report.signal.hasTouchscreen ? '有' : '无'} · '
                    '方向键=${ff.report.signal.hasDpad ? '有' : '无'}',
              ),
              if (ff.report.isTv)
                const _Hint(
                  '电视形态：锁定横屏、隐藏系统栏、导航常驻，全部操作可用方向键/确认键/返回键完成。'
                  '投屏入口在电视形态下不显示（本机就是输出端）。',
                )
              else
                const _Hint(
                  '手机形态：可竖屏浏览，进入播放自动横屏全屏；支持触摸手势与投屏。',
                ),
              const SizedBox(height: 6),
              for (final p in FormFactorPreference.values)
                RadioListTile<FormFactorPreference>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: p,
                  // ignore: deprecated_member_use
                  groupValue: ff.preference,
                  // ignore: deprecated_member_use
                  onChanged: (v) async {
                    if (v == null) return;
                    await ff.setPreference(v);
                    if (mounted) setState(() {});
                  },
                  title: Text(p.label, style: const TextStyle(fontSize: 14)),
                  subtitle: p == FormFactorPreference.auto
                      ? const Text(
                          '按系统 UI 模式与输入设备自动判定（推荐）',
                          style: TextStyle(fontSize: 11, color: AppTheme.textTertiary),
                        )
                      : null,
                ),
              const _Hint(
                '判定不依赖屏幕分辨率：误把 4K 手机当电视会藏掉触摸交互，'
                '所以只有在「系统声明为电视」或「无触摸屏且有方向键」时才进电视形态。'
                '遇到误判（例如电视盒子接了触摸屏），在这里强制指定即可。',
              ),
            ],
          ),
          _Section(
            title: '电视直播',
            children: [
              _InfoRow(label: '频道表', value: live.sourceLabel),
              _InfoRow(label: '频道数', value: '${live.channels.length}'),
              _InfoRow(label: '当前频道', value: live.current?.name ?? '未选台'),
              if (live.warnings.isNotEmpty)
                _InfoRow(
                  label: '降级说明',
                  value: live.warnings.first,
                  warning: true,
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _reloading ? null : _reloadChannels,
                    icon: _reloading
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded, size: 18),
                    label: Text(_reloading ? '正在拉取…' : '重新获取频道表'),
                  ),
                  const SizedBox(width: 10),
                  TextButton(
                    onPressed: () => unawaited(live.retry()),
                    child: const Text('重连当前台'),
                  ),
                ],
              ),
              const _Hint(
                '频道表会自动从公开索引获取，失败时回退到内置清单。'
                '这一步只是手动重试，平时不需要点。',
              ),
            ],
          ),
          // 运营商通道：档位 C 默认关闭组播、自动识别出口运营商、地址表只由
          // 用户自行导入。诊断三项也放在这一组，方便一次看清「为什么没用内网源」。
          ChannelSettingsSection(services: s),
          _Section(
            title: '播放',
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: s.queue.autoNext,
                onChanged: (v) async {
                  await s.queue.setAutoNext(v);
                  if (mounted) setState(() {});
                },
                title: const Text('看完自动播放下一集', style: TextStyle(fontSize: 14)),
                subtitle: const Text(
                  '只对多集内容生效；最后一集不会重播。',
                  style: TextStyle(fontSize: 11, color: AppTheme.textTertiary),
                ),
              ),
              _InfoRow(label: '播放内核', value: playerBackendLabel(s.player)),
            ],
          ),
          _Section(
            title: '跨端续播',
            children: [
              const _Hint('进度只保存「去广告后的内容坐标」，换设备、换源都能对齐到同一位置。'),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _syncing ? null : _syncNow,
                icon: _syncing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync_rounded, size: 18),
                label: Text(_syncing ? '正在同步…' : '立即同步一次'),
              ),
            ],
          ),
          _Section(
            title: '片库',
            children: [
              _InfoRow(label: '点播片源', value: VodCatalog.sourceId),
              _InfoRow(
                label: '片库规模',
                value: '电影 ${VodCatalog.inSection(VodSection.movies).length} · '
                    '电视剧 ${VodCatalog.inSection(VodSection.series).length} · '
                    '纪录片 ${VodCatalog.inSection(VodSection.documentaries).length}',
              ),
              const _Hint(
                '内置片库只包含可公开分发的素材（Blender 开源影片、公开示例视频），'
                '随包分发不涉及授权问题。接入自有片源请走「高级工具」里的源配置导入。',
              ),
            ],
          ),
          if (widget.advancedBuilder != null)
            _Section(
              title: '高级',
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('高级工具与源配置', style: TextStyle(fontSize: 14)),
                  subtitle: const Text(
                    '外部源导入、换源对齐演示、投屏、诊断轨迹',
                    style: TextStyle(fontSize: 11, color: AppTheme.textTertiary),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded, size: 20),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: widget.advancedBuilder!),
                  ),
                ),
              ],
            ),
          // R10：诊断三件套 —— 形态判定结果、判定依据、渠道与版本。
          // 目的是「装错包或形态误判时用户能自查」，所以这里全是可直接复制的事实，
          // 不写「可能」「建议」这类猜测性文案。
          _Section(
            title: '关于与诊断',
            children: [
              _InfoRow(label: '应用', value: '顺播 shunbo ${build.versionName}'),
              _InfoRow(label: '渠道', value: build.channelLabel),
              _InfoRow(label: '版本号', value: build.displayName),
              _InfoRow(label: '应用标识', value: build.applicationId),
              _InfoRow(
                label: '设备架构',
                value: build.abis.isEmpty ? '未知' : build.abis.join(' / '),
              ),
              _InfoRow(label: '形态', value: ff.report.effective.form.label),
              _InfoRow(label: '判定依据', value: ff.report.effective.rule.label),
              if (ff.report.overridden)
                _InfoRow(
                  label: '自动判定',
                  value: '${ff.report.detected.form.label} · '
                      '${ff.report.detected.rule.label}',
                ),
              _InfoRow(label: '冷启动', value: StartupTrace.summary()),
              _InfoRow(label: '播放内核', value: playerBackendLabel(s.player)),
              // 版本兼容分支：把「比较对象 / 阈值 / 当前分支 / 判定依据」
              // 变成可直接复制的事实，报障时不用猜是不是版本门槛。
              _InfoRow(
                label: '运行分支',
                value: '${s.compatDecision.branch.label}'
                    '（${s.compatDecision.reason.label}）',
              ),
              _InfoRow(
                label: '版本比较',
                value: '$kVersionCompatSubject · '
                    'API < $kMinSupportedAndroidApi 进兼容分支'
                    '${s.compatDecision.apiLevel == null
                        ? ' · 读数未知'
                        : ' · 实测 ${s.compatDecision.apiLevel}'}',
              ),
              if (ff.isTv)
                const _InfoRow(
                  label: '投屏',
                  value: '电视形态不显示投屏入口（本机即输出端）',
                ),
              const SizedBox(height: 8),
              const _Hint(
                '渠道说明：完整版（com.shunbo.tv）为手机+电视主力包；'
                '精简版（com.shunbo.tv.lite）面向老设备，两个包可同机并存、数据互不影响。'
                '若「装上了但遥控器点不动」，多半是装成了精简版或形态被判成手机——'
                '先对照上方「判定依据」，再在上面的「屏幕形态」里强制指定。',
              ),
            ],
          ),
          _Section(
            title: '电视安装与保活',
            children: [
              const _Hint(
                '① 侧载入口：U 盘安装器（电视卫士/媒体中心里的「本地安装」）、'
                '应用市场的「本地安装」、部分机型的工厂菜单 ADB（默认关闭，需先开启开发者模式）。'
                '侧载前请允许「安装未知来源应用」。',
              ),
              const SizedBox(height: 8),
              const _Hint(
                '② 遥控器键值：菜单键与主页键常被系统占用。本应用不依赖这两个键——'
                '分类切换与频道列表都可用方向键到达；数字键直接跳台；返回键按层级退出。',
              ),
              const SizedBox(height: 8),
              const _Hint(
                '③ 后台保活：酷开、小米等系统会主动结束后台进程。播放期间应用会启用'
                '前台服务以降低被杀概率；更彻底的做法是在系统的「电池/应用管理」里'
                '把顺播加入白名单（允许后台运行、关闭省电限制）。',
              ),
              const SizedBox(height: 8),
              const _Hint(
                '④ 无 GMS 依赖：本应用不使用 Google 推送、账号、地图或播放服务，'
                '国内无 GMS 的机型可正常使用。',
              ),
              const SizedBox(height: 8),
              const _Hint(
                '⑤ 播放内核：以 libmpv 为主，系统内核（ExoPlayer）仅作兜底，'
                '任何能力判断都不依赖系统播放器。当前实际使用的内核见上方「播放内核」。',
              ),
            ],
          ),
          if (_note != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _note!,
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _reloadChannels() async {
    setState(() {
      _reloading = true;
      _note = null;
    });
    try {
      await widget.services.live.bootstrap(remote: true);
      if (!mounted) return;
      setState(() {
        _reloading = false;
        _note = '已更新：${widget.services.live.sourceLabel}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _reloading = false;
        _note = '拉取失败，仍使用当前频道表：$e';
      });
    }
  }

  Future<void> _syncNow() async {
    setState(() {
      _syncing = true;
      _note = null;
    });
    final result = await widget.services.syncEngine.sync();
    if (!mounted) return;
    setState(() {
      _syncing = false;
      _note = result.userMessage;
    });
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

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
  const _InfoRow({required this.label, required this.value, this.warning = false});

  final String label;
  final String value;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: AppTheme.textTertiary),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: warning ? AppTheme.warn : AppTheme.textPrimary,
              ),
            ),
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
        fontSize: 11,
        height: 1.6,
        color: AppTheme.textTertiary,
      ),
    );
  }
}
