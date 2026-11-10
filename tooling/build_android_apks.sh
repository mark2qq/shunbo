#!/usr/bin/env bash
# 安卓渠道包打包（R8/R9 的打包矩阵落地）。
#
# 为什么用脚本而不是让人记命令：`--target-platform` 一旦漏写，打出来的就是
# 「全 ABI 通用包」（实测 55 MB 且带 x86_64），与精简版几乎没有区别 ——
# 这种偏差在文件管理器里看不出来，只有装到 1 GB 盒子上才发现「怎么这么大」。
#
# 矩阵（与《安卓端形态与安装包要求》一致）：
#   完整版 com.shunbo.tv       arm64-v8a + armeabi-v7a   手机 + 电视
#   精简版 com.shunbo.tv.lite  armeabi-v7a               电视优先（老设备）
#
# 用法：
#   bash tooling/build_android_apks.sh            # release
#   MODE=debug bash tooling/build_android_apks.sh # 调试包
#
# 环境变量：ANDROID_HOME / JAVA_HOME / FLUTTER_STORAGE_BASE_URL 由调用方提供；
# 未提供时用仓库里记录的本机默认值（与 README 一致）。
set -euo pipefail

cd "$(dirname "$0")/.."

# 工具链：优先用仓库约定的 JDK17。
#
# 不能只写 `${JAVA_HOME:-默认值}`：本机环境变量里可能**残留 JDK8**
# （AGP 9 明确拒绝，报 "JAVA_HOME is set to an invalid directory"），
# 那样脚本会在第一行就失败，而不是按约定构建。
JDK17="D:/Android/openjdk/jdk-17.0.12"
SDK="D:/Android/android-sdk"
[ -d "$JDK17" ] && export JAVA_HOME="$JDK17"
[ -d "$SDK" ] && export ANDROID_HOME="$SDK"
export ANDROID_HOME="${ANDROID_HOME:-D:/Android/android-sdk}"
export JAVA_HOME="${JAVA_HOME:-D:/Android/openjdk/jdk-17.0.12}"
# 引擎产物走国内镜像，否则首次构建会卡在下载（实测 68 KB/s → 8.7 MB/s）。
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"

FLUTTER="${FLUTTER:-D:/flutter/bin/flutter}"
MODE="${MODE:-release}"
OUT="build/app/outputs/flutter-apk"

build() {
  local flavor="$1" platforms="$2"
  echo "==> building $flavor ($platforms, $MODE)"
  "$FLUTTER" build apk "--$MODE" --flavor "$flavor" --target-platform "$platforms"
}

build full android-arm64,android-arm
build lite android-arm

echo
echo "==> 产物"
for f in "$OUT/app-full-$MODE.apk" "$OUT/app-lite-$MODE.apk"; do
  if [ -f "$f" ]; then
    size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")
    # R9：单包不超过 60 MB（60 * 1024 * 1024），超出时先裁语言资源而不是裁内核能力。
    if [ "$size" -gt 62914560 ]; then
      echo "FAIL $f 超过 60 MB（$size 字节）" >&2
      exit 1
    fi
    printf '%s  %s bytes\n' "$f" "$size"
    sha256sum "$f" 2>/dev/null || shasum -a 256 "$f"
  else
    echo "缺失：$f" >&2
    exit 1
  fi
done
