// GENERATED FILE — 由 tooling/gen_official_satellite.dart 生成，勿手改。
//
// 官方源 = 广电 / 持牌平台自有 CDN 的直连流（非境外中转、非第三方转播）。
// 每条都经过 libmpv 解码验证：建起解码链 + 解码器零报错。
// 带 `resolverUrl` 的线路在起播前会重新解析 302，换取当次有效的 CDN 令牌；
// 解析失败退回原地址，由既有换线链路兜底。
//
// 生成时间：2026-11-07（12 个台）
library;

import 'live_channel.dart';

/// 生成时间戳（ISO8601，UTC）。公开 CDN 令牌以小时计过期，
/// 这份清单本身也应按月重新验证。
const String kOfficialSatelliteAt = '2026-11-07T02:45:28Z';

/// 内置官方源频道（解码实测通过）。
const List<LiveChannel> kOfficialSatelliteChannels = <LiveChannel>[
  LiveChannel(
    id: '卫视频道:东方卫视',
    name: '东方卫视',
    group: '卫视频道',
    badge: '东方卫视',
    categories: <String>['卫视频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://gslbmgsplive.miguvideo.com/wd_r4/dfl/dongfangwshd/1200/index.m3u8?msisdn=dc32bc170e63d50c6a529b8ac5040db2&mdspid=&spid=600697&netType=0&sid=5910022185&pid=2028597139&timestamp=20261107090430&Channel_ID=0116_2600034600-99000-201600010010028&ProgramID=651632648&ParentNodeID=-99&assertID=5910022185&client_ip=110.188.239.109&SecurityKey=20261107090430&promotionId=&mvid=5100043384&mcid=500020&playurlVersion=WX-A1-9.10.1-SNAPSHOT&userid=&jmhm=&videocodec=h264&appCode=miguvideo_android&bean=mgspad&tid=android&conFee=0&puData=ed237f97b8556ebbeed4fef7d6a7f41a&ddCalcu=ae1dv42af3w77aaf69d77bf8e5f546deebeb&sv=10004&ct=android',
        label: '官方直连·720P',
        qualityRank: 60,
        headers: <String, String>{'User-Agent': 'AptvPlayer-UA'},
        decodeVerified: true,
        resolverUrl: 'http://101.35.240.114:88/live.php?id=%E4%B8%9C%E6%96%B9%E5%8D%AB%E8%A7%86',
      ),
    ],
  ),
  LiveChannel(
    id: '卫视频道:江苏卫视',
    name: '江苏卫视',
    group: '卫视频道',
    badge: '江苏卫视',
    categories: <String>['卫视频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://gslbmgsplive.miguvideo.com/wd_r2/cctv/jiangsuhd/1200/index.m3u8?msisdn=dc32bc170e63d50c6a529b8ac5040db2&mdspid=&spid=699067&netType=0&sid=5500199408&pid=2028597139&timestamp=20261107090342&Channel_ID=0116_2600034600-99000-201600010010028&ProgramID=623899368&ParentNodeID=-99&assertID=5500199408&client_ip=110.188.239.109&SecurityKey=20261107090342&promotionId=&mvid=5100156802&mcid=500020&playurlVersion=WX-A1-9.10.1-SNAPSHOT&userid=&jmhm=&videocodec=h264&appCode=miguvideo_android&bean=mgspad&tid=android&conFee=0&puData=9430db488ec2c37c86e71324a96d9414&ddCalcu=4914v43a90bdda6b94a8482e3c127ce3678c&sv=10004&ct=android',
        label: '官方直连·720P',
        qualityRank: 60,
        headers: <String, String>{'User-Agent': 'AptvPlayer-UA', 'Referer': 'https://litchi-play-encrypted-site.jstv.com/'},
        decodeVerified: true,
        resolverUrl: 'http://101.35.240.114:88/live.php?id=%E6%B1%9F%E8%8B%8F%E5%8D%AB%E8%A7%86',
      ),
    ],
  ),
  LiveChannel(
    id: '卫视频道:浙江卫视',
    name: '浙江卫视',
    group: '卫视频道',
    badge: '浙江卫视',
    categories: <String>['卫视频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://ali-xwl.cztv.com/live/channel4k2160p.m3u8',
        label: '官方直连·2160P',
        qualityRank: 100,
        headers: <String, String>{'User-Agent': 'aliplayer'},
        decodeVerified: true,
        resolverUrl: 'http://101.35.240.114:88/live.php?id=%E6%B5%99%E6%B1%9F%E5%8D%AB%E8%A7%864K',
      ),
    ],
  ),
  LiveChannel(
    id: '卫视频道:浙江卫视4k',
    name: '浙江卫视4K',
    group: '卫视频道',
    badge: '浙江卫视',
    categories: <String>['卫视频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://ali-xwl.cztv.com/live/channel4k2160p.m3u8',
        label: '官方直连·2160P',
        qualityRank: 100,
        headers: <String, String>{'User-Agent': 'aliplayer'},
        decodeVerified: true,
        resolverUrl: 'http://101.35.240.114:88/live.php?id=%E6%B5%99%E6%B1%9F%E5%8D%AB%E8%A7%864K',
      ),
    ],
  ),
  LiveChannel(
    id: '卫视频道:深圳卫视4k',
    name: '深圳卫视4K',
    group: '卫视频道',
    badge: '深圳卫视',
    categories: <String>['卫视频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://livepull-tcyzb.sztv.com.cn/4KBack.m3u8',
        label: '官方直连·2160P',
        qualityRank: 100,
        headers: <String, String>{'User-Agent': 'AptvPlayer-UA'},
        decodeVerified: true,
        resolverUrl: 'http://101.35.240.114:88/live.php?id=%E6%B7%B1%E5%9C%B3%E5%8D%AB%E8%A7%864K',
      ),
    ],
  ),
  LiveChannel(
    id: '卫视频道:湖北卫视',
    name: '湖北卫视',
    group: '卫视频道',
    badge: '湖北卫视',
    categories: <String>['卫视频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://gslbmgsplive.miguvideo.com/wd_r2/2018/ocn/hubeiwshd/2000/index.m3u8?msisdn=dc32bc170e63d50c6a529b8ac5040db2&mdspid=&spid=600633&netType=0&sid=5910022163&pid=2028597139&timestamp=20261107090405&Channel_ID=0116_2600034600-99000-201600010010028&ProgramID=947472496&ParentNodeID=-99&assertID=5910022163&client_ip=110.188.239.109&SecurityKey=20261107090405&promotionId=&mvid=5900004355&mcid=500020&playurlVersion=WX-A1-9.10.1-SNAPSHOT&userid=&jmhm=&videocodec=h264&appCode=miguvideo_android&bean=mgspad&tid=android&conFee=0&puData=413f2d2ddc8ae57c630f98ad945da7bd&ddCalcu=d4b1v73aafyd2a5d429dddac889afe05376c&sv=10004&ct=android',
        label: '官方直连·720P',
        qualityRank: 60,
        headers: <String, String>{'User-Agent': 'AptvPlayer-UA'},
        decodeVerified: true,
        resolverUrl: 'http://101.35.240.114:88/live.php?id=%E6%B9%96%E5%8C%97%E5%8D%AB%E8%A7%86',
      ),
    ],
  ),
  LiveChannel(
    id: '卫视频道:湖南卫视',
    name: '湖南卫视',
    group: '卫视频道',
    badge: '湖南卫视',
    categories: <String>['卫视频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://hlsal-ldvt.qing.mgtv.com/nn_live/nn_x64/dWlwPTEyNy4wLjAuMSZ1aWQ9cWluZy1jbXMmbm5fdGltZXpvbmU9OCZjZG5leF9pZD1hbF9obHNfbGR2dCZ1dWlkPTliODY4NmU5ZTM2YzYwMmMmZT02OTE0NjA0JnY9MSZpZD1ITldTWkdTVCZzPTcwN2RiYTc2YzJjNmJmMTQ4MmUyZGYzOWU2NWM3YWFi/HNWSZGST.m3u8',
        label: '官方直连·2160P',
        qualityRank: 100,
        headers: <String, String>{'User-Agent': 'aliplayer'},
        decodeVerified: true,
        resolverUrl: 'http://101.35.240.114:88/live.php?id=%E6%B9%96%E5%8D%97%E5%8D%AB%E8%A7%864K',
      ),
    ],
  ),
  LiveChannel(
    id: '卫视频道:湖南卫视4k',
    name: '湖南卫视4K',
    group: '卫视频道',
    badge: '湖南卫视',
    categories: <String>['卫视频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://hlsal-ldvt.qing.mgtv.com/nn_live/nn_x64/dWlwPTEyNy4wLjAuMSZ1aWQ9cWluZy1jbXMmbm5fdGltZXpvbmU9OCZjZG5leF9pZD1hbF9obHNfbGR2dCZ1dWlkPTliODY4NmU5ZTM2YzYwMmMmZT02OTE0NjA0JnY9MSZpZD1ITldTWkdTVCZzPTcwN2RiYTc2YzJjNmJmMTQ4MmUyZGYzOWU2NWM3YWFi/HNWSZGST.m3u8',
        label: '官方直连·2160P',
        qualityRank: 100,
        headers: <String, String>{'User-Agent': 'aliplayer'},
        decodeVerified: true,
        resolverUrl: 'http://101.35.240.114:88/live.php?id=%E6%B9%96%E5%8D%97%E5%8D%AB%E8%A7%864K',
      ),
    ],
  ),
  LiveChannel(
    id: '地方频道:广州南国都市4k',
    name: '广州南国都市4K',
    group: '地方频道',
    badge: '广州南国',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://tencentplaybusiness.gztv.com/live/nanguodushi.m3u8',
        label: '补充源·名义4K·实测1080P',
        qualityRank: 80,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '地方频道:河北4k',
    name: '河北4K',
    group: '地方频道',
    badge: '河北4K',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://event.pull.hebtv.com:443/live/live101.m3u8',
        label: '官方直连·2160P',
        qualityRank: 100,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '地方频道:苏州4k',
    name: '苏州4K',
    group: '地方频道',
    badge: '苏州4K',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://tylive.kan0512.com/norecord/csztv4k_4k.m3u8',
        label: '官方直连·2160P',
        qualityRank: 100,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://live-auth.51kandianshi.com/szgd/csztv1.m3u8',
        label: '补充源·名义4K·实测1080P',
        qualityRank: 80,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '地方频道:苏州4k频道',
    name: '苏州4K频道',
    group: '地方频道',
    badge: '苏州4K',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://tylive.kan0512.com/norecord/csztv4k_fhd.m3u8',
        label: '补充源·名义4K·实测1080P',
        qualityRank: 80,
        decodeVerified: true,
      ),
    ],
  ),
];
