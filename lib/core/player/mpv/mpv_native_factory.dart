import '../../diagnostics/diagnostic_sink.dart';
import 'metrics_sampler.dart';
import 'mpv_backend_resolver.dart';
import 'mpv_event_channel.dart';
import 'mpv_event_pipeline.dart';
import 'mpv_ffi_bindings.dart';
import 'mpv_ffi_native.dart';
import 'mpv_native.dart';
import 'mpv_platform_channel_native.dart';
import 'player_metrics.dart';

/// 后端选择结果：包含可用的 [MpvNative] 与决议理由（供 UI 明示降级）。
class MpvBackendSelection {
  final MpvNative native;
  final MpvBackendResolution resolution;

  const MpvBackendSelection(this.native, this.resolution);

  bool get isFallback => resolution.backend == MpvBackend.platformChannel;
}

/// 按 [MpvLibraryProbe] 决议并构造播放内核（E3 真实集成入口）。
///
/// - libmpv 动态库可用 → [MpvFfiNative]（FFI 零桥接）。
/// - 不可用 → [MpvPlatformChannelNative]（Android ExoPlayer 回退），
///   并通过 [MpvBackendSelection.isFallback] 告知 UI 明示。
///
/// [memoryProbe] 为平台内存探针（MB）；真机由 OS API/原生侧提供，
/// 纯逻辑验证可注入常量。
MpvBackendSelection createMpvBackend({
  required MpvLibraryProbe probe,
  required double Function() memoryProbe,
  SamplerClock? clock,
}) {
  final resolution = resolveMpvBackend(probe);

  if (resolution.backend == MpvBackend.ffi && probe is FfiMpvLibraryProbe) {
    final lib = probe.opened;
    if (lib != null) {
      final sampler = MetricsSampler(
        clock: clock,
        memoryProbe: memoryProbe,
      );
      return MpvBackendSelection(
        MpvFfiNative(bindings: MpvFfiBindings(lib), sampler: sampler),
        resolution,
      );
    }
    // 决议为 ffi 但拿不到句柄（异常态）：安全降级，不抛给用户。
    return MpvBackendSelection(
      MpvPlatformChannelNative(),
      const MpvBackendResolution(
        MpvBackend.platformChannel,
        'libmpv 句柄不可用，安全降级到平台通道',
      ),
    );
  }

  return MpvBackendSelection(MpvPlatformChannelNative(), resolution);
}

/// 真机「事件驱动指标管线」的一行式入口，与 [createMpvBackend] 配套。
///
/// 原生侧按 `shunbo/mpv/events` EventChannel 推送 JSON 事件后，
/// 首帧/内存/卡顿门禁即由事件流自动驱动，无需手工调用采样器。
/// 纯逻辑环境请改用 `MpvEventPipeline.attach(MpvEventFeed(), ...)` 注入假事件。
MpvEventPipeline createMpvEventPipeline({
  required double Function() memoryProbe,
  SamplerClock? clock,
  PlayerMetricGate gate = const PlayerMetricGate(),
  int sampleEveryFrames = 300,
  DiagnosticSink? diagnostics,
  void Function(PlayerMetrics metrics, GateResult result)? onSample,
}) =>
    MpvEventPipeline.attach(
      MpvEventChannelSource(),
      sampler: MetricsSampler(clock: clock, memoryProbe: memoryProbe),
      gate: gate,
      sampleEveryFrames: sampleEveryFrames,
      diagnostics: diagnostics,
      onSample: onSample,
    );
