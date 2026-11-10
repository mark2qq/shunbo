package com.shunbo.legacy;

/**
 * 版本兼容分支判定 —— Flutter 主程序 {@code lib/platform/version_compat.dart}
 * 在原生层的**语义镜像**。
 *
 * <p>单一事实来源仍是 Dart 文件；这里的常量、严格小于判定、保守降级策略
 * 必须与它逐字对齐，构建脚本 {@code build_legacy.py} 会用跨语言断言锁住。
 * 之所以需要一份 Java 实现：兼容分支是纯原生 APK，运行时没有 Dart VM。
 *
 * <p>比较对象只认 {@code Build.VERSION.SDK_INT}（整数 Android API 等级）。
 * 明确排除：应用版本 1.0.0、{@code Build.VERSION.RELEASE} 展示串「4.3」、
 * eUI 8.0 等厂商 UI 版本 —— 这些都不是门槛，字符串比较还会出现
 * 「9 &gt; 10」式误判。{@code release} 只进诊断文本，绝不参与比较。
 *
 * <p>阈值 24（Flutter 3.47 引擎 AAR 下限 / Android 7.0），严格 {@code <}：
 * 23 进兼容、24 走默认、25 走默认；本机实测 API 18 进兼容分支。
 */
public final class LegacyVersionCompat {

    /** 与 Dart kMinSupportedAndroidApi 一致。 */
    public static final int MIN_SUPPORTED_API = 24;

    public static final String SUBJECT = "Android API 等级（Build.VERSION.SDK_INT）";

    private LegacyVersionCompat() {}

    public enum Branch {
        DEFAULT_FLOW("defaultFlow", "默认流程"),
        LEGACY_COMPAT("legacyCompat", "兼容分支"),
        NOT_APPLICABLE("notApplicable", "不适用");

        public final String name;
        public final String label;

        Branch(String name, String label) {
            this.name = name;
            this.label = label;
        }
    }

    public enum Reason {
        MEETS_REQUIREMENT("meetsRequirement", "版本满足要求（API ≥ 24）"),
        BELOW_THRESHOLD("belowThreshold", "设备 API < 24，进入兼容分支"),
        NOT_APPLICABLE("notApplicable", "非 Android 平台，保持默认流程"),
        PROBE_FAILED("probeFailed", "版本探测失败，保守进入兼容分支"),
        MISSING_VERSION("missingVersion", "版本信息缺失，保守进入兼容分支"),
        INVALID_VERSION("invalidVersion", "版本信息非法，保守进入兼容分支");

        public final String name;
        public final String label;

        Reason(String name, String label) {
            this.name = name;
            this.label = label;
        }
    }

    /** 不可变的一次决策结果；启动期锁存一次，运行期不翻转。 */
    public static final class Decision {
        public final Branch branch;
        public final Reason reason;
        /** 解析成功的 API 等级；缺失 / 非法为 null。 */
        public final Integer apiLevel;
        /** true = 因探测失败而降级，与「确知是低版本」区分。 */
        public final boolean degraded;
        /** 仅展示，绝不参与比较。 */
        public final String release;

        Decision(Branch branch, Reason reason, Integer apiLevel,
                 boolean degraded, String release) {
            this.branch = branch;
            this.reason = reason;
            this.apiLevel = apiLevel;
            this.degraded = degraded;
            this.release = release == null ? "" : release;
        }

        public boolean isLegacyCompat() { return branch == Branch.LEGACY_COMPAT; }

        public String diagnosticText() {
            return "运行分支：" + branch.label + "（" + branch.name + "）\n"
                    + "判定依据：" + reason.label + "（" + reason.name + "）\n"
                    + "比较对象：" + SUBJECT + "\n"
                    + "低版本阈值：API < " + MIN_SUPPORTED_API
                    + " 进兼容分支，≥ 阈值走默认流程\n"
                    + "实测 API：" + (apiLevel == null ? "未知" : apiLevel) + "\n"
                    + "系统版本字符串：" + (release.length() == 0 ? "未知" : release)
                    + "（仅展示，不参与比较）"
                    + (degraded ? "\n检测状态：降级（探测未成功）" : "\n检测状态：正常");
        }
    }

    /**
     * 只接受 {@code 1..1000} 的纯整数：int / long / 整数值 double / 纯数字字符串。
     * 拒绝 {@code "4.3"}、{@code "1.0.0"}、bool、NaN、±∞、集合、越界值。
     */
    public static Integer parseApiLevel(Object raw) {
        if (raw == null) return null;
        long value;
        if (raw instanceof Integer) {
            value = ((Integer) raw).longValue();
        } else if (raw instanceof Long) {
            value = ((Long) raw).longValue();
        } else if (raw instanceof Double || raw instanceof Float) {
            double d = ((Number) raw).doubleValue();
            if (Double.isNaN(d) || Double.isInfinite(d) || d != Math.rint(d)) return null;
            if (d < 1.0d || d > 1000.0d) return null;
            value = (long) d;
        } else if (raw instanceof String) {
            String s = ((String) raw).trim();
            if (s.length() == 0 || s.length() > 4) return null;
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                if (c < '0' || c > '9') return null;
            }
            try {
                value = Long.parseLong(s);
            } catch (NumberFormatException e) {
                return null;
            }
        } else {
            return null;
        }
        return (value >= 1 && value <= 1000) ? Integer.valueOf((int) value) : null;
    }

    /** 唯一整数比较入口，与 Dart compareToThreshold 同语义。 */
    public static int compareToThreshold(int apiLevel) {
        return apiLevel - MIN_SUPPORTED_API;
    }

    /**
     * @param rawSdkInt 原生探测到的原始值（可能是 null / 非法值）
     * @param probeOk   探测是否成功（异常、字段缺失都算失败）
     * @param isAndroid 非 Android 平台走 notApplicable，默认流程逐字不变
     */
    public static Decision decide(Object rawSdkInt, boolean probeOk,
                                  boolean isAndroid, String release) {
        if (!isAndroid) {
            return new Decision(Branch.NOT_APPLICABLE, Reason.NOT_APPLICABLE,
                    null, false, release);
        }
        if (!probeOk) {
            return new Decision(Branch.LEGACY_COMPAT, Reason.PROBE_FAILED,
                    parseApiLevel(rawSdkInt), true, release);
        }
        if (rawSdkInt == null) {
            return new Decision(Branch.LEGACY_COMPAT, Reason.MISSING_VERSION,
                    null, true, release);
        }
        Integer parsed = parseApiLevel(rawSdkInt);
        if (parsed == null) {
            return new Decision(Branch.LEGACY_COMPAT, Reason.INVALID_VERSION,
                    null, true, release);
        }
        boolean legacy = compareToThreshold(parsed.intValue()) < 0;
        return new Decision(
                legacy ? Branch.LEGACY_COMPAT : Branch.DEFAULT_FLOW,
                legacy ? Reason.BELOW_THRESHOLD : Reason.MEETS_REQUIREMENT,
                parsed, false, release);
    }
}
