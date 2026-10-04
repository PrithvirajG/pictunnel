plugins {
    kotlin("jvm") version "2.3.20"
    kotlin("plugin.serialization") version "2.3.20"
}

group = "io.github.prithvirajg.pictunnel"

repositories {
    mavenCentral()
}

kotlin {
    jvmToolchain(17)
    sourceSets["main"].kotlin.srcDir("generated/src/main/kotlin")
}

dependencies {
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
    systemProperty("pictunnel.protocolDir", rootDir.resolve("../../../api/protocol").canonicalPath)
}
