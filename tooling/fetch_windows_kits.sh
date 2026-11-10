#!/usr/bin/env bash
# 预取 media_kit 的 Windows 原生依赖（libmpv dev 包 + ANGLE）。
#
# 为什么需要：`media_kit_libs_windows_video` 在 CMake configure 阶段直接
# `file(DOWNLOAD https://github.com/...)`，两个问题在国内网络下必现：
#   ① 走系统代理时 CONNECT 被 502；② CMake 的下载不带重试，失败后留下 0 字节文件，
#      而它只在 md5 不匹配时才删除重下 —— 表现就是「Integrity check failed」反复出现。
# 所以这里在构建前用 curl 走加速镜像 + 断点续传把包放到 CMake 期望的位置，
# 之后的构建就能命中 md5、直接解压（CMake 自己那份下载不会再触发）。
#
# 用法：bash tooling/fetch_windows_kits.sh [build/windows/x64]
set -u
DEST="${1:-build/windows/x64}"
mkdir -p "$DEST"

fetch() { # url md5 name max_rounds
  local url="$1" md5="$2" name="$3" rounds="${4:-40}"
  local out="$DEST/$name"
  if [ -f "$out" ] && [ "$(md5sum "$out" | cut -d' ' -f1)" = "$md5" ]; then
    echo "[skip] $name 已就绪"
    return 0
  fi
  for i in $(seq 1 "$rounds"); do
    curl --noproxy '*' -L -C - --max-time 300 -s -o "$out" "$url" || true
    if [ "$(md5sum "$out" 2>/dev/null | cut -d' ' -f1)" = "$md5" ]; then
      echo "[ok] $name 第 $i 轮完成"
      return 0
    fi
    echo "[retry $i] $name $(stat -c%s "$out" 2>/dev/null || echo 0) bytes"
  done
  echo "[fail] $name 未能通过 md5 校验"
  return 1
}

# 镜像按实测速度排序（国内网络）：imciel 最快（~140KB/s），gh-proxy.com 仅 ~11KB/s。
# 断点续传跨镜像安全：同一个 release 资产，字节一致，md5 仍由脚本最后校验。
BASE="${SHUNBO_GH_MIRROR:-https://ghproxy.imciel.com}/https://github.com"
fetch "$BASE/media-kit/libmpv-win32-video-build/releases/download/2023-09-24/mpv-dev-x86_64-20230924-git-652a1dd.7z" \
      a832ef24b3a6ff97cd2560b5b9d04cd8 mpv-dev-x86_64-20230924-git-652a1dd.7z
fetch "$BASE/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z" \
      e866f13e8d552348058afaafe869b1ed ANGLE.7z
