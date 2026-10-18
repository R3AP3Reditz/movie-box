import java.io.File

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeystorePath = providers.environmentVariable("MOVIE_BOX_KEYSTORE_PATH").orNull
val releaseStorePassword = providers.environmentVariable("MOVIE_BOX_STORE_PASSWORD").orNull
val releaseKeyAlias = providers.environmentVariable("MOVIE_BOX_KEY_ALIAS").orNull
val releaseKeyPassword = providers.environmentVariable("MOVIE_BOX_KEY_PASSWORD").orNull
val hasReleaseSigning = listOf(
    releaseKeystorePath, releaseStorePassword, releaseKeyAlias, releaseKeyPassword,
).all { !it.isNullOrBlank() }

val verifyReleaseSigning = tasks.register("verifyReleaseSigning") {
    doLast {
        check(hasReleaseSigning) {
            "Release signing requires MOVIE_BOX_KEYSTORE_PATH, MOVIE_BOX_STORE_PASSWORD, " +
                "MOVIE_BOX_KEY_ALIAS, and MOVIE_BOX_KEY_PASSWORD. See docs/signing.md."
        }
        val keystore = File(requireNotNull(releaseKeystorePath))
        check(keystore.isAbsolute && keystore.isFile) {
            "MOVIE_BOX_KEYSTORE_PATH must point to an existing keystore using an absolute path."
        }
    }
}

val stripIntegrationTestRegistrant = tasks.register("stripIntegrationTestRegistrant") {
    doLast {
        val registrant = file("src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java")
        if (!registrant.isFile) return@doLast
        val lines = registrant.readLines()
        val kept = mutableListOf<String>()
        var index = 0
        while (index < lines.size) {
            val block = lines.subList(index, minOf(index + 6, lines.size)).joinToString("\n")
            if (lines[index].trim() == "try {" && block.contains("integration_test.IntegrationTestPlugin")) {
                index += 1
                while (index < lines.size && lines[index].trim() != "}") index += 1
                if (index < lines.size) index += 1
                continue
            }
            kept.add(lines[index])
            index += 1
        }
        val updated = kept.joinToString("\n") + "\n"
        if (updated != registrant.readText()) registrant.writeText(updated)
    }
}

tasks.configureEach {
    if (name == "preReleaseBuild") {
        dependsOn(verifyReleaseSigning)
    }
    if (name == "compileFlutterBuildRelease") {
        stripIntegrationTestRegistrant.configure { mustRunAfter(this@configureEach) }
    }
    if (name == "compileReleaseJavaWithJavac") {
        dependsOn(stripIntegrationTestRegistrant)
    }
}

android {
    namespace = "dev.r3ap3r.movie_box_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        // Separate from the previous release so a new signing key can install
        // beside an existing copy instead of being rejected as an update.
        applicationId = "dev.r3ap3r.moviebox"
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

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseKeystorePath!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
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
