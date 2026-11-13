import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.quarklite.quarklite"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.quarklite.quarklite"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                // 加固：缺少 key.properties 时原本静默退回 debug 签名，
                // 会让误打的发布包与正式包签名不同（用户无法覆盖安装）却毫无提示。
                // 现在显式告警，并支持 -Pquarklite.requireReleaseSigning 直接失败
                // （CI 用它兜底，另在构建后校验 APK 签名者）。
                val strict = (findProperty("quarklite.requireReleaseSigning")?.toString() == "true")
                if (strict) {
                    throw GradleException(
                        "release 构建缺少 android/key.properties，拒绝以 debug 签名出包。" +
                            "本地自测请改用 --debug，或按 docs/operations.md 配置签名材料。"
                    )
                }
                logger.warn(
                    "Quarklite: android/key.properties 不存在，release 将使用 DEBUG 签名——" +
                        "该包不可对外发布（与正式包签名不同，用户无法覆盖安装）。"
                )
                signingConfigs.getByName("debug")
            }
        }
    }

    packagingOptions {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

dependencies {
    implementation(files("libs/libgopeed.aar"))
    implementation("androidx.core:core:1.17.0")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
