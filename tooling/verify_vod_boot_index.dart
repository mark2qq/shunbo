// 启动期「索引一致性校验 + 加载」状态机回归（第 2 项）。
//
// 为什么值得单独一套门禁：这段代码决定「首屏能不能搜到片」，而它的分支
// 全部藏在网络与文件 IO 后面 —— 真机上只表现为「有时候要等很久」「有时候
// 搜不到」，靠手点几乎无法复现。这里把 IO 全部换成可控回调，把六态转移图
// 逐条钉死：每一条转移都由一个断言守着，改坏了立刻红。
//
// 运行：dart run tooling/verify_vod_boot_index.dart
import 'dart:io';

import 'package:shunbo/features/vod/vod_boot_index.dart';
import 'package:shunbo/features/vod/vod_builtin_index.dart';

int _pass = 0;
int _fail = 0;
final List<String> _failures = <String>[];

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
    _failures.add(detail.isEmpty ? name : '$name —— $detail');
    stdout.writeln('  FAIL $name${detail.isEmpty ? '' : ' —— $detail'}');
  }
}

const String kUrl = 'http://47.96.82.41:5188/config.json';
const String kOtherUrl = 'http://example.com/config.json';

/// 门禁用的固定时钟，避免「今天跑绿、明天过期变红」。
final DateTime _now = DateTime.utc(2026, 11, 12, 12, 0, 0);

BuiltinIndexManifest _manifest({
  String sourceUrl = kUrl,
  DateTime? generatedAt,
  int total = 1000,
  int shards = 2,
  int recordsPerShard = 500,
}) {
  final list = <BuiltinIndexShard>[];
  const keys = <String>['movies', 'series', 'documentaries', 'shortVideo'];
  for (var i = 0; i < shards; i++) {
    list.add(BuiltinIndexShard(
      key: keys[i % keys.length],
      label: keys[i % keys.length],
      file: '${keys[i % keys.length]}.tsv.gz',
      records: recordsPerShard,
      gzBytes: 1024,
      sha256: 'f' * 64,
    ));
  }
  return BuiltinIndexManifest(
    version: kBuiltinIndexVersion,
    generatedAt: generatedAt ?? _now.subtract(const Duration(days: 1)),
    sourceUrl: sourceUrl,
    sites: const <BuiltinIndexSite>[
      BuiltinIndexSite(key: 'dyttzy', name: '电影天堂', api: 'http://a/api', total: 500),
    ],
    types: const <String>['动作片', '国产剧'],
    shards: list,
    total: total,
    rawTotal: total,
  );
}

/// 造一个「一切正常」的控制器，返回它和可变开关，方便各断言改单点。
class _Rig {
  _Rig({
    BuiltinIndexManifest? manifest,
    bool manifestThrows = false,
    Set<String>? missingShards,
    String? syncFailure,
    bool syncThrows = false,
  })  : manifest = manifest,
        manifestThrows = manifestThrows,
        missingShards = missingShards ?? <String>{},
        syncFailure = syncFailure,
        syncThrows = syncThrows;

  BuiltinIndexManifest? manifest;
  bool manifestThrows = false;
  Set<String> missingShards;
  String? syncFailure;
  bool syncThrows = false;

  int manifestLoads = 0;
  int shardLoads = 0;
  int syncCalls = 0;

  late final VodBootController controller = VodBootController(
    loadManifest: () async {
      manifestLoads++;
      if (manifestThrows) throw StateError('资产读取失败');
      return manifest;
    },
    loadShard: (file) async {
      shardLoads++;
      if (missingShards.contains(file)) return null;
      return <int>[31, 139, 8, 0];
    },
    syncNetwork: () async {
      syncCalls++;
      if (syncThrows) throw StateError('网络异常');
      return syncFailure;
    },
    now: () => _now,
  );
}

Future<void> main() async {
  // ── N. settled：让后台同步等校验结论（1.0.5 第十五次修）──
  //
  // 背景：栏目页的后台全量同步（11 次修）与启动校验（13 次修）互不通气。
  // 同步在 initState 就跑，而 boot 要等首帧之后才触发 —— 那时 `hasLocalIndex`
  // 还是 false，于是「已加载内置索引 60.5 万条」和「目录同步中」同屏出现。
  // 修法：同步先 `await settled`，再读 `hasLocalIndex`。
  {
    final rig = _Rig(manifest: _manifest());
    check('N01 未调用 boot 时 started 为假', !rig.controller.started);
    final returned = await Future.any(<Future<bool>>[
      rig.controller.settled.then((_) => true),
      Future<bool>.delayed(const Duration(milliseconds: 300), () => false),
    ]);
    check('N02 未开始时 settled 立刻返回（不挂住调用方）', returned);
  }
  {
    final rig = _Rig(manifest: _manifest());
    final future = rig.controller.boot(
      selectedUrl: kUrl,
      builtinSourceUrl: kUrl,
    );
    check('N03 boot 一调用 started 即为真', rig.controller.started);
    check('N04 结论未出时 hasLocalIndex 仍为假（所以必须先等）',
        !rig.controller.hasLocalIndex, '${rig.controller.phase}');
    await rig.controller.settled;
    check('N05 settled 返回时已是终态',
        rig.controller.phase == VodBootPhase.readyBuiltin,
        '${rig.controller.phase}');
    check('N06 settled 与 boot 的返回值一致',
        (await future) == rig.controller.phase);
  }

  // ── A. 一致 ⇒ 直接加载本地索引，一个网络包都不发 ──
  {
    final rig = _Rig(manifest: _manifest());
    final phase = await rig.controller.boot(
      selectedUrl: kUrl,
      builtinSourceUrl: kUrl,
    );
    check('A01 地址一致 → readyBuiltin', phase == VodBootPhase.readyBuiltin,
        '$phase');
    check('A02 一致时零网络同步', rig.syncCalls == 0, '${rig.syncCalls} 次');
    check('A03 一致时校验了全部分片', rig.shardLoads == 2, '${rig.shardLoads} 片');
    check('A04 hasLocalIndex 为真', rig.controller.hasLocalIndex);
    check('A05 busy 为假（已就绪）', !rig.controller.busy);
    check('A06 文案含「已加载内置索引」',
        rig.controller.note.contains('已加载内置索引'), rig.controller.note);
    check('A07 文案带打包日期',
        rig.controller.note.contains('2026-11-11'), rig.controller.note);
    check('A08 文案把条数换算成万',
        rig.controller.note.contains('1000') || rig.controller.note.contains('万'),
        rig.controller.note);
    check('A09 verdict 记录判据为「地址一致」',
        rig.controller.verdict?.reason.contains('地址一致') ?? false,
        rig.controller.verdict?.reason ?? 'null');
    check('A10 只读了一次 manifest', rig.manifestLoads == 1);
  }

  // ── B. 地址不一致 ⇒ 同步网络（这是「用户换了接口」的唯一正确反应）──
  {
    final rig = _Rig(manifest: _manifest());
    final phase = await rig.controller.boot(
      selectedUrl: kOtherUrl,
      builtinSourceUrl: kUrl,
    );
    check('B01 地址不一致 + 同步成功 → readyBuiltin',
        phase == VodBootPhase.readyBuiltin, '$phase');
    check('B02 地址不一致必然发起同步', rig.syncCalls == 1);
    check('B03 地址不一致时不去读分片（省一次 IO）', rig.shardLoads == 0,
        '${rig.shardLoads} 片');
    check('B04 verdict 理由写明两个地址',
        (rig.controller.verdict?.reason.contains(kUrl) ?? false) &&
            (rig.controller.verdict?.reason.contains(kOtherUrl) ?? false),
        rig.controller.verdict?.reason ?? 'null');
    check('B05 同步成功后文案为「已从接口同步最新索引」',
        rig.controller.note.contains('已从接口同步'), rig.controller.note);
  }

  // ── C. 地址不一致 + 同步失败 ⇒ 回退内置（有索引就不能让用户没片看）──
  {
    final rig = _Rig(manifest: _manifest(), syncFailure: '超时');
    final phase = await rig.controller.boot(
      selectedUrl: kOtherUrl,
      builtinSourceUrl: kUrl,
    );
    check('C01 同步失败 → fallbackBuiltin', phase == VodBootPhase.fallbackBuiltin,
        '$phase');
    check('C02 回退后仍算有本地索引', rig.controller.hasLocalIndex);
    check('C03 回退文案明示「可能不是最新」',
        rig.controller.note.contains('可能不是最新'), rig.controller.note);
    check('C04 回退文案说明原因是接口同步失败',
        rig.controller.note.contains('接口同步失败'), rig.controller.note);
  }

  // ── D. 同步抛异常也要被吞掉（不能让启动崩在这里）──
  {
    final rig = _Rig(manifest: _manifest(), syncThrows: true);
    final phase = await rig.controller.boot(
      selectedUrl: kOtherUrl,
      builtinSourceUrl: kUrl,
    );
    check('D01 syncNetwork 抛异常 → 仍回退而不是抛出',
        phase == VodBootPhase.fallbackBuiltin, '$phase');
  }

  // ── E. 内置索引缺失 ⇒ 只能靠网络；网络也不行就 incomplete ──
  {
    final rig = _Rig(manifest: null);
    final phase = await rig.controller.boot(
      selectedUrl: kUrl,
      builtinSourceUrl: kUrl,
    );
    check('E01 无内置索引 + 同步成功 → readyBuiltin',
        phase == VodBootPhase.readyBuiltin, '$phase');
    check('E02 无内置索引时依然发起同步', rig.syncCalls == 1);
  }
  {
    final rig = _Rig(manifest: null, syncFailure: '无网络');
    final phase = await rig.controller.boot(
      selectedUrl: kUrl,
      builtinSourceUrl: kUrl,
    );
    check('E03 无内置索引 + 同步失败 → incomplete',
        phase == VodBootPhase.incomplete, '$phase');
    check('E04 incomplete 不算有本地索引', !rig.controller.hasLocalIndex);
    check('E05 incomplete 文案说明「无内置索引可用」',
        rig.controller.note.contains('无内置索引可用'), rig.controller.note);
  }

  // ── F. manifest 读取抛异常 ⇒ 等同缺失，不炸启动 ──
  {
    final rig = _Rig(manifest: _manifest(), manifestThrows: true);
    final phase = await rig.controller.boot(
      selectedUrl: kUrl,
      builtinSourceUrl: kUrl,
    );
    check('F01 manifest 读取抛异常被吞掉', phase == VodBootPhase.readyBuiltin,
        '$phase');
    check('F02 读不到 manifest 时仍走网络', rig.syncCalls == 1);
  }

  // ── G. 分片缺失 / 损坏 ⇒ 不能装作一致，必须回源 ──
  {
    final rig = _Rig(manifest: _manifest(), missingShards: {'series.tsv.gz'});
    final phase = await rig.controller.boot(
      selectedUrl: kUrl,
      builtinSourceUrl: kUrl,
    );
    check('G01 分片读不到 → 触发同步（不静默放行）', rig.syncCalls == 1);
    check('G02 同步成功后 readyBuiltin', phase == VodBootPhase.readyBuiltin,
        '$phase');
    check('G03 verdict 指出是哪个分片',
        rig.controller.verdict?.reason.contains('series.tsv.gz') ?? false,
        rig.controller.verdict?.reason ?? 'null');
  }
  {
    final m = _manifest();
    // 条数为 0 的分片：文件在也不算完整。
    final zero = BuiltinIndexManifest(
      version: m.version,
      generatedAt: m.generatedAt,
      sourceUrl: m.sourceUrl,
      sites: m.sites,
      types: m.types,
      shards: <BuiltinIndexShard>[
        const BuiltinIndexShard(
            key: 'movies',
            label: '电影',
            file: 'movies.tsv.gz',
            records: 0,
            gzBytes: 0,
            sha256: ''),
      ],
      total: 0,
    );
    final rig = _Rig(manifest: zero);
    final phase = await rig.controller.boot(
      selectedUrl: kUrl,
      builtinSourceUrl: kUrl,
    );
    check('G04 条数为 0 的内置索引不算可用（isEmpty）',
        phase != VodBootPhase.readyBuiltin || rig.syncCalls == 1, '$phase');
  }

  // ── H. allowSync=false（离线模式 / 用户在设置里关掉了自动同步）──
  {
    final rig = _Rig(manifest: _manifest());
    final phase = await rig.controller.boot(
      selectedUrl: kOtherUrl,
      builtinSourceUrl: kUrl,
      allowSync: false,
    );
    check('H01 禁同步 + 地址不一致 → fallbackBuiltin',
        phase == VodBootPhase.fallbackBuiltin, '$phase');
    check('H02 禁同步时零网络调用', rig.syncCalls == 0);
    check('H03 禁同步文案说明「未联网校验」',
        rig.controller.note.contains('未联网校验'), rig.controller.note);
  }
  {
    final rig = _Rig(manifest: null);
    final phase = await rig.controller.boot(
      selectedUrl: kUrl,
      builtinSourceUrl: kUrl,
      allowSync: false,
    );
    check('H04 禁同步 + 无索引 → incomplete', phase == VodBootPhase.incomplete,
        '$phase');
  }

  // ── I. 过期判定（新鲜度是第二判据）──
  {
    final old = _manifest(generatedAt: _now.subtract(const Duration(days: 30)));
    final rig = _Rig(manifest: old);
    await rig.controller.boot(
      selectedUrl: kUrl,
      builtinSourceUrl: kUrl,
    );
    check('I01 内置索引 30 天未更新 → 触发同步', rig.syncCalls == 1);
    check('I02 过期文案说明「已过期」',
        rig.controller.note.contains('过期') ||
            (rig.controller.verdict?.reason.contains('过期') ?? false),
        '${rig.controller.note} / ${rig.controller.verdict?.reason}');
  }
  {
    final fresh = _manifest(generatedAt: _now.subtract(const Duration(days: 6)));
    final rig = _Rig(manifest: fresh);
    final phase = await rig.controller.boot(
      selectedUrl: kUrl,
      builtinSourceUrl: kUrl,
    );
    check('I03 6 天内的索引仍然新鲜 → 不联网', rig.syncCalls == 0);
    check('I04 6 天内 → readyBuiltin', phase == VodBootPhase.readyBuiltin);
  }
  {
    // 打包机时区错导致 generatedAt 在未来：不能因此判过期（否则每次启动都重下）。
    final future = _manifest(generatedAt: _now.add(const Duration(days: 2)));
    final rig = _Rig(manifest: future);
    await rig.controller.boot(selectedUrl: kUrl, builtinSourceUrl: kUrl);
    check('I05 未来时间戳（时区错）不判过期', rig.syncCalls == 0);
  }

  // ── J. 状态机自身：busy / listener / idle 初值 ──
  {
    final rig = _Rig(manifest: _manifest());
    check('J01 初始状态 idle', rig.controller.phase == VodBootPhase.idle);
    check('J02 初始 note 为空', rig.controller.note.isEmpty);
    check('J03 初始 verdict 为 null', rig.controller.verdict == null);
    check('J04 初始 hasLocalIndex 为假', !rig.controller.hasLocalIndex);
    var fired = 0;
    void l() => fired++;
    rig.controller.addListener(l);
    await rig.controller.boot(selectedUrl: kUrl, builtinSourceUrl: kUrl);
    check('J05 监听器在状态变化时被通知', fired >= 2, '$fired 次');
    rig.controller.removeListener(l);
    final before = fired;
    await rig.controller.boot(selectedUrl: kUrl, builtinSourceUrl: kUrl);
    check('J06 移除后不再通知', fired == before, '$fired vs $before');
  }

  // ── K. 覆盖策略：内置索引更新是否该盖掉用户本地缓存 ──
  {
    final builtin = _manifest();
    check(
      'K01 无本地缓存 → 应当落盘',
      shouldReplaceCache(
        builtin: builtin,
        cacheSavedAt: null,
        cacheSourceUrl: kUrl,
      ),
    );
    check(
      'K02 内置比缓存新 → 覆盖（升级就该拿到新片）',
      shouldReplaceCache(
        builtin: builtin,
        cacheSavedAt: _now.subtract(const Duration(days: 10)),
        cacheSourceUrl: kUrl,
      ),
    );
    check(
      'K03 内置比缓存旧 → 不覆盖（降级/重装不能删用户数据）',
      !shouldReplaceCache(
        builtin: builtin,
        cacheSavedAt: _now.add(const Duration(days: 5)),
        cacheSourceUrl: kUrl,
      ),
    );
    check(
      'K04 接口地址变了 → 覆盖（旧 id 全指向错的站）',
      shouldReplaceCache(
        builtin: builtin,
        cacheSavedAt: _now.add(const Duration(days: 5)),
        cacheSourceUrl: kOtherUrl,
      ),
    );
    check(
      'K05 无内置索引 → 永不覆盖',
      !shouldReplaceCache(
        builtin: null,
        cacheSavedAt: null,
        cacheSourceUrl: kUrl,
      ),
    );
    check(
      'K06 空内置索引（total=0）→ 不覆盖',
      !shouldReplaceCache(
        builtin: _manifest(total: 0, shards: 0),
        cacheSavedAt: null,
        cacheSourceUrl: kUrl,
      ),
    );
  }

  // ── L. 一致性判定的布尔版与理由版必须同口径 ──
  {
    final m = _manifest();
    final boolVerdict = builtinIndexMatches(
        manifest: m, selectedUrl: kUrl, now: _now);
    final richVerdict =
        evaluateBuiltinIndex(manifest: m, selectedUrl: kUrl, now: _now);
    check('L01 一致时两版判定相同（true）', boolVerdict == richVerdict.match,
        '$boolVerdict vs ${richVerdict.match}');

    final boolBad = builtinIndexMatches(
        manifest: m, selectedUrl: kOtherUrl, now: _now);
    final richBad =
        evaluateBuiltinIndex(manifest: m, selectedUrl: kOtherUrl, now: _now);
    check('L02 地址不符时两版判定相同（false）', boolBad == richBad.match,
        '$boolBad vs ${richBad.match}');

    final old = _manifest(generatedAt: _now.subtract(const Duration(days: 9)));
    check(
        'L03 过期时两版判定相同（false）',
        builtinIndexMatches(manifest: old, selectedUrl: kUrl, now: _now) ==
            evaluateBuiltinIndex(manifest: old, selectedUrl: kUrl, now: _now)
                .match);
    check('L04 空 manifest 两版都为 false',
        !builtinIndexMatches(manifest: null, selectedUrl: kUrl, now: _now) &&
            !evaluateBuiltinIndex(manifest: null, selectedUrl: kUrl, now: _now)
                .match);
  }

  // ── M. 源码静态护栏：接入点必须真的存在 ──
  {
    final mainSrc = File('lib/main.dart').readAsStringSync();
    final servicesSrc = File('lib/app/services.dart').readAsStringSync();
    check('M01 main.dart 已构造 VodBootController',
        mainSrc.contains('VodBootController('));
    check('M02 main.dart 用 rootBundle 读 manifest',
        mainSrc.contains('assets/vod_index/manifest.json'));
    check('M03 services.dart 暴露 vodBoot',
        servicesSrc.contains('vodBoot'));
    check(
      'M04 状态机不含 dart:io（保证裸 dart run 可回归）',
      !File('lib/features/vod/vod_boot_index.dart')
          .readAsStringSync()
          .contains("import 'dart:io'"),
    );
    check(
      'M05 状态机不含 flutter 依赖',
      !File('lib/features/vod/vod_boot_index.dart')
          .readAsStringSync()
          .contains('package:flutter/'),
    );
  }

  // ── S. 接线护栏：后台全量同步必须让位于内置索引（1.0.5 第十五次修）──
  //
  // 这一组只能静态断言：真正的行为发生在 Widget 的 initState 里，裸 `dart run`
  // 撑不起 Flutter 树。它守的是一个**真实发生过**的回归 —— 界面同时显示
  // 「已加载内置索引 60.5 万条」和「目录同步中」，而那条同步在结构上永远
  // 追不上接口（1 万条上限 vs 147 万条）。
  {
    final page = File('lib/ui/vod/vod_page.dart').readAsStringSync();
    final bootSrc =
        File('lib/features/vod/vod_boot_index.dart').readAsStringSync();
    check('S01 状态机暴露 settled 供同步链路等待',
        bootSrc.contains('Future<void> get settled'));
    check('S02 后台同步先等启动校验出结论', page.contains('await boot.settled'));
    check('S03 内置索引就绪 ⇒ 不启动全量同步',
        page.contains('if (boot.hasLocalIndex) return;'));
    check('S04 同步循环每批前复查内置索引是否已就绪',
        page.contains('!boot.hasLocalIndex'));
    check('S05 状态行不再把百万级接口总数当分母',
        !page.contains('目录同步中：已加载'));
    check('S06 状态行改说「内置索引已可检索」', page.contains('条已可直接检索'));
  }

  _report();
}

void _report() {
  stdout.writeln('');
  if (_fail == 0) {
    stdout.writeln('回归通过：$_pass/$_pass 断言通过');
  } else {
    stdout.writeln('回归失败：$_pass 通过 / $_fail 失败');
    for (final f in _failures) {
      stdout.writeln('  - $f');
    }
    exit(1);
  }
}
