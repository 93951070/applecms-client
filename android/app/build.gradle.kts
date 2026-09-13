plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 是否打包 32 位 armeabi-v7a；由 android/gradle.properties 的
// echotv.packArmeabiV7a 控制，默认关闭以缩小安装包，后期可随时开启。
val packArmeabiV7a = (project.findProperty("echotv.packArmeabiV7a") as String?)?.toBoolean() ?: false

android {
    namespace = "com.hoowhoami.echotv"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.hoowhoami.echotv"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        jniLibs {
            // 压缩原生库以缩小 APK，安装时解压（安装后占用空间基本不变）
            useLegacyPackaging = true
            // 关闭 32 位打包时移除非 arm64-v8a 的原生库。
            // Flutter 注入的 .so 不受 abiFilters 影响，需在此按路径排除。
            if (!packArmeabiV7a) {
                excludes += setOf(
                    "lib/armeabi-v7a/**",
                    "lib/armeabi/**",
                    "lib/x86/**",
                    "lib/x86_64/**",
                )
            }
        }
    }

    signingConfigs {
        create("release") {
            // 固定签名，保证应用内覆盖升级成功。可通过环境变量覆盖以便轮换。
            storeFile = file(System.getenv("ANDROID_KEYSTORE_PATH") ?: "echotv-release.p12")
            storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: "echotv2026"
            keyAlias = System.getenv("ANDROID_KEY_ALIAS") ?: "echotv"
            keyPassword = System.getenv("ANDROID_KEY_PASSWORD") ?: "echotv2026"
            storeType = "PKCS12"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            // R8 代码裁剪 + 资源压缩；反射入口由 proguard-rules.pro 保留。
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}
