#!/usr/bin/env bash
set -e
DL=/d/flutter_dl
TMP=/d/flutter_tmp
URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.47.9-stable.zip"
SHA="d8e2b5977e09082c6440f89dc1aa887b94c8fbcc3b39222797046295a3f68a9e"

mkdir -p "$DL" "$TMP"
cd "$DL"

echo "[1/3] 下载 Flutter 3.47.9 ..."
if [ -f flutter.zip ]; then
  echo "已存在 flutter.zip，跳过下载"
else
  curl -L --retry 3 --max-time 1100 -o flutter.zip "$URL"
fi
echo "下载大小: $(stat -c %s flutter.zip 2>/dev/null || echo unknown) bytes"

echo "[2/3] 校验 sha256 ..."
calc=$(sha256sum flutter.zip | awk '{print $1}')
if [ "$calc" = "$SHA" ]; then
  echo "sha256 OK"
else
  echo "sha256 不匹配: got $calc expected $SHA"
  exit 1
fi

echo "[3/3] 解压到 D:/flutter ..."
rm -rf "$TMP"
unzip -q -o flutter.zip -d "$TMP"
rm -rf /d/flutter
mv "$TMP/flutter" /d/flutter
echo "解压完成: $(ls /d/flutter/bin)"
echo "FLUTTER_INSTALL_DONE"
