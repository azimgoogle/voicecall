import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}

// Load signing credentials from key.properties (never committed to source control).
val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties()
if (keyPropertiesFile.exists()) {
    keyProperties.load(FileInputStream(keyPropertiesFile))
}

android {
    namespace = "com.zunova.nestcall"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.zunova.nestcall"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // ── Flavors ───────────────────────────────────────────────────────────────
    // Run with:  flutter run --flavor dev
    //            flutter run --flavor prod
    //            flutter build apk --flavor prod
    //
    // google-services.json per flavor:
    //   android/app/src/dev/google-services.json   (app ID: ...nestcall.dev)
    //   android/app/src/prod/google-services.json  (app ID: ...nestcall)
    flavorDimensions += "environment"
    productFlavors {
        create("dev") {
            dimension = "environment"
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            // App label is overridden in src/dev/res/values/strings.xml
        }
        create("prod") {
            dimension = "environment"
            // Uses defaultConfig applicationId and main/res strings as-is.
            // Strip x86/x86_64 (emulator-only ABIs) — real devices are arm64 or armv7.
            // This alone cuts the APK by ~30 %. For Play Store (AAB) Google further
            // splits per-ABI automatically, so users download only their arch.
            ndk {
                abiFilters += listOf("arm64-v8a", "armeabi-v7a")
            }
        }
    }

    signingConfigs {
        create("release") {
            keyAlias = keyProperties.getProperty("keyAlias")
            keyPassword = keyProperties.getProperty("keyPassword")
            storeFile = file(keyProperties.getProperty("storeFile"))
            storePassword = keyProperties.getProperty("storePassword")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

// Explicitly enable Crashlytics mapping file upload (default is true, but
// making it explicit ensures it's never accidentally disabled).
firebaseCrashlytics {
    mappingFileUploadEnabled = true
}
