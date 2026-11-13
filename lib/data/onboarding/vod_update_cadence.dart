/// 「设置-点播源」的自动更新间隔档位（1.0.5 第二十四次修）。
///
/// 用户红标：「可以手动设定更新时间，比如一天、三天、一周、一月、一季度、
/// 半年、一年这种」—— 这七档就是界面上的七个选项，顺序即界面顺序。
///
/// 单独成一个文件，是因为它同时被三处读：
///  * 设置持久化 `VodSourceAddressSettings`（只存天数，读回来做容错）；
///  * 调度器 `VodIndexAutoUpdater`（按当前档位判断「到点了吗」）；
///  * 设置页 UI（渲染七个选项）。
/// 纯枚举、零依赖，`dart run` 门禁能直接把整张表核完，不必起界面。
library;

enum VodUpdateCadence {
  day(1, '一天'),
  threeDays(3, '三天'),
  week(7, '一周'),
  month(30, '一月'),
  quarter(90, '一季度'),
  halfYear(180, '半年'),
  year(365, '一年');

  const VodUpdateCadence(this.days, this.label);

  /// 间隔天数。月按 30 天、季度按 90 天、半年按 180 天、年按 365 天计 ——
  /// 这里要的是「用户能理解的间隔」，不是日历精确值（二月也是 30 天）。
  final int days;

  /// 界面文案，同时也是「距上次更新不足 X」里的 X。
  final String label;

  Duration get duration => Duration(days: days);

  /// 落盘值只认这七档；其余（旧配置没有这个键、手改坏值、越界负数）
  /// 一律回落「一天」。不认识的数字不该变成「永不更新」，
  /// 也不该被放行成「半小时一次」。
  static VodUpdateCadence fromDays(int days) {
    for (final c in values) {
      if (c.days == days) return c;
    }
    return VodUpdateCadence.day;
  }

  /// 解析落盘值：非整数 / 不在表里都给 null，方便调用方区分「没配过」。
  static VodUpdateCadence? tryParse(Object? raw) {
    if (raw is! int) return null;
    for (final c in values) {
      if (c.days == raw) return c;
    }
    return null;
  }
}
