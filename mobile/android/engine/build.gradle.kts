import java.util.Properties

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("com.google.devtools.ksp")
}

// The generated Pigeon bridge (bridge/Pigeon.g.kt) compiles against the Flutter
// embedding. The host app supplies it at runtime, so it is compileOnly here. The
// Flutter Gradle plugin applied to :app registers the download.flutter.io repo
// for every project; the version is the engine stamp of the configured SDK.
val flutterSdkPath: String =
    Properties()
        .apply {
            val f = rootProject.file("local.properties")
            if (f.exists()) f.inputStream().use { load(it) }
        }.getProperty("flutter.sdk")
        ?: System.getenv("FLUTTER_ROOT")
        ?: error("flutter.sdk not set in local.properties and FLUTTER_ROOT unset")
val flutterEngineVersion = "1.0.0-" + file("$flutterSdkPath/bin/cache/engine.stamp").readText().trim()

android {
    namespace = "io.github.prithvirajg.pictunnel.engine"
    compileSdk = 36

    defaultConfig {
        minSdk = 29
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    lint {
        targetSdk = 36
    }

    // Exported Room schemas are test assets for MigrationTestHelper.
    sourceSets.getByName("test").assets.srcDir("$projectDir/schemas")

    testOptions {
        targetSdk = 36
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()
                it.systemProperty(
                    "pictunnel.protocolDir",
                    rootProject.file("../../api/protocol").canonicalPath,
                )
                it.maxHeapSize = "1g"
                // Robolectric's SDK 36 runtime reaches into FileDescriptor internals on JDK 17+.
                it.jvmArgs("--add-exports=java.base/jdk.internal.access=ALL-UNNAMED")
                // ServerIntegrationTest runs against a real server binary when this is set.
                System.getenv("PICTUNNEL_BIN")?.let { bin -> it.environment("PICTUNNEL_BIN", bin) }
                it.testLogging {
                    events("failed", "skipped")
                    exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

ksp {
    arg("room.schemaLocation", "$projectDir/schemas")
    arg("room.generateKotlin", "true")
}

dependencies {
    compileOnly("io.flutter:flutter_embedding_debug:$flutterEngineVersion")

    implementation("androidx.room:room-runtime:2.8.4")
    implementation("androidx.room:room-ktx:2.8.4")
    ksp("androidx.room:room-compiler:2.8.4")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
    // OkHttp 5 only. engine-api pins OkHttp 4.12, so :engine does not depend on it
    // and hand-writes the few DTOs it needs (net/CheckApi.kt, net/ServerClient.kt).
    implementation("com.squareup.okhttp3:okhttp:5.3.2")

    testImplementation(platform("org.junit:junit-bom:5.14.4"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
    // Robolectric runs on JUnit 4; the vintage engine runs it on the JUnit Platform.
    testImplementation("junit:junit:4.13.2")
    testRuntimeOnly("org.junit.vintage:junit-vintage-engine")
    testImplementation("org.robolectric:robolectric:4.17")
    testImplementation("androidx.test:core:1.7.0")
    testImplementation("androidx.room:room-testing:2.8.4")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    testImplementation("com.squareup.okhttp3:mockwebserver3:5.3.2")
    testImplementation("com.squareup.okhttp3:okhttp-tls:5.3.2")
}
