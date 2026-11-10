/// 播放器抽象（E3）。
///
/// 具体实现将基于 libmpv 封装（Android/桌面/TV 共用内核，必要时 ExoPlayer 回退）。
/// 此处仅定义能力与状态契约，供 UI 与调度层依赖，避免直接耦合具体播放内核。
///
/// 坐标约定：本接口所有 `episode`/`rawSeconds` 均为**源原始坐标（含广告）**。
/// 「去广告的规范内容坐标」由调度层（alignment.dart）负责换算，播放内核只做物理播放。
///
/// 关键非功能约束（取自设计稿）：首帧快、内存低、不卡顿——三者相互牵制，
/// 将在 E3 内核集成阶段实测并设门禁（见 mpv/player_metrics.dart）。
abstract class PlayerController {
  /// 初始化底层内核（libmpv 实例、surface/texture 绑定等）。
  Future<void> initialize();

  /// 载入播放地址并定位到源原始坐标。
  ///
  /// [url] 为源适配层解析所得的真实播放地址；[episode]/[rawSeconds] 为源原始坐标
  /// （含广告），引擎直接 seek 到 [rawSeconds] 对应的物理位置。
  /// 载入地址。[headers] 为该源播放时必须携带的请求头（Referer/UA 等）——
  /// 源站普遍校验 Referer，取数带了、播放不带就是「能搜到、一播 403」。
  Future<void> load(String url, int episode, double rawSeconds,
      {Map<String, String> headers = const <String, String>{}});

  Future<void> play();
  Future<void> pause();

  /// 跳转到源原始秒数（同样为含广告的物理坐标）。
  Future<void> seek(double rawSeconds);

  /// 设置音量（0–100）。取值会被夹到合法区间，越界不抛异常。
  ///
  /// 为什么放进抽象层：UI 的音量滑块/静音键需要统一的入口，
  /// 而不关心底层是 libmpv 还是 Media3——否则每个实现各写一套，
  /// 回调里还得判断内核类型。
  Future<void> setVolume(double volume);

  /// 当前音量（0–100）。内核未就绪时返回 100（默认满音量），
  /// 不抛异常：UI 在冷启动阶段照常渲染滑块即可。
  double get volume;

  /// 音量变化流。未就绪时发一个 100 的初始值，避免订阅者拿不到初值。
  Stream<double> get volumeChanges;

  /// 当前源原始秒数（供换源时回传给调度层做内容对齐）。
  Future<double> currentRawSeconds();

  /// 当前载入媒体的总时长（源原始秒数，含广告）。
  ///
  /// **未知时返回 0，不抛异常**。这条契约是刻意的：
  /// - 内核刚 `load` 尚未 file-loaded 时、直播/未知长度流、读数失败，都会拿不到时长；
  /// - 调用方（片尾判定）必须把「不知道」与「没有时长」同等对待——两者都不能触发
  ///   任何「已看完」推断，否则会把正好卡在缓冲中的正常播放误判成播放完毕。
  ///
  /// 单位与 [currentRawSeconds] 一致（源原始坐标），换算成内容时长由调度层负责。
  Future<double> duration();

  Future<void> dispose();
}

/// 能报告「是不是真的出画面了」的内核。
///
/// 为什么需要它：**直播不能用播放位置判断起播**。实测一条 1080p 公共 HLS 线路，
/// 内核已经 `VO: [libmpv] 1920x1080 nv12`、纹理都建好了、声音在出，
/// `time-pos` 却一直是 `0:00:00`（直播没有可 seek 的时间轴，位置要等时间轴稳定
/// 才开始推进）。只看位置就会把「正在正常播放」判成「线路挂了」，
/// 于是 UI 显示「暂无信号」而画面其实在动——本项目就这么错过一次。
///
/// 所以直播的起播判定要用两个信号：
/// 1. 位置是否前进（点播与已稳定下来的直播）；
/// 2. **是否已经解码出画面**（[hasPicture]，直播刚起播时唯一的可靠信号）。
///
/// 做成独立接口而不是往 [PlayerController] 里加方法：这个能力依赖具体内核
/// （mpv 有视频参数，纯音频或占位内核没有），放进主接口会逼所有实现返回假值。
abstract class PictureProbe {
  /// 是否已拿到视频参数（宽高非 0）——即首帧已经进入解码/渲染。
  bool get hasPicture;

  /// 「拿到视频参数」的次数（单调递增）。
  ///
  /// 这是判断**新载入的流**是否出画面的关键：只问 [hasPicture] 不够——
  /// 换到同分辨率的台时内核的宽高值不变，`hasPicture` 在 `load` 前后都是 true，
  /// 于是「还没开始解码」会被当成「已经出画面」，一条死线路也能显示「正在播放」
  /// （画面还停在上一个台的最后一帧）。世代号每次收到新的视频参数才 +1，
  /// 调度层只要比较「load 前后有没有变」就知道是不是新画面。
  int get pictureEpoch;

  /// 内核是否仍在缓冲。与 [hasPicture] 一起用来区分「卡住了」和「正常在播」。
  bool get isBuffering;

  /// 最近一次内核错误（成功载入后清空）。没有错误时为 null。
  ///
  /// 直播换线**靠它快失败**：一条死地址不必等满起播超时，内核会自己报
  /// `Failed to open` / `HTTP error 5xx`，拿到这类终态错误就该立刻换下一条。
  /// 反过来，只要内核还在静默重试（没报终态错误），就该多等一会儿——
  /// 实测公共 1080p HLS 线路要重试 20 秒以上才出画面，
  /// 用固定超时去卡它会把「其实能播」的线路判死（这正是首屏黑屏的成因之一）。
  String? get lastError;
}
