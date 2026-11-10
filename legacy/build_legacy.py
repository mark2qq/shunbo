#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
构建「顺播原生兼容分支」APK（路线 B）。

目标设备（真机自检 331.jpg 实测）：
  Letv S50 Air / Android 4.3 / API 18 / armeabi-v7a,armeabi / 不识别 v2 签名

产物：
  shunbo/dist/Shunbo-Legacy-1.0.4-armv7a.apk
    minSdk 16 / targetSdk 22 / 仅 v1(JAR, SHA-1) 签名 / 仅 armeabi-v7a
    LEANBACK + LAUNCHER 双入口 / banner 320x180 / 明文 HTTP
    独立包名 com.shunbo.tv.legacy（不覆盖、不影响主程序 1.0.4）

内核：ijkplayer 0.8.8 官方 Maven 制品（LGPL-2.1），本地 third_party/*.aar，
      不从加固过的第三方 APK 里抠 so / dex。频道清单由
      tooling/gen_legacy_catalog.dart 从主程序 verified_channels.g.dart 生成。

用法：python legacy/build_legacy.py
"""
import datetime
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import zipfile
import zlib

ROOT = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(ROOT)
DIST = os.path.join(PROJECT, "dist")
THIRD = os.path.join(ROOT, "third_party")
EXTRACTED = os.path.join(THIRD, "extracted")
SRC = os.path.join(ROOT, "src", "com", "shunbo", "legacy")
RES = os.path.join(ROOT, "res")
ASSETS = os.path.join(ROOT, "assets")
# 默认 work；可用 SHUNBO_LEGACY_WORK 指定干净目录以绕开清理时的批量删除护栏。
WORK = os.path.join(ROOT, os.environ.get("SHUNBO_LEGACY_WORK", "work"))

SDK = "D:/Android/android-sdk"
BT = SDK + "/build-tools/35.0.0"
PLATFORM = SDK + "/platforms/android-35/android.jar"
JAVA = "D:/Android/openjdk/jdk-17.0.12/bin/java.exe"
JAVAC = "D:/Android/openjdk/jdk-17.0.12/bin/javac.exe"
KEYSTORE = "C:/Users/Administrator/.android/debug.keystore"
KS_PASS = "android"
KS_ALIAS = "androiddebugkey"

AAPT2 = BT + "/aapt2.exe"
ZIPALIGN = BT + "/zipalign.exe"
APKSIGNER = BT + "/lib/apksigner.jar"
D8 = BT + "/lib/d8.jar"

OUT_NAME = "Shunbo-Legacy-1.0.4-armv7a.apk"
OUT_PATH = os.path.join(DIST, OUT_NAME)
DART_POLICY = os.path.join(PROJECT, "lib", "platform", "version_compat.dart")
JAVA_POLICY = os.path.join(SRC, "LegacyVersionCompat.java")
MANIFEST = os.path.join(ROOT, "AndroidManifest.xml")
CATALOG = os.path.join(ASSETS, "channels.json")

JAVA_SOURCES = [
    os.path.join(SRC, n) for n in [
        "LegacyVersionCompat.java",
        "ChannelCatalog.java",
        "CrashReport.java",
        "Prefs.java",
        "Ui.java",
        "ControlBar.java",
        "ChannelPanel.java",
        "RegionPanel.java",
        "SettingsPanel.java",
        "BootReceiver.java",
        "SearchPanel.java",
        "PlaybackController.java",
        "LegacyPlayerActivity.java",
        "DeviceCapability.java",
        "Tuning.java",
        "StreamMemory.java",
    ]
]
# JAVA_SOURCES 只用来固定编译顺序。新增 .java 忘了登记时，症状是「源码在、
# dex 里没有」（本轮就踩到：DeviceCapability 未登记，编译期报找不到符号）。
# 这里把 SRC 下所有未登记的 .java 自动补到末尾，彻底消掉这个坑。
_REGISTERED = set(os.path.basename(p) for p in JAVA_SOURCES)
JAVA_SOURCES += [os.path.join(SRC, n) for n in sorted(os.listdir(SRC))
                 if n.endswith(".java") and n not in _REGISTERED]
IJK_JAVA_JAR = os.path.join(EXTRACTED, "ijkplayer-java-0.8.8-classes.jar")
IJK_ARM_JAR = os.path.join(EXTRACTED, "ijkplayer-armv7a-0.8.8-classes.jar")
SO_FILES = ["libijkffmpeg.so", "libijksdl.so", "libijkplayer.so"]

MIN_SDK = 16
TARGET_SDK = 22
MIN_SUPPORTED_API = 24   # 与 Dart / Java 版本兼容策略一致

# 编译用 android-35.jar，javac 不检查 API level，因此显式扫描 dex 里的
# framework 类引用。目标设备是 API 18，下面这些类都是 API 19+ 才出现的。
# ijkplayer-java 0.8.8 自带 AndroidMediaPlayer$MediaDataSourceProxy，引用
# API 23 的 MediaDataSource；兼容分支只实例化 IjkMediaPlayer，不碰该路径，
# Dalvik 按需加载不会触发。这里把它列为「已知且唯一允许」的残留引用，
# 一旦将来出现别的高版本类就构建失败，逼着人工复核而不是悄悄带上。
API19_PLUS_CLASSES = {
    "android/media/MediaDataSource",      # API 23
    "android/media/MediaTimestamp",       # API 23
    "android/media/AudioAttributes",      # API 21
    "android/media/MediaSession2",        # API 28
    "android/app/job/JobScheduler",       # API 21
    "android/app/usage/UsageStatsManager",  # API 21
    "android/telecom/TelecomManager",     # API 21
    "android/hardware/camera2/CameraManager",  # API 21
    "android/os/PersistableBundle",       # API 21
    "android/view/WindowInsets",          # API 20
    "android/notification/NotificationChannel",  # API 26
}
ALLOWED_API19_PLUS = {"android/media/MediaDataSource"}


def run(cmd, label):
    r = subprocess.run(cmd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if r.returncode != 0:
        sys.stderr.write("[FAIL] %s\nCMD: %s\nSTDOUT:\n%s\nSTDERR:\n%s\n" % (
            label, " ".join(str(x) for x in cmd),
            (r.stdout or "")[-4000:], (r.stderr or "")[-4000:]))
        raise SystemExit(1)
    return r.stdout or ""


def make_png(path, w, h, base, span):
    """生成纯色渐变 PNG（不依赖 PIL），用于 TV banner 与启动图标。"""
    def chunk(t, data):
        body = t + data
        return struct.pack(">I", len(data)) + body + \
               struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    raw = bytearray()
    for y in range(h):
        raw.append(0)
        k = float(y) / max(1, h - 1)
        r = base[0] + int(span[0] * k)
        g = base[1] + int(span[1] * k)
        b = base[2] + int(span[2] * k)
        raw.extend(bytes([r & 0xFF, g & 0xFF, b & 0xFF]) * w)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def collect_classes(directory):
    out = []
    for base, _dirs, files in os.walk(directory):
        for f in files:
            if f.endswith(".class"):
                out.append(os.path.join(base, f))
    return sorted(out)


def branch_of(api, probe_ok):
    """构建期自检表：与 Dart / Java 判定逐项对齐（不参与打包）。"""
    if not probe_ok or api is None or not (1 <= api <= 1000):
        return "legacyCompat"
    return "legacyCompat" if api < MIN_SUPPORTED_API else "defaultFlow"


def main():
    required = [AAPT2, ZIPALIGN, APKSIGNER, D8, PLATFORM, JAVAC, JAVA,
                KEYSTORE, CATALOG, IJK_JAVA_JAR, IJK_ARM_JAR, MANIFEST,
                DART_POLICY, JAVA_POLICY]
    required += [os.path.join(THIRD, "ijkplayer-java-0.8.8.aar"),
                 os.path.join(THIRD, "ijkplayer-armv7a-0.8.8.aar"),
                 os.path.join(THIRD, "ijkplayer-java-0.8.8.pom"),
                 os.path.join(THIRD, "ijkplayer-armv7a-0.8.8.pom")]
    required += [os.path.join(EXTRACTED, s) for s in SO_FILES]
    required += JAVA_SOURCES
    missing = [p for p in required if not os.path.exists(p)]
    if missing:
        sys.stderr.write("[FAIL] 缺少输入文件：\n  " + "\n  ".join(missing) + "\n")
        raise SystemExit(1)

    if os.path.isdir(WORK):
        shutil.rmtree(WORK)
    os.makedirs(WORK)
    os.makedirs(os.path.join(RES, "drawable-nodpi"), exist_ok=True)
    os.makedirs(DIST, exist_ok=True)
    # 重建会覆盖同名产物。上一版很可能正是真机验证过的那只包，
    # 直接覆盖就等于把用户手上唯一能回退的文件丢了（本轮真踩过）。
    # 归档到 dist/_prev/ 带内容哈希，同名不同内容不会互相覆盖。
    if os.path.isfile(OUT_PATH):
        prev_dir = os.path.join(DIST, "_prev")
        os.makedirs(prev_dir, exist_ok=True)
        prev_sha = sha256(OUT_PATH)
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        prev_name = "%s.%s.%s.apk.bak" % (
            os.path.splitext(OUT_NAME)[0], stamp, prev_sha[:8])
        shutil.move(OUT_PATH, os.path.join(prev_dir, prev_name))
        print("   归档上一版产物 -> dist/_prev/%s (sha256=%s…)" % (prev_name, prev_sha[:8]))
    make_png(os.path.join(RES, "drawable-nodpi", "banner.png"),
             320, 180, (16, 35, 63), (18, 48, 72))
    make_png(os.path.join(RES, "drawable-nodpi", "ic_launcher.png"),
             96, 96, (16, 35, 63), (30, 80, 120))

    # ---- 资源编译 ----
    res_zip = os.path.join(WORK, "res.zip")
    run([AAPT2, "compile", "--dir", RES, "-o", res_zip], "aapt2 compile")

    # ---- 清单链接 ----
    base_apk = os.path.join(WORK, "base.apk")
    run([AAPT2, "link", "-o", base_apk, "-I", PLATFORM,
         "--manifest", MANIFEST,
         "--min-sdk-version", str(MIN_SDK),
         "--target-sdk-version", str(TARGET_SDK),
         "--version-code", "5", "--version-name", "1.0.4",
         res_zip, "--auto-add-overlay"], "aapt2 link")

    # ---- Java 编译（Java 8 语法 + android.jar，不用任何 API 23+ 接口）----
    classes_dir = os.path.join(WORK, "classes")
    os.makedirs(classes_dir)
    cp = os.pathsep.join([PLATFORM, IJK_JAVA_JAR, IJK_ARM_JAR])
    run([JAVAC, "--release", "8", "-encoding", "UTF-8",
         "-classpath", cp, "-d", classes_dir] + JAVA_SOURCES, "javac")

    # ---- dex（含 ijkplayer Java 层）----
    dex_dir = os.path.join(WORK, "dex")
    os.makedirs(dex_dir)
    d8_inputs = collect_classes(classes_dir) + [IJK_JAVA_JAR, IJK_ARM_JAR]
    run([JAVA, "-cp", D8, "com.android.tools.r8.D8",
         "--lib", PLATFORM, "--min-api", str(MIN_SDK),
         "--output", dex_dir] + d8_inputs, "d8")
    dex_data = open(os.path.join(dex_dir, "classes.dex"), "rb").read()

    # ---- 组装 APK ----
    unsigned = os.path.join(WORK, "unsigned.apk")

    def fixed_info(name, stored):
        # 固定 ZIP 时间戳，让同一份输入产出字节一致的 APK（可复现构建），
        # 这样 build_report.json 里的 sha256 才是可靠的护栏而不是每次都变。
        info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_STORED if stored else zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        return info

    with zipfile.ZipFile(base_apk) as zin, \
         zipfile.ZipFile(unsigned, "w", zipfile.ZIP_DEFLATED) as zout:
        for info in zin.infolist():
            # aapt2 输出的时间戳也归一，否则每次 link 都会换一批字节。
            clone = zipfile.ZipInfo(info.filename,
                                   date_time=(1980, 1, 1, 0, 0, 0))
            clone.compress_type = info.compress_type
            clone.external_attr = info.external_attr
            zout.writestr(clone, zin.read(info.filename))
        zout.writestr(fixed_info("classes.dex", False), dex_data)
        # native libs 必须 stored：zipalign 才能 4 字节对齐，
        # API 18 上系统可直接 mmap，避免再解压一份。
        for so in SO_FILES:
            zout.writestr(fixed_info("lib/armeabi-v7a/" + so, True),
                          open(os.path.join(EXTRACTED, so), "rb").read())
        zout.writestr(fixed_info("assets/channels.json", False),
                      open(CATALOG, "rb").read())

    aligned = os.path.join(WORK, "aligned.apk")
    run([ZIPALIGN, "-f", "4", unsigned, aligned], "zipalign")

    # ---- 仅 v1(SHA-1) 签名：API 18 不识别 v2；minSdk 16 让 apksigner
    #      选 SHA-1 摘要（API 16/17 不认 SHA-256 v1 摘要）。----
    run([JAVA, "-jar", APKSIGNER, "sign",
         "--ks", KEYSTORE,
         "--ks-pass", "pass:" + KS_PASS,
         "--key-pass", "pass:" + KS_PASS,
         "--ks-key-alias", KS_ALIAS,
         "--min-sdk-version", str(MIN_SDK),
         "--max-sdk-version", "36",
         "--v1-signing-enabled", "true",
         "--v2-signing-enabled", "false",
         "--v3-signing-enabled", "false",
         "--out", OUT_PATH, aligned], "apksigner sign")

    # ---- 断言 ----
    badging = run([AAPT2, "dump", "badging", OUT_PATH], "aapt2 badging")
    verify16 = run([JAVA, "-jar", APKSIGNER, "verify",
                    "--min-sdk-version", "16", "--verbose", OUT_PATH], "verify@16")
    verify18 = run([JAVA, "-jar", APKSIGNER, "verify",
                    "--min-sdk-version", "18", "--verbose", OUT_PATH], "verify@18")

    with zipfile.ZipFile(OUT_PATH) as z:
        names = z.namelist()
        mf = z.read("META-INF/MANIFEST.MF").decode("utf-8", "replace")
        dex = z.read("classes.dex")
        catalog_bytes = z.read("assets/channels.json")
        arsc = z.getinfo("resources.arsc")
        so_entries = [n for n in names if n.startswith("lib/") and n.endswith(".so")]
        abis = sorted(set(n.split("/")[1] for n in so_entries))
        so_stored = all(z.getinfo(n).compress_type == zipfile.ZIP_STORED
                        for n in so_entries)
    catalog_json = json.loads(catalog_bytes.decode("utf-8"))
    manifest_text = open(MANIFEST, encoding="utf-8").read()
    dart = open(DART_POLICY, encoding="utf-8").read()
    java_policy = open(JAVA_POLICY, encoding="utf-8").read()
    pom = open(os.path.join(THIRD, "ijkplayer-java-0.8.8.pom"),
               encoding="utf-8").read()

    with open(OUT_PATH, "rb") as f:
        f.seek(-22, 2)
        eocd = f.read(22)
    zip_entries = struct.unpack("<H", eocd[10:12])[0]

    dex_classes = set(m.decode("ascii") for m in
                      re.findall(rb"L(android/[A-Za-z0-9_/\$]+);", dex))
    high_api_refs = sorted(dex_classes & API19_PLUS_CLASSES)

    # ---- 启动入口可解析性（上一版真机闪退的根因护栏）----
    # aapt2 badging 给出的是系统实际去 ClassLoader.loadClass 的全限定名；
    # 相对名 ".XxxActivity" 会被拼上 manifest package，与 Java 源码包不一致时
    # 安装能过、一点开就 ClassNotFoundException。这里反查 dex 描述符锁死。
    launch_match = re.search(r"(?m)^launchable-activity: name='([^']+)'", badging)
    leanback_match = re.search(
        r"(?m)^leanback-launchable-activity: name='([^']+)'", badging)
    launch_name = launch_match.group(1) if launch_match else ""
    leanback_name = leanback_match.group(1) if leanback_match else ""
    launch_descriptor = ("L" + launch_name.replace(".", "/") + ";").encode("ascii")
    activity_src = open(os.path.join(SRC, "LegacyPlayerActivity.java"),
                        encoding="utf-8").read()
    playback_src = open(os.path.join(SRC, "PlaybackController.java"),
                        encoding="utf-8").read()
    crash_src = open(os.path.join(SRC, "CrashReport.java"),
                     encoding="utf-8").read()
    prefs_src = open(os.path.join(SRC, "Prefs.java"), encoding="utf-8").read()
    ui_src = open(os.path.join(SRC, "Ui.java"), encoding="utf-8").read()
    bar_src = open(os.path.join(SRC, "ControlBar.java"), encoding="utf-8").read()
    panel_src = open(os.path.join(SRC, "ChannelPanel.java"), encoding="utf-8").read()
    search_src = open(os.path.join(SRC, "SearchPanel.java"), encoding="utf-8").read()
    catalog_src = open(os.path.join(SRC, "ChannelCatalog.java"),
                       encoding="utf-8").read()
    ledger_path = os.path.join(ASSETS, "probe_ledger.json")
    ledger = (json.load(open(ledger_path, encoding="utf-8"))
              if os.path.exists(ledger_path) else {})

    checks = {
        "sign verifies @16": "Verifies" in verify16 and "DOES NOT VERIFY" not in verify16,
        "sign verifies @18": "Verifies" in verify18 and "DOES NOT VERIFY" not in verify18,
        "v1 true": "v1 scheme (JAR signing): true" in verify16,
        "v2 false": "v2 scheme (APK Signature Scheme v2): false" in verify16,
        "v1 uses SHA-1 digest": "SHA1-Digest" in mf,
        "MANIFEST.MF present": "META-INF/MANIFEST.MF" in names,
        "minSdk 16": "minSdkVersion:'16'" in badging,
        "targetSdk 22": "targetSdkVersion:'22'" in badging,
        "versionName 1.0.4": "versionName='1.0.4'" in badging,
        "versionCode 5": "versionCode='5'" in badging,
        "independent package": "name='com.shunbo.tv.legacy'" in badging,
        "3 native libs": len(so_entries) == len(SO_FILES),
        "only armeabi-v7a": abis == ["armeabi-v7a"],
        "native libs stored": so_stored,
        "resources.arsc stored": arsc.compress_type == zipfile.ZIP_STORED,
        "no ZIP64 / <65535 entries": zip_entries < 65535 and eocd[:4] == b"PK\x05\x06",
        "our activity in dex": b"Lcom/shunbo/legacy/LegacyPlayerActivity;" in dex,
        "version compat in dex": b"Lcom/shunbo/legacy/LegacyVersionCompat;" in dex,
        "ijkplayer in dex": b"Ltv/danmaku/ijk/media/player/IjkMediaPlayer;" in dex,
        "catalog asset present": "assets/channels.json" in names,
        "catalog format": catalog_json.get("format") == "shunbo-legacy-catalog/1",
        "catalog counts match": (catalog_json.get("channelCount") ==
                                 len(catalog_json.get("channels", [])) and
                                 catalog_json.get("streamCount") ==
                                 sum(len(c["streams"]) for c in catalog_json["channels"])),
        "catalog all http(s) m3u8": all(
            s["url"].startswith("http://") or s["url"].startswith("https://")
            for c in catalog_json["channels"] for s in c["streams"]),
        "manifest leanback": 'android.software.leanback' in manifest_text
                             and 'LEANBACK_LAUNCHER' in manifest_text,
        "manifest launcher": 'android.intent.category.LAUNCHER' in manifest_text,
        "manifest no touchscreen required": 'android.hardware.touchscreen' in manifest_text
                                            and 'android:required="false"' in manifest_text,
        "manifest banner": 'android:banner="@drawable/banner"' in manifest_text,
        "manifest INTERNET": 'android.permission.INTERNET' in manifest_text,
        "Dart threshold 24": "kMinSupportedAndroidApi = 24" in dart,
        "Java threshold 24": "MIN_SUPPORTED_API = 24" in java_policy,
        "Dart strict lower-than": "compareToThreshold(parsed) < 0" in dart,
        "Java strict lower-than": "compareToThreshold(parsed.intValue()) < 0" in java_policy,
        "Dart fail-safe": "CompatReason.probeFailed" in dart
                          and "RuntimeBranch.legacyCompat" in dart,
        "Java fail-safe": "Reason.PROBE_FAILED" in java_policy
                          and "Branch.LEGACY_COMPAT" in java_policy,
        "release never compared": "仅展示" in dart and "绝不参与比较" in java_policy,
        "LGPL source declared": "LGPL-2.1" in pom and "ijkplayer" in pom,
        # API 18 设备：dex 里不能出现未复核的 API 19+ framework 类。
        "no unexpected API19+ refs": set(high_api_refs) <= ALLOWED_API19_PLUS,
        # ---- 启动入口可解析性（真机闪退根因护栏，必须逐条保留）----
        "launchable activity resolves to dex class":
            bool(launch_name) and launch_descriptor in dex,
        "leanback launchable resolves to same class":
            bool(leanback_name) and leanback_name == launch_name
            and leanback_name.replace(".", "/") in launch_descriptor.decode("ascii"),
        "manifest activity uses fully-qualified name":
            'android:name="com.shunbo.legacy.LegacyPlayerActivity"' in manifest_text
            and 'android:name=".LegacyPlayerActivity"' not in manifest_text,
        "crash reporter in dex": b"Lcom/shunbo/legacy/CrashReport;" in dex,
        "crash reporter installed before super.onCreate":
            "CrashReport.install(this);" in activity_src
            and activity_src.index("CrashReport.install(this);")
                < activity_src.index("super.onCreate(savedInstanceState);"),
        "onCreate catches Throwable with fatal screen":
            "catch (Throwable t)" in activity_src
            and "showFatal(t)" in activity_src
            and "CrashReport.record(this, \"onCreate\", t)" in activity_src,
        "fatal state intercepts key events":
            "if (fatal)" in activity_src and "showFatalLast()" in activity_src,
        "native load failure carries real cause":
            "nativeLibraryError" in activity_src
            and "return t.getClass().getName()" in playback_src,
        "crash reporter writes private file only":
            "openFileOutput" in crash_src and "deleteFile" in crash_src
            and "getExternalStorage" not in crash_src,
    }

    # ---- 遥控器交互 / 收藏 / 检索 / 台账（本轮新增，逐条锁死）----
    all_channels = catalog_json["channels"]
    pinyin_ok = all(c.get("pyi") for c in all_channels)
    probe_known = all("probeOk" in s for c in all_channels for s in c["streams"])
    # 每条台内：一旦出现 probeOk=false，后面不允许再出现 probeOk=true
    alive_first = True
    for c in all_channels:
        seen_dead = False
        for st in c["streams"]:
            if st.get("probeOk") is False:
                seen_dead = True
            elif seen_dead and st.get("probeOk") is True:
                alive_first = False
    dead_channels_kept = all(len(c["streams"]) > 0 for c in all_channels)
    # 台账由 probe_legacy_streams.dart 直接从**当前清单**逐条探测，因此明文
    # 镜像线路也在台账里；只有 collect_extra_streams.dart 后补的扩展线路另由
    # extra_streams.json 自证，不在台账覆盖范围内。台账只与「非扩展线路」
    # 逐条对齐，扩展线路数量由清单自己的 extraStreamCount 声明锁住。
    mirror_streams = [s for c in all_channels for s in c["streams"]
                      if s.get("mirror") is True]
    extra_streams = [s for c in all_channels for s in c["streams"]
                     if s.get("extra") is True]
    base_stream_count = sum(len(c["streams"]) for c in all_channels) - len(extra_streams)
    suzhou = [c for c in all_channels if c.get("city") == "苏州"]
    suzhou_plain = all(
        any(not s.get("https") for s in c["streams"]) for c in suzhou)

    checks.update({
        "plaintext mirrors declared": (
            catalog_json.get("plaintextMirrorCount") == len(mirror_streams)
            and all(s["url"].startswith("http://") for s in mirror_streams)
            and all("probeOk" in s for s in mirror_streams)),
        "Suzhou local channels all have plaintext fallback": (
            len(suzhou) >= 7 and suzhou_plain),
        "interaction classes in dex": all(
            ("Lcom/shunbo/legacy/%s;" % n).encode("ascii") in dex
            for n in ["Prefs", "Ui", "ControlBar", "ChannelPanel", "SearchPanel"]),
        "control bar navigable": "void move(int delta)" in bar_src
                                 and "void activate()" in bar_src
                                 and "Ui.styleButton" in bar_src,
        # 2026-11-09：自动隐藏改成设置项驱动，且控制条 / 频道栏 / 地区 /
        # 检索共用同一个计时器。判据必须锁「动态字段 + 统一计时 + 按键重置」。
        "control bar auto hides": "idleHideMs = prefs.panelIdleMs()" in activity_src
                                  and "scheduleControlHide" in activity_src
                                  and "ui.postDelayed(controlHideTask, idleHideMs)"
                                      in activity_src
                                  and "private void resetOverlayHide()" in activity_src,
        "focus ring visible": "FOCUS = 0xFF1E88E5" in ui_src
                              and "rect(c, FOCUS" in ui_src
                              and "styleRow(context, row" in panel_src,
        "panel groups dynamic": "GROUP_FAV" in panel_src and "shortGroup" in panel_src
                                and "groups.add(new String[]{g" in panel_src,
        # 列表内 OK 永远只切台：↑ 仍可循环环绕，但 ↓ 走到末行不再误聚焦底部
        # 「切换地区」卡片（那是「选频道却弹省市台面板」的根源）；地区切换改走
        # 绿键 / 控制条「地区」/ 设置菜单里的「地区切换」，底部卡片只作信息展示。
        "panel focus wraps": "focus = (focus - 1 + filtered.size()) % filtered.size()"
                             in panel_src
                             and "if (focus < filtered.size() - 1) focus++" in panel_src
                             and "onRegionFromSettings" in activity_src,
        "favorites persisted": 'K_FAV = "favorites"' in prefs_src
                               and "putStringSet" in prefs_src,
        "last watched persisted": 'K_LAST_NUM = "last_channel_num"' in prefs_src
                                  and "K_LAST_STREAM" in prefs_src
                                  and "preferredChannelIndex" in activity_src,
        "resume last stream index": "prefs.lastStream()" in activity_src
                                    and "open(currentChannel(), startStream)"
                                        in activity_src,
        "zap coalesced": "zapCommitMs = prefs.zapCommitMs()" in activity_src
                         and "zapCommitTask" in activity_src
                         and "ui.removeCallbacks(zapCommitTask)" in activity_src
                         and "ui.postDelayed(zapCommitTask, zapCommitMs)"
                             in activity_src,
        "number direct entry overlay": "appendNumber" in activity_src
                                       and "numberPanel" in activity_src
                                       and "numberCommitMs = prefs.numberCommitMs()"
                                           in activity_src
                                       and "ui.postDelayed(numberCommitTask, numberCommitMs)"
                                           in activity_src,
        "search pinyin match": "pyi.startsWith(q)" in search_src
                               and "py.startsWith(q)" in search_src
                               and "score(c, q)" in search_src,
        "search keyboard 26 letters": "".join(
            ["ABCDEFG", "HIJKLMN", "OPQRSTU", "VWXYZ"]) ==
            "".join(re.findall(r'"([A-Z]+)"', search_src.split("KEY_ROWS")[1]
                               .split("};")[0])),
        "panel hidden falls back to play": "!channelPanel.isVisible()" in activity_src,
        # 只看真实 import：注释里提到 RecyclerView / Leanback 是在解释「刻意不用它」，
        # 扫全文会把说明文字当成依赖，这类误判会逼着人删掉有用的注释。
        "no support/leanback dependency": all(
            not re.search(r"(?m)^import\s+(android\.support|androidx\.|.*leanback)",
                          src)
            for src in [activity_src, panel_src, search_src, bar_src, ui_src]),
        "prefs stay in private storage": "getSharedPreferences" in prefs_src
                                         and "getExternalStorage" not in prefs_src,
        # 按键覆盖：电视遥控器上实际存在的那几个键
        "remote keys covered": all(
            k in activity_src for k in [
                "KEYCODE_DPAD_UP", "KEYCODE_DPAD_DOWN",
                "KEYCODE_DPAD_LEFT", "KEYCODE_DPAD_RIGHT",
                "KEYCODE_DPAD_CENTER", "KEYCODE_BACK", "KEYCODE_MENU",
                "KEYCODE_CHANNEL_UP", "KEYCODE_CHANNEL_DOWN",
                "KEYCODE_MEDIA_PLAY_PAUSE", "KEYCODE_STAR", "KEYCODE_PROG_RED",
                "KEYCODE_SEARCH",
            ]),
        # 清单 / 台账
        "catalog pinyin coverage": pinyin_ok,
        "catalog probe coverage": probe_known,
        "catalog alive streams first": alive_first,
        "all-dead channels kept": dead_channels_kept,
        "ledger present": ledger.get("format") == "shunbo-legacy-probe/1",
        "ledger matches catalog": (ledger.get("streamCount") == base_stream_count
                                   and catalog_json["streamCount"] ==
                                   base_stream_count + len(extra_streams)
                                   and catalog_json.get("extraStreamCount") ==
                                   len(extra_streams)
                                   and all(s.get("extra") is True
                                           and s.get("probeOk") is True
                                           and "quality" in s
                                           for s in extra_streams)),
        "catalog probeAt from ledger": (catalog_json.get("probeAt") or "") ==
                                       (ledger.get("probedAt") or "NO_LEDGER"),
    })

    # 分支场景表：把 Dart / Java 的判定语义在构建期逐点复核。
    cases = [
        ("API 18 真机", 18, True, "legacyCompat"),
        ("API 23 边界", 23, True, "legacyCompat"),
        ("API 24 边界", 24, True, "defaultFlow"),
        ("API 25", 25, True, "defaultFlow"),
        ("API 36", 36, True, "defaultFlow"),
        ("缺失", None, True, "legacyCompat"),
        ("探测失败", 30, False, "legacyCompat"),
        ("非法值", 1001, True, "legacyCompat"),
    ]
    for label, api, ok, expected in cases:
        checks["branch: " + label] = branch_of(api, ok) == expected

    print("== %s ==" % OUT_NAME)
    print("   size=%d  sha256=%s" % (os.path.getsize(OUT_PATH), sha256(OUT_PATH)))
    print("   channels=%d streams=%d dex=%dB entries=%d" % (
        catalog_json["channelCount"], catalog_json["streamCount"],
        len(dex), zip_entries))
    failed = [k for k, v in checks.items() if not v]
    for k, ok in checks.items():
        print("   [%s] %s" % ("OK" if ok else "FAIL", k))

    report = {
        "apk": OUT_NAME,
        "path": OUT_PATH.replace("\\", "/"),
        "size": os.path.getsize(OUT_PATH),
        "sha256": sha256(OUT_PATH),
        "minSdk": MIN_SDK, "targetSdk": TARGET_SDK,
        "versionName": "1.0.4", "versionCode": 5,
        "package": "com.shunbo.tv.legacy",
        "launchableActivity": launch_name,
        "leanbackLaunchableActivity": leanback_name,
        "signature": "v1-only (JAR, SHA-1 digest)",
        "abis": abis,
        "nativeLibs": so_entries,
        "channelCount": catalog_json["channelCount"],
        "streamCount": catalog_json["streamCount"],
        "verifiedAt": catalog_json["verifiedAt"],
        "probeAt": catalog_json.get("probeAt", ""),
        "probeReachableStreams": sum(
            1 for c in catalog_json["channels"] for s2 in c["streams"]
            if s2.get("probeOk") is True),
        "probeDeadStreams": sum(
            1 for c in catalog_json["channels"] for s2 in c["streams"]
            if s2.get("probeOk") is False),
        "channelsWithReachable": sum(1 for c in catalog_json["channels"]
                                     if c.get("reachable", 0) > 0),
        "httpsStreams": sum(1 for c in catalog_json["channels"]
                            for s in c["streams"] if s.get("https")),
        "dexBytes": len(dex),
        "zipEntries": zip_entries,
        "highApiClassRefs": high_api_refs,
        "highApiNote": "ijkplayer-java 0.8.8 的 AndroidMediaPlayer$MediaDataSourceProxy "
                       "引用 API 23 的 MediaDataSource；兼容分支只实例化 "
                       "IjkMediaPlayer，不触碰该路径，Dalvik 按需加载。",
        "checks": checks,
        "verify16": verify16.strip().splitlines()[:8],
        "branchScenarios": [
            {"label": l, "api": a, "probeOk": o, "expected": e,
             "actual": branch_of(a, o)} for l, a, o, e in cases
        ],
    }
    with open(os.path.join(ROOT, "build_report.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)

    if failed:
        sys.stderr.write("[FAIL] %d 条断言未通过: %s\n" % (len(failed), ", ".join(failed)))
        raise SystemExit(1)
    print("\n全部 %d 条断言通过，报告: legacy/build_report.json" % len(checks))


if __name__ == "__main__":
    main()
