import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.arcade.clipboard"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    sourceSets {
        getByName("main") {
            java.srcDir("../../../../platform/android/src/main/kotlin")
            res.srcDir("../../../../platform/android/src/main/res")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.arcade.clipboard"
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // The release key comes from CI secrets (ARCADE_ANDROID_KEYSTORE, a
    // base64 keystore decoded to a file, plus its passwords and alias) or a
    // local, untracked android/key.properties. Without one, release builds are
    // left unsigned; only debug builds use the debug key.
    val keyProperties = Properties().apply {
        val file = rootProject.file("key.properties")
        if (file.isFile) file.inputStream().use { load(it) }
    }
    fun releaseKey(property: String, variable: String): String? =
        System.getenv(variable)?.takeIf { it.isNotEmpty() } ?: keyProperties.getProperty(property)
    val releaseStore = releaseKey("storeFile", "ARCADE_ANDROID_KEYSTORE_FILE")
    signingConfigs {
        if (releaseStore != null) {
            create("release") {
                storeFile = file(releaseStore)
                storePassword = releaseKey("storePassword", "ARCADE_ANDROID_KEYSTORE_PASSWORD")
                keyAlias = releaseKey("keyAlias", "ARCADE_ANDROID_KEY_ALIAS")
                keyPassword = releaseKey("keyPassword", "ARCADE_ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
