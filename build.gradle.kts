import com.github.jengelman.gradle.plugins.shadow.tasks.ShadowJar


plugins {
    kotlin("jvm") version "2.4.0"
    kotlin("plugin.serialization") version "2.4.0"
    id("com.gradleup.shadow") version "8.3.6"
    application
    jacoco
}

group = "com.gentepede"
version = "1.0.0"

repositories {
    mavenCentral()
}

dependencies {
    // MCP SDK — official Kotlin implementation, handles JSON-RPC + stdio transport
    implementation("io.modelcontextprotocol:kotlin-sdk:0.13.0")

    // JSON serialization — used for blueprint parsing and lock file I/O
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.8.0")

    // Coroutines — MCP SDK requires coroutine scope for tool handler registration
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")

    // Test dependencies
    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.14.4")
    testImplementation("org.junit.jupiter:junit-jupiter-params:5.14.4")
}

application {
    mainClass.set("com.gentepede.MainKt")
}

kotlin {
    jvmToolchain(21)
}

// Bundle templates/ and helm-chart/ into the fat JAR classpath.
// Using processResources to avoid accidentally filtering out src/main/resources/.
// Result: templates/ecs/main.tf is accessible as getResourceAsStream("templates/ecs/main.tf"),
//         helm-chart/Chart.yaml is accessible as getResourceAsStream("helm-chart/Chart.yaml").
tasks.processResources {
    from(projectDir) {
        include("templates/**")
        include("helm-chart/**")
    }
}

tasks.test {
    useJUnitPlatform()
    finalizedBy(tasks.jacocoTestReport)
}

tasks.jacocoTestReport {
    dependsOn(tasks.test)
    reports {
        xml.required.set(true)
        html.required.set(true)
    }
}

tasks.named<ShadowJar>("shadowJar") {
    archiveClassifier.set("all")
    // Drop the version from the artifact name so the output is gentepede-mcp-all.jar
    // (not gentepede-mcp-1.0.0-all.jar). README, docs, and the CI workflow all
    // reference build/libs/gentepede-mcp-all.jar — keep this name in sync with them.
    archiveVersion.set("")
    mergeServiceFiles()
    manifest {
        attributes["Main-Class"] = "com.gentepede.MainKt"
    }
}

tasks.build {
    dependsOn(tasks.named("shadowJar"))
}
