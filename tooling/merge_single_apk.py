#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把「Flutter 全量包」与「原生兼容内核」合并成**一个** APK（minSdk 16）。

为什么必须手工组装
------------------
Flutter 3.47 的 Gradle 插件把 minSdk 的下限焊死在引擎要求上：把 app 的
`minSdk` 写成 16，`flutter build` 会**把脚本改写回** `flutter.minSdkVersion`
（=24），产物 `aapt2 dump badging` 仍是 `minSdkVersion:'24'`（本机实测）。
所以「一个包同时装进 API 18 的乐视 S50 Air 和现代设备」没法走 `flutter build`，
只能：

  1. 照常 `flutter build` 出完整的 Flutter 产物（拿 dex / so / assets / arsc）；
  2. 用本脚本的 manifest（minSdk 16 + 分流入口）单独 `aapt2 link`，**只取产物里的
     AndroidManifest.xml**，arsc 仍用 Flutter 那份（资源 ID 靠 `--stable-ids` 对齐，
     脚本会断言两边的 LaunchTheme / ic_launcher / tv_banner ID 完全一致）；
  3. dex 顺序是关键：**原生内核必须作 classes.dex**，Flutter 的两个 dex 顺延为
     classes2/classes3。API 18 没有 multidex，系统只加载 classes.dex，于是它只会
     看到原生类，绝不会触碰 Flutter 的类；API 24+ 原生支持多 dex，两套都能用。
  4. 原生界面的频道清单 `assets/channels.json` 只存在于 legacy/assets/，Flutter 产物
     里没有（Flutter 的资产在 assets/flutter_assets/ 下），必须由本脚本搬进去。
     这份清单由 `tooling/dump_live_catalog.dart` → `tooling/gen_legacy_catalog.dart`
     从主程序运行时导出，保证两个界面用的是同一套频道与线路。

运行时怎么分流：唯一入口 `com.shunbo.legacy.RouterActivity` 读 SDK_INT，
≥24 跳 `com.shunbo.shunbo.MainActivity`（Flutter），否则跳原生播放界面。
RouterActivity 用 `Class.forName` 做探针，类找不到就走原生，不依赖任何 Flutter 类。

产物：dist/Shunbo-<version>-full.apk（v1 + v2 双签，v1 给老解析器）

用法：
  python tooling/merge_single_apk.py                      # 用默认路径与版本
  python tooling/merge_single_apk.py --skip-flutter-build # 复用已有 Flutter 产物
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(ROOT, "dist")
LEGACY = os.path.join(ROOT, "legacy")
SRC = os.path.join(LEGACY, "src", "com", "shunbo", "legacy")
THIRD_EXTRACTED = os.path.join(LEGACY, "third_party", "extracted")
LEGACY_ASSETS = os.path.join(LEGACY, "assets")
SINGLE = os.path.join(LEGACY, "single")
# 旧 work 目录可能被系统安全策略加了「禁止删除子项」的 ACL，rmtree/重命名都会
# 失败。允许用环境变量换一个干净目录重跑，既不动保护规则也不影响可复现构建。
WORK = os.path.join(SINGLE, os.environ.get("SHUNBO_SINGLE_WORK", "work"))
MANIFEST = os.path.join(SINGLE, "AndroidManifest.xml")
APP_RES = os.path.join(ROOT, "android", "app", "src", "main", "res")

SDK = "D:/Android/android-sdk"
BT = SDK + "/build-tools/36.0.0"
PLATFORM = SDK + "/platforms/android-36/android.jar"
JAVA = "D:/Android/openjdk/jdk-17.0.12/bin/java.exe"
JAVAC = "D:/Android/openjdk/jdk-17.0.12/bin/javac.exe"
KEYSTORE = "C:/Users/Administrator/.android/debug.keystore"
KS_PASS = "android"
KS_ALIAS = "androiddebugkey"

AAPT2 = BT + "/aapt2.exe"
ZIPALIGN = BT + "/zipalign.exe"
APKSIGNER = BT + "/lib/apksigner.jar"
D8 = BT + "/lib/d8.jar"

FLUTTER_APK = os.path.join(ROOT, "build", "app", "outputs", "flutter-apk",
                           "app-full-release.apk")
IJK_JAVA_JAR = os.path.join(THIRD_EXTRACTED, "ijkplayer-java-0.8.8-classes.jar")
IJK_ARM_JAR = os.path.join(THIRD_EXTRACTED, "ijkplayer-armv7a-0.8.8-classes.jar")
IKJ_SO_DIR = THIRD_EXTRACTED  # build_legacy.py 解包后 so 就平铺在这里
SO_FILES = ["libijkffmpeg.so", "libijksdl.so", "libijkplayer.so"]

MIN_SDK = 16
TARGET_SDK = 36
FLUTTER_MIN_API = 24

# 原生界面只从 APK 的 assets/ 读这份清单（ChannelCatalog.ASSET）。
# Flutter 产物里没有它（Flutter 的资产在 assets/flutter_assets/ 下），必须手动搬。
LEGACY_CATALOG = "channels.json"
CATALOG_ENTRY = "assets/" + LEGACY_CATALOG
# 规模下限：与 verify_legacy_compat 的 E03 同源，防止把空清单或旧的小清单打进去
CATALOG_MIN_CHANNELS = 900
CATALOG_MIN_STREAMS = 1500

checks = {}


def check(name, ok, detail=None):
    checks[name] = bool(ok)
    flag = "OK  " if ok else "FAIL"
    line = "   [%s] %s" % (flag, name)
    if detail:
        line += "  (%s)" % detail
    print(line)
    return ok


def run(cmd, label):
    proc = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    if proc.returncode != 0:
        print("[%s] 失败：%s" % (label, " ".join(str(c) for c in cmd[:4])))
        print(proc.stdout[-3000:])
        print(proc.stderr[-3000:])
        raise SystemExit(1)
    return proc.stdout


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fixed_info(name, stored, external_attr=0o644 << 16):
    """固定时间戳，让同一份输入产出字节一致的包（可复现构建）。"""
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_STORED if stored else zipfile.ZIP_DEFLATED
    info.external_attr = external_attr
    return info


def collect_java():
    out = []
    for base, _dirs, files in os.walk(SRC):
        for f in sorted(files):
            if f.endswith(".java"):
                out.append(os.path.join(base, f))
    return sorted(out)


def stable_ids(apk, target):
    """从 Flutter 产物导出 资源名→ID 表，确保新 link 的 manifest 指向同一批资源。"""
    dump = run([AAPT2, "dump", "resources", apk], "aapt2 dump resources")
    pkg = re.search(r"Package name=(\S+) id=", dump)
    name = pkg.group(1) if pkg else "com.shunbo.tv"
    rows = []
    for ln in dump.splitlines():
        m = re.match(r"^    resource (0x[0-9a-f]+) (\S+)\s*$", ln)
        if m:
            rows.append("%s:%s = %s" % (name, m.group(2), m.group(1)))
    with open(target, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(rows) + "\n")
    return rows


def dump_badging(apk):
    return run([AAPT2, "dump", "badging", apk], "aapt2 badging")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--flutter-apk", default=FLUTTER_APK)
    ap.add_argument("--version-name", default="1.0.4")
    ap.add_argument("--version-code", default="5")
    ap.add_argument("--skip-flutter-build", action="store_true")
    args = ap.parse_args()

    flutter_apk = args.flutter_apk
    out_name = "Shunbo-%s-full.apk" % args.version_name
    out_path = os.path.join(DIST, out_name)

    print("== 单包组装：%s ==" % out_name)
    if os.path.isdir(WORK):
        shutil.rmtree(WORK)
    os.makedirs(WORK)
    os.makedirs(DIST, exist_ok=True)

    # ---- 0. Flutter 产物 ----
    if not args.skip_flutter_build:
        if os.path.isfile(flutter_apk):
            # 覆盖前留一版，理由同 build_legacy.py：上一版可能是唯一能回退的包。
            prev = os.path.join(SINGLE, "prev")
            os.makedirs(prev, exist_ok=True)
            shutil.copy2(flutter_apk, os.path.join(prev, "app-full-release.prev.apk"))
    if not os.path.isfile(flutter_apk):
        print("缺少 Flutter 产物：%s" % flutter_apk)
        print("先跑：flutter build apk --flavor full --release --target-platform android-arm,android-arm64")
        raise SystemExit(1)

    # 覆盖前归档上一只单包（真机验证过的那只，绝不能直接丢）
    if os.path.isfile(out_path):
        prev_dir = os.path.join(DIST, "_prev")
        os.makedirs(prev_dir, exist_ok=True)
        prev_sha = sha256(out_path)
        import datetime
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        prev_name = "%s.%s.%s.apk.bak" % (
            os.path.splitext(out_name)[0], stamp, prev_sha[:8])
        shutil.move(out_path, os.path.join(prev_dir, prev_name))
        print("   归档上一版 -> dist/_prev/%s" % prev_name)

    src_badging = dump_badging(flutter_apk)
    src_min = re.search(r"minSdkVersion:'(\d+)'", src_badging)
    check("Flutter 产物的 minSdk 仍是引擎下限 24（证明必须绕开它）",
          src_min is not None and int(src_min.group(1)) >= FLUTTER_MIN_API,
          "minSdk=%s" % (src_min.group(1) if src_min else "?"))

    # ---- 1. 新 manifest：单独 link，只取 AndroidManifest.xml ----
    ids_path = os.path.join(WORK, "stable-ids.txt")
    rows = stable_ids(flutter_apk, ids_path)
    check("导出资源 ID 表（供 --stable-ids 锁定）", len(rows) > 50, "%d 条" % len(rows))

    res_zip = os.path.join(WORK, "res.zip")
    run([AAPT2, "compile", "--dir", APP_RES, "-o", res_zip], "aapt2 compile")
    base_apk = os.path.join(WORK, "manifest-base.apk")
    run([AAPT2, "link", "-o", base_apk, "-I", PLATFORM,
         "--manifest", MANIFEST,
         "--min-sdk-version", str(MIN_SDK),
         "--target-sdk-version", str(TARGET_SDK),
         "--version-code", str(args.version_code),
         "--version-name", args.version_name,
         res_zip, "--auto-add-overlay", "--stable-ids", ids_path], "aapt2 link")

    with zipfile.ZipFile(base_apk) as z:
        new_manifest = z.read("AndroidManifest.xml")
    check("新 manifest 非空", len(new_manifest) > 1000, "%d B" % len(new_manifest))

    # ---- 2. 原生 dex（必须是 classes.dex：API 18 只加载它）----
    classes_dir = os.path.join(WORK, "classes")
    os.makedirs(classes_dir)
    cp = os.pathsep.join([PLATFORM, IJK_JAVA_JAR, IJK_ARM_JAR])
    run([JAVAC, "--release", "8", "-encoding", "UTF-8", "-classpath", cp,
         "-d", classes_dir] + collect_java(), "javac")
    dex_dir = os.path.join(WORK, "dex")
    os.makedirs(dex_dir)
    d8_inputs = []
    for base, _dirs, files in os.walk(classes_dir):
        for f in sorted(files):
            if f.endswith(".class"):
                d8_inputs.append(os.path.join(base, f))
    d8_inputs += [IJK_JAVA_JAR, IJK_ARM_JAR]
    run([JAVA, "-cp", D8, "com.android.tools.r8.D8",
         "--lib", PLATFORM, "--min-api", str(MIN_SDK),
         "--output", dex_dir] + d8_inputs, "d8")
    legacy_dex = os.path.join(dex_dir, "classes.dex")
    native_dex = open(legacy_dex, "rb").read()
    dex_files = sorted(f for f in os.listdir(dex_dir) if f.endswith(".dex"))
    check("原生 dex 只有一份（单 dex 放得下 441 台客户端的类）",
          dex_files == ["classes.dex"], str(dex_files))

    # ---- 3. 组装 ----
    # 先把原生清单读进来并校验规模：这是原生界面唯一的频道/线路来源，
    # 也是「主程序与兼容界面用同一套频道表」这条要求的落点。
    catalog_path = os.path.join(LEGACY_ASSETS, LEGACY_CATALOG)
    if not os.path.isfile(catalog_path):
        print("缺少兼容版清单：%s" % catalog_path)
        print("先跑：dart run tooling/gen_legacy_catalog.dart")
        raise SystemExit(1)
    catalog_bytes = open(catalog_path, "rb").read()
    try:
        catalog = json.loads(catalog_bytes.decode("utf-8"))
    except Exception as exc:  # noqa: BLE001
        print("兼容版清单不是合法 JSON：%s" % exc)
        raise SystemExit(1)
    cat_channels = catalog.get("channels") or []
    cat_streams = sum(len(c.get("streams") or []) for c in cat_channels)
    check("兼容版清单规模达标（≥%d 台 / ≥%d 线路）"
          % (CATALOG_MIN_CHANNELS, CATALOG_MIN_STREAMS),
          len(cat_channels) >= CATALOG_MIN_CHANNELS and cat_streams >= CATALOG_MIN_STREAMS,
          "%d 台 / %d 线路" % (len(cat_channels), cat_streams))

    unsigned = os.path.join(WORK, "unsigned.apk")
    with zipfile.ZipFile(flutter_apk) as zin:
        names = zin.namelist()
        flutter_dex = [n for n in names if re.match(r"^classes\d*\.dex$", n)]
        check("Flutter 产物是 2 个 dex（顺延为 classes2/classes3）",
              len(flutter_dex) == 2, str(flutter_dex))
        dex_payload = {}
        for i, n in enumerate(sorted(flutter_dex)):
            dex_payload["classes%d.dex" % (i + 2)] = zin.read(n)

        with zipfile.ZipFile(unsigned, "w", zipfile.ZIP_DEFLATED) as zout:
            zout.writestr(fixed_info("AndroidManifest.xml", stored=False), new_manifest)
            zout.writestr(fixed_info("classes.dex", stored=False), native_dex)
            for name in sorted(dex_payload):
                zout.writestr(fixed_info(name, stored=False), dex_payload[name])

            # resources.arsc 必须 stored 且 4 字节对齐（API 30+ 强校验）
            zout.writestr(fixed_info("resources.arsc", stored=True),
                          zin.read("resources.arsc"))

            skip = set(flutter_dex) | {"AndroidManifest.xml", "resources.arsc"}
            for info in zin.infolist():
                if info.filename in skip:
                    continue
                if info.is_dir():
                    continue
                zout.writestr(fixed_info(info.filename,
                                         stored=(info.compress_type == zipfile.ZIP_STORED),
                                         external_attr=info.external_attr),
                              zin.read(info.filename))

            # 原生界面的频道清单：Flutter 产物里没有，必须补。
            # stored=True 保持与 build_legacy.py 一致（getAssets().open 两种都能读，
            # 但 uncompressed 让首帧读清单更快，且便于 aapt2 校验）。
            zout.writestr(fixed_info(CATALOG_ENTRY, stored=True), catalog_bytes)

    # ---- 4. 追加 ijkplayer 的 so（只进 armeabi-v7a）----
    have_so = set()
    with zipfile.ZipFile(unsigned) as z:
        for n in z.namelist():
            if n.startswith("lib/armeabi-v7a/"):
                have_so.add(os.path.basename(n))
    missing = [s for s in SO_FILES if s not in have_so]
    check("Flutter 产物里没有 ijkplayer 的 so（需要追加）", len(missing) == 3, str(missing))
    if missing:
        with zipfile.ZipFile(unsigned, "a", zipfile.ZIP_DEFLATED) as z:
            for so in missing:
                src = os.path.join(IKJ_SO_DIR, so)
                if not os.path.isfile(src):
                    print("缺少 so：%s" % src)
                    raise SystemExit(1)
                z.writestr(fixed_info("lib/armeabi-v7a/" + so, stored=True),
                           open(src, "rb").read())

    # ---- 5. 对齐 + 双签 ----
    aligned = os.path.join(WORK, "aligned.apk")
    run([ZIPALIGN, "-p", "-f", "4", unsigned, aligned], "zipalign")
    run([JAVA, "-jar", APKSIGNER, "sign",
         "--ks", KEYSTORE, "--ks-pass", "pass:" + KS_PASS,
         "--key-pass", "pass:" + KS_PASS, "--ks-key-alias", KS_ALIAS,
         "--min-sdk-version", str(MIN_SDK),
         "--max-sdk-version", str(TARGET_SDK),
         "--v1-signing-enabled", "true",
         "--v2-signing-enabled", "true",
         "--v3-signing-enabled", "false",
         "--out", out_path, aligned], "apksigner sign")

    # ---- 6. 断言 ----
    badging = dump_badging(out_path)
    min_sdk = re.search(r"minSdkVersion:'(\d+)'", badging)
    tgt_sdk = re.search(r"targetSdkVersion:'(\d+)'", badging)
    launch = re.search(r"^launchable-activity: name='([^']+)'", badging, re.M)
    leanback = re.search(r"^leanback-launchable-activity: name='([^']+)'", badging, re.M)
    check("单包 minSdk 降到 16（能装进 API 18 的电视）",
          min_sdk is not None and int(min_sdk.group(1)) == MIN_SDK,
          "minSdk=%s" % (min_sdk.group(1) if min_sdk else "?"))
    check("targetSdk 保持 36（不改变现代设备的行为）",
          tgt_sdk is not None and int(tgt_sdk.group(1)) == TARGET_SDK,
          "targetSdk=%s" % (tgt_sdk.group(1) if tgt_sdk else "?"))
    check("唯一桌面入口是分流路由",
          launch is not None and launch.group(1) == "com.shunbo.legacy.RouterActivity",
          launch.group(1) if launch else "?")
    check("电视端（LEANBACK）入口与手机入口同一个",
          leanback is not None and launch is not None and
          leanback.group(1) == launch.group(1),
          leanback.group(1) if leanback else "?")

    with zipfile.ZipFile(out_path) as z:
        names = z.namelist()
        dex_order = [n for n in names if re.match(r"^classes\d*\.dex$", n)]
        dex_order.sort(key=lambda s: 0 if s == "classes.dex" else int(re.findall(r"\d+", s)[0]))
        check("dex 顺序：classes.dex(原生) → classes2/3(Flutter)",
              dex_order == ["classes.dex", "classes2.dex", "classes3.dex"], str(dex_order))
        # 主 dex 里必须有路由与播放界面，且不能有 Flutter 的类
        main_dex = z.read("classes.dex")
        check("主 dex 含 RouterActivity / LegacyPlayerActivity 的类名",
              b"Lcom/shunbo/legacy/RouterActivity;" in main_dex and
              b"Lcom/shunbo/legacy/LegacyPlayerActivity;" in main_dex)
        check("主 dex 不含 Flutter / androidx 的类（API 18 不会被牵连）",
              b"Lio/flutter/" not in main_dex and b"Landroidx/" not in main_dex)
        so_names = sorted(n for n in names if n.endswith(".so"))
        check("三个 ijkplayer so 只进 armeabi-v7a",
              all(("lib/armeabi-v7a/" + s) in so_names for s in SO_FILES) and
              not any(s in n for n in so_names for s in SO_FILES
                      if not n.startswith("lib/armeabi-v7a/")),
              "%d 个 so" % len(so_names))
        check("Flutter 两套 ABI 的 so 都还在（现代设备走 64 位）",
              "lib/arm64-v8a/libflutter.so" in so_names and
              "lib/armeabi-v7a/libflutter.so" in so_names)
        check("不再声明 androidx.startup 初始化 Provider（API 18 会崩在启动）",
              b"androidx.startup" not in new_manifest)

        # 原生界面能不能起播，全看这份清单在不在、是不是同一份。
        check("单包内含 assets/channels.json（原生界面的频道表）",
              CATALOG_ENTRY in names, CATALOG_ENTRY if CATALOG_ENTRY in names else "缺失")
        if CATALOG_ENTRY in names:
            in_apk = z.read(CATALOG_ENTRY)
            check("包内清单与 legacy/assets/%s 字节一致（同一套频道与线路）"
                  % LEGACY_CATALOG, in_apk == catalog_bytes,
                  "%d B" % len(in_apk))
            try:
                apk_cat = json.loads(in_apk.decode("utf-8"))
                apk_ch = apk_cat.get("channels") or []
                apk_st = sum(len(c.get("streams") or []) for c in apk_ch)
                check("包内清单规模与源文件一致（%d 台 / %d 线路）"
                      % (len(cat_channels), cat_streams),
                      len(apk_ch) == len(cat_channels) and apk_st == cat_streams,
                      "%d 台 / %d 线路" % (len(apk_ch), apk_st))
            except Exception as exc:  # noqa: BLE001
                check("包内清单可解析为 JSON", False, str(exc))

    verify16 = run([JAVA, "-jar", APKSIGNER, "verify", "--min-sdk-version", "16",
                    "--verbose", out_path], "verify@16")
    verify18 = run([JAVA, "-jar", APKSIGNER, "verify", "--min-sdk-version", "18",
                    "--verbose", out_path], "verify@18")
    check("apksigner @16 通过（v1 SHA-1 覆盖 API 18）",
          "Verifies" in verify16, verify16.splitlines()[0] if verify16 else "")
    check("apksigner @18 通过", "Verifies" in verify18)
    check("v1 与 v2 同时存在",
          re.search(r"Verified using v1 scheme \(JAR signing\): true", verify18) is not None
          and re.search(r"Verified using v2 scheme.*: true", verify18) is not None)

    size = os.path.getsize(out_path)
    digest = sha256(out_path)
    check("产物大于 20 MB（Flutter 引擎 + 双 ABI 是主要内容）", size > 20 * 1024 * 1024,
          "%d B" % size)

    report = {
        "out": out_name,
        "path": out_path.replace("\\", "/"),
        "size": size,
        "sha256": digest,
        "minSdk": MIN_SDK,
        "targetSdk": TARGET_SDK,
        "versionName": args.version_name,
        "versionCode": int(args.version_code),
        "launchable": launch.group(1) if launch else None,
        "leanbackLaunchable": leanback.group(1) if leanback else None,
        "dexOrder": dex_order,
        "flutterMinSdk": int(src_min.group(1)) if src_min else None,
        "catalog": {
            "entry": CATALOG_ENTRY,
            "bytes": len(catalog_bytes),
            "channels": len(cat_channels),
            "streams": cat_streams,
            "sourceSha256": sha256(catalog_path),
        },
        "checks": checks,
    }
    os.makedirs(SINGLE, exist_ok=True)
    with open(os.path.join(SINGLE, "single_report.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)

    print("")
    failed = [k for k, v in checks.items() if not v]
    print("   size=%d  sha256=%s" % (size, digest))
    if failed:
        print("单包组装失败：%d/%d 条断言未通过" % (len(failed), len(checks)))
        for k in failed:
            print("   - %s" % k)
        raise SystemExit(1)
    print("单包组装通过：%d/%d 条断言" % (len(checks), len(checks)))
    print("产物：dist/%s" % out_name)


if __name__ == "__main__":
    main()
