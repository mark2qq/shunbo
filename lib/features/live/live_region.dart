/// 频道栏分组导航 + 「地方频道按城市」的纯逻辑层。
///
/// 刻意不 import flutter：这层要能被裸 `dart run` 的回归脚本直接 import
/// （本机的 flutter_tester 不可用，见项目 README）。UI 只负责把这里算出的
/// 分组 / 城市列表渲染出来，并把手势翻译成 `moveGroup` 的 ±1。
library;

import 'live_channel.dart';

/// 省级行政区（GB/T 2260 顺序），「按省加载地方台」的选项顺序即此顺序。
///
/// 与 [CityDirectory.cityCodes] 的前两位代码一一对应。省名**刻意不进**
/// `cityAliases`：省份不是城市，`Jiangsu City Channel` 是省级台，
/// 若把「江苏」当城市收进去，`inferCity` 会把所有省级台误判成同一个市。
const List<String> kProvinces = <String>[
  '北京', '天津', '河北', '山西', '内蒙古', '辽宁', '吉林', '黑龙江',
  '上海', '江苏', '浙江', '安徽', '福建', '江西', '山东', '河南',
  '湖北', '湖南', '广东', '广西', '海南', '重庆', '四川', '贵州',
  '云南', '西藏', '陕西', '甘肃', '青海', '宁夏', '新疆',
];

/// 行政区划代码前两位 → 省名。
const Map<String, String> kProvinceByCodePrefix = <String, String>{
  '11': '北京', '12': '天津', '13': '河北', '14': '山西', '15': '内蒙古',
  '21': '辽宁', '22': '吉林', '23': '黑龙江', '31': '上海', '32': '江苏',
  '33': '浙江', '34': '安徽', '35': '福建', '36': '江西', '37': '山东',
  '41': '河南', '42': '湖北', '43': '湖南', '44': '广东', '45': '广西',
  '46': '海南', '50': '重庆', '51': '四川', '52': '贵州', '53': '云南',
  '54': '西藏', '61': '陕西', '62': '甘肃', '63': '青海', '64': '宁夏',
  '65': '新疆',
};

/// 省级台的英文/拼音别名（真实索引里出现过 `Xinjiang TV 1` 这类台名）。
const Map<String, String> kProvinceAliases = <String, String>{
  'xinjiang': '新疆',
  'neimonggol': '内蒙古',
  'innermongolia': '内蒙古',
  'tibet': '西藏',
  'hongkong': '香港',
  'macau': '澳门',
  'taiwan': '台湾',
};

/// 4K / 超高清频道的「归集置顶」规则。
///
/// 与台号排序、线路排序完全无关，只在列表渲染前做一次**稳定分区**：
/// 4K 台整组挪到最前，4K 之间、非 4K 之间都保持原顺序。
/// 主程序 UI 与 `gen_legacy_catalog.dart` 共用这一个正则，避免手机和电视
/// 对「哪些台算 4K」给出不同答案。`CCTV-8K` 不是 4K（要求字面 4K）。
abstract final class ChannelQuality {
  static bool is4K(String name) =>
      RegExp(r'4\s*[kK]|超高清|UHD', caseSensitive: false).hasMatch(name);

  static List<T> fourKFirst<T>(
    Iterable<T> source,
    bool Function(T item) isFourK,
  ) {
    final fourK = <T>[];
    final rest = <T>[];
    for (final item in source) {
      (isFourK(item) ? fourK : rest).add(item);
    }
    return <T>[...fourK, ...rest];
  }
}

/// 频道栏的固定分组顺序。
///
/// 不从「实际有哪些频道」反推：那样某个分组暂时没数据就会整个消失，
/// 用户再也找不到入口——这正是「少儿、其它等分类访问不到」的成因。
/// 常驻显示 + 空态提示，比动态隐藏更符合主流播放器的分类栏。
///
/// 顺序对应用户要求：全部 → 央视频道 → 卫视频道 → 地方频道 → 内容分类 → 其它。
/// 与 `LiveChannel.groupRank` 一致（购物频道已按需求从目录层剔除）。
abstract final class LiveRegion {
  static const String allGroup = '全部';
  static const String localGroup = '地方频道';

  static const List<String> groups = <String>[
    allGroup,
    '央视频道',
    '卫视频道',
    localGroup,
    '新闻',
    '体育',
    '影视',
    '少儿',
    '纪实',
    '生活',
    '其它频道',
  ];

  /// 左右切换分组：到头就停（主流播放器不回绕）。
  ///
  /// 返回钳制后的下标，越界输入也安全（手势可能给出异常值）。
  static int moveGroup(int current, int delta) {
    if (groups.isEmpty) return 0;
    final base = current.clamp(0, groups.length - 1);
    return (base + delta).clamp(0, groups.length - 1);
  }

  /// 分组名 → 下标；未知分组落到「全部」。
  static int indexOfGroup(String? group) {
    if (group == null) return 0;
    final i = groups.indexOf(group);
    return i < 0 ? 0 : i;
  }

  static String groupAt(int index) => groups[index.clamp(0, groups.length - 1)];
}

/// 一个可切换的城市项。
class CityOption {
  const CityOption(this.name, this.count);

  final String name;

  /// 该城市收录了多少个地方频道（UI 用它给下拉项标注台数）。
  final int count;

  @override
  String toString() => 'CityOption($name, $count)';
}

/// 城市目录：**行政区划代码 + 中英文/拼音别名**两套索引。
///
/// 为什么需要两套：
/// - IP 定位接口返回的是行政区划代码（`cityCode=320500`）或英文市名
///   （`Jiaxing`），都得能落到同一个标准中文市名上；
/// - 频道台名是中英混排（`苏州新闻综合` / `Suzhou News Channel` /
///   `呼市新闻综合`），城市归属只能从名字里推断。
abstract final class CityDirectory {
  static const String allCities = '全部城市';
  static const String otherCities = '其它城市';

  /// 默认本地城市：没有用户选择、IP 也没定位到已收录城市时用它，
  /// 而不是把全国 896 个地方台一股脑铺出来（用户要求默认只看本地台）。
  static const String defaultLocalCity = '苏州';

  /// 「按省加载」的选择值前缀。带前缀才能和同名市区分（北京 / 上海
  /// 既是直辖市也是市），且不必改 `LiveRegionStore` 的存储格式。
  static const String provincePrefix = '省:';

  static bool isProvinceSelection(String? value) =>
      value != null && value.startsWith(provincePrefix);

  static String? provinceOfSelection(String? value) =>
      isProvinceSelection(value) ? value!.substring(provincePrefix.length) : null;

  static bool isProvince(String name) =>
      kProvinces.contains(name) || kProvinceAliases.values.contains(name);

  /// 下拉里显示的文字：`省:江苏` → `江苏全省`。
  static String selectionLabel(String value) =>
      isProvinceSelection(value) ? '${provinceOfSelection(value)}全省' : value;

  /// 一个频道的省份归属：省级台从台名前缀读，市级台从城市反查行政区代码。
  static String? provinceOfChannel(LiveChannel channel) =>
      provinceOfName(channel.name) ??
      provinceOfCity(inferCity(channel.name, tvgId: channel.tvgId));

  /// GB/T 2260 行政区划代码（前四位 + 00 的地级市码）。
  ///
  /// 覆盖省会/直辖市 + 江苏、浙江、广东、山东全部地级市 + 常见地市。
  /// 优先用代码而不是中文市名：实测 pconline 的中文是 GBK，
  /// 直接解析会拿到乱码，而 `cityCode` 是纯 ASCII 数字，稳定可靠。
  static const Map<String, String> cityCodes = <String, String>{
    '110100': '北京', '120100': '天津', '310100': '上海', '500100': '重庆',
    // 江苏（用户所在省份，全部 13 市）。
    '320100': '南京', '320200': '无锡', '320300': '徐州', '320400': '常州',
    '320500': '苏州', '320600': '南通', '320700': '连云港', '320800': '淮安',
    '320900': '盐城', '321000': '扬州', '321100': '镇江', '321200': '泰州',
    '321300': '宿迁',
    // 浙江。
    '330100': '杭州', '330200': '宁波', '330300': '温州', '330400': '嘉兴',
    '330500': '湖州', '330600': '绍兴', '330700': '金华', '330800': '衢州',
    '330900': '舟山', '331000': '台州', '331100': '丽水',
    // 广东。
    '440100': '广州', '440300': '深圳', '440400': '珠海', '440500': '汕头',
    '440600': '佛山', '440700': '江门', '441300': '惠州', '441900': '东莞',
    '442000': '中山', '445100': '潮州', '440800': '湛江', '441200': '肇庆',
    // 山东。
    '370100': '济南', '370200': '青岛', '370300': '淄博', '370600': '烟台',
    '370700': '潍坊', '371300': '临沂',
    // 省会 / 自治区首府 / 计划单列市。
    '130100': '石家庄', '140100': '太原', '150100': '呼和浩特',
    '150200': '包头', '150600': '鄂尔多斯', '150800': '巴彦淖尔',
    '150900': '乌兰察布', '150400': '赤峰',
    '210100': '沈阳', '210200': '大连', '220100': '长春', '220200': '吉林',
    '220300': '四平', '220500': '通化', '220600': '白山', '220700': '松原',
    '220800': '白城', '222400': '延边',
    '230100': '哈尔滨', '230200': '齐齐哈尔', '230600': '大庆',
    '231000': '牡丹江', '230800': '佳木斯',
    '340100': '合肥', '340200': '芜湖', '340300': '蚌埠', '340400': '淮南',
    '340800': '安庆', '341100': '滁州', '341500': '六安', '341600': '亳州',
    '350100': '福州', '350200': '厦门', '350300': '莆田', '350500': '泉州',
    '360100': '南昌', '360300': '萍乡', '360400': '九江',
    '410100': '郑州', '410300': '洛阳', '410600': '鹤壁', '410700': '新乡',
    '411400': '商丘', '411500': '信阳',
    '420100': '武汉', '420500': '宜昌', '420600': '襄阳', '420800': '荆门',
    '421000': '荆州',
    '430100': '长沙', '430200': '株洲', '430300': '湘潭', '430600': '岳阳',
    '450100': '南宁', '460100': '海口',
    '510100': '成都', '510700': '绵阳', '511500': '宜宾', '513400': '凉山',
    '520100': '贵阳', '520400': '安顺', '520500': '毕节', '520300': '遵义',
    '530100': '昆明', '532300': '楚雄', '532900': '大理',
    '540100': '拉萨',
    '610100': '西安', '610400': '咸阳', '610800': '榆林',
    '620100': '兰州', '620900': '酒泉', '621100': '定西', '622900': '临夏',
    '630100': '西宁', '640100': '银川', '650100': '乌鲁木齐',
    '652300': '昌吉', '652800': '巴音郭楞',
  };

  /// 标准市名 → 中英文/拼音别名。
  ///
  /// 拼音别名来自 iptv-org 的真实台名（`Suzhou News Channel`、
  /// `Chuxiong News Channel`、`Harbin Comprehensive News Channel`…），
  /// 中文别名来自国内索引（`呼市新闻综合`、`包头新闻综合`…）。
  /// 省份名**刻意不收**：`Jiangsu City Channel` 是省级台，不该变成「江苏市」。
  static const Map<String, List<String>> cityAliases = <String, List<String>>{
    '北京': ['beijing', 'peking'],
    '上海': ['shanghai'],
    '天津': ['tianjin'],
    '重庆': ['chongqing'],
    '广州': ['guangzhou', 'canton'],
    '深圳': ['shenzhen'],
    '杭州': ['hangzhou'],
    '成都': ['chengdu'],
    '武汉': ['wuhan'],
    '西安': ["xi'an", 'xian'],
    '郑州': ['zhengzhou'],
    '济南': ['jinan'],
    '青岛': ['qingdao', 'qtv'],
    '长沙': ['changsha'],
    '合肥': ['hefei'],
    '福州': ['fuzhou'],
    '厦门': ['xiamen', 'amoy'],
    '南昌': ['nanchang'],
    '昆明': ['kunming'],
    '贵阳': ['guiyang'],
    '南宁': ['nanning'],
    '海口': ['haikou'],
    '兰州': ['lanzhou'],
    '西宁': ['xining'],
    '银川': ['yinchuan'],
    '乌鲁木齐': ['urumqi', 'wulumuqi'],
    '拉萨': ['lhasa'],
    '呼和浩特': ['hohhot', 'huhhot', '呼市'],
    '太原': ['taiyuan'],
    '石家庄': ['shijiazhuang'],
    '哈尔滨': ['harbin'],
    '长春': ['changchun'],
    '沈阳': ['shenyang'],
    '大连': ['dalian'],
    '宁波': ['ningbo'],
    '温州': ['wenzhou'],
    '嘉兴': ['jiaxing'],
    '湖州': ['huzhou'],
    '绍兴': ['shaoxing'],
    '金华': ['jinhua'],
    '台州': ['taizhou'],
    '舟山': ['zhoushan'],
    '衢州': ['quzhou'],
    '丽水': ['lishui'],
    '南京': ['nanjing'],
    '无锡': ['wuxi'],
    '徐州': ['xuzhou'],
    '常州': ['changzhou'],
    '苏州': ['suzhou', 'soochow'],
    '南通': ['nantong'],
    '连云港': ['lianyungang'],
    '淮安': ["huai'an", 'huaian'],
    '盐城': ['yancheng'],
    '扬州': ['yangzhou'],
    '镇江': ['zhenjiang'],
    '泰州': ['taizhou2'],
    '宿迁': ['suqian'],
    '东莞': ['dongguan'],
    '佛山': ['foshan'],
    '珠海': ['zhuhai'],
    '中山': ['zhongshan'],
    '惠州': ['huizhou'],
    '汕头': ['shantou'],
    '潮州': ['chaozhou'],
    '泉州': ['quanzhou'],
    '烟台': ['yantai'],
    '潍坊': ['weifang'],
    '淄博': ['zibo'],
    '洛阳': ['luoyang'],
    '芜湖': ['wuhu'],
    '蚌埠': ['bengbu'],
    '滁州': ['chuzhou'],
    '安顺': ['anshun'],
    '遵义': ['zunyi'],
    '毕节': ['bijie'],
    '楚雄': ['chuxiong'],
    '大理': ['dali'],
    '包头': ['baotou'],
    '鄂尔多斯': ['ordos', 'eerduosi'],
    '巴彦淖尔': ['bayannur', 'bayannaoer'],
    '乌兰察布': ['ulanqab', 'wulanchabu'],
    '赤峰': ['chifeng'],
    '四平': ['siping'],
    '通化': ['tonghua'],
    '白城': ['baicheng'],
    '白山': ['baishan'],
    '松原': ['songyuan'],
    '吉林': ['jilin'],
    '延边': ['yanbian'],
    '齐齐哈尔': ['qiqihar'],
    '大庆': ['daqing'],
    '牡丹江': ['mudanjiang'],
    '佳木斯': ['jiamusi'],
    '鹤壁': ['hebi'],
    '商丘': ['shangqiu'],
    '信阳': ['xinyang'],
    '宜昌': ['yichang'],
    '襄阳': ['xiangyang'],
    '荆门': ['jingmen'],
    '荆州': ['jingzhou'],
    '株洲': ['zhuzhou'],
    '湘潭': ['xiangtan'],
    '岳阳': ['yueyang'],
    '绵阳': ['mianyang'],
    '宜宾': ['yibin'],
    '凉山': ['liangshan'],
    '酒泉': ['jiuquan'],
    '敦煌': ['dunhuang'],
    '临夏': ['linxia', 'hezheng'],
    '和政': ['hezheng2'],
    '萍乡': ['pingxiang'],
    '九江': ['jiujiang'],
    '潜江': ['qianjiang'],
  };

  /// 关键词 → 标准市名（运行期展开一次）。
  static final Map<String, String> _byKeyword = () {
    final m = <String, String>{};
    cityAliases.forEach((city, aliases) {
      m[_key(city)] = city;
      for (final a in aliases) {
        final k = _key(a);
        // 'taizhou2' / 'hezheng2' 只是消歧占位，不作为匹配关键词。
        if (!k.endsWith('2')) m[k] = city;
      }
    });
    return m;
  }();

  /// 中文关键词优先、按长度降序（「鄂尔多斯」必须比「赤峰」先比）。
  static final List<String> _chineseKeywords = () {
    final l = _byKeyword.keys.where((k) => k.contains(RegExp(r'[\u4e00-\u9fa5]'))).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    return l;
  }();

  /// 拼音关键词也按长度降序：`xiangyang` 要先于 `xian`，
  /// 否则「襄阳」会被「西安」吃掉。
  static final List<String> _latinKeywords = () {
    final l = _byKeyword.keys.where((k) => !k.contains(RegExp(r'[\u4e00-\u9fa5]'))).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    return l;
  }();

  /// 归一化匹配键：小写、只留字母数字与汉字。
  static String _key(String raw) => raw
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fa5]'), '');

  /// 是否是已知城市（IP 定位结果只有命中这里才被采纳，防脏数据注入 UI）。
  static bool isKnown(String city) => cityAliases.containsKey(city);

  /// 是否是合法的城市选择项（含「全部城市 / 其它城市」两个虚拟项，
  /// 以及 `省:XX` 形式的按省加载项）。
  static bool isValidSelection(String? city) {
    if (city == null) return false;
    if (city == allCities || city == otherCities) return true;
    if (isProvinceSelection(city)) {
      final province = provinceOfSelection(city);
      return province != null &&
          province.isNotEmpty &&
          province.length <= 16 &&
          isProvince(province);
    }
    return isKnown(city);
  }

  /// 行政区划代码 → 标准市名；区县码会先归到所属地级市。
  static String? cityOfCode(String raw) {
    final code = raw.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) return null;
    final direct = cityCodes[code];
    if (direct != null) return direct;
    // 有些接口给到区县一级（例如 320505），归到 320500。
    return cityCodes['${code.substring(0, 4)}00'];
  }

  /// 把定位接口给的市名归一成标准市名。
  ///
  /// 处理形态：`江苏省苏州市`、`苏州市`、`Suzhou`、`Jiaxing`、`未知`。
  static String? cityOfName(String raw) {
    var s = raw.trim();
    if (s.isEmpty || s.length > 48) return null;
    // **顺序不能反**：先去行政后缀，再去省份前缀。
    // 反过来的话「苏州市」会被 `^XX(省|市)` 整个吃掉（「苏州」+「市」），
    // 只剩空串，定位结果直接失效。
    //   江苏省苏州市 → 江苏省苏州 → 苏州
    //   苏州市       → 苏州       → 苏州
    s = s
        .replaceAll(RegExp(r'(市|地区|自治州|盟|特别行政区)$'), '')
        .trim();
    s = s
        .replaceAll(
            RegExp(r'^[\u4e00-\u9fa5]{2,8}(省|自治区|特别行政区)'), '')
        .trim();
    if (s.isEmpty || s.length > 24) return null;
    final key = _key(s);
    if (key.isEmpty) return null;
    final hit = _byKeyword[key];
    if (hit != null) return hit;
    // 拼音可能带空格/连字符（_key 已去掉），再按长度降序做一次前缀匹配。
    for (final k in _latinKeywords) {
      if (k.length >= 4 && key.startsWith(k)) return _byKeyword[k];
    }
    return null;
  }

  /// 从台名 / tvg-id 推断城市归属。
  ///
  /// 中文用全串子串（「江苏苏州新闻」也能命中），拼音只在台名开头匹配
  /// （`Suzhou News Channel` 这类形态），避免 `Channel 8` 中间随便一个词误判。
  static String? inferCity(String name, {String? tvgId}) {
    final full = _key(name);
    if (full.isNotEmpty) {
      for (final k in _chineseKeywords) {
        if (full.contains(k)) return _byKeyword[k];
      }
      final head = full.length > 20 ? full.substring(0, 20) : full;
      for (final k in _latinKeywords) {
        if (head.startsWith(k)) return _byKeyword[k];
      }
    }
    if (tvgId != null && tvgId.isNotEmpty) {
      final id = _key(tvgId);
      for (final k in _latinKeywords) {
        if (id.startsWith(k)) return _byKeyword[k];
      }
    }
    return null;
  }

  /// 统计地方频道里出现的城市（按台数降序，同数按名称，保证顺序稳定）。
  static List<CityOption> citiesOf(Iterable<LiveChannel> channels) {
    final counts = <String, int>{};
    for (final c in channels) {
      final city = inferCity(c.name, tvgId: c.tvgId);
      if (city == null) continue;
      counts[city] = (counts[city] ?? 0) + 1;
    }
    final list = counts.entries
        .map((e) => CityOption(e.key, e.value))
        .toList()
      ..sort((a, b) {
        final byCount = b.count.compareTo(a.count);
        return byCount != 0 ? byCount : a.name.compareTo(b.name);
      });
    return list;
  }

  /// 标准市名 → 所属省：用行政区划代码反查，避免再维护一份「市 → 省」表。
  ///
  /// 返回 null 表示该市不在 [cityCodes] 里（少数别名城市），调用方应
  /// 退到「其它城市」或台名前缀判断，不能凭空猜一个省。
  static String? provinceOfCity(String? city) {
    if (city == null || city.isEmpty) return null;
    for (final e in cityCodes.entries) {
      if (e.value == city) {
        return kProvinceByCodePrefix[e.key.substring(0, 2)];
      }
    }
    return null;
  }

  /// 从台名开头识别省名：`江苏体育`、`浙江钱江都市`、
  /// `Xinjiang TV 1`、`Nei Monggol TV 2` 这类省级台推断不出城市，
  /// 但「选省加载本省全部地方台」时必须能收进来。
  ///
  /// 只认**开头**：台名中间夹一个省名（如「苏州江苏戏曲」）不构成省份归属，
  /// 否则会把市级台错误地同时挂到省与市两份列表里。
  static String? provinceOfName(String name) {
    final key = _key(name);
    if (key.isEmpty) return null;
    for (final p in _provinceKeywords) {
      if (key.startsWith(p)) return _provinceByKeyword[p];
    }
    return null;
  }

  /// 省份关键词按长度降序：`内蒙古` 必须比 `蒙` 先比，
  /// `黑龙江` 不能先被「黑」之类短词截断。
  static final List<String> _provinceKeywords = () {
    final keys = <String>[...kProvinces, ...kProvinceAliases.keys];
    keys.sort((a, b) => b.length.compareTo(a.length));
    return keys;
  }();

  static final Map<String, String> _provinceByKeyword = () {
    final m = <String, String>{
      for (final p in kProvinces) _key(p): p,
    };
    kProvinceAliases.forEach((alias, province) => m[_key(alias)] = province);
    return m;
  }();

  /// 统计地方频道里出现的**省**（按 GB/T 2260 顺序，别名省排后面）。
  static List<CityOption> provincesOf(Iterable<LiveChannel> channels) {
    final counts = <String, int>{};
    for (final c in channels) {
      final province = provinceOfChannel(c);
      if (province == null) continue;
      counts[province] = (counts[province] ?? 0) + 1;
    }
    final names = counts.keys.toList()
      ..sort((a, b) {
        final ia = kProvinces.indexOf(a);
        final ib = kProvinces.indexOf(b);
        if (ia >= 0 && ib >= 0) return ia.compareTo(ib);
        if (ia >= 0) return -1;
        if (ib >= 0) return 1;
        return a.compareTo(b);
      });
    return <CityOption>[for (final n in names) CityOption(n, counts[n]!)];
  }

  /// 按城市 / 按省过滤地方频道。
  ///
  /// {城市名} → 只返回该市台；`省:XX` → 返回该省**全部**地方台（含省级台）；
  /// [allCities] 返回全部；[otherCities] 返回「推断不出城市」的那些台——
  /// 保证没有任何频道会因为识别不了城市而彻底消失。
  static List<LiveChannel> filter(Iterable<LiveChannel> channels, String? city) {
    if (city == null || city == allCities) {
      return channels.toList(growable: false);
    }
    if (isProvinceSelection(city)) {
      final province = provinceOfSelection(city);
      return channels
          .where((c) => provinceOfChannel(c) == province)
          .toList(growable: false);
    }
    return channels
        .where((c) {
          final inferred = inferCity(c.name, tvgId: c.tvgId);
          return city == otherCities ? inferred == null : inferred == city;
        })
        .toList(growable: false);
  }

  /// 默认选中的城市。
  ///
  /// 优先级：**用户上次的选择 > IP 定位 > 本地默认城市（[defaultLocalCity]）
  /// > 全部城市**。[preferredLocal] 是可选项，纯逻辑回归用例不传时不改变
  /// 历史行为；主程序 UI 传 `defaultLocalCity`，于是开机只显示苏州地方台。
  static String defaultCity(
    Iterable<LiveChannel> local, {
    String? saved,
    String? located,
    String? preferredLocal,
  }) {
    final known = citiesOf(local).map((e) => e.name).toSet();
    if (saved != null &&
        (saved == allCities ||
            saved == otherCities ||
            (isProvinceSelection(saved) &&
                isProvince(provinceOfSelection(saved) ?? '')) ||
            known.contains(saved))) {
      return saved;
    }
    if (located != null && known.contains(located)) return located;
    if (preferredLocal != null && known.contains(preferredLocal)) {
      return preferredLocal;
    }
    return allCities;
  }
}
