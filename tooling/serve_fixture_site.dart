// 本地样本站点服务：让 App 本体在没有任何外部站点的情况下跑通真实 HTTP 链路。
//
// 用法：
//   dart run tooling/serve_fixture_site.dart [legacy|vod|json] [端口]
// 默认端口 56782（被占用时自动改用随机端口），与 App 导入框里的示例配置一致。
//
// 启动后会直接打印一份可粘贴的源配置 JSON，粘进 App「源配置导入」对话框
// 即可完成「外部配置 → 真实多源 → 搜索/取址/播放」的闭环，无需 --dart-define。
// 也可另开终端用旧方式运行：
//   flutter run --dart-define=SHUNBO_LIVE_BASE_URL=<打印出的地址> \
//               --dart-define=SHUNBO_LIVE_RULE=<打印出的规则名>
//
// 只依赖 dart:io，裸 dart run 可执行；按 Ctrl+C 退出。
import 'dart:io';

import 'package:shunbo/data/onboarding/sample_source_config.dart';

import 'fixture_site.dart';

const Map<String, String> _ruleByKind = <String, String>{
  'legacy': 'legacy',
  'vod': 'vod-html',
  'json': 'json-api',
};

Future<void> main(List<String> args) async {
  final kind = args.isNotEmpty && _ruleByKind.containsKey(args[0])
      ? args[0]
      : 'legacy';
  final requestedPort =
      args.length > 1 ? int.tryParse(args[1]) ?? 0 : kDefaultFixturePort;
  final site = FixtureSite(kind);
  try {
    await site.start(port: requestedPort);
  } on SocketException {
    await site.start();
  }
  final rule = _ruleByKind[kind]!;
  stdout.writeln('样本站点已启动：$kind @ ${site.origin}');
  stdout.writeln('站点结构：$rule（搜索 / 剧集 / 播放地址 / 故障路径均可用）');
  stdout.writeln('');
  stdout.writeln('把下面这段 JSON 粘贴到 App 的「源配置导入」对话框即可：');
  stdout.writeln(sampleSourceConfigJson(baseUrl: site.origin, ruleName: rule));
  stdout.writeln('');
  stdout.writeln('按 Ctrl+C 退出。');
  await ProcessSignal.sigint.watch().first;
  await site.close();
}
