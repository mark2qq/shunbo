// GENERATED FILE — 由 tooling/gen_verified_channels.dart 生成，勿手改。
//
// 数据来源：昭昭TV(`cc.zztv.tvbox`) 的直播源总表 kds_common.txt（7270 条 / 3083 台）
// 筛法：① HTTP 层并发探测留下「返回合法 m3u8」的线路；② 逐条用 libmpv 播放，
//       判定「建起解码链 + 解码器零报错」。浅判据（HTTP 200 / 有 EXTINF /
//       分片首字节 0x47 / SPS 可解析）在央视加扰流上全部为真，但画面是满屏色块。
// 验证时间：2026-11-07（517 条通过，去重后 515 条线路 / 440 个台）
//
// **这份清单有保质期。** 公开直播地址以周为单位腐烂，`verifiedAt` 超过一个月
// 就该重跑 tooling/scan_batch_decode.dart + 本工具重新生成，而不是继续信它。
library;

import 'live_channel.dart';

/// 生成时间戳（ISO8601，UTC）。
const String kVerifiedLiveAt = '2026-11-07T00:46:39Z';

/// 实测解码通过的频道清单。
///
/// 只放**真的出得了画面**的线路：判据是 libmpv 建起解码链且解码器零报错，
/// 不是 HTTP 200，也不是「有 EXTINF / 分片首字节是 0x47」——
/// 这两种浅判据在央视加扰流上全部为真，但画面是满屏色块。
const List<LiveChannel> kVerifiedLiveChannels = <LiveChannel>[
  LiveChannel(
    id: '央视频道:cctv1',
    name: 'CCTV-1',
    group: '央视频道',
    badge: '1',
    categories: <String>['央视频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play.kankanlive.com/live/1698234869325962.m3u8',
        label: 'CCTV-1综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '央视频道:cctv2',
    name: 'CCTV-2',
    group: '央视频道',
    badge: '2',
    categories: <String>['央视频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play.kankanlive.com/live/1698234898628961.m3u8',
        label: 'CCTV-2财经 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '央视频道:cctv4中文国际',
    name: 'CCTV-4中文国际',
    group: '央视频道',
    badge: 'CCTV',
    categories: <String>['央视频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play.kankanlive.com/live/1698234936258960.m3u8',
        label: 'CCTV-4中文国际 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '央视频道:cctv5',
    name: 'CCTV-5',
    group: '央视频道',
    badge: '5',
    categories: <String>['央视频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://207.56.13.146:81/cdnlive/cctv5.m3u8',
        label: 'CCTV-5体育 720P',
        qualityRank: 60,
        headers: <String, String>{'User-Agent': 'AptvPlayer-UA'},
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '央视频道:cctv9',
    name: 'CCTV-9',
    group: '央视频道',
    badge: '9',
    categories: <String>['央视频道', '纪实'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play.kankanlive.com/live/1698423397390920.m3u8',
        label: 'CCTV-9纪录 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '央视频道:cctv10',
    name: 'CCTV-10',
    group: '央视频道',
    badge: '10',
    categories: <String>['央视频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play.kankanlive.com/live/1698423445959919.m3u8',
        label: 'CCTV-10科教 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '央视频道:cctv11',
    name: 'CCTV-11',
    group: '央视频道',
    badge: '11',
    categories: <String>['央视频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play.kankanlive.com/live/1698423476198918.m3u8',
        label: 'CCTV-11戏曲 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '央视频道:cctv12',
    name: 'CCTV-12',
    group: '央视频道',
    badge: '12',
    categories: <String>['央视频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play.kankanlive.com/live/1698423511884917.m3u8',
        label: 'CCTV-12社会与法 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '央视频道:cctv13',
    name: 'CCTV-13',
    group: '央视频道',
    badge: '13',
    categories: <String>['央视频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play.kankanlive.com/live/1698423543275916.m3u8',
        label: 'CCTV-13新闻 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '央视频道:cctv14',
    name: 'CCTV-14',
    group: '央视频道',
    badge: '14',
    categories: <String>['央视频道', '少儿'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play.kankanlive.com/live/1698423575756915.m3u8',
        label: 'CCTV-14少儿 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '央视频道:cctv15',
    name: 'CCTV-15',
    group: '央视频道',
    badge: '15',
    categories: <String>['央视频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play.kankanlive.com/live/1698423607826914.m3u8',
        label: 'CCTV-15音乐 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '央视频道:cctv17',
    name: 'CCTV-17',
    group: '央视频道',
    badge: '17',
    categories: <String>['央视频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play.kankanlive.com/live/1698423272597921.m3u8',
        label: 'CCTV-17农业农村 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '央视频道:cgtn',
    name: 'CGTN',
    group: '央视频道',
    badge: 'CGTN',
    categories: <String>['央视频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://english-liveali.cgtn.com/hls/yypdyyctzb/yypdyyctzbcd/playlist.m3u8',
        label: 'CGTN 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://english-liveali.cgtn.com/hls/yypdyyctzb/yypdyyctzbhd/playlist.m3u8',
        label: 'CGTN 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://english-liveali.cgtn.com/hls/yypdyyctzb/playlist.m3u8',
        label: 'CGTN 480P',
        qualityRank: 40,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://english-livetx.cgtn.com/hls/yypdyyctzb_hd.m3u8',
        label: 'CGTN 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://english-livetx.cgtn.com/hls/yypdyyctzb/playlist.m3u8',
        label: 'CGTN 480P',
        qualityRank: 40,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'http://play.kankanlive.com/live/1698423645566913.m3u8',
        label: 'CGTN 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '央视频道:cgtn纪录',
    name: 'CGTN纪录',
    group: '央视频道',
    badge: 'CGTN',
    categories: <String>['央视频道', '纪实'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://english-liveali.cgtn.com/hls/yypdjlctzb/yypdjlctzbcd/playlist.m3u8',
        label: 'CGTN纪录 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://english-liveali.cgtn.com/hls/yypdjlctzb/yypdjlctzbhd/playlist.m3u8',
        label: 'CGTN纪录 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://english-liveali.cgtn.com/hls/yypdjlctzb/playlist.m3u8',
        label: 'CGTN纪录 480P',
        qualityRank: 40,
        decodeVerified: true,
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
        url: 'http://ali-m-l.cztv.com/channels/lantian/channel001/1080p.m3u8',
        label: '浙江卫视HD 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'http://ali-m-l.cztv.com/channels/lantian/channel001/540p.m3u8',
        label: '浙江卫视 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '卫视频道:吉林卫视',
    name: '吉林卫视',
    group: '卫视频道',
    badge: '吉林卫视',
    categories: <String>['卫视频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream4.jlntv.cn/jlwshd/sd/live.m3u8',
        label: '吉林卫视HD 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '卫视频道:黑龙江卫视',
    name: '黑龙江卫视',
    group: '卫视频道',
    badge: '黑龙江卫',
    categories: <String>['卫视频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://idclive.hljtv.com:4430/live/hljws_own.m3u8',
        label: '黑龙江卫视 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '卫视频道:河南卫视',
    name: '河南卫视',
    group: '卫视频道',
    badge: '河南卫视',
    categories: <String>['卫视频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://media.hndyjyfw.gov.cn/live/jz-hnweishi/live.m3u8',
        label: '河南卫视 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '卫视频道:山东教育卫视',
    name: '山东教育卫视',
    group: '卫视频道',
    badge: '山东教育',
    categories: <String>['卫视频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://livewai.sdetv.com.cn/live/da4ebbb91ee8468db5a9d230a535391f_transios/playlist.m3u8',
        label: '山东教育卫视 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:东宁综合',
    name: '东宁综合',
    group: '地方频道',
    badge: '东宁综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/dongning.m3u8',
        label: '东宁综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/UQdxnsw8.m3u8',
        label: '东宁综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '安徽:淮北新闻频道',
    name: '淮北新闻频道',
    group: '地方频道',
    badge: '淮北新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://vms-x.hbnews.net/video/xwzh/index.m3u8',
        label: '淮北新闻频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '安徽:淮北经济生活',
    name: '淮北经济生活',
    group: '地方频道',
    badge: '淮北经济',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://vms-x.hbnews.net/video/JJSH/index.m3u8',
        label: '淮北经济生活 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '安徽:宿州新闻综合',
    name: '宿州新闻综合',
    group: '地方频道',
    badge: '宿州新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.ahsz.tv/video/s10001-szzh/index.m3u8',
        label: '宿州新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '安徽:宿州经济生活',
    name: '宿州经济生活',
    group: '地方频道',
    badge: '宿州经济',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.ahsz.tv/video/s10001-ggpd/index.m3u8',
        label: '宿州经济生活 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '安徽:宿州科教频道',
    name: '宿州科教频道',
    group: '地方频道',
    badge: '宿州科教',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.ahsz.tv/video/s10001-kxjy/index.m3u8',
        label: '宿州科教频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '安徽:阜阳生活频道',
    name: '阜阳生活频道',
    group: '地方频道',
    badge: '阜阳生活',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://41007.hlsplay.aodianyun.com/tv_radio_41007/tv_channel_2853.m3u8?auth_key=4835990486-0-0-dcdb6cc0aee871a664044ee7a3e83308&extra_key=jiEx28IYtuWJ1_w9kBTIOKIb4qAj8AdUpC907-3A-1heP_ZkcC9shKy2LFM4R9AiQLgQILrQJL1arILWCMAAizwLLRfZ5JckaokxNmuSv2KZs6SyYxsEki45eCNOFysmPiq_XKQRYYjgnOQiBte9knM20QVSjr7_kfGY0ZMQJoKWXhwFqOC7MaahYRl6X9Bv',
        label: '阜阳生活频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '安徽:亳州新闻频道',
    name: '亳州新闻频道',
    group: '地方频道',
    badge: '亳州新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://zbbf2.ahbztv.com/live/416.m3u8',
        label: '亳州新闻频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '安徽:亳州农村频道',
    name: '亳州农村频道',
    group: '地方频道',
    badge: '亳州农村',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://zbbf2.ahbztv.com/live/418.m3u8',
        label: '亳州农村频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '安徽:固镇新闻频道',
    name: '固镇新闻频道',
    group: '地方频道',
    badge: '固镇新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://www.guzhenm.com:7001/hls/hd-live.m3u8',
        label: '固镇新闻频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '安徽:阜南新闻综合',
    name: '阜南新闻综合',
    group: '地方频道',
    badge: '阜南新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://xhmm-new-live.media.xinhuamm.net/liveNoRecord/a42bf9ee9c224a44a393aafc33990c78_111ae5a842ff4b32ab277ed1d9e216c5.m3u8?auth_key=2017017629-3866c768f70a4b47a2352f7b746e7bc1-0-1470ba4cbd641cbe479da8838d3396da',
        label: '阜南新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '安徽:泾县新闻综合',
    name: '泾县新闻综合',
    group: '地方频道',
    badge: '泾县新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://apisave.jxnn.cn/hls/xwzonhe/playlist.m3u8',
        label: '泾县新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '安徽:淮北矿业新闻综合',
    name: '淮北矿业新闻综合',
    group: '地方频道',
    badge: '淮北矿业',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://xcblive.hbcoal.com/3/sd/live.m3u8',
        label: '淮北矿业新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '安徽:祁门综合频道',
    name: '祁门综合频道',
    group: '地方频道',
    badge: '祁门综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://file.qmxrmt.com/nmip-media/channellive/channel108622/playlist.m3u8',
        label: '祁门综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '安徽:灵璧综合频道',
    name: '灵璧综合频道',
    group: '地方频道',
    badge: '灵璧综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.cms.anhuinews.com/video/s10003-lbtv/index.m3u8',
        label: '灵璧综合频道 480P',
        qualityRank: 40,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '安徽:涡阳新闻综合',
    name: '涡阳新闻综合',
    group: '地方频道',
    badge: '涡阳新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://220.180.124.18:888/live/ch2.m3u8',
        label: '涡阳新闻综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'http://220.180.124.18:888/live/ch0.m3u8',
        label: '涡阳新闻综合 480P',
        qualityRank: 40,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '安徽:蒙城新闻频道',
    name: '蒙城新闻频道',
    group: '地方频道',
    badge: '蒙城新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://play-hsbj.vzan.com/200263/698384284379943742/live.m3u8',
        label: '蒙城新闻频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '安徽:潜山新闻综合',
    name: '潜山新闻综合',
    group: '地方频道',
    badge: '潜山新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://60.171.171.101:8278/rtmp_export/video22.m3u8',
        label: '潜山新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '安徽:金寨综合频道',
    name: '金寨综合频道',
    group: '地方频道',
    badge: '金寨综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://file.kanjinzhai.cn/hls/jinzhaixw/playlist.m3u8',
        label: '金寨综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '北京:党员教育频道',
    name: '党员教育频道',
    group: '地方频道',
    badge: '党员教育',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://12371wbndali.v.myalicdn.com/12371wbnd/dangyuanwang_2hd.m3u8',
        label: '党员教育频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '重庆:万州三峡移民',
    name: '万州三峡移民',
    group: '地方频道',
    badge: '万州三峡',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://123.146.162.24:8017/c2F0hmi/1000/live.m3u8',
        label: '万州三峡移民 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '重庆:璧山综合频道',
    name: '璧山综合频道',
    group: '地方频道',
    badge: '璧山综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://222.179.42.129:8181/hls1.m3u8',
        label: '璧山综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '重庆:合川综合频道',
    name: '合川综合频道',
    group: '地方频道',
    badge: '合川综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://125.62.24.72:8030/ch0.m3u8',
        label: '合川综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '重庆:江津新闻综合',
    name: '江津新闻综合',
    group: '地方频道',
    badge: '江津新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://222.179.155.21:1935/ch1.m3u8',
        label: '江津新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '重庆:荣昌综合频道',
    name: '荣昌综合频道',
    group: '地方频道',
    badge: '荣昌综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://183.64.181.25:40023/rongchang01.m3u8',
        label: '荣昌综合频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '福建:福州综合',
    name: '福州综合',
    group: '地方频道',
    badge: '福州综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.zohi.tv/video/s10001-fztv-1/index.m3u8',
        label: '福州综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '福建:福州生活',
    name: '福州生活',
    group: '地方频道',
    badge: '福州生活',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.zohi.tv/video/s10001-fztv-3/index.m3u8',
        label: '福州生活 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '福建:福州少儿',
    name: '福州少儿',
    group: '地方频道',
    badge: '福州少儿',
    categories: <String>['地方频道', '少儿'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.zohi.tv/video/s10001-fztv-4/index.m3u8',
        label: '福州少儿 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '福建:邵武新闻频道',
    name: '邵武新闻频道',
    group: '地方频道',
    badge: '邵武新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://lxhls.yisoftai.com/live/hw_lxlive.m3u8',
        label: '邵武新闻频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '福建:德化新闻综合',
    name: '德化新闻综合',
    group: '地方频道',
    badge: '德化新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://play.cmptp.fjgdwl.com/live/63a563ec75764af588f3215b0afa2588.m3u8',
        label: '德化新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '福建:晋江电视台',
    name: '晋江电视台',
    group: '地方频道',
    badge: '晋江电视',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://live.ijjnews.com/jjtv/sd/live.m3u8',
        label: '晋江电视台 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '福建:云霄综合',
    name: '云霄综合',
    group: '地方频道',
    badge: '云霄综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.zzyxxw.com:85/live/xwzh.m3u8',
        label: '云霄综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '甘肃:白银综合频道',
    name: '白银综合频道',
    group: '地方频道',
    badge: '白银综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play.kankanlive.com/live/1720408089419110.m3u8',
        label: '白银综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '甘肃:白银文化教育',
    name: '白银文化教育',
    group: '地方频道',
    badge: '白银文化',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play.kankanlive.com/live/1720408280309109.m3u8',
        label: '白银文化教育 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '甘肃:庆阳文体旅游',
    name: '庆阳文体旅游',
    group: '地方频道',
    badge: '庆阳文体',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://play.kankanlive.com/live/1704770893271981.m3u8',
        label: '庆阳文体旅游 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '甘肃:平凉新闻综合',
    name: '平凉新闻综合',
    group: '地方频道',
    badge: '平凉新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://play.kankanlive.com/live/1694661314645984.m3u8',
        label: '平凉新闻综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '甘肃:张掖新闻综合',
    name: '张掖新闻综合',
    group: '地方频道',
    badge: '张掖新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://play.kankanlive.com/live/1720583434627241.m3u8',
        label: '张掖新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '甘肃:永昌综合频道',
    name: '永昌综合频道',
    group: '地方频道',
    badge: '永昌综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://play.kankanlive.com/live/1652755738635915.m3u8',
        label: '永昌综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '甘肃:古浪综合频道',
    name: '古浪综合频道',
    group: '地方频道',
    badge: '古浪综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://play.kankanlive.com/live/1711282408137964.m3u8',
        label: '古浪综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '甘肃:迭部综合频道',
    name: '迭部综合频道',
    group: '地方频道',
    badge: '迭部综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://play.kankanlive.com/live/1711955827175988.m3u8',
        label: '迭部综合频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '甘肃:碌曲综合频道',
    name: '碌曲综合频道',
    group: '地方频道',
    badge: '碌曲综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://play.kankanlive.com/live/1711956095637983.m3u8',
        label: '碌曲综合频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '甘肃:西峰综合频道',
    name: '西峰综合频道',
    group: '地方频道',
    badge: '西峰综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://play.kankanlive.com/live/1683944827526991.m3u8',
        label: '西峰综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '甘肃:天祝综合频道',
    name: '天祝综合频道',
    group: '地方频道',
    badge: '天祝综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://play.kankanlive.com/live/1656487214793905.m3u8',
        label: '天祝综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '广东:广州综合',
    name: '广州综合',
    group: '地方频道',
    badge: '广州综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://tencentplaybusiness.gztv.com/live/zonghes.m3u8',
        label: '广州综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '广东:广州新闻',
    name: '广州新闻',
    group: '地方频道',
    badge: '广州新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://tencentplaybusiness.gztv.com/live/xinwen.m3u8',
        label: '广州新闻 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '广东:广州南国都市4k',
    name: '广州南国都市4K',
    group: '地方频道',
    badge: '广州南国',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://tencentplaybusiness.gztv.com/live/nanguodushi.m3u8',
        label: '广州南国都市4K 1080P',
        qualityRank: 100,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '广东:东莞综合',
    name: '东莞综合',
    group: '地方频道',
    badge: '东莞综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://stream.sun0769.com/dgrtv1/mp4tv1_1500/index.m3u8',
        label: '东莞综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '广东:韶关综合',
    name: '韶关综合',
    group: '地方频道',
    badge: '韶关综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://live.sgmsw.cn/hls/lhx1FUeZg/playlist.m3u8',
        label: '韶关综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '广东:汕尾综合',
    name: '汕尾综合',
    group: '地方频道',
    badge: '汕尾综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://iswtv.swrtv.com/live/xwzhpd.m3u8',
        label: '汕尾综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '广东:中山综合',
    name: '中山综合',
    group: '地方频道',
    badge: '中山综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://v.zsbtv.com.cn/lsdream/qTl38me/1000/live.m3u8',
        label: '中山综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '广西:南宁新闻综合',
    name: '南宁新闻综合',
    group: '地方频道',
    badge: '南宁新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://hls.nntv.cn/nnlive/XWZH_24.m3u8',
        label: '南宁新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '广西:南宁影视娱乐',
    name: '南宁影视娱乐',
    group: '地方频道',
    badge: '南宁影视',
    categories: <String>['地方频道', '影视'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://hls.nntv.cn/nnlive/YSYL_244.m3u8',
        label: '南宁影视娱乐 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '广西:南宁文旅生活',
    name: '南宁文旅生活',
    group: '地方频道',
    badge: '南宁文旅',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://hls.nntv.cn/nnlive/WLSH_24.m3u8',
        label: '南宁文旅生活 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '广西:玉林新闻综合',
    name: '玉林新闻综合',
    group: '地方频道',
    badge: '玉林新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://51742.hlsplay.aodianyun.com/tv_radio_51742/tv_channel_3289.m3u8?auth_key=4846965841-0-0-9764667fa15da8675d9343a9d685e93b&extra_key=3G7phQNujucfjDfVZX7XtFsfMjeELWIZpjNRADdYpRWOUdAykIw7RkxbAmiF9U934MKf8LNlRPUVp9ooT4UEvKJQlaJrZuMqJnw-UvayII5G4kw7jFgAqhhjpD4DC7gyZEtynT7zMnF8xzE3J1g6soaagSkmkag_tsjqRTH1zeM',
        label: '玉林新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '广西:来宾综合频道',
    name: '来宾综合频道',
    group: '地方频道',
    badge: '来宾综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://zb.gxlbamc.com:1935/live/lbzh.stream/playlist.m3u8',
        label: '来宾综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '广西:来宾新闻荟萃',
    name: '来宾新闻荟萃',
    group: '地方频道',
    badge: '来宾新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://zb.gxlbamc.com:1935/live/xwhc.stream/playlist.m3u8',
        label: '来宾新闻荟萃 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '广西:都安综合',
    name: '都安综合',
    group: '地方频道',
    badge: '都安综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rtmp.gdlive.gdmain.com/live/lgo97185.m3u8',
        label: '都安综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://lives.myun.tv/live/lgo97185.m3u8',
        label: '都安综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '广西:凌云综合',
    name: '凌云综合',
    group: '地方频道',
    badge: '凌云综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://lives.myun.tv/live/lnp683z5.m3u8',
        label: '凌云综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://rtmp.gdlive.gdmain.com/live/lnp683z5.m3u8',
        label: '凌云综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '广西:那坡综合',
    name: '那坡综合',
    group: '地方频道',
    badge: '那坡综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://lives.myun.tv/live/ljkp2890.m3u8',
        label: '那坡综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://rtmp.gdlive.gdmain.com/live/ljkp2890.m3u8',
        label: '那坡综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '广西:藤县综合',
    name: '藤县综合',
    group: '地方频道',
    badge: '藤县综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://srs.txdst.cn/live/txtv.m3u8',
        label: '藤县综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '贵州:黔南新闻综合',
    name: '黔南新闻综合',
    group: '地方频道',
    badge: '黔南新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://tvfile.qntv.net/nmip-media/channellive/channel108689/playlist.m3u8',
        label: '黔南新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '贵州:黔南公共频道',
    name: '黔南公共频道',
    group: '地方频道',
    badge: '黔南公共',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://tvfile.qntv.net/nmip-media/channellive/channel109066/playlist.m3u8',
        label: '黔南公共频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:邯郸新闻综合',
    name: '邯郸新闻综合',
    group: '地方频道',
    badge: '邯郸新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://jwcdnqx.hebyun.com.cn/live/hdxwzh/1500k/tzwj_video.m3u8',
        label: '邯郸新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:邯郸公共频道',
    name: '邯郸公共频道',
    group: '地方频道',
    badge: '邯郸公共',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://jwcdnqx.hebyun.com.cn/live/hdgg/1500k/tzwj_video.m3u8',
        label: '邯郸公共频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:邯郸科技教育',
    name: '邯郸科技教育',
    group: '地方频道',
    badge: '邯郸科技',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://jwcdnqx.hebyun.com.cn/live/hdkj/1500k/tzwj_video.m3u8',
        label: '邯郸科技教育 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:衡水新闻综合',
    name: '衡水新闻综合',
    group: '地方频道',
    badge: '衡水新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://hls.hsrtv.cn/live/hshstv1.m3u8',
        label: '衡水新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:衡水公共频道',
    name: '衡水公共频道',
    group: '地方频道',
    badge: '衡水公共',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://hls.hsrtv.cn/live/hshstv2.m3u8',
        label: '衡水公共频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:邢台综合频道',
    name: '邢台综合频道',
    group: '地方频道',
    badge: '邢台综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://jwplay.hebyun.com.cn/live/xtsrmtzs/1500k/tzwj_video.m3u8',
        label: '邢台综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:邢台城市生活',
    name: '邢台城市生活',
    group: '地方频道',
    badge: '邢台城市',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://jwcdnqx.hebyun.com.cn/live/xtcsshpd/1500k/tzwj_video.m3u8',
        label: '邢台城市生活 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:张家口一套',
    name: '张家口一套',
    group: '地方频道',
    badge: '张家口一',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://nlive.zjkgdcs.com:8572/live/xwzhpd.m3u8',
        label: '张家口一套 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:张家口二套',
    name: '张家口二套',
    group: '地方频道',
    badge: '张家口二',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://nlive.zjkgdcs.com:8572/live/zjktv2.m3u8',
        label: '张家口二套 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:涉县新闻综合',
    name: '涉县新闻综合',
    group: '地方频道',
    badge: '涉县新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://jwcdnqx.hebyun.com.cn/live/SXTV1/1500k/tzwj_video.m3u8',
        label: '涉县新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:枣强综合',
    name: '枣强综合',
    group: '地方频道',
    badge: '枣强综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://hbzqdb.chinashadt.com:1937/live/zqzh.stream_360p/playlist.m3u8',
        label: '枣强综合 480P',
        qualityRank: 40,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:昌黎综合频道',
    name: '昌黎综合频道',
    group: '地方频道',
    badge: '昌黎综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://jwcdnqx.hebyun.com.cn/live/clzhpd/1500k/tzwj_video.m3u8',
        label: '昌黎综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:迁西综合频道',
    name: '迁西综合频道',
    group: '地方频道',
    badge: '迁西综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://jwcdnqx.hebyun.com.cn/live/qxzhpd/1500k/tzwj_video.m3u8',
        label: '迁西综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:南宫电视一套',
    name: '南宫电视一套',
    group: '地方频道',
    badge: '南宫电视',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://jwcdnqx.hebyun.com.cn/live/ngtv1/1500k/tzwj_video.m3u8',
        label: '南宫电视一套 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:南和综合频道',
    name: '南和综合频道',
    group: '地方频道',
    badge: '南和综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://jwcdnqx.hebyun.com.cn/live/NHTV1/1500k/tzwj_video.m3u8',
        label: '南和综合频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:南和影视频道',
    name: '南和影视频道',
    group: '地方频道',
    badge: '南和影视',
    categories: <String>['地方频道', '影视'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://jwcdnqx.hebyun.com.cn/live/NHTV2/1500k/tzwj_video.m3u8',
        label: '南和影视频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:清河经济综艺',
    name: '清河经济综艺',
    group: '地方频道',
    badge: '清河经济',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://jwcdnqx.hebyun.com.cn/live/qinghe1/1500k/tzwj_video.m3u8',
        label: '清河经济综艺 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:任丘综合',
    name: '任丘综合',
    group: '地方频道',
    badge: '任丘综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://jwcdnqx.hebyun.com.cn/live/rqtv1/1500k/tzwj_video.m3u8',
        label: '任丘综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:肃宁一套',
    name: '肃宁一套',
    group: '地方频道',
    badge: '肃宁一套',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://jwplay.hebyun.com.cn/live/sndst01/1500k/tzwj_video.m3u8',
        label: '肃宁一套 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:涞源综合频道',
    name: '涞源综合频道',
    group: '地方频道',
    badge: '涞源综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://jwcdnqx.hebyun.com.cn/live/jiyunlaiyuan/1500k/tzwj_video.m3u8',
        label: '涞源综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:清苑新闻频道',
    name: '清苑新闻频道',
    group: '地方频道',
    badge: '清苑新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://jwcdnqx.hebyun.com.cn/live/qyxwpd/1500k/tzwj_video.m3u8',
        label: '清苑新闻频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:徐水综合频道',
    name: '徐水综合频道',
    group: '地方频道',
    badge: '徐水综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://jwcdnqx.hebyun.com.cn/live/jiyunxushui123/1500k/tzwj_video.m3u8',
        label: '徐水综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:丰宁综合频道',
    name: '丰宁综合频道',
    group: '地方频道',
    badge: '丰宁综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://jwcdnqx.hebyun.com.cn/live/fengningzonghe/1500k/tzwj_video.m3u8',
        label: '丰宁综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:滦平新闻频道',
    name: '滦平新闻频道',
    group: '地方频道',
    badge: '滦平新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://jwplay.hebyun.com.cn/live/LPTV001/1500k/tzwj_video.m3u8',
        label: '滦平新闻频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:平泉综合频道',
    name: '平泉综合频道',
    group: '地方频道',
    badge: '平泉综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://jwcdnqx.hebyun.com.cn/live/pqzh/1500k/tzwj_video.m3u8',
        label: '平泉综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:平泉影视频道',
    name: '平泉影视频道',
    group: '地方频道',
    badge: '平泉影视',
    categories: <String>['地方频道', '影视'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://jwcdnqx.hebyun.com.cn/live/pqys/1500k/tzwj_video.m3u8',
        label: '平泉影视频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:双滦新闻频道',
    name: '双滦新闻频道',
    group: '地方频道',
    badge: '双滦新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://jwcdnqx.hebyun.com.cn/live/slxw/1500k/tzwj_video.m3u8',
        label: '双滦新闻频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河北:兴隆综合频道',
    name: '兴隆综合频道',
    group: '地方频道',
    badge: '兴隆综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://jwcdnqx.hebyun.com.cn/live/xlzh/1500k/tzwj_video.m3u8',
        label: '兴隆综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:黑龙江文体',
    name: '黑龙江文体',
    group: '地方频道',
    badge: '黑龙江文',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://idclive.hljtv.com:4430/live/hljwy_hd.m3u8',
        label: '黑龙江文体 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:黑龙江新闻法治',
    name: '黑龙江新闻法治',
    group: '地方频道',
    badge: '黑龙江新',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://idclive.hljtv.com:4430/live/hljxw_hd.m3u8',
        label: '黑龙江新闻法治 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:黑龙江公共农业',
    name: '黑龙江公共农业',
    group: '地方频道',
    badge: '黑龙江公',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://idclive.hljtv.com:4430/live/hljgg_hd.m3u8',
        label: '黑龙江公共农业 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:黑龙江影视',
    name: '黑龙江影视',
    group: '地方频道',
    badge: '黑龙江影',
    categories: <String>['地方频道', '影视'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://idclive.hljtv.com:4430/live/hljys_hd.m3u8',
        label: '黑龙江影视 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:黑龙江都市',
    name: '黑龙江都市',
    group: '地方频道',
    badge: '黑龙江都',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://idclive.hljtv.com:4430/live/dushi_hd.m3u8',
        label: '黑龙江都市 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:黑龙江少儿',
    name: '黑龙江少儿',
    group: '地方频道',
    badge: '黑龙江少',
    categories: <String>['地方频道', '少儿'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://idclive.hljtv.com:4430/live/hljse_hd.m3u8',
        label: '黑龙江少儿 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:哈尔滨新闻综合',
    name: '哈尔滨新闻综合',
    group: '地方频道',
    badge: '哈尔滨新',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/haerbin.m3u8',
        label: '哈尔滨新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'http://stream.hrbtv.net/xwzh/sd/live.m3u8',
        label: '哈尔滨新闻综合 480P',
        qualityRank: 40,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/sPvVy8Ju.m3u8',
        label: '哈尔滨新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:哈尔滨影视',
    name: '哈尔滨影视',
    group: '地方频道',
    badge: '哈尔滨影',
    categories: <String>['地方频道', '影视'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream.hrbtv.net/yspd/sd/live.m3u8',
        label: '哈尔滨影视 480P',
        qualityRank: 40,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:哈尔滨生活',
    name: '哈尔滨生活',
    group: '地方频道',
    badge: '哈尔滨生',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream.hrbtv.net/shpd/sd/live.m3u8',
        label: '哈尔滨生活 480P',
        qualityRank: 40,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:大庆新闻综合',
    name: '大庆新闻综合',
    group: '地方频道',
    badge: '大庆新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/4WdrZLCq.m3u8',
        label: '大庆新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:绥化综合',
    name: '绥化综合',
    group: '地方频道',
    badge: '绥化综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://liveplaysr.dbw.cn/lsdream/amzPoBP/1000/live.m3u8',
        label: '绥化综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/suihua.m3u8',
        label: '绥化综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/v4o2g1hs.m3u8',
        label: '绥化综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:伊春综合频道',
    name: '伊春综合频道',
    group: '地方频道',
    badge: '伊春综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/yichun.m3u8',
        label: '伊春综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/vQtnS3vX.m3u8',
        label: '伊春综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:七台河新闻综合',
    name: '七台河新闻综合',
    group: '地方频道',
    badge: '七台河新',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/qitaihe.m3u8',
        label: '七台河新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'http://live.qthnews.org.cn:1935/live/live1/800k/tzwj_video.m3u8',
        label: '七台河新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/9FZ7k2XF.m3u8',
        label: '七台河新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:佳木斯新闻综合',
    name: '佳木斯新闻综合',
    group: '地方频道',
    badge: '佳木斯新',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/jiamusi.m3u8',
        label: '佳木斯新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/l9wQtsVs.m3u8',
        label: '佳木斯新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:鸡西新闻综合',
    name: '鸡西新闻综合',
    group: '地方频道',
    badge: '鸡西新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/jixi.m3u8',
        label: '鸡西新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/uqFwlQDH.m3u8',
        label: '鸡西新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:黑河新闻综合',
    name: '黑河新闻综合',
    group: '地方频道',
    badge: '黑河新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://liveplaysr.dbw.cn/lsdream/86qwqcs/1024/live.m3u8',
        label: '黑河新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:大兴安岭新闻综合',
    name: '大兴安岭新闻综合',
    group: '地方频道',
    badge: '大兴安岭',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/daxinganling.m3u8',
        label: '大兴安岭新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/H2kVyS15.m3u8',
        label: '大兴安岭新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:肇源综合',
    name: '肇源综合',
    group: '地方频道',
    badge: '肇源综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/XkQg7QSI.m3u8',
        label: '肇源综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:富锦电视台',
    name: '富锦电视台',
    group: '地方频道',
    badge: '富锦电视',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/fujin.m3u8',
        label: '富锦电视台 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/wOBN3GqO.m3u8',
        label: '富锦电视台 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:抚远电视台',
    name: '抚远电视台',
    group: '地方频道',
    badge: '抚远电视',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/fuyuan.m3u8',
        label: '抚远电视台 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/tVnkOTOG.m3u8',
        label: '抚远电视台 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:桦川新闻综合',
    name: '桦川新闻综合',
    group: '地方频道',
    badge: '桦川新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/NYQcW0fS.m3u8',
        label: '桦川新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:桦南综合',
    name: '桦南综合',
    group: '地方频道',
    badge: '桦南综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/huanan.m3u8',
        label: '桦南综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/76oCVZd3.m3u8',
        label: '桦南综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:汤原综合',
    name: '汤原综合',
    group: '地方频道',
    badge: '汤原综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/tangyuan.m3u8',
        label: '汤原综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/lt2CmppY.m3u8',
        label: '汤原综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:安达综合',
    name: '安达综合',
    group: '地方频道',
    badge: '安达综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/anda.m3u8',
        label: '安达综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/FsGxlDZQ.m3u8',
        label: '安达综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:庆安综合',
    name: '庆安综合',
    group: '地方频道',
    badge: '庆安综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/qingan.m3u8',
        label: '庆安综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/ayksl1Ur.m3u8',
        label: '庆安综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:青冈综合',
    name: '青冈综合',
    group: '地方频道',
    badge: '青冈综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/qinggang.m3u8',
        label: '青冈综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/bJGIloJe.m3u8',
        label: '青冈综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:望奎综合',
    name: '望奎综合',
    group: '地方频道',
    badge: '望奎综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/wangkui.m3u8',
        label: '望奎综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/d3loVdqX.m3u8',
        label: '望奎综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:肇东综合',
    name: '肇东综合',
    group: '地方频道',
    badge: '肇东综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/zhaodong.m3u8',
        label: '肇东综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/G84ZsUTP.m3u8',
        label: '肇东综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:巴彦电视台',
    name: '巴彦电视台',
    group: '地方频道',
    badge: '巴彦电视',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/bayan.m3u8',
        label: '巴彦电视台 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/vAtZi96R.m3u8',
        label: '巴彦电视台 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:方正综合',
    name: '方正综合',
    group: '地方频道',
    badge: '方正综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/fangzheng.m3u8',
        label: '方正综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/sSN2Uyb2.m3u8',
        label: '方正综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:呼兰综合',
    name: '呼兰综合',
    group: '地方频道',
    badge: '呼兰综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/hulan.m3u8',
        label: '呼兰综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/zja8TAIO.m3u8',
        label: '呼兰综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:尚志新闻综合',
    name: '尚志新闻综合',
    group: '地方频道',
    badge: '尚志新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/shangzhi.m3u8',
        label: '尚志新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/EQnKvoc9.m3u8',
        label: '尚志新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:通河新闻',
    name: '通河新闻',
    group: '地方频道',
    badge: '通河新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/tonghe.m3u8',
        label: '通河新闻 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/b71kCDir.m3u8',
        label: '通河新闻 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:五常综合',
    name: '五常综合',
    group: '地方频道',
    badge: '五常综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/wuchang.m3u8',
        label: '五常综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/R9bOklLT.m3u8',
        label: '五常综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:依兰新闻综合',
    name: '依兰新闻综合',
    group: '地方频道',
    badge: '依兰新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/yilan.m3u8',
        label: '依兰新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/4sTJDdbE.m3u8',
        label: '依兰新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:延寿综合',
    name: '延寿综合',
    group: '地方频道',
    badge: '延寿综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/yanshou.m3u8',
        label: '延寿综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/XBqKssjB.m3u8',
        label: '延寿综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:孙吴综合',
    name: '孙吴综合',
    group: '地方频道',
    badge: '孙吴综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/sunwu.m3u8',
        label: '孙吴综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/eXFjvNaf.m3u8',
        label: '孙吴综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:逊克综合',
    name: '逊克综合',
    group: '地方频道',
    badge: '逊克综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/a0CULO9O.m3u8',
        label: '逊克综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '安徽:安徽导视',
    name: '安徽导视',
    group: '地方频道',
    badge: '安徽导视',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://dspdhls.appcoo.com:8888/live/dspd/index.m3u8',
        label: '安徽导视 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:海林综合',
    name: '海林综合',
    group: '地方频道',
    badge: '海林综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/hailin.m3u8',
        label: '海林综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/lqo9Fcdy.m3u8',
        label: '海林综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:林口综合',
    name: '林口综合',
    group: '地方频道',
    badge: '林口综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/linkou.m3u8',
        label: '林口综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/pqheD07F.m3u8',
        label: '林口综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:绥芬河综合',
    name: '绥芬河综合',
    group: '地方频道',
    badge: '绥芬河综',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/suifenhe.m3u8',
        label: '绥芬河综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/pXxFNIbi.m3u8',
        label: '绥芬河综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:嘉荫综合频道',
    name: '嘉荫综合频道',
    group: '地方频道',
    badge: '嘉荫综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/k5IX9frJ.m3u8',
        label: '嘉荫综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:铁力综合频道',
    name: '铁力综合频道',
    group: '地方频道',
    badge: '铁力综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/tieli.m3u8',
        label: '铁力综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/iUtbDFud.m3u8',
        label: '铁力综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:拜泉综合',
    name: '拜泉综合',
    group: '地方频道',
    badge: '拜泉综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/baiquan.m3u8',
        label: '拜泉综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/zHtOXXUz.m3u8',
        label: '拜泉综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:富裕综合',
    name: '富裕综合',
    group: '地方频道',
    badge: '富裕综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://221.209.44.174:1980/hls/1001.m3u8',
        label: '富裕综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:甘南县综合',
    name: '甘南县综合',
    group: '地方频道',
    badge: '甘南县综',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/gannan.m3u8',
        label: '甘南县综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/YbFyF4Jb.m3u8',
        label: '甘南县综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:克东综合',
    name: '克东综合',
    group: '地方频道',
    badge: '克东综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/kedong.m3u8',
        label: '克东综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/PO1DiGiN.m3u8',
        label: '克东综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:龙江综合',
    name: '龙江综合',
    group: '地方频道',
    badge: '龙江综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/longjiang.m3u8',
        label: '龙江综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/vRSdDMSR.m3u8',
        label: '龙江综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:讷河综合',
    name: '讷河综合',
    group: '地方频道',
    badge: '讷河综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/nehe.m3u8',
        label: '讷河综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/PXWxDY1V.m3u8',
        label: '讷河综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:泰来综合',
    name: '泰来综合',
    group: '地方频道',
    badge: '泰来综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/tailai.m3u8',
        label: '泰来综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/cfkAgOUK.m3u8',
        label: '泰来综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:依安综合',
    name: '依安综合',
    group: '地方频道',
    badge: '依安综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/yian.m3u8',
        label: '依安综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/4hhgo1mX.m3u8',
        label: '依安综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:呼玛综合',
    name: '呼玛综合',
    group: '地方频道',
    badge: '呼玛综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/huma.m3u8',
        label: '呼玛综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/yN3vDovm.m3u8',
        label: '呼玛综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:漠河综合',
    name: '漠河综合',
    group: '地方频道',
    badge: '漠河综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/rlVvbTZN.m3u8',
        label: '漠河综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/mohe.m3u8',
        label: '漠河综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:塔河综合',
    name: '塔河综合',
    group: '地方频道',
    badge: '塔河综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/tahe.m3u8',
        label: '塔河综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/qXrATpGj.m3u8',
        label: '塔河综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:虎林综合',
    name: '虎林综合',
    group: '地方频道',
    badge: '虎林综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/hulin.m3u8',
        label: '虎林综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/SJJAEqBS.m3u8',
        label: '虎林综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:鸡东综合',
    name: '鸡东综合',
    group: '地方频道',
    badge: '鸡东综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/jidong.m3u8',
        label: '鸡东综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/o4NExHSz.m3u8',
        label: '鸡东综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:饶河综合',
    name: '饶河综合',
    group: '地方频道',
    badge: '饶河综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/raohe.m3u8',
        label: '饶河综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/DokNxER6.m3u8',
        label: '饶河综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '黑龙江:勃利综合频道',
    name: '勃利综合频道',
    group: '地方频道',
    badge: '勃利综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rmplive.hljtv.com/live/boli.m3u8',
        label: '勃利综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://masterpull.hljtv.com/live/6rx9bifO.m3u8',
        label: '勃利综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河南:河南都市',
    name: '河南都市',
    group: '地方频道',
    badge: '河南都市',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://media.hndyjyfw.gov.cn/live/jz-henandushi/live.m3u8',
        label: '河南都市 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河南:河南民生',
    name: '河南民生',
    group: '地方频道',
    badge: '河南民生',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://media.hndyjyfw.gov.cn/live/jz-henanminsheng/live.m3u8',
        label: '河南民生 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河南:河南戏曲',
    name: '河南戏曲',
    group: '地方频道',
    badge: '河南戏曲',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://media.hndyjyfw.gov.cn/live/jz-henanliyuan/live.m3u8',
        label: '河南戏曲 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河南:河南远程党员教育',
    name: '河南远程党员教育',
    group: '地方频道',
    badge: '河南远程',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://media.hndyjyfw.gov.cn/live/jz-m-ycjy/live.m3u8',
        label: '河南远程党员教育 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河南:郑州教育频道',
    name: '郑州教育频道',
    group: '地方频道',
    badge: '郑州教育',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://livezzutv.chinamcache.com/zb02/zb02.m3u8?auth_key=1694413413-0-0-fdccf5824fa42b4a2e285f73e7d2d12b',
        label: '郑州教育频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河南:焦作综合频道',
    name: '焦作综合频道',
    group: '地方频道',
    badge: '焦作综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://zhpull.dxhmt.cn/jiaozuo/b75a92c9503e47cf9e89f7ff247b65f2/playlist.m3u8',
        label: '焦作综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河南:焦作公共频道',
    name: '焦作公共频道',
    group: '地方频道',
    badge: '焦作公共',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://zhpull.dxhmt.cn/jiaozuo/29b65b69130c4ef1a3283cc7b913da05/playlist.m3u8',
        label: '焦作公共频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河南:信阳综合频道',
    name: '信阳综合频道',
    group: '地方频道',
    badge: '信阳综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rtmp.xytv.cn/live/514f8a62d467.m3u8',
        label: '信阳综合频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河南:信阳文旅频道',
    name: '信阳文旅频道',
    group: '地方频道',
    badge: '信阳文旅',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://rtmp.xytv.cn/live/118cfcf8c6df.m3u8',
        label: '信阳文旅频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河南:平顶山教育',
    name: '平顶山教育',
    group: '地方频道',
    badge: '平顶山教',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://219.150.204.175:81/hls/live1.m3u8',
        label: '平顶山教育 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河南:永城新闻综合',
    name: '永城新闻综合',
    group: '地方频道',
    badge: '永城新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://tvpull.dxhmt.cn:9081/tv/11481-1.m3u8',
        label: '永城新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河南:上街电视台',
    name: '上街电视台',
    group: '地方频道',
    badge: '上街电视',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://tvpull.dxhmt.cn:9081/tv/10106-1.m3u8',
        label: '上街电视台 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河南:荥阳综合',
    name: '荥阳综合',
    group: '地方频道',
    badge: '荥阳综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://tvpull.dxhmt.cn:9081/tv/10182-1.m3u8',
        label: '荥阳综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河南:新野综合',
    name: '新野综合',
    group: '地方频道',
    badge: '新野综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://tvpull.dxhmt.cn:9081/tv/11329-1.m3u8',
        label: '新野综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河南:延津综合频道',
    name: '延津综合频道',
    group: '地方频道',
    badge: '延津综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://tvpull.dxhmt.cn:9081/tv/10726-1.m3u8',
        label: '延津综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河南:陕州综合频道',
    name: '陕州综合频道',
    group: '地方频道',
    badge: '陕州综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://tvpull.dxhmt.cn:9081/tv/11203-1.m3u8',
        label: '陕州综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '湖北:恩施文旅',
    name: '恩施文旅',
    group: '地方频道',
    badge: '恩施文旅',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://46240.hlsplay.aodianyun.com/tv_radio_46240/tv_channel_1811.m3u8?auth_key=4857760464-0-0-ecabcbf26d39dc20cde584db2fa2a053&extra_key=D1dJezG95YTkYytoe8tr2Qhf-jhFFJmJpij9JNzLnfjYgxE5Q69rjZT1b2VrOxeb2zvhRo107e0Ze_h5agVjcLhNxl4RzjBShtdz-pQKUqaNbHnJMUJaS637QCoHNkKlJAb5i0lkR8MlxmIB6LIGojFm8kqvpZp_pI7SG10olDg',
        label: '恩施文旅 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '湖北:十堰经济旅游',
    name: '十堰经济旅游',
    group: '地方频道',
    badge: '十堰经济',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://p8.vzan.com/slowlive/701367497774448672/live.m3u8',
        label: '十堰经济旅游 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '湖北:荆门新闻综合',
    name: '荆门新闻综合',
    group: '地方频道',
    badge: '荆门新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream.jmtv.com.cn/xwzh/sd/live.m3u8',
        label: '荆门新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '湖北:荆门科教文旅',
    name: '荆门科教文旅',
    group: '地方频道',
    badge: '荆门科教',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream.jmtv.com.cn/ggsh/sd/live.m3u8',
        label: '荆门科教文旅 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '湖北:咸丰新闻综合',
    name: '咸丰新闻综合',
    group: '地方频道',
    badge: '咸丰新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://46240.hlsplay.aodianyun.com/tv_radio_46240/tv_channel_3567.m3u8?auth_key=4867549325-0-0-cc7ce201270f1bfda8bd5c54e0e5739c&extra_key=hKfYhS2z6614oV0yCs-AFVt7IpvlJJgoGCHOij1q2onFz-Yr5Us2Cd41rIlv4l1XjWrMXCVgYMdOmrNAgjF2W_2a6vxf1HxtHHoYEC6BCIqSeo4VGtaHFxadD2xtzAtmsjFPKB3DP_Ev_ci_KC8TQllAks-AnwmJWoohc4XLA6Q',
        label: '咸丰新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '湖北:麻城综合',
    name: '麻城综合',
    group: '地方频道',
    badge: '麻城综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://video.yscxy.cn:8888/mctv1.m3u8',
        label: '麻城综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '湖北:崇阳新闻综合',
    name: '崇阳新闻综合',
    group: '地方频道',
    badge: '崇阳新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://61.184.176.248:10500/live/live.m3u8',
        label: '崇阳新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '湖北:江夏新闻综合',
    name: '江夏新闻综合',
    group: '地方频道',
    badge: '江夏新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://59.175.226.142:280/gb28181/xwzh.m3u8',
        label: '江夏新闻综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '湖南:湘潭新闻综合',
    name: '湘潭新闻综合',
    group: '地方频道',
    badge: '湘潭新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.hnxttv.com:9601/live/xwzh/800K/tzwj_video.m3u8',
        label: '湘潭新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:苏州新闻综合',
    name: '苏州新闻综合',
    group: '地方频道',
    badge: '苏州新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://live-auth.51kandianshi.com/szgd/csztv1.m3u8',
        label: '苏州新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:苏州社会经济',
    name: '苏州社会经济',
    group: '地方频道',
    badge: '苏州社会',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://live-auth.51kandianshi.com/szgd/csztv2.m3u8',
        label: '苏州社会经济 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:苏州文化生活',
    name: '苏州文化生活',
    group: '地方频道',
    badge: '苏州文化',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://live-auth.51kandianshi.com/szgd/csztv3.m3u8',
        label: '苏州文化生活 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:苏州电影娱乐信息',
    name: '苏州电影娱乐信息',
    group: '地方频道',
    badge: '苏州电影',
    categories: <String>['地方频道', '影视'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://live-auth.51kandianshi.com/szgd/csztv4.m3u8',
        label: '苏州电影娱乐信息 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:苏州生活资讯',
    name: '苏州生活资讯',
    group: '地方频道',
    badge: '苏州生活',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://live-auth.51kandianshi.com/szgd/csztv5.m3u8',
        label: '苏州生活资讯 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:徐州新闻综合',
    name: '徐州新闻综合',
    group: '地方频道',
    badge: '徐州新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream3.huaihai.tv/xwzh1t/sd/live.m3u8',
        label: '徐州新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:徐州经济生活',
    name: '徐州经济生活',
    group: '地方频道',
    badge: '徐州经济',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream3.huaihai.tv/xz2t/sd/live.m3u8',
        label: '徐州经济生活 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:徐州文艺影视',
    name: '徐州文艺影视',
    group: '地方频道',
    badge: '徐州文艺',
    categories: <String>['地方频道', '影视'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream3.huaihai.tv/xz3t/sd/live.m3u8',
        label: '徐州文艺影视 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:徐州公共频道',
    name: '徐州公共频道',
    group: '地方频道',
    badge: '徐州公共',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream3.huaihai.tv/xz4t/sd/live.m3u8',
        label: '徐州公共频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:无锡移动电视',
    name: '无锡移动电视',
    group: '地方频道',
    badge: '无锡移动',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://m.m3u8.wifiwx.com/live/wifiwx-494.m3u8',
        label: '无锡移动电视 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:泰州新闻综合',
    name: '泰州新闻综合',
    group: '地方频道',
    badge: '泰州新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream1.mytaizhou.net/xwzhnew/sd/live.m3u8',
        label: '泰州新闻综合 480P',
        qualityRank: 40,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:泰州经济生活',
    name: '泰州经济生活',
    group: '地方频道',
    badge: '泰州经济',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream1.mytaizhou.net/jjshnew/playlist.m3u8',
        label: '泰州经济生活 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:泰州影视娱乐',
    name: '泰州影视娱乐',
    group: '地方频道',
    badge: '泰州影视',
    categories: <String>['地方频道', '影视'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream1.mytaizhou.net/ysylnew/playlist.m3u8',
        label: '泰州影视娱乐 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:张家港民生频道',
    name: '张家港民生频道',
    group: '地方频道',
    badge: '张家港民',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://3gvod.zjgonline.com.cn:1935/live/_definst_/shehuishenghuo_app/chunklist.m3u8',
        label: '张家港民生频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:溧阳新闻综合',
    name: '溧阳新闻综合',
    group: '地方频道',
    badge: '溧阳新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://tvlive.cxzly.com/live/tv.m3u8',
        label: '溧阳新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:武进新闻频道',
    name: '武进新闻频道',
    group: '地方频道',
    badge: '武进新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://live.wjyanghu.com/live/CH1.m3u8',
        label: '武进新闻频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:邳州综合频道',
    name: '邳州综合频道',
    group: '地方频道',
    badge: '邳州综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://liveplus.pznews.com/pzzhpd/sd/live.m3u8',
        label: '邳州综合频道 480P',
        qualityRank: 40,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:句容新闻综合',
    name: '句容新闻综合',
    group: '地方频道',
    badge: '句容新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://jrlive.jrntv.com/live/_definst_/jrxwzhs/playlist.m3u8',
        label: '句容新闻综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:句容生活频道',
    name: '句容生活频道',
    group: '地方频道',
    badge: '句容生活',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://jrlive.jrntv.com/live/_definst_/shenghuos/playlist.m3u8',
        label: '句容生活频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:句容影视频道',
    name: '句容影视频道',
    group: '地方频道',
    badge: '句容影视',
    categories: <String>['地方频道', '影视'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://jrlive.jrntv.com/live/_definst_/yingshis/playlist.m3u8',
        label: '句容影视频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:句容党建频道',
    name: '句容党建频道',
    group: '地方频道',
    badge: '句容党建',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://jrlive.jrntv.com/live/_definst_/dangjians/playlist.m3u8',
        label: '句容党建频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:靖江新闻综合',
    name: '靖江新闻综合',
    group: '地方频道',
    badge: '靖江新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://visit.jjbctv.com:1935/live/xwzhmb/playlist.m3u8',
        label: '靖江新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江西:德兴新闻综合',
    name: '德兴新闻综合',
    group: '地方频道',
    badge: '德兴新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://218.64.164.152:5021/live_hls/2/playlist.m3u8',
        label: '德兴新闻综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:长春综合',
    name: '长春综合',
    group: '地方频道',
    badge: '长春综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream2.jlntv.cn/jlcc/sd/live.m3u8',
        label: '长春综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:通化新闻',
    name: '通化新闻',
    group: '地方频道',
    badge: '通化新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream2.jlntv.cn/tonghua1/sd/live.m3u8',
        label: '通化新闻 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:吉林市新闻综合',
    name: '吉林市新闻综合',
    group: '地方频道',
    badge: '吉林市新',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream2.jlntv.cn/jilin1/sd/live.m3u8',
        label: '吉林市新闻综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:四平新闻综合',
    name: '四平新闻综合',
    group: '地方频道',
    badge: '四平新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream2.jlntv.cn/sptv/sd/live.m3u8',
        label: '四平新闻综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:辽源新闻综合',
    name: '辽源新闻综合',
    group: '地方频道',
    badge: '辽源新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream2.jlntv.cn/liaoyuan1/sd/live.m3u8',
        label: '辽源新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:白山旅游生活',
    name: '白山旅游生活',
    group: '地方频道',
    badge: '白山旅游',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream8.jlntv.cn/baishan2/playlist.m3u8',
        label: '白山旅游生活 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:松原新闻综合',
    name: '松原新闻综合',
    group: '地方频道',
    badge: '松原新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream2.jlntv.cn/sytv/sd/live.m3u8',
        label: '松原新闻综合 480P',
        qualityRank: 40,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:松原公共频道',
    name: '松原公共频道',
    group: '地方频道',
    badge: '松原公共',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream8.jlntv.cn/sytv2/sd/live.m3u8',
        label: '松原公共频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:白城新闻综合',
    name: '白城新闻综合',
    group: '地方频道',
    badge: '白城新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream2.jlntv.cn/baicheng1/sd/live.m3u8',
        label: '白城新闻综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:长白山电视台',
    name: '长白山电视台',
    group: '地方频道',
    badge: '长白山电',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream8.jlntv.cn/cbstv/sd/live.m3u8',
        label: '长白山电视台 480P',
        qualityRank: 40,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:德惠综合',
    name: '德惠综合',
    group: '地方频道',
    badge: '德惠综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream11.jlntv.cn/dehuitv/sd/live.m3u8',
        label: '德惠综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:九台综合',
    name: '九台综合',
    group: '地方频道',
    badge: '九台综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream10.jlntv.cn/jiutaitv/sd/live.m3u8',
        label: '九台综合 480P',
        qualityRank: 40,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:农安新闻综合',
    name: '农安新闻综合',
    group: '地方频道',
    badge: '农安新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream2.jlntv.cn/naxw/sd/live.m3u8',
        label: '农安新闻综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:双阳综合',
    name: '双阳综合',
    group: '地方频道',
    badge: '双阳综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream11.jlntv.cn/shuangyang/sd/live.m3u8',
        label: '双阳综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:榆树综合频道',
    name: '榆树综合频道',
    group: '地方频道',
    badge: '榆树综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream11.jlntv.cn/yushuds/sd/live.m3u8',
        label: '榆树综合频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:长白新闻综合',
    name: '长白新闻综合',
    group: '地方频道',
    badge: '长白新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://hplayer1.juyun.tv/camera/11347146.m3u8',
        label: '长白新闻综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:长白朝语频道',
    name: '长白朝语频道',
    group: '地方频道',
    badge: '长白朝语',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://hplayer1.juyun.tv/camera/11344136.m3u8',
        label: '长白朝语频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:江源综合频道',
    name: '江源综合频道',
    group: '地方频道',
    badge: '江源综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream10.jlntv.cn/jiangyuantv/sd/live.m3u8',
        label: '江源综合频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:靖宇综合频道',
    name: '靖宇综合频道',
    group: '地方频道',
    badge: '靖宇综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream8.jlntv.cn/jytv/sd/live.m3u8',
        label: '靖宇综合频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:敦化一套',
    name: '敦化一套',
    group: '地方频道',
    badge: '敦化一套',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream8.jlntv.cn/dhtv/playlist.m3u8',
        label: '敦化一套 480P',
        qualityRank: 40,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:珲春新闻综合',
    name: '珲春新闻综合',
    group: '地方频道',
    badge: '珲春新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream8.jlntv.cn/hctv/sd/live.m3u8',
        label: '珲春新闻综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:龙井综合',
    name: '龙井综合',
    group: '地方频道',
    badge: '龙井综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream8.jlntv.cn/ljtv/sd/live.m3u8',
        label: '龙井综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:公主岭综合',
    name: '公主岭综合',
    group: '地方频道',
    badge: '公主岭综',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream5.jlntv.cn/gzl/sd/live.m3u8',
        label: '公主岭综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:桦甸综合',
    name: '桦甸综合',
    group: '地方频道',
    badge: '桦甸综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream10.jlntv.cn/huadian/sd/live.m3u8',
        label: '桦甸综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:磐石综合',
    name: '磐石综合',
    group: '地方频道',
    badge: '磐石综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream5.jlntv.cn/ps/sd/live.m3u8',
        label: '磐石综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:舒兰新闻综合',
    name: '舒兰新闻综合',
    group: '地方频道',
    badge: '舒兰新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream8.jlntv.cn/shulan/sd/live.m3u8',
        label: '舒兰新闻综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:永吉综合频道',
    name: '永吉综合频道',
    group: '地方频道',
    badge: '永吉综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream10.jlntv.cn/yongji/sd/live.m3u8',
        label: '永吉综合频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:东丰综合',
    name: '东丰综合',
    group: '地方频道',
    badge: '东丰综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream5.jlntv.cn/df/sd/live.m3u8',
        label: '东丰综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:东辽综合',
    name: '东辽综合',
    group: '地方频道',
    badge: '东辽综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream5.jlntv.cn/dl/sd/live.m3u8',
        label: '东辽综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:双辽综合',
    name: '双辽综合',
    group: '地方频道',
    badge: '双辽综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream5.jlntv.cn/sl/sd/live.m3u8',
        label: '双辽综合 480P',
        qualityRank: 40,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:前郭综合频道',
    name: '前郭综合频道',
    group: '地方频道',
    badge: '前郭综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream2.jlntv.cn/qg/sd/live.m3u8',
        label: '前郭综合频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:辉南新闻综合',
    name: '辉南新闻综合',
    group: '地方频道',
    badge: '辉南新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream5.jlntv.cn/hn/sd/live.m3u8',
        label: '辉南新闻综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:集安综合频道',
    name: '集安综合频道',
    group: '地方频道',
    badge: '集安综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream2.jlntv.cn/ja/sd/live.m3u8',
        label: '集安综合频道 480P',
        qualityRank: 40,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:柳河综合',
    name: '柳河综合',
    group: '地方频道',
    badge: '柳河综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream5.jlntv.cn/lh/sd/live.m3u8',
        label: '柳河综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:通化县综合',
    name: '通化县综合',
    group: '地方频道',
    badge: '通化县综',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream5.jlntv.cn/thx/sd/live.m3u8',
        label: '通化县综合 480P',
        qualityRank: 40,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '吉林:汪清综合',
    name: '汪清综合',
    group: '地方频道',
    badge: '汪清综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://stream5.jlntv.cn/wq/sd/live.m3u8',
        label: '汪清综合 480P',
        qualityRank: 40,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '内蒙古:呼和浩特新闻综合',
    name: '呼和浩特新闻综合',
    group: '地方频道',
    badge: '呼和浩特',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play1-qk.nmtv.cn/live/1735545967595013.m3u8',
        label: '呼和浩特新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '内蒙古:鄂尔多斯新闻综合',
    name: '鄂尔多斯新闻综合',
    group: '地方频道',
    badge: '鄂尔多斯',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play1-qk.nmtv.cn/live/1735546299241021.m3u8',
        label: '鄂尔多斯新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '内蒙古:包头新闻综合',
    name: '包头新闻综合',
    group: '地方频道',
    badge: '包头新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play1-qk.nmtv.cn/live/1735546150395017.m3u8',
        label: '包头新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '内蒙古:赤峰新闻综合',
    name: '赤峰新闻综合',
    group: '地方频道',
    badge: '赤峰新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play1-qk.nmtv.cn/live/1735546697341033.m3u8',
        label: '赤峰新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '内蒙古:兴安新闻综合',
    name: '兴安新闻综合',
    group: '地方频道',
    badge: '兴安新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play1-qk.nmtv.cn/live/1735546886977046.m3u8',
        label: '兴安新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '内蒙古:通辽新闻综合',
    name: '通辽新闻综合',
    group: '地方频道',
    badge: '通辽新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play1-qk.nmtv.cn/live/1735546745882037.m3u8',
        label: '通辽新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '内蒙古:呼伦贝尔新闻综合',
    name: '呼伦贝尔新闻综合',
    group: '地方频道',
    badge: '呼伦贝尔',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play1-qk.nmtv.cn/live/1735546791130040.m3u8',
        label: '呼伦贝尔新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '内蒙古:巴彦淖尔新闻综合',
    name: '巴彦淖尔新闻综合',
    group: '地方频道',
    badge: '巴彦淖尔',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play1-qk.nmtv.cn/live/1735546423467029.m3u8',
        label: '巴彦淖尔新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '内蒙古:阿拉善新闻综合',
    name: '阿拉善新闻综合',
    group: '地方频道',
    badge: '阿拉善新',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play1-qk.nmtv.cn/live/1735547046115053.m3u8',
        label: '阿拉善新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '内蒙古:乌兰察布新闻综合',
    name: '乌兰察布新闻综合',
    group: '地方频道',
    badge: '乌兰察布',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play1-qk.nmtv.cn/live/1735546836103043.m3u8',
        label: '乌兰察布新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'http://222.74.233.6/xwzhpd/sd/live.m3u8',
        label: '乌兰察布新闻综合 480P',
        qualityRank: 40,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '内蒙古:乌兰察布经济生活',
    name: '乌兰察布经济生活',
    group: '地方频道',
    badge: '乌兰察布',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://222.74.233.6/jjshpd/sd/live.m3u8',
        label: '乌兰察布经济生活 480P',
        qualityRank: 40,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '内蒙古:乌海新闻综合',
    name: '乌海新闻综合',
    group: '地方频道',
    badge: '乌海新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play1-qk.nmtv.cn/live/1735546358166026.m3u8',
        label: '乌海新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'http://live.wuhainews.org.cn/xwzh/sd/live.m3u8',
        label: '乌海新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '内蒙古:乌海都市生活',
    name: '乌海都市生活',
    group: '地方频道',
    badge: '乌海都市',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.wuhainews.org.cn/dssh/sd/live.m3u8',
        label: '乌海都市生活 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '内蒙古:锡林郭勒盟一套',
    name: '锡林郭勒盟一套',
    group: '地方频道',
    badge: '锡林郭勒',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play1-qk.nmtv.cn/live/1735546994821050.m3u8',
        label: '锡林郭勒盟一套 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '青海:西宁新闻综合',
    name: '西宁新闻综合',
    group: '地方频道',
    badge: '西宁新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://liveout.xntv.tv/a65jur/96iln2.m3u8',
        label: '西宁新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '陕西:西安新闻综合',
    name: '西安新闻综合',
    group: '地方频道',
    badge: '西安新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://xatv-yt.xiancity.cn/live/1/index.m3u8',
        label: '西安新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '陕西:西安都市频道',
    name: '西安都市频道',
    group: '地方频道',
    badge: '西安都市',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://xatv-yt.xiancity.cn/live/2/index.m3u8',
        label: '西安都市频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '陕西:西安戏剧影视',
    name: '西安戏剧影视',
    group: '地方频道',
    badge: '西安戏剧',
    categories: <String>['地方频道', '影视'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://xatv-yt.xiancity.cn/live/4/index.m3u8',
        label: '西安戏剧影视 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '陕西:西安丝路频道',
    name: '西安丝路频道',
    group: '地方频道',
    badge: '西安丝路',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://xatv-yt.xiancity.cn/live/5/index.m3u8',
        label: '西安丝路频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '陕西:西安移动电视',
    name: '西安移动电视',
    group: '地方频道',
    badge: '西安移动',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://xatv-yt.xiancity.cn/live/7/index.m3u8',
        label: '西安移动电视 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山东:烟台新闻综合',
    name: '烟台新闻综合',
    group: '地方频道',
    badge: '烟台新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.yantaitv.cn/live/212803c257394d429606a0815d20e3ce/710c510f5a5441cb8fc062e2dd3e1a76.m3u8',
        label: '烟台新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山东:烟台公共频道',
    name: '烟台公共频道',
    group: '地方频道',
    badge: '烟台公共',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.yantaitv.cn/live/412a6764092149faa58f80a0fd8004e9/22bbe85c960145dc95fc25e699d0fb3a-1.m3u8',
        label: '烟台公共频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山东:临沂综合频道',
    name: '临沂综合频道',
    group: '地方频道',
    badge: '临沂综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://m3u8-channel.lytv.tv/nmip-media/channellive/channel111841/playlist.m3u8',
        label: '临沂综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山东:临沂经济频道',
    name: '临沂经济频道',
    group: '地方频道',
    badge: '临沂经济',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://m3u8-channel.lytv.tv/nmip-media/channellive/channel115062/playlist.m3u8',
        label: '临沂经济频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山东:菏泽新闻综合',
    name: '菏泽新闻综合',
    group: '地方频道',
    badge: '菏泽新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.hznet.tv:1935/live/live1/500K/tzwj_video.m3u8',
        label: '菏泽新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山东:菏泽经济生活',
    name: '菏泽经济生活',
    group: '地方频道',
    badge: '菏泽经济',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.hznet.tv:1935/live/live2/500K/tzwj_video.m3u8',
        label: '菏泽经济生活 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山西:晋城新闻',
    name: '晋城新闻',
    group: '地方频道',
    badge: '晋城新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.jinnews.com.cn/xwzh/sd/live.m3u8',
        label: '晋城新闻 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山西:晋城文化生活',
    name: '晋城文化生活',
    group: '地方频道',
    badge: '晋城文化',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.jinnews.com.cn/ggpd/sd/live.m3u8',
        label: '晋城文化生活 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山西:壶关电视台',
    name: '壶关电视台',
    group: '地方频道',
    badge: '壶关电视',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://zmjp3jin.live.sxmty.com/live/hls/268fe96f955d496db37fb10bb887cda9/fc196029d289449ea524a94a95379a0d.m3u8',
        label: '壶关电视台 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山西:平顺综合',
    name: '平顺综合',
    group: '地方频道',
    badge: '平顺综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://player4.juyun.tv/tv/149466149.m3u8',
        label: '平顺综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山西:屯留综合频道',
    name: '屯留综合频道',
    group: '地方频道',
    badge: '屯留综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://f3jok3az.live.sxmty.com/live/hls/ebaa2bf2e7f94dc79d4e642ac76d2415/0d97361a940348729fbd0ee3f4eb9e47.m3u8',
        label: '屯留综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山西:娄烦综合',
    name: '娄烦综合',
    group: '地方频道',
    badge: '娄烦综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://d2lp2ch2.live.sxmty.com/live/hls/dd05b3d63074444abe815913a24d3a35/4c59b61fb67f4a45b7fa1f8416b9fffb-1.m3u8',
        label: '娄烦综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山西:阳曲综合',
    name: '阳曲综合',
    group: '地方频道',
    badge: '阳曲综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://83awgyp5.live.sxmty.com/live/hls/6f6f4b36f9bd42628b718b595ba507ed/724b7e8907a8414d873eb2a2f69bfa18.m3u8',
        label: '阳曲综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山西:怀仁综合频道',
    name: '怀仁综合频道',
    group: '地方频道',
    badge: '怀仁综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://1yp7hc5p.live.sxmty.com/live/hls/bff8529922344209985b6e49baa9555a/efa2543628fc4a7ea93d3d6c975f77dc.m3u8',
        label: '怀仁综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山西:平鲁综合频道',
    name: '平鲁综合频道',
    group: '地方频道',
    badge: '平鲁综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://player4.juyun.tv/tv/167019161.m3u8',
        label: '平鲁综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山西:平遥新闻综合',
    name: '平遥新闻综合',
    group: '地方频道',
    badge: '平遥新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://tntgjhjb.live.sxmty.com/live/hls/3a4585ac11ec4e1bb07b419101b370c3/baf63e2b313440c2a25d7859f9b73b05-1.m3u8',
        label: '平遥新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山西:汾西综合',
    name: '汾西综合',
    group: '地方频道',
    badge: '汾西综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://qmmqvzoz.live.sxmty.com/live/hls/f24f8a390c084386a564074c9260100c/be3fdf07606145739ab2c4b80fe0136a.m3u8',
        label: '汾西综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山西:古县综合',
    name: '古县综合',
    group: '地方频道',
    badge: '古县综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://l2fpdktp.live.sxmty.com/live/hls/e4c3b363cc4549788e2d983f403e07db/d99ce1eb686e41b9afc888110bd95aa7.m3u8',
        label: '古县综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山西:霍州综合',
    name: '霍州综合',
    group: '地方频道',
    badge: '霍州综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://iwlbdjk7.live.sxmty.com/live/hls/768ce7880a2545daac8d20a1910a399b/72b4712ef0224990ab744552c190f28c.m3u8',
        label: '霍州综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山西:隰县新闻综合',
    name: '隰县新闻综合',
    group: '地方频道',
    badge: '隰县新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://fpsfgptf.live.sxmty.com/live/hls/b41fb247f68048f893a7a1d320044ce8/790f46c0807048bf82894eaf4c88ccdb.m3u8',
        label: '隰县新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山西:太谷新闻综合',
    name: '太谷新闻综合',
    group: '地方频道',
    badge: '太谷新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://p2.vzan.com/slowlive/596867413819827251/live.m3u8',
        label: '太谷新闻综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:嘉善新闻综合',
    name: '嘉善新闻综合',
    group: '地方频道',
    badge: '嘉善新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://p2hs.vzan.com/slowlive/633251673265558519/live.m3u8',
        label: '嘉善新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山西:闻喜综合频道',
    name: '闻喜综合频道',
    group: '地方频道',
    badge: '闻喜综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://www.wxhcgbds.com:8081/channelTv/WXTV_1.m3u8',
        label: '闻喜综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山西:垣曲综合频道',
    name: '垣曲综合频道',
    group: '地方频道',
    badge: '垣曲综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://media.yqrmt.com/hls/hd-live.m3u8',
        label: '垣曲综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山西:左云电视台',
    name: '左云电视台',
    group: '地方频道',
    badge: '左云电视',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://wu31afbh.live.sxmty.com/live/hls/c5a0ebd3e73b4c4cbc91ea3b9abf1f54/51859030f2384070bf5bedce43126f6b-1.m3u8',
        label: '左云电视台 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:四川科教频道',
    name: '四川科教频道',
    group: '地方频道',
    badge: '四川科教',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://182.150.115.21:8030/pcgacg/pcgacg_0.m3u8',
        label: '四川科教频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:广安新闻综合',
    name: '广安新闻综合',
    group: '地方频道',
    badge: '广安新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live1.gatv.com.cn:85/live/XWZH.m3u8',
        label: '广安新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'http://live1.gatv.com.cn:85/live/XWZH_HD.m3u8',
        label: '广安新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'http://live1.gatv.com.cn:90/live/XWZH.m3u8',
        label: '广安新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:广安文旅乡村',
    name: '广安文旅乡村',
    group: '地方频道',
    badge: '广安文旅',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live1.gatv.com.cn:85/live/GGPD.m3u8',
        label: '广安文旅乡村 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'http://live1.gatv.com.cn:85/live/GGPD_ggpdzm.m3u8',
        label: '广安文旅乡村 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'http://live1.gatv.com.cn:90/live/GGPD.m3u8',
        label: '广安文旅乡村 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:雅安新闻综合',
    name: '雅安新闻综合',
    group: '地方频道',
    badge: '雅安新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://play.yunxya.com/channellive/xinwen.m3u8',
        label: '雅安新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:雅安雨城频道',
    name: '雅安雨城频道',
    group: '地方频道',
    badge: '雅安雨城',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://m3u8channel-yc.yunxya.com/nmip-media/channellive/channel100103/playlist.m3u8',
        label: '雅安雨城频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:广元综合频道',
    name: '广元综合频道',
    group: '地方频道',
    badge: '广元综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://m3u8.channel.dzsm.com/nmip-media/channellive/channel100999/playlist.m3u8',
        label: '广元综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:广元文化生活',
    name: '广元文化生活',
    group: '地方频道',
    badge: '广元文化',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://m3u8.channel.dzsm.com/nmip-media/channellive/channel101257/playlist.m3u8',
        label: '广元文化生活 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:泸州新闻综合',
    name: '泸州新闻综合',
    group: '地方频道',
    badge: '泸州新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://m3u8.channel.luzhoubs.com/nmip-media/channellive/channel106011/playlist.m3u8',
        label: '泸州新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:泸州科教生活',
    name: '泸州科教生活',
    group: '地方频道',
    badge: '泸州科教',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://m3u8.channel.luzhoubs.com/nmip-media/channellive/channel103074/playlist.m3u8',
        label: '泸州科教生活 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:内江综合频道',
    name: '内江综合频道',
    group: '地方频道',
    badge: '内江综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://www.scnj.tv/hls_njtv_direct/1.m3u8',
        label: '内江综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://www.scnj.tv/hls_njtv_direct/2.m3u8',
        label: '内江综合频道 480P',
        qualityRank: 40,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:内江科教生活',
    name: '内江科教生活',
    group: '地方频道',
    badge: '内江科教',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://www.scnj.tv/hls_njtv_direct/9.m3u8',
        label: '内江科教生活 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:崇州综合频道',
    name: '崇州综合频道',
    group: '地方频道',
    badge: '崇州综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://livesec.mudu.tv/watch/x6h90s.m3u8?auth_key=1718591057-413387-0-d86b69d055411656b69ef6be0fc89497',
        label: '崇州综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:金堂电视台',
    name: '金堂电视台',
    group: '地方频道',
    badge: '金堂电视',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.jtxwzx.com.cn/jtdst/hd/live.m3u8',
        label: '金堂电视台 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'http://p8.vzan.com/slowlive/188010566442385577/live.m3u8',
        label: '金堂电视台 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:双流综合频道',
    name: '双流综合频道',
    group: '地方频道',
    badge: '双流综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://171.221.250.132:28080/live/3146B3F489F1246E4E542E341B99EEAD.m3u8',
        label: '双流综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:南溪综合频道',
    name: '南溪综合频道',
    group: '地方频道',
    badge: '南溪综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://p2hs.vzan.com/slowlive/371673471833525863/live.m3u8',
        label: '南溪综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:渠县新闻综合',
    name: '渠县新闻综合',
    group: '地方频道',
    badge: '渠县新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://183.222.248.153:81/hls/cfp2p8m3.m3u8',
        label: '渠县新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:宣汉新闻综合',
    name: '宣汉新闻综合',
    group: '地方频道',
    badge: '宣汉新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://livexuanhan.chinamcache.com/live/push1.m3u8',
        label: '宣汉新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:阆中综合频道',
    name: '阆中综合频道',
    group: '地方频道',
    badge: '阆中综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://p2hs.vzan.com/slowlive/798833473879633259/live.m3u8',
        label: '阆中综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:仪陇综合频道',
    name: '仪陇综合频道',
    group: '地方频道',
    badge: '仪陇综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://live.yilongnews.com/live/ylzhpd.m3u8?auth_key=1741134122-0-0-fbf8d764c05b0a2547234f0f9f64e4b6',
        label: '仪陇综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:营山电视台',
    name: '营山电视台',
    group: '地方频道',
    badge: '营山电视',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://file.ysxtv.cn/nmip-media/channellive/channel101492/playlist.m3u8',
        label: '营山电视台 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://m3u8channel.ysxtv.cn/nmip-media/channellive/channel101492/playlist.m3u8',
        label: '营山电视台 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:黑水新闻综合',
    name: '黑水新闻综合',
    group: '地方频道',
    badge: '黑水新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.schstv.com:90/live/xwzh.m3u8',
        label: '黑水新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:金川新闻综合',
    name: '金川新闻综合',
    group: '地方频道',
    badge: '金川新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.jinchuanrmt.com:90/live/zhxw.m3u8',
        label: '金川新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'http://139.203.180.9:90/live/zhxw.m3u8',
        label: '金川新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:金川乡村频道',
    name: '金川乡村频道',
    group: '地方频道',
    badge: '金川乡村',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.jinchuanrmt.com:90/live/jcxc.m3u8',
        label: '金川乡村频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'http://139.203.180.9:90/live/jcxc.m3u8',
        label: '金川乡村频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:松潘新闻综合',
    name: '松潘新闻综合',
    group: '地方频道',
    badge: '松潘新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.spccmc.com:90/live/spxwzh.m3u8',
        label: '松潘新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:汶川新闻综合',
    name: '汶川新闻综合',
    group: '地方频道',
    badge: '汶川新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.iwcmt.cn:90/live/zhxw.m3u8',
        label: '汶川新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:荣县综合频道',
    name: '荣县综合频道',
    group: '地方频道',
    badge: '荣县综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://play.rongxianwang.net/ydrx/rongxianlive.m3u8?auth_key=1715846517-0-0-69728c58ca3d40f9331a8cf77d985e93',
        label: '荣县综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:朝天新闻综合',
    name: '朝天新闻综合',
    group: '地方频道',
    badge: '朝天新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://m3u8.channel.dzsm.com/nmip-media/channellive/channel104601/playlist.m3u8',
        label: '朝天新闻综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:剑阁新闻综合',
    name: '剑阁新闻综合',
    group: '地方频道',
    badge: '剑阁新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://m3u8.channel.dzsm.com/nmip-media/channellive/channel105549/playlist.m3u8',
        label: '剑阁新闻综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:青川新闻综合',
    name: '青川新闻综合',
    group: '地方频道',
    badge: '青川新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://qcfile.qcrmt.com/nmip-media/channellive/channel100933/playlist.m3u8',
        label: '青川新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:旺苍新闻综合',
    name: '旺苍新闻综合',
    group: '地方频道',
    badge: '旺苍新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://channel.wcrmt.cn/nmip-media/channellive/channel105268/playlist.m3u8',
        label: '旺苍新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:仁寿综合频道',
    name: '仁寿综合频道',
    group: '地方频道',
    badge: '仁寿综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://play.scrstv.com.cn/TV/xwzh.m3u8?auth_key=1724660870-0-0-a245e661caf0188f84e8e486754a80ce',
        label: '仁寿综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:乐至综合频道',
    name: '乐至综合频道',
    group: '地方频道',
    badge: '乐至综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://175.155.106.72:89/live1/live1.m3u8',
        label: '乐至综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:会东综合频道',
    name: '会东综合频道',
    group: '地方频道',
    badge: '会东综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://file.schdxww.com/nmip-media/channellive/channel100055/playlist.m3u8',
        label: '会东综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:西昌综合频道',
    name: '西昌综合频道',
    group: '地方频道',
    badge: '西昌综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://xcfb.screx.com.cn:18085/hlsnew1/channel1.m3u8',
        label: '西昌综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:德格综合频道',
    name: '德格综合频道',
    group: '地方频道',
    badge: '德格综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://dgfile.ganzitv.com/nmip-media/channellive/channel101955/playlist.m3u8',
        label: '德格综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:宝兴综合频道',
    name: '宝兴综合频道',
    group: '地方频道',
    badge: '宝兴综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://m3u8channel-bx.yunxya.com/nmip-media/channellive/channel104666/playlist.m3u8',
        label: '宝兴综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:名山综合频道',
    name: '名山综合频道',
    group: '地方频道',
    badge: '名山综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://m3u8channel-ms.yunxya.com/nmip-media/channellive/channel100249/playlist.m3u8',
        label: '名山综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:石棉综合频道',
    name: '石棉综合频道',
    group: '地方频道',
    badge: '石棉综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://m3u8channel-sm.yunxya.com/nmip-media/channellive/channel100420/playlist.m3u8',
        label: '石棉综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:天全新闻频道',
    name: '天全新闻频道',
    group: '地方频道',
    badge: '天全新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://m3u8channel-tq.yunxya.com/nmip-media/channellive/channel100634/playlist.m3u8',
        label: '天全新闻频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:荥经综合频道',
    name: '荥经综合频道',
    group: '地方频道',
    badge: '荥经综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://m3u8channel-yj.yunxya.com/nmip-media/channellive/channel101140/playlist.m3u8',
        label: '荥经综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:沐川综合频道',
    name: '沐川综合频道',
    group: '地方频道',
    badge: '沐川综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://tvfile.mcrm.org.cn/nmip-media/channellive/channel103064/playlist.m3u8',
        label: '沐川综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:泸县新闻综合',
    name: '泸县新闻综合',
    group: '地方频道',
    badge: '泸县新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://lxfile.lxxcb.cn/nmip-media/channellive/channel103799/playlist.m3u8',
        label: '泸县新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '天津:滨海新闻',
    name: '滨海新闻',
    group: '地方频道',
    badge: '滨海新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://traffic.jbh.tjbh.com/live/bhtv10/playlist.m3u8',
        label: '滨海新闻 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:伊犁哈萨克',
    name: '伊犁哈萨克',
    group: '地方频道',
    badge: '伊犁哈萨',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://110.153.180.106:55555/out_3/index.m3u8',
        label: '伊犁哈萨克 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:伊犁经济法制',
    name: '伊犁经济法制',
    group: '地方频道',
    badge: '伊犁经济',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://110.153.180.106:55555/out_4/index.m3u8',
        label: '伊犁经济法制 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:巴音郭楞州综合',
    name: '巴音郭楞州综合',
    group: '地方频道',
    badge: '巴音郭楞',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://file.loulannews.cn/nmip-media/channellive/channel101476/playlist.m3u8',
        label: '巴音郭楞州综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:巴音郭楞州蒙语',
    name: '巴音郭楞州蒙语',
    group: '地方频道',
    badge: '巴音郭楞',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://file.loulannews.cn/nmip-media/channellive/channel102433/playlist.m3u8',
        label: '巴音郭楞州蒙语 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:巴音郭楞州维吾尔语',
    name: '巴音郭楞州维吾尔语',
    group: '地方频道',
    badge: '巴音郭楞',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://file.loulannews.cn/nmip-media/channellive/channel103824/playlist.m3u8',
        label: '巴音郭楞州维吾尔语 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:巴音郭楞州教育',
    name: '巴音郭楞州教育',
    group: '地方频道',
    badge: '巴音郭楞',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://file.loulannews.cn/nmip-media/channellive/channel104199/playlist.m3u8',
        label: '巴音郭楞州教育 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:塔城一套',
    name: '塔城一套',
    group: '地方频道',
    badge: '塔城一套',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://218.84.35.38:3000/m3u8/live/tctv-1/index.m3u8',
        label: '塔城一套 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:塔城二套',
    name: '塔城二套',
    group: '地方频道',
    badge: '塔城二套',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://218.84.35.38:3000/m3u8/live/tctv-2/index.m3u8',
        label: '塔城二套 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:塔城三套',
    name: '塔城三套',
    group: '地方频道',
    badge: '塔城三套',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://218.84.35.38:3000/m3u8/live/tctv-3/index.m3u8',
        label: '塔城三套 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:布尔津汉语综合',
    name: '布尔津汉语综合',
    group: '地方频道',
    badge: '布尔津汉',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://st-video.xjmty.com/fs/livedit/6fc961a3e0f06313/c9338510613c6394.m3u8',
        label: '布尔津汉语综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:布尔津哈语综合',
    name: '布尔津哈语综合',
    group: '地方频道',
    badge: '布尔津哈',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://st-video.xjmty.com/fs/livedit/e55abfa37af26e19/8ce9971c2177b3dd.m3u8',
        label: '布尔津哈语综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:吉木萨尔综合',
    name: '吉木萨尔综合',
    group: '地方频道',
    badge: '吉木萨尔',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://218.31.201.189:9000/api/material/local/mnt/shiping1/prog_index.m3u8',
        label: '吉木萨尔综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:兵团四师可克达拉综合',
    name: '兵团四师可克达拉综合',
    group: '地方频道',
    badge: '兵团四师',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://test5.btzx.com.cn/live/kkdl.stream/playlist.m3u8',
        label: '兵团四师可克达拉综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:兵团六师五家渠新闻综合',
    name: '兵团六师五家渠新闻综合',
    group: '地方频道',
    badge: '兵团六师',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://liveout.btzx.com.cn/62ds9e/d9vi5g.m3u8',
        label: '兵团六师五家渠新闻综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:兵团八师石河子新闻综合',
    name: '兵团八师石河子新闻综合',
    group: '地方频道',
    badge: '兵团八师',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://124.88.144.73:1935/live/xwzh/playlist.m3u8',
        label: '兵团八师石河子新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:兵团九师白杨电视台',
    name: '兵团九师白杨电视台',
    group: '地方频道',
    badge: '兵团九师',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://liveout.btzx.com.cn/3pyc0h/dbfvwu.m3u8',
        label: '兵团九师白杨电视台 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:兵团十三师新星综合',
    name: '兵团十三师新星综合',
    group: '地方频道',
    badge: '兵团十三',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://test5.btzx.com.cn/live/13TV.stream/playlist.m3u8',
        label: '兵团十三师新星综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:兵团十四师昆玉综合',
    name: '兵团十四师昆玉综合',
    group: '地方频道',
    badge: '兵团十四',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://test5.btzx.com.cn/live/14TV.stream/playlist.m3u8',
        label: '兵团十四师昆玉综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:奎屯汉语综合',
    name: '奎屯汉语综合',
    group: '地方频道',
    badge: '奎屯汉语',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://218.84.12.186:8001/hls/main/playlist.m3u8',
        label: '奎屯汉语综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:奎屯哈萨克语',
    name: '奎屯哈萨克语',
    group: '地方频道',
    badge: '奎屯哈萨',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://218.84.12.186:8002/hls/main/playlist.m3u8',
        label: '奎屯哈萨克语 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:玛纳斯综合频道',
    name: '玛纳斯综合频道',
    group: '地方频道',
    badge: '玛纳斯综',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://218.84.127.245:1026/hls/main1/playlist.m3u8',
        label: '玛纳斯综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '西藏:拉萨汉语综合',
    name: '拉萨汉语综合',
    group: '地方频道',
    badge: '拉萨汉语',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://tvfile.lasatv.cn/nmip-media/channellive/channel101894/playlist.m3u8',
        label: '拉萨汉语综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '西藏:拉萨藏语综合',
    name: '拉萨藏语综合',
    group: '地方频道',
    badge: '拉萨藏语',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://tvfile.lasatv.cn/nmip-media/channellive/channel104335/playlist.m3u8',
        label: '拉萨藏语综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '西藏:拉萨文旅频道',
    name: '拉萨文旅频道',
    group: '地方频道',
    badge: '拉萨文旅',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://tvfile.lasatv.cn/nmip-media/channellive/channel103157/playlist.m3u8',
        label: '拉萨文旅频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '西藏:察隅电视台',
    name: '察隅电视台',
    group: '地方频道',
    badge: '察隅电视',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://file.chayutv.com/nmip-media/channellive/channel105276/playlist.m3u8',
        label: '察隅电视台 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '云南:江川综合',
    name: '江川综合',
    group: '地方频道',
    badge: '江川综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://zb-live.ynurl.com/jiangchuan/ad8dc86f-f35a-4203-85f0-dfd0eef52d18.m3u8',
        label: '江川综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '云南:通海电视台',
    name: '通海电视台',
    group: '地方频道',
    badge: '通海电视',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://zb-live.ynurl.com/tonghai/3bfe3a9e-48e6-4c1e-8770-1df66447cc6c.m3u8',
        label: '通海电视台 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '云南:易门综合',
    name: '易门综合',
    group: '地方频道',
    badge: '易门综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://zb-live.ynurl.com/yimen/3b75a2f9-7941-46b7-992d-a9796fbca5fe.m3u8',
        label: '易门综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '云南:广南电视台',
    name: '广南电视台',
    group: '地方频道',
    badge: '广南电视',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://zb-live.ynurl.com/guangnan/31407c0a-ec07-4b5f-8a89-c26fbcc1fcf9.m3u8',
        label: '广南电视台 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '云南:麻栗坡电视台',
    name: '麻栗坡电视台',
    group: '地方频道',
    badge: '麻栗坡电',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://m3u8.channel.wsrtv.com.cn/cms/videos/nmip-media/channellive/channel18/playlist.m3u8',
        label: '麻栗坡电视台 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:浙江钱江都市',
    name: '浙江钱江都市',
    group: '地方频道',
    badge: '浙江钱江',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://ali-m-l.cztv.com/channels/lantian/channel002/1080p.m3u8',
        label: '浙江钱江都市 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:浙江经济生活',
    name: '浙江经济生活',
    group: '地方频道',
    badge: '浙江经济',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://ali-m-l.cztv.com/channels/lantian/channel003/1080p.m3u8',
        label: '浙江经济生活 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:浙江教科影视',
    name: '浙江教科影视',
    group: '地方频道',
    badge: '浙江教科',
    categories: <String>['地方频道', '影视'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://ali-m-l.cztv.com/channels/lantian/channel004/1080p.m3u8',
        label: '浙江教科影视 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:浙江民生休闲',
    name: '浙江民生休闲',
    group: '地方频道',
    badge: '浙江民生',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://ali-m-l.cztv.com/channels/lantian/channel006/1080p.m3u8',
        label: '浙江民生休闲 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:浙江新闻',
    name: '浙江新闻',
    group: '地方频道',
    badge: '浙江新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://ali-m-l.cztv.com/channels/lantian/channel007/1080p.m3u8',
        label: '浙江新闻 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'https://sdxflive-pc.wasu.cn/sdxf/zhejianggonggongxinwen.m3u8?auth_key=1685203743804-0-0-690ae1cb22bc01f7dba833919ea5a9c1',
        label: '浙江新闻 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:浙江少儿',
    name: '浙江少儿',
    group: '地方频道',
    badge: '浙江少儿',
    categories: <String>['地方频道', '少儿'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://ali-m-l.cztv.com/channels/lantian/channel008/1080p.m3u8',
        label: '浙江少儿 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:浙江国际',
    name: '浙江国际',
    group: '地方频道',
    badge: '浙江国际',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://ali-m-l.cztv.com/channels/lantian/channel010/1080p.m3u8',
        label: '浙江国际 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:浙江之江纪录',
    name: '浙江之江纪录',
    group: '地方频道',
    badge: '浙江之江',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://ali-m-l.cztv.com/channels/lantian/channel012/1080p.m3u8',
        label: '浙江之江纪录 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:好易购',
    name: '好易购',
    group: '地方频道',
    badge: '好易购',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://ali-m-l.cztv.com/channels/lantian/channel011/1080p.m3u8',
        label: '好易购 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:绍兴新闻综合',
    name: '绍兴新闻综合',
    group: '地方频道',
    badge: '绍兴新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.shaoxing.com.cn/video/s10001-sxhb/index.m3u8',
        label: '绍兴新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'http://live.shaoxing.com.cn/video/s10001-sxtv1/index.m3u8',
        label: '绍兴新闻综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:绍兴公共频道',
    name: '绍兴公共频道',
    group: '地方频道',
    badge: '绍兴公共',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.shaoxing.com.cn/video/s10001-sxtv2/index.m3u8',
        label: '绍兴公共频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:绍兴文化影视',
    name: '绍兴文化影视',
    group: '地方频道',
    badge: '绍兴文化',
    categories: <String>['地方频道', '影视'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.shaoxing.com.cn/video/s10001-sxtv3/index.m3u8',
        label: '绍兴文化影视 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:湖州新闻综合',
    name: '湖州新闻综合',
    group: '地方频道',
    badge: '湖州新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://hzcm-live.media.hugd.com/3f5fa7d64c7c46a38c6bd8ad35e836cc/65128273761b4731ae53729ea6dcf932.m3u8?auth_key=2277598215-9d21c15111244bea8d298c361d31a72e-0-d031198f58d44b0e91ba2e3f3b188865',
        label: '湖州新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:湖州公共民生',
    name: '湖州公共民生',
    group: '地方频道',
    badge: '湖州公共',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://hzcm-live.media.hugd.com/1e6b554b9ab74513958c0e1ffe664d22/9acaa7634309494cb29a85eb12136607.m3u8?auth_key=2272900830-9a2389b8bf4e49d580d4ad807423d326-0-ea78a5c7a678c436263582d368f5009e',
        label: '湖州公共民生 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:湖州文化娱乐',
    name: '湖州文化娱乐',
    group: '地方频道',
    badge: '湖州文化',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://hzcm-live.media.hugd.com/613c47f0ab0d4eaa98b21378d0db6ded/0051d31c9dd543a7825eea4e49675b2a.m3u8?auth_key=2277598059-0a5ebfa1c0dc4671b42a60810fc37039-0-fa625b7d1feab612062453c12e3c8887',
        label: '湖州文化娱乐 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:温州新闻综合',
    name: '温州新闻综合',
    group: '地方频道',
    badge: '温州新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play-qk.wzrb.com.cn/live/1728463192330572.m3u8?auth_key=2044351793-fa66d1d33e3d426ca3dccb94845595d7-0-4bc36ce83dfac0c77ddd501ffe397bcc',
        label: '温州新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:东阳新闻综合',
    name: '东阳新闻综合',
    group: '地方频道',
    badge: '东阳新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play-sh13.quklive.com/live/1681113308206040.m3u8?auth_key=2028413158-ad2723c5e94045f393c4ccc595b573f9-0-c75b8d81f4470e67519c154e85115a4e',
        label: '东阳新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:武义新闻综合',
    name: '武义新闻综合',
    group: '地方频道',
    badge: '武义新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play-sh13.quklive.com/live/1707437639053211.m3u8?auth_key=2039926222-0c20643324d74ab6bca329f2864d9615-0-ad7dc9def9f83b2cc7693a23f6d91251',
        label: '武义新闻综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:平湖新闻综合',
    name: '平湖新闻综合',
    group: '地方频道',
    badge: '平湖新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://l.cztvcloud.com/channels/lantian/SXpinghu1/720p.m3u8',
        label: '平湖新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:萧山新闻综合',
    name: '萧山新闻综合',
    group: '地方频道',
    badge: '萧山新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://l.cztvcloud.com/channels/lantian/SXxiaoshan1/720p.m3u8',
        label: '萧山新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'http://l.cztvcloud.com/channels/lantian/SXxiaoshan2/720p.m3u8',
        label: '萧山新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:桐庐综合频道',
    name: '桐庐综合频道',
    group: '地方频道',
    badge: '桐庐综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://31666.hlsplay.aodianyun.com/tv_radio_31666/tv_channel_3566.m3u8?auth_key=4867613167-0-0-7e4d136d59c046f779f0c50461de5fe5&extra_key=ZsnRdSSZsd_55ssIU7GXV9vL2bVgmdCUfbd0zhEWRYtF1fIJa_P34oEH8HVCgRtNY3GLWcIgRP1lO0kocw3d7cCCfJYKu980fDypjkFzkHzqrB4amtUEsglZvsGvzYzoDZyioKwM9H2EUg0PFXBSWFJ1WyLLQNoQey-Q6kSGklw',
        label: '桐庐综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:余杭综合频道',
    name: '余杭综合频道',
    group: '地方频道',
    badge: '余杭综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://29371.hlsplay.aodianyun.com/lms_29371/slow_channel_master_seat_1445826801.m3u8?auth_key=3300411293-0-0-273f15e1d217965ba192be222ea38b2d&extra_key=V8uEmh_EXr1eVHhCsqQdCb2KQpy3kbF4Lfrf1S8rAZfBbea83rMZ6uqfZL74iDr9sfX_YL2E_25HrvU_mbtZh3ifdtd3R0IP_tWpoeTaMP3EUgp-m3whWwmoBhHzmq7QlJkExjuwjfwj_lLUpyUtp6oiMrocqaUoGIgnjsNh9WM',
        label: '余杭综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:余杭未来e频道',
    name: '余杭未来E频道',
    group: '地方频道',
    badge: '余杭未来',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://l.cztvcloud.com/channels/lantian/SXyuhang3/720p.m3u8',
        label: '余杭未来E频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:诸暨新闻综合',
    name: '诸暨新闻综合',
    group: '地方频道',
    badge: '诸暨新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://l.cztvcloud.com/channels/lantian/SXzhuji3/720p.m3u8',
        label: '诸暨新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:上虞新闻综合',
    name: '上虞新闻综合',
    group: '地方频道',
    badge: '上虞新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://l.cztvcloud.com/channels/lantian/SXshangyu1/720p.m3u8',
        label: '上虞新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:上虞新商都',
    name: '上虞新商都',
    group: '地方频道',
    badge: '上虞新商',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://l.cztvcloud.com/channels/lantian/SXshangyu3/720p.m3u8',
        label: '上虞新商都 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:兰溪新闻综合',
    name: '兰溪新闻综合',
    group: '地方频道',
    badge: '兰溪新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://l.cztvcloud.com/channels/lantian/SXlanxi1/720p.m3u8',
        label: '兰溪新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:瑞安新闻综合',
    name: '瑞安新闻综合',
    group: '地方频道',
    badge: '瑞安新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play-sh-21.quklive.com/live/1681269183807252.m3u8?auth_key=2033114999-67ff99bfbe1b4577b013750618ffce6b-0-454401c27452e83159ca9466ef742db2',
        label: '瑞安新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:文成综合频道',
    name: '文成综合频道',
    group: '地方频道',
    badge: '文成综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://l.cztvcloud.com/channels/lantian/SXwencheng1/720p.m3u8',
        label: '文成综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:长兴新闻综合',
    name: '长兴新闻综合',
    group: '地方频道',
    badge: '长兴新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play-a11.quklive.com/live/1689126294179076.m3u8',
        label: '长兴新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:柯桥新闻综合',
    name: '柯桥新闻综合',
    group: '地方频道',
    badge: '柯桥新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://play-a2.quklive.com/live/1640945211435051.m3u8',
        label: '柯桥新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:象山新闻综合',
    name: '象山新闻综合',
    group: '地方频道',
    badge: '象山新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play-sh13.quklive.com/live/1702360350551252.m3u8?auth_key=2037107484-800189c57a5a44d3b823b60cf84f6756-0-a6f6828a62d5c167cff5e68735fa0d39',
        label: '象山新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'http://l.cztvcloud.com/channels/lantian/SXxiangshan1/720p.m3u8',
        label: '象山新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:宁海新闻综合',
    name: '宁海新闻综合',
    group: '地方频道',
    badge: '宁海新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://33658.hlsplay.aodianyun.com/tv_radio_33658/tv_channel_1423.m3u8',
        label: '宁海新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:江山电视台',
    name: '江山电视台',
    group: '地方频道',
    badge: '江山电视',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play-sh13.quklive.com/live/1623117710666335.m3u8?auth_key=2027320874-f4ab7bf26c7f450398f90acd51fbe541-0-b9952255f66849bc8e7afaa8e6865488',
        label: '江山电视台 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:龙游新闻综合',
    name: '龙游新闻综合',
    group: '地方频道',
    badge: '龙游新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://l.cztvcloud.com/channels/lantian/SXlongyou1/720p.m3u8',
        label: '龙游新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:龙游生活娱乐',
    name: '龙游生活娱乐',
    group: '地方频道',
    badge: '龙游生活',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://l.cztvcloud.com/channels/lantian/SXlongyou2/720p.m3u8',
        label: '龙游生活娱乐 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:衢江新闻综合',
    name: '衢江新闻综合',
    group: '地方频道',
    badge: '衢江新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://play-sh13.quklive.com/live/1700720505174325.m3u8?auth_key=2027466026-7724b0f948044faa9f0b8d0ecfc275fc-0-dfc23fb7449b475a18a52dc4b796516e',
        label: '衢江新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
      LiveStream(
        url: 'http://l.cztvcloud.com/channels/lantian/SXqujiang1/720p.m3u8',
        label: '衢江新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:缙云综合频道',
    name: '缙云综合频道',
    group: '地方频道',
    badge: '缙云综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://l.cztvcloud.com/channels/lantian/SXjinyun1/720p.m3u8',
        label: '缙云综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:龙泉新闻综合',
    name: '龙泉新闻综合',
    group: '地方频道',
    badge: '龙泉新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://l.cztvcloud.com/channels/lantian/SXlongquan1/720p.m3u8',
        label: '龙泉新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:松阳综合频道',
    name: '松阳综合频道',
    group: '地方频道',
    badge: '松阳综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://l.cztvcloud.com/channels/lantian/SXsongyang1/720p.m3u8',
        label: '松阳综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:云和新闻综合',
    name: '云和新闻综合',
    group: '地方频道',
    badge: '云和新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://l.cztvcloud.com/channels/lantian/SXyunhe1/720p.m3u8',
        label: '云和新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:青田电视台',
    name: '青田电视台',
    group: '地方频道',
    badge: '青田电视',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://l.cztvcloud.com/channels/lantian/SXqingtian1/720p.m3u8',
        label: '青田电视台 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '重庆:巴南综合频道',
    name: '巴南综合频道',
    group: '地方频道',
    badge: '巴南综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://live.cqbntv.com/bnmc/tv0709.m3u8',
        label: '巴南综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '甘肃:甘南综合频道',
    name: '甘南综合频道',
    group: '地方频道',
    badge: '甘南综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://play.kankanlive.com/live/1711955176432990.m3u8',
        label: '甘南综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '甘肃:张掖农业旅游',
    name: '张掖农业旅游',
    group: '地方频道',
    badge: '张掖农业',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://play.kankanlive.com/live/1720583009200246.m3u8',
        label: '张掖农业旅游 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '甘肃:玛曲综合频道',
    name: '玛曲综合频道',
    group: '地方频道',
    badge: '玛曲综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://play.kankanlive.com/live/1711955878545987.m3u8',
        label: '玛曲综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '甘肃:卓尼综合频道',
    name: '卓尼综合频道',
    group: '地方频道',
    badge: '卓尼综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://play.kankanlive.com/live/1711955964973985.m3u8',
        label: '卓尼综合频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河南:安阳新闻综合',
    name: '安阳新闻综合',
    group: '地方频道',
    badge: '安阳新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://zhpull.dxhmt.cn/anyang/7e3b40563af54e2f9f48e2c67c5d9fab/playlist.m3u8',
        label: '安阳新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '河南:安阳文旅频道',
    name: '安阳文旅频道',
    group: '地方频道',
    badge: '安阳文旅',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://zhpull.dxhmt.cn/anyang/24edb37167474b17948c6fbaf09890b8/playlist.m3u8',
        label: '安阳文旅频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '湖南:吉首综合频道',
    name: '吉首综合频道',
    group: '地方频道',
    badge: '吉首综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://liveplay-srs.voc.com.cn/hls/tv/143_70175b.m3u8',
        label: '吉首综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '湖南:永兴综合频道',
    name: '永兴综合频道',
    group: '地方频道',
    badge: '永兴综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://liveplay-srs.voc.com.cn/hls/tv/40_1d0ed0.m3u8',
        label: '永兴综合频道 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '湖南:衡阳县时政综合',
    name: '衡阳县时政综合',
    group: '地方频道',
    badge: '衡阳县时',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://liveplay-srs.voc.com.cn/hls/tv/183_554704.m3u8',
        label: '衡阳县时政综合 576P',
        qualityRank: 50,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '湖南:津市新闻频道',
    name: '津市新闻频道',
    group: '地方频道',
    badge: '津市新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://liveplay-srs.voc.com.cn/hls/tv/187_2abf84.m3u8',
        label: '津市新闻频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '湖南:桃源综合频道',
    name: '桃源综合频道',
    group: '地方频道',
    badge: '桃源综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://liveplay-srs.voc.com.cn/hls/tv/157_66df9e.m3u8#6#1',
        label: '桃源综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '湖南:沅江电视台',
    name: '沅江电视台',
    group: '地方频道',
    badge: '沅江电视',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://liveplay-srs.voc.com.cn/hls/tv/163_2c7011.m3u8',
        label: '沅江电视台 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '湖南:新晃时政',
    name: '新晃时政',
    group: '地方频道',
    badge: '新晃时政',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://liveplay-srs.voc.com.cn/hls/tv/23_5d556a.m3u8',
        label: '新晃时政 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '江苏:吴江新闻综合',
    name: '吴江新闻综合',
    group: '地方频道',
    badge: '吴江新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://ctlive2.wjdaily.com/wjtv/ch1.m3u8',
        label: '吴江新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山东:临沂公共频道',
    name: '临沂公共频道',
    group: '地方频道',
    badge: '临沂公共',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://m3u8-channel.lytv.tv/nmip-media/channellive/channel113571/playlist.m3u8',
        label: '临沂公共频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山西:古交综合',
    name: '古交综合',
    group: '地方频道',
    badge: '古交综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://pili-live-hls.189.i2863.com/i2863-189/live_189_170656.m3u8',
        label: '古交综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山西:定襄综合',
    name: '定襄综合',
    group: '地方频道',
    badge: '定襄综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://lbyzztfe.live.sxmty.com/live/hls/645ff4c60e0a49f0a203abbd73dd8be9/0720e665f10f48e98c9639f4f492fb4a-1.m3u8',
        label: '定襄综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:乐山新闻综合',
    name: '乐山新闻综合',
    group: '地方频道',
    badge: '乐山新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://pwpull.leshan.cn/live/21609091019110008654ed1a00000000/playlist.m3u8',
        label: '乐山新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:雅安文化生活',
    name: '雅安文化生活',
    group: '地方频道',
    badge: '雅安文化',
    categories: <String>['地方频道', '生活'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://play.yunxya.com/channellive/whsh.m3u8',
        label: '雅安文化生活 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:普格综合频道',
    name: '普格综合频道',
    group: '地方频道',
    badge: '普格综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://171.215.30.43:8086/0.m3u8',
        label: '普格综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:汉源综合频道',
    name: '汉源综合频道',
    group: '地方频道',
    badge: '汉源综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://m3u8channel-hy.yunxya.com/nmip-media/channellive/channel104355/playlist.m3u8',
        label: '汉源综合频道 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:平昌新闻综合',
    name: '平昌新闻综合',
    group: '地方频道',
    badge: '平昌新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://dcpull.sctvcloud.com/live/9d774482018e1000fec02f9500000000/playlist.m3u8',
        label: '平昌新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:通江新闻综合',
    name: '通江新闻综合',
    group: '地方频道',
    badge: '通江新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://dcpull.sctvcloud.com/live/04ea69fa018910006ae9ef0600000000/playlist.m3u8',
        label: '通江新闻综合 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:井研综合频道',
    name: '井研综合频道',
    group: '地方频道',
    badge: '井研综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://tvfile.jyrmt.cn/nmip-media/channellive/channel104452/playlist.m3u8',
        label: '井研综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '四川:金口河综合频道',
    name: '金口河综合频道',
    group: '地方频道',
    badge: '金口河综',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://pili-live-hls.227.i2863.com/i2863-227/live_227_687291.m3u8',
        label: '金口河综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '新疆:伊犁维吾尔',
    name: '伊犁维吾尔',
    group: '地方频道',
    badge: '伊犁维吾',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://110.153.180.106:55555/out_2/index.m3u8',
        label: '伊犁维吾尔 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '浙江:海宁新闻综合',
    name: '海宁新闻综合',
    group: '地方频道',
    badge: '海宁新闻',
    categories: <String>['地方频道', '新闻'],
    streams: <LiveStream>[
      LiveStream(
        url: 'https://p2hs.vzan.com/slowlive/317913155078575177/live.m3u8',
        label: '海宁新闻综合 720P',
        qualityRank: 70,
        decodeVerified: true,
      ),
    ],
  ),
  LiveChannel(
    id: '山西:万荣综合频道',
    name: '万荣综合频道',
    group: '地方频道',
    badge: '万荣综合',
    categories: <String>['地方频道'],
    streams: <LiveStream>[
      LiveStream(
        url: 'http://60.222.246.220:19433/hls1.m3u8',
        label: '万荣综合频道 1080P',
        qualityRank: 90,
        decodeVerified: true,
      ),
    ],
  ),
];
