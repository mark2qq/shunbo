plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.shunbo.shunbo"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 应用标识按《安卓端形态与安装包要求》打包矩阵定稿：
        //   完整版 com.shunbo.tv      精简版 com.shunbo.tv.lite（applicationIdSuffix）
        // 标识一旦定稿不再变更——变了就是「另一个应用」，同机升级会变成并存两份数据。
        applicationId = "com.shunbo.tv"
        // minSdk 说明（R9 要求完整版 21、精简版 19，此处无法照做，原因必须写清）：
        // 1) Flutter 3.47 的 Gradle 插件对 minSdk < 23 的变体**直接抛异常**
        //    （DependencyVersionChecker.errorMinSdkVersion = 23）；
        // 2) 更硬的下限来自引擎：flutter_embedding 的 AAR 自身声明 minSdk 24，
        //    清单合并取最大值 —— 实测 aapt2 badging 输出 minSdkVersion:'24'。
        //    写 23 只会被静默抬成 24，让人误以为支持 Android 6.0。
        // 因此两个渠道统一 24（Android 7.0）。要回到 19/21 必须降级 Flutter 并自建
        // 播放内核，属独立任务，已在交付说明中列为已知偏差。
        // 显式写死而不沿用 flutter.minSdkVersion：后者的默认值会随 SDK 升级变化，
        // 「同一个版本号打出不同适配范围」对侧载分发是事故。
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 渠道维度（R8/R9）：两个包只在「应用标识 / ABI」上不同，
    // 业务代码、协议层、解析、调度、换源状态机全部共用同一份（R5/R6 的物理保证）。
    flavorDimensions += "channel"

    productFlavors {
        create("full") {
            dimension = "channel"
            // 主力包：手机 + 电视（arm64-v8a + armeabi-v7a）。
            //
            // ABI **不在**这里用 ndk.abiFilters 约束：Flutter 的 Gradle 插件会按
            // `-Ptarget-platform` 覆盖该字段（实测在 gradle 里写死双架构，
            // 打出来的包仍带 x86_64、体积 55 MB）。ABI 由打包脚本
            // `tooling/build_android_apks.sh` 的 --target-platform 决定，
            // 并由 `verify_android_form` 校验该脚本，避免「以为限了架构其实没限」。
        }
        create("lite") {
            dimension = "channel"
            // 精简版：与完整版可同机并存，数据互不影响（各自的 applicationId
            // 决定了独立的 files 目录与独立的偏好命名空间）。
            applicationIdSuffix = ".lite"
            // 电视盒子以 armeabi-v7a 为主，只出 v7a（见打包脚本）。
        }
    }

    // 电视端安装兼容（1.0.0）：参考实现（可在乐视 EUI 8.0 上安装并使用）采用
    // v1(JAR) + v2 双签名，实测本项目 0.1.0 产物为 **仅 v2**：
    //   apksigner verify --verbose            → v1: false, v2: true
    //   apksigner verify --min-sdk-version 22 → DOES NOT VERIFY / Missing META-INF/MANIFEST.MF
    // 原因是 AGP 9 在 minSdk >= 24 时默认关闭 v1。但国产老电视 / 定制 ROM 的包
    // 解析器在**解析阶段**仍会读 META-INF/MANIFEST.MF，找不到就抛统一的
    // 「解析程序包时出现问题」（INSTALL_PARSE_FAILED_NO_CERTIFICATES）。
    //
    // 这里显式双签：v1 给旧解析器，v2 给 API 24+ 的完整校验；**证书仍用原来的
    // debug.keystore**，签名身份不变 → 0.1.0 可覆盖升级到 1.0.0，也能反向回退，
    // 不引入新 keystore、不改变任何运行期行为。
    // 注意：不能只靠改 minSdk 数字来兼容更老系统，原因见上面 defaultConfig 的说明。
    signingConfigs {
        getByName("debug") {
            enableV1Signing = true
            enableV2Signing = true
        }
    }

    buildTypes {
        release {
            // 侧载分发（U 盘 / 应用市场本地安装），暂用 debug 签名。
            // 正式发布前必须换成独立的 release keystore —— 同一渠道内升级必须用
            // 同一签名，否则系统判定为不同应用、拒绝覆盖安装（R8）。
            // 1.0.0 兼容版刻意**不换证书**：换证书会让「版本回退」变成先卸载再装。
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    // R9「超出 60 MB 时优先裁剪非必要语言资源与字体，不裁剪内核能力」：
    // 本应用只有中英文界面，其余语言资源全部裁掉。
    // AGP 9 起 `resourceConfigurations` 已被 `androidResources.localeFilters` 取代，
    // 旧字段在新 DSL 下会直接编译失败。
    androidResources {
        localeFilters += listOf("zh", "en")
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // E3 平台通道回退后端：libmpv 缺失时的 ExoPlayer。
    // 选 media3 而不是 android.media.MediaPlayer 的原因：HLS(m3u8) 与自定义请求头
    // 在 MediaPlayer 上机型差异极大，而流媒体源这两个能力是刚需。
    implementation("androidx.media3:media3-exoplayer:1.5.1")
    implementation("androidx.media3:media3-exoplayer-hls:1.5.1")
}

flutter {
    source = "../.."
}
