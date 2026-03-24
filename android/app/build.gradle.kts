plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}

android {
    namespace = "com.familycall.children_voice_call"
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
        applicationId = "com.familycall.children_voice_call"
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
    //   android/app/src/dev/google-services.json   (app ID: ...children_voice_call.dev)
    //   android/app/src/prod/google-services.json  (app ID: ...children_voice_call)
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
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
