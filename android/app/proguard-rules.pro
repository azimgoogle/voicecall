# Preserve source file names and line numbers for Crashlytics stack traces
-keepattributes SourceFile,LineNumberTable

# Flutter WebRTC
-keep class org.webrtc.** { *; }

# Firebase
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }

# flutter_foreground_task
-keep class com.pravera.flutter_foreground_task.** { *; }

# Keep BuildConfig
-keep class com.zunova.nestcall.BuildConfig { *; }
