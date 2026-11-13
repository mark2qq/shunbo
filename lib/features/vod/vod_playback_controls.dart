/// 点播播放页的控制逻辑（**纯 Dart**，不依赖 Flutter，裸 `dart run` 可回归）。
///
/// 为什么把这几行从 widget 里抽出来：位置夹取、相邻集、时钟文案、按键映射
/// 全是「算错了用户立刻能感觉到」的地方（快退到负数、最后一集还提示下一集、
/// 00:60 这种时间显示），但它们跟 UI 无关。抽成纯函数后可以在门禁里逐条锁死，
/// 不用起真机、不用截图。
library;

/// 快进 / 快退步长（秒）。10 秒是主流播放器的默认档：广告跳段、走神回看都够用，
/// 又不会一按就跳过一整段剧情。
const double kVodSeekStepSeconds = 10;

/// 每档音量（百分点）。
const double kVodVolumeStep = 5;

/// 控制条无操作自动隐藏的时间。
///
/// 4 秒是「遥控器按完还能看清按钮」与「别一直挡画面」的折中；
/// 主流播放器多在 3–5 秒区间。
const Duration kVodControlsIdleTimeout = Duration(seconds: 4);

/// 播放页右栏「影片详情」的**兜底**自动收缩时长（没有指针悬停时用）。
///
/// **8 秒**。这个值不是抄控制条的 4 秒：4 秒是「按完按钮让出画面」，
/// 而详情是**读**——标题、类型、两行简介，8 秒刚够读完一遍。
/// 主流播放器的信息层（Netflix 的 info、Plex 的侧栏、爱奇艺桌面端）
/// 都落在 5–10 秒这个区间，取中间偏长的一档，避免「还没看清就缩回去」。
///
/// 与 [kVodControlsIdleTimeout] 完全独立：控制条 4 秒淡出时，右栏还在；
/// 用户读详情不需要先唤出控制条。
///
/// 第二十三次修：鼠标用户走悬停（[kVodDetailHoverExitDelay]），这个 8 秒
/// 只剩两个用途 —— 刚进播放页的兜底，以及遥控器 / 触屏没有指针时的兜底。
const Duration kVodDetailIdleTimeout = Duration(seconds: 8);

/// 指针移出右栏后多久收缩。
///
/// **1.2 秒**，与左侧导航栏 `_scheduleSideHide` 的离栏延迟完全一致
/// （第二十三次修，用户红标「参考左栏的模式」）。留一点延迟是为了
/// 「移出去又移回来」时不闪：光标擦边过去，面板不该跟着抖一下。
const Duration kVodDetailHoverExitDelay = Duration(milliseconds: 1200);

/// 右栏宽度上下限。
///
/// 下限 340 px 保证标题 + 两行简介不被挤成「一字一行」；
/// 上限 440 px 保证 1920 宽下画面仍占七成以上（右栏是信息，不是主角）。
///
/// 第二十四次修：原来收起后还留一条 44 px 的「详情」竖条，用户红标
/// 「隐藏后还会有详情条，要参考左栏完全隐藏」—— 竖条整个删掉，收起就是
/// 整块滑出屏幕（与左栏 `left: -188` 同构），改由 [kVodDetailSlideDuration]
/// 决定滑动时长、由右侧边缘热区负责重新呼出。
const double kVodDetailMinWidth = 340;
const double kVodDetailMaxWidth = 440;

/// 右栏滑入 / 滑出屏幕的时长。
///
/// **240 ms**，与左侧导航栏 `AnimatedPositioned` 完全同档 —— 两块侧栏在同一个
/// 播放页上，收放节奏不一致会显得右边「拖着走」。
const Duration kVodDetailSlideDuration = Duration(milliseconds: 240);

/// 播放页「选集」右栏无响应多久自动收起（第二十八次修，用户红标「6 秒」）。
///
/// 6 秒不是随手取的：这个抽屉是**第二十六次修**里唯一还留着常驻关闭按钮的
/// 浮层，用户的意思是「它跟控制条一样该自己让开画面」。控制条是 4 秒
/// （[kVodControlsIdleTimeout]），详情右栏读文字要 8 秒（[kVodDetailIdleTimeout]），
/// 选集夹在中间 —— 扫一眼集数标题 6 秒够用，又不至于看完一集还在挡画面。
///
/// **「无响应」的口径**：指针移动 / 点击 / 滚轮 / 列表滚动 / 焦点落入 / 按键，
/// 任意一种都会把计时器重置（见 `PanelIdleHider`）。所以「鼠标停在栏上不动」
/// 也会被收起 —— 与左栏控制条、右栏详情同口径：静止即让位。
const Duration kVodEpisodeIdleHide = Duration(seconds: 6);

/// 按视口宽度算右栏展开宽度：取 32%，夹在 [kVodDetailMinWidth, kVodDetailMaxWidth]。
///
/// 用比例而不是固定像素：1280 的小窗给 440 会挡掉三分之一画面，
/// 而 2560 的屏给 340 又读不清简介。
double vodDetailWidth(double viewportWidth) {
  if (!viewportWidth.isFinite || viewportWidth <= 0) return kVodDetailMinWidth;
  final w = viewportWidth * 0.32;
  if (w < kVodDetailMinWidth) return kVodDetailMinWidth;
  if (w > kVodDetailMaxWidth) return kVodDetailMaxWidth;
  return w;
}

/// 右栏详情面板的输入来源。展开 / 收缩、以及 8 秒计时是否重置都由它决定。
enum VodDetailInput {
  /// 刚进入播放页（点卡片直连播放）。
  enterPlayback,

  /// 指针在面板内部（移动、滚动、点按钮）。
  pointerOnPanel,

  /// 指针移进画面**右边缘热区**（或点在热区上）。
  ///
  /// 第二十四次修：右栏收起后整块滑出屏幕，屏幕上没有可点的竖条了，
  /// 所以「重新呼出」只剩两个入口 —— 右边缘热区（[EdgeRevealHandle]）
  /// 与 I / D / 信息键。这个枚举值就是热区那一路。
  pointerOnEdge,

  /// 指针**移出**右栏（第二十三次修，与左栏 onExit 同一语义）：
  /// 延迟 [kVodDetailHoverExitDelay] 后收缩。
  pointerLeftPanel,

  /// 按 I / D / 信息键。
  toggleKey,

  /// 指针在画面其他位置（不在右栏）。只刷新计时，不改变展开状态。
  pointerElsewhere,

  /// 8 秒无操作到点。
  idleTimeout,
}

/// 状态转移：给定当前是否展开与一次输入，返回输入之后是否展开。
///
/// 规则（用户明确要求的那几条）：
/// * **进入播放页即展开** —— 详情从详情页搬到了右栏，进来不该是空的；
/// * **悬停即展开** —— 指针进栏就展开、离开栏才收缩（左栏同一套时序）；
/// * **交互即刷新** —— 按 I 键、快进、调音量都重新计 8 秒；
/// * **到点即隐藏** —— 整块滑出屏幕，**不留竖条**（第二十四次修，照左栏）；
///   「怎么再叫出来」由右边缘热区与 I / D / 信息键回答。
///
/// 「画面别处点击」是唯一**不改变状态**的输入：控制条收起时用户会点画面，
/// 那一下不该把刚收起的详情又弹出来。
bool vodDetailExpandedAfter(bool expanded, VodDetailInput input) {
  switch (input) {
    case VodDetailInput.enterPlayback:
    case VodDetailInput.pointerOnPanel:
    case VodDetailInput.pointerOnEdge:
      return true;
    case VodDetailInput.pointerLeftPanel:
      return false;
    case VodDetailInput.toggleKey:
      return !expanded;
    case VodDetailInput.pointerElsewhere:
      return expanded;
    case VodDetailInput.idleTimeout:
      return false;
  }
}

/// 这次输入之后要不要（重新）起 8 秒计时。
///
/// 只有「展开着」才计时：收起态不该在后台空转一个永远不会触发的定时器。
/// 展开态下的**任何**输入都重置计时 —— 包括点画面、快进、调音量，
/// 因为这些都说明用户还在操作，详情不该在他正忙的时候缩回去。
///
/// 悬停输入（[VodDetailInput.pointerOnPanel]）例外：它由 UI 层直接取消
/// 计时器 —— 停在栏上就该一直开着，见 `vod_page.dart` 的 `_pokeDetail`。
bool vodDetailRestartsTimer(bool expandedAfterInput) => expandedAfterInput;

/// 快进/快退目标位置。
///
/// 规则：
/// * 结果不小于 0（否则 libmpv 会收到负值，表现为「按一下回到片头」）；
/// * 已知时长时不越过片尾（越过就等于立刻触发片尾/连播，用户只是想快进一点）；
/// * 未知时长（0 / 非有限值）时只做非负夹取 —— 直播型地址没有总时长。
double vodSeekTarget(double position, double duration, double delta) {
  final p = position.isFinite ? position : 0.0;
  var target = p + delta;
  if (!target.isFinite) return p;
  if (target < 0) target = 0;
  if (duration.isFinite && duration > 0 && target > duration) target = duration;
  return target;
}

/// 按剧集表取相邻集号。`direction` 为 +1 下一集、-1 上一集。
///
/// 用「有序集号表里相邻的一项」而不是 `current + 1`：采集站的集号经常跳号
/// （1,2,3,5,8…），加一变出来的集不存在，用户会看到「下一集点了没反应」。
/// 到头部/尾部返回 null，UI 据此把按钮置灰而不是给出假承诺。
int? vodAdjacentEpisode(
  List<int> sortedEpisodes,
  int current,
  int direction,
) {
  if (sortedEpisodes.isEmpty) return null;
  if (direction > 0) {
    for (final e in sortedEpisodes) {
      if (e > current) return e;
    }
    return null;
  }
  int? prev;
  for (final e in sortedEpisodes) {
    if (e >= current) break;
    prev = e;
  }
  return prev;
}

/// 当前集在剧集表里的序号（从 1 开始）；找不到返回 0。
int vodEpisodeOrdinal(List<int> sortedEpisodes, int current) {
  for (var i = 0; i < sortedEpisodes.length; i++) {
    if (sortedEpisodes[i] == current) return i + 1;
  }
  return 0;
}

/// 时钟文案：`mm:ss`，满一小时用 `h:mm:ss`；非法/负值显示 `--:--`。
///
/// 负值必须是 `--:--` 而不是 `00:00`：内核刚 load 时位置可能读到 -1，
/// 显示 00:00 会让人以为「停住了」。
String vodClock(double seconds) {
  if (!seconds.isFinite || seconds < 0) return '--:--';
  final total = seconds.round();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

/// 进度比例，未知时长返回 0（不返回 1，否则进度条一开始就是满的）。
double vodProgress(double position, double duration) {
  if (!duration.isFinite || duration <= 0) return 0;
  final r = (position.isFinite ? position : 0) / duration;
  if (r.isNaN) return 0;
  return r.clamp(0.0, 1.0);
}

/// 缓冲比例：`已缓冲 / 总时长`，夹在 `[已播比例, 1]` 之间。
///
/// 为什么必须夹到「不小于已播」：弱源上 `bufferedSeconds` 偶尔会短暂小于
/// `position`（内核把出队的数据从 cache 里扣掉了，而播放位置还在往前走）。
/// 不夹的话进度条中间的缓冲段会**缩到已播段后面**，画面上表现为
/// 「已播蓝条中间缺一块」，看着像渲染坏了。
double vodBufferedProgress(double buffered, double position, double duration) {
  final b = vodProgress(buffered, duration);
  final p = vodProgress(position, duration);
  return b < p ? p : b;
}

/// 倍速档位（0.5×–2.0×）。0.25× 与 4× 不放进来：前者几乎不出帧，
/// 后者音轨开始丢样本，都不是「正常看片」会用的档。
const List<double> kVodRateOptions = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// 倍速文案：`1.0x` / `0.75x`。整数档补一位小数（`1.0x` 而不是 `1x`），
/// 这样「1.0x → 1.25x」切换时按钮宽度基本不跳。
String vodRateLabel(double rate) {
  if (!rate.isFinite || rate <= 0) return '1.0x';
  final oneDecimal = (rate * 10).roundToDouble() == rate * 10;
  return '${rate.toStringAsFixed(oneDecimal ? 1 : 2)}x';
}

/// 实测分辨率 → 画质标签（`4K` / `2K` / `1080P` / `720P` / `480P` / `360P`）。
///
/// 按**长边**判定而不是固定用高度：很多片源是 `1920×800` 这种带黑边的
/// letterbox，按高度会算出「800P」这种谁都没见过的档名。
///
/// 读不到画质（宽或高为 0，即还没出画）时返回空串 —— 调用方据此显示「自动」，
/// 不编一个好看的档名。
String vodResolutionLabel(int width, int height) {
  if (width <= 0 || height <= 0) return '';
  final long = width >= height ? width : height;
  if (long >= 3400) return '4K';
  if (long >= 2400) return '2K';
  if (long >= 1700) return '1080P';
  if (long >= 1150) return '720P';
  if (long >= 700) return '480P';
  if (long >= 320) return '360P';
  return '${long}P';
}

/// 音量文案（`72%`）。悬浮预览与无障碍标签共用，避免两处四舍五入不一致。
String vodVolumeLabel(double volume) {
  final v = volume.isFinite ? volume.clamp(0.0, 100.0) : 0.0;
  return '${v.round()}%';
}

/// 播放页可执行的动作。
enum VodControlAction {
  togglePlay,
  forward,
  backward,
  nextEpisode,
  previousEpisode,
  toggleEpisodes,
  toggleFullscreen,
  close,
  volumeUp,
  volumeDown,
  none,
}

/// 按键名 → 动作。
///
/// [keyName] 传 Flutter `LogicalKeyboardKey.debugName`（或 `keyLabel`）并已由
/// 调用方小写化、去掉空格，因此 `'Arrow Left'` / `'arrowleft'` 都能匹配。
///
/// 覆盖三类输入：遥控器（方向键 + OK + 返回）、键盘（空格 / 左右 / Esc）、
/// 媒体键（播放暂停 / 快进 / 快退 / 上下曲）。
VodControlAction vodActionFor(String keyName) {
  final k = keyName.toLowerCase().replaceAll(' ', '').replaceAll('_', '');
  switch (k) {
    case 'space':
    case 'enter':
    case 'select':
    case 'numpadenter':
    case 'mediaplaypause':
      return VodControlAction.togglePlay;
    case 'arrowleft':
    case 'left':
    case 'mediafastrewind':
      return VodControlAction.backward;
    case 'arrowright':
    case 'right':
    case 'mediafastforward':
      return VodControlAction.forward;
    case 'arrowup':
    case 'up':
      return VodControlAction.volumeUp;
    case 'arrowdown':
    case 'down':
      return VodControlAction.volumeDown;
    case 'mediatracknext':
      return VodControlAction.nextEpisode;
    case 'mediatrackprevious':
      return VodControlAction.previousEpisode;
    case 'm':
      return VodControlAction.toggleEpisodes;
    // F 是各家播放器的全屏约定键（YouTube / VLC / iQiyi 都是它）。
    // 遥控器上另有显式的全屏按钮，不依赖这个键。
    case 'f':
      return VodControlAction.toggleFullscreen;
    case 'escape':
    case 'browserback':
    case 'goback':
      return VodControlAction.close;
    default:
      return VodControlAction.none;
  }
}
