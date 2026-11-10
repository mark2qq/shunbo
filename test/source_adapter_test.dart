import 'package:flutter_test/flutter_test.dart';
import 'package:shunbo/core/source/memory_source_adapter.dart';
import 'package:shunbo/core/source/source_adapter.dart';
import 'package:shunbo/core/source/source_registry.dart';
import 'package:shunbo/core/source/source_profile.dart';

void main() {
  test('MemorySourceAdapter 返回剧集与多清晰度候选', () async {
    final eps = const [
      EpisodeInfo(episode: 1, title: 'E1'),
      EpisodeInfo(episode: 2, title: 'E2'),
    ];
    final urls = {
      'm#1': const [
        PlayUrl(url: 'a.mp4', qualityRank: 1),
        PlayUrl(url: 'b.mp4', qualityRank: 2),
      ],
    };
    final adapter = MemorySourceAdapter(
      id: 'demo',
      profile: const SourceProfile(name: 'demo'),
      episodes: {'m': eps},
      urls: urls,
    );

    final found = await adapter.search('m');
    expect(found.length, 1);
    expect(found.first.mediaId, 'm');

    final gotEps = await adapter.getEpisodes('m');
    expect(gotEps.length, 2);
    expect(gotEps.first.episode, 1);

    final gotUrls = await adapter.resolvePlayUrl('m', 1);
    expect(gotUrls.length, 2);
    // qualityRank 大者更清晰，换源调度择优依据
    expect(gotUrls.map((u) => u.qualityRank).toList(), containsAll([1, 2]));
  });

  test('SourceRegistry 按平台裁剪可用源', () {
    final androidOnly = MemorySourceAdapter(
      id: 'a-only',
      profile: const SourceProfile(name: 'a-only'),
      supportedPlatforms: {SourcePlatform.android},
    );
    final universal = MemorySourceAdapter(
      id: 'uni',
      profile: const SourceProfile(name: 'uni'),
      supportedPlatforms: {
        SourcePlatform.android,
        SourcePlatform.desktop,
        SourcePlatform.tv,
      },
    );
    final reg = SourceRegistry()
      ..register(androidOnly)
      ..register(universal);

    final desktop = reg.availableOn(SourcePlatform.desktop);
    expect(desktop.map((a) => a.id), ['uni']);

    final android = reg.availableOn(SourcePlatform.android);
    expect(android.map((a) => a.id), containsAll(['a-only', 'uni']));
  });
}
