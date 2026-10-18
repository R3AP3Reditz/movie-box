# The Flutter Gradle plugin enables R8 for release builds. shared_preferences_android
# 2.5.x is called through package:jni, which looks classes and members up by their
# exact JVM names and descriptors at runtime instead of by direct reference. Renaming
# any of them makes the lookup throw, and because the lookup happens during
# SharedPreferences.getInstance() in main(), the failure precedes the first Flutter
# frame and the Android launch screen stays up forever.
#
# The plugin's own classes and API.
-keep class io.flutter.plugins.sharedpreferences.** { *; }

# Kotlin stdlib names that package:jni resolves by string (see jni/lib/src/kotlin.dart):
# CoroutineSingletons, IntrinsicsKt, Continuation, Result, Result$Failure, and Unit.
-keep class kotlin.Unit { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.coroutines.Continuation { *; }
-keep class kotlin.coroutines.intrinsics.** { *; }