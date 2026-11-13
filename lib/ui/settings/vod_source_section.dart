import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/services.dart';
import '../../app/theme.dart';
import '../../data/onboarding/vod_source_address.dart';
// 同时带出 `VodUpdateCadence`（updater 里 export 了档位表）与
// `VodIndexUpdateOutcome`，不必再单独 import 档位文件。
import '../../data/onboarding/vod_index_updater.dart';
import '../../features/vod/vod_build_progress.dart';
import '../../features/vod/vod_index_gate.dart';

/// 设置页「点播源」区块（第二十一次修：极简单输入框；第二十四次修：去版本号）。
///
/// 界面上只剩**一个第三方片源接口地址输入框**、一行免责版权说明、一个
/// 「立即获取最新片源」入口、一组自动更新间隔档位与一行状态。原先的三个
/// 开关、七条候选地址、自定义地址列表，以及三个并列的动作按钮全部去掉 ——
/// 那些控件之间互相牵连（先开开关 → 再选候选 → 再点确认），电视遥控器上
/// 根本走不完。
///
/// 底层口径一个没丢：
///  * 输入完成（回车 / 输入框失焦）即自动提交给 [VodIndexGateController.submit]，
///    沿用 `decideVodIndexSubmit` 的**原有判断逻辑**：填的地址与默认索引
///    记录的地址一致 ⇒ 直接复用默认记录、零网络；否则按该地址取片源生成
///    **它自己那份**目录文件，不覆盖任何其它接口，也不影响默认索引；
///  * 明文 http 仍需一次显式确认（确认动作本身即放行），风险声明检查保留；
///  * `enabled` / `allowInsecureHttp` / `allowExternalCode` / `customUrls`
///    等既有设定字段继续沿用，界面只是不再暴露开关。
class VodSourceAddressSection extends StatefulWidget {
  const VodSourceAddressSection({super.key, required this.services});

  final ShunboServices services;

  @override
  State<VodSourceAddressSection> createState() =>
      _VodSourceAddressSectionState();
}

class _VodSourceAddressSectionState extends State<VodSourceAddressSection> {
  VodSourceAddressSettings _settings = VodSourceAddressSettings.defaults;
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  String? _note;
  String? _updateNote;
  bool _busy = false;
  bool _updating = false;
  bool _loaded = false;

  /// 最近一条状态是不是**失败**（决定用告警色而不是灰字）。
  bool _noteIsError = false;

  /// 正在生成新接口索引时的进度（来自闸门，第二十六次修）。
  VodBuildProgress? _progress;

  /// 一次获取已经跑了多久。只用来在进度条下面显示「已用 N 秒」——
  /// 用户判断「还在动还是卡死了」靠的就是这个数在涨。
  final Stopwatch _busyWatch = Stopwatch();
  Timer? _tick;
  int _elapsedSec = 0;

  /// 同一地址不重复提交：`onSubmitted` 与失焦会在一次输入里各触发一次。
  String _lastSubmitted = '';

  @override
  void initState() {
    super.initState();
    _input.addListener(_onInputChanged);
    _focus.addListener(_onFocusLost);
    widget.services.vodIndexGate.addListener(_onGateChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _input.removeListener(_onInputChanged);
    _focus.removeListener(_onFocusLost);
    widget.services.vodIndexGate.removeListener(_onGateChanged);
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onInputChanged() {
    // 文本一变就作废「上次已提交」标记：用户改了地址（哪怕改回去）
    // 都允许重新提交；文本没变的「回车 + 失焦」则只提交一次。
    if (_input.text.trim() != _lastSubmitted) _lastSubmitted = '';
    if (mounted) setState(() {});
  }

  void _onGateChanged() {
    if (!mounted) return;
    final p = widget.services.vodIndexGate.buildProgress;
    // 进度只有闸门那一份是真值：`building` 期间由 `VodSession` 逐批上报，
    // 结束（成功 / 失败 / 超时）后闸门自己清成 null，这里跟着收掉进度条。
    if (p == _progress) return;
    setState(() => _progress = p);
  }

  /// 开始刷「已用 N 秒」。只在一次获取进行中跑，结束一律走 [_stopTicker]。
  void _startTicker() {
    _busyWatch
      ..reset()
      ..start();
    _elapsedSec = 0;
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final sec = _busyWatch.elapsed.inSeconds;
      if (sec != _elapsedSec) setState(() => _elapsedSec = sec);
    });
  }

  void _stopTicker() {
    _busyWatch.stop();
    _tick?.cancel();
    _tick = null;
  }

  void _onFocusLost() {
    if (!_focus.hasFocus) unawaited(_submitAddress());
  }

  Future<void> _load() async {
    final loaded = await widget.services.vodSourceStore.load();
    if (!mounted) return;
    // 需求：接口地址输入框**不预填已保存的地址**，默认留空。
    // 这里显式清一次，防止以后有人为了「省一次输入」把 selectedUrl 灌进来。
    _input.clear();
    setState(() {
      _settings = loaded;
      _loaded = true;
    });
  }

  Future<void> _save(VodSourceAddressSettings next) async {
    setState(() => _settings = next);
    await widget.services.vodSourceStore.save(next);
  }

  VodAddressCheck _check(String url) => validateVodSourceAddress(url,
      allowInsecureHttp: _settings.allowInsecureHttp);

  /// 明文 http 的显式确认。这一下点击**就是**「显式放行」本身：
  /// 只对当前这条点播源生效，不碰直播，也不改 1.0.4 的 E9 导入策略。
  /// 界面上不再放开关，确认框就是唯一的放行入口。
  Future<bool?> _confirmInsecure(String url) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('这条地址是明文 http', style: TextStyle(fontSize: 16)),
          content: Text(
            '$url\n\n'
            '明文传输的内容可能被中间人替换。放行只对这一条点播源生效，'
            '不会改变直播链路，也不会放开 1.0.4 的链接导入策略。',
            style: const TextStyle(fontSize: 12, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('放行并获取'),
            ),
          ],
        ),
      );

  /// 输入完成后**自动**获取片源索引并落本地。
  ///
  /// 判断逻辑完全交给既有闸门（`decideVodIndexSubmit`）：
  ///  * 地址 == 默认索引记录地址 ⇒ `loadExisting`，直接复用默认记录、零网络；
  ///  * 该地址已有独立目录 ⇒ `loadExisting`，直接加载、不重复获取；
  ///  * 其余 ⇒ `rebuild`，按地址取片源、写进**该地址专属**的目录文件。
  Future<void> _submitAddress() async {
    final raw = _input.text.trim();
    if (raw.isEmpty || _busy || _updating || !_loaded) return;
    if (raw == _lastSubmitted) return;
    if (isKnownUnusableSource(raw)) {
      final c = kVodSourceCandidates.firstWhere((x) => x.url == raw);
      setState(() => _note =
          '${c.label}：${c.unavailableReason}。请改用带 type:1 采集接口的地址。');
      return;
    }
    var insecure = _settings.allowInsecureHttp;
    final check = _check(raw);
    if (check.verdict == VodAddressVerdict.plainHttp) {
      final agreed = await _confirmInsecure(raw);
      if (agreed != true) return;
      insecure = true;
      await _save(_settings.copyWith(allowInsecureHttp: true));
    } else if (!check.acceptable) {
      setState(() => _note = '未获取：${check.reason}');
      return;
    }
    if (!widget.services.onboarding.state.disclaimerAccepted) {
      setState(() => _note = '请先阅读并接受风险声明，才能接入第三方点播数据');
      return;
    }
    _lastSubmitted = raw;
    setState(() {
      _busy = true;
      _noteIsError = false;
      _progress = null;
      _note = '正在校验接口地址与本地片源索引目录…';
    });
    _startTicker();
    VodIndexGateVerdict verdict;
    try {
      verdict = await widget.services.vodIndexGate.submit(
        raw,
        allowInsecureHttp: insecure,
      );
    } catch (e) {
      // 兜底：不管底层抛什么，状态都要收拾干净 —— 界面绝不允许停在
      // 一条永远不动的进度条上（用户红标「不能死循环」）。
      _stopTicker();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
        _noteIsError = true;
        _lastSubmitted = '';
        _note = '获取失败：$e，可改地址或稍后重试';
      });
      return;
    }
    _stopTicker();
    final saved = await widget.services.vodSourceStore.load();
    if (!mounted) return;
    setState(() {
      _settings = saved;
      _busy = false;
      _progress = null;
      // 失败不留「已提交」标记：输入内容没变也能失焦重试。
      if (!verdict.ready) _lastSubmitted = '';
      _noteIsError = !verdict.ready;
      _note = verdict.ready
          ? (verdict.origin == VodIndexOrigin.builtin
              ? '与当前片源索引地址一致，已直接复用当前记录（未发起网络请求）'
              : '已按该接口生成独立索引目录：${verdict.note}')
          : verdict.note;
    });
  }

  /// 手动获取最新片源：与定时更新**同一条**追加合并链路。
  /// force 只跳过周期判断，让位 / 单飞两道闸照旧生效。
  ///
  /// 第二十三次修：默认接口不再被跳过（用户红标「不是只读不能获取」）——
  /// 它写的是本地增补文件，随包索引依旧只读。
  Future<void> _fetchLatest() async {
    if (_updating || _busy) return;
    setState(() {
      _updating = true;
      _updateNote = '正在获取最新片源（只取各站最新一页）…';
    });
    _startTicker();
    VodIndexUpdateOutcome result;
    try {
      result = await widget.services.vodIndexUpdater.runOnce(force: true);
    } catch (e) {
      // 同上：`runOnce` 内部已经兜了一层，这里再兜一层 —— 只要按钮亮了
      // 就一定会有结论，绝不留下一个转不停的图标。
      result = VodIndexUpdateOutcome(
        status: VodIndexUpdateStatus.failed,
        message: '片源更新失败：$e',
      );
    }
    _stopTicker();
    if (!mounted) return;
    setState(() {
      _updating = false;
      _updateNote = result.message;
    });
  }

  /// 切换自动更新间隔（第二十四次修）。
  ///
  /// 只落盘 + 刷新本区块：调度器下一次 tick 会读到新档位，不必重启定时器，
  /// 也不做任何网络请求 —— 档位不该顺手触发一次取数。
  Future<void> _selectCadence(VodUpdateCadence cadence) async {
    if (_settings.updateIntervalDays == cadence.days) return;
    await _save(_settings.copyWith(updateIntervalDays: cadence.days));
  }

  /// 状态区：**进行中给进度条，结束给一句话**（第二十六次修）。
  ///
  /// 用户红标：「当在获取新接口片源索引时，最好有一个进度条」。
  /// 两种进行中分开处理：
  ///  * 按新接口生成目录 —— 闸门逐批上报站点数，走**确定**进度条；
  ///  * 立即获取最新片源 —— 链路只给结论不给计数，走**不确定**进度条，
  ///    但下面那行「已用 N 秒」一直在涨，用户能看出没卡死。
  Widget _statusArea() {
    final p = _progress;
    // 有进度就渲染进度条 —— 不要求本页发起的这次获取（用户也可能是在点播页
    // 的输入框里提交的），闸门里的进度是全局唯一的那一份。
    final building = p != null;
    if (building || _updating) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: _updating ? null : p?.fraction,
              minHeight: 3,
              backgroundColor: AppTheme.divider,
              valueColor:
                  const AlwaysStoppedAnimation<Color>(AppTheme.accent),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            _updating
                ? (_updateNote ?? '正在获取最新片源…')
                : (p?.note ?? '正在获取片源…'),
            style: const TextStyle(
                fontSize: 11, color: AppTheme.textSecondary, height: 1.3),
          ),
          if (_elapsedSec > 0) ...<Widget>[
            const SizedBox(height: 2),
            Text('已用 $_elapsedSec 秒',
                style: const TextStyle(
                    fontSize: 10, color: AppTheme.textTertiary)),
          ],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_note != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(_note!,
              style: TextStyle(
                fontSize: 11,
                height: 1.3,
                color: _noteIsError ? AppTheme.warn : AppTheme.textSecondary,
              )),
        ],
        if (_updateNote != null) ...<Widget>[
          const SizedBox(height: 4),
          Text(_updateNote!,
              style: const TextStyle(
                  fontSize: 11, color: AppTheme.textSecondary)),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final typed = _input.text.trim();
    final inputCheck = _check(typed);
    final current = _settings.effectiveUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _input,
          focusNode: _focus,
          // 第二十六次修：提交期间用 `readOnly` 而不是 `enabled: false`。
          // 置灰会让输入框**丢焦点**（焦点一丢就触发一次失焦提交，虽然被
          // `_busy` 挡住，但光标会闪一下），readOnly 既禁编辑又保住焦点。
          readOnly: _busy || _updating,
          decoration: const InputDecoration(
            isDense: true,
            labelText: '第三方片源接口地址（输入完成后自动获取）',
            hintText: 'https://example.com/vod.json',
            // 第二十三次修（用户红标「去除」）：这里原本还挂着一行说明
            // （讲回填与复用默认记录的），删掉 —— 输入框下面紧跟状态行
            // 「当前生效：…」，再挂一行解释只是噪音，还把这格撑高。
            border: OutlineInputBorder(),
          ),
          style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
          onSubmitted: (_) => unawaited(_submitAddress()),
        ),
        const SizedBox(height: 4),
        // 第二十四次修（用户红标「加一个简短的免责版权说明」）：
        // 原来这行位置放的是「默认留空 / 复用默认记录」这类技术说明，
        // 第二十三次修删掉后一直空着。现在按红标放免责与版权归属。
        const Text(
          '仅聚合第三方公开接口的索引信息，不提供、不存储、不传播任何影音内容；'
          '片源与版权归各来源站点所有，请自行确认来源合法。',
          style: TextStyle(
              fontSize: 11, color: AppTheme.textTertiary, height: 1.4),
        ),
        const SizedBox(height: 6),
        Text(
          typed.isEmpty
              ? '当前生效：${current.isEmpty ? '默认片源索引（随包）' : current}'
              : '输入地址校验：${inputCheck.reason}',
          style: TextStyle(
            fontSize: 11,
            color: typed.isEmpty || inputCheck.ok
                ? AppTheme.textSecondary
                : AppTheme.warn,
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _updating || _busy ? null : () => unawaited(_fetchLatest()),
          icon: _updating
              ? const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.system_update_alt_rounded, size: 16),
          label: Text(_updating ? '获取中…' : '立即获取最新片源',
              style: const TextStyle(fontSize: 12)),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.accent,
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        const SizedBox(height: 12),
        // 第二十四次修：用户红标「可以手动设定更新时间，比如一天、三天、
        // 一周、一月、一季度、半年、一年」—— 七档就是下面这排选项，
        // 顺序即 `VodUpdateCadence.values` 的顺序，不按命中数或常用度重排。
        const Text('自动更新间隔',
            style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final c in VodUpdateCadence.values)
              _CadenceChip(
                cadence: c,
                selected: _settings.updateIntervalDays == c.days,
                enabled: _loaded,
                onTap: () => unawaited(_selectCadence(c)),
              ),
          ],
        ),
        _statusArea(),
      ],
    );
  }
}

/// 一档自动更新间隔。做成独立小组件而不是 `ChoiceChip`：
/// 设置页是深色底，`ChoiceChip` 的默认边框 / 勾选标记会带一层 Material 配色，
/// 在电视上看着比正文还亮；这里只保留「选中 = 描边 + 淡底」。
class _CadenceChip extends StatelessWidget {
  const _CadenceChip({
    required this.cadence,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final VodUpdateCadence cadence;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: selected ? AppTheme.accentDim : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: selected ? AppTheme.accent : AppTheme.divider,
              ),
            ),
            child: Text(
              cadence.label,
              style: TextStyle(
                fontSize: 11,
                color: selected ? AppTheme.textPrimary : AppTheme.textSecondary,
              ),
            ),
          ),
        ),
      );
}
