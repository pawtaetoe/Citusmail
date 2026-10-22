import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.fluminaris.citusmail"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Needed by flutter_local_notifications on older Android versions.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.fluminaris.citusmail"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Release signing: from android/key.properties (never committed) or,
    // in CI, from environment variables filled from repository secrets.
    val keyProperties = Properties().apply {
        val file = rootProject.file("key.properties")
        if (file.exists()) file.inputStream().use { load(it) }
    }
    fun signing(name: String, env: String): String? =
        keyProperties.getProperty(name) ?: System.getenv(env)
    val storePath = signing("storeFile", "FMAIL_KEYSTORE_PATH")

    signingConfigs {
        if (storePath != null) {
            create("release") {
                storeFile = file(storePath)
                storePassword = signing("storePassword", "FMAIL_KEYSTORE_PASSWORD")
                keyAlias = signing("keyAlias", "FMAIL_KEY_ALIAS")
                keyPassword = signing("keyPassword", "FMAIL_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Without a release key, release builds are signed with the
            // debug key and marked as such: fine for trying locally, never
            // for distribution (CI's release job requires the key).
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = if (storePath != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    // Periodic background checks (reviewed: Google's AndroidX WorkManager).
    implementation("androidx.work:work-runtime:2.10.1")
    implementation("androidx.concurrent:concurrent-futures:1.2.0")
    // Java library backports for older Android (Google).
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
