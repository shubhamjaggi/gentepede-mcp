package com.gentepede

import kotlinx.serialization.json.*
import org.junit.jupiter.api.*
import org.junit.jupiter.api.Assertions.*
import java.io.File
import java.nio.file.*

/**
 * Tests for [InfrastructureService] — all business logic, no MCP server required.
 *
 * These tests exercise the service directly using a temp directory as the workspace root.
 * They verify file content, workspace structure, providers.tf generation, lock file
 * behaviour, and ProcessBuilder working-directory correctness.
 */
class InfrastructureServiceTest {

    private lateinit var svc: InfrastructureService
    private lateinit var tempDir: Path

    @BeforeEach
    fun setUp() {
        tempDir = Files.createTempDirectory("gentepede-test-")
        svc = InfrastructureService()
    }

    @AfterEach
    fun tearDown() {
        tempDir.toFile().deleteRecursively()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Blueprint loading
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `listBlueprints returns all six blueprints`() {
        val blueprints = svc.listBlueprints()
        assertEquals(6, blueprints.size, "Expected 6 blueprints")
    }

    @Test
    fun `loadBlueprint returns correct fields for springboot-postgres`() {
        val bp = svc.loadBlueprint("springboot-postgres")
        assertNotNull(bp, "Blueprint should exist")
        assertEquals("springboot-postgres", bp!!.blueprintId)
        assertEquals(OutputType.TERRAFORM_ONLY, bp.outputType)
        assertEquals(TemplateFamily.ecs, bp.templateFamily)
        assertNotNull(bp.terraformProviderVersion, "terraformProviderVersion must be present")
        assertNotNull(bp.lastVerifiedDate, "lastVerifiedDate must be present")
        assertTrue(bp.terraformProviderVersion.matches(Regex("\\d+\\.\\d+\\.\\d+")),
            "Provider version must be in X.Y.Z format")
    }

    @Test
    fun `loadBlueprint returns null for unknown blueprint`() {
        val bp = svc.loadBlueprint("nonexistent-blueprint")
        assertNull(bp)
    }

    @Test
    fun `all blueprints have required fields`() {
        for (bp in svc.listBlueprints()) {
            assertNotNull(bp.blueprintId, "${bp.blueprintId}: blueprintId missing")
            assertNotNull(bp.outputType, "${bp.blueprintId}: outputType missing")
            assertNotNull(bp.templateFamily, "${bp.blueprintId}: templateFamily missing")
            assertTrue(bp.terraformProviderVersion.isNotBlank(), "${bp.blueprintId}: provider version blank")
            assertTrue(bp.lastVerifiedDate.matches(Regex("\\d{4}-\\d{2}")),
                "${bp.blueprintId}: lastVerifiedDate must be YYYY-MM format")
        }
    }

    @Test
    fun `eks blueprints have TERRAFORM_K8S outputType`() {
        val springbootEks = svc.loadBlueprint("springboot-eks")!!
        val nodejsEks = svc.loadBlueprint("nodejs-eks")!!
        assertEquals(OutputType.TERRAFORM_K8S, springbootEks.outputType)
        assertEquals(OutputType.TERRAFORM_K8S, nodejsEks.outputType)
        assertEquals(TemplateFamily.eks, springbootEks.templateFamily)
        assertEquals(TemplateFamily.eks, nodejsEks.templateFamily)
    }

    @Test
    fun `non-eks blueprints have TERRAFORM_ONLY outputType`() {
        val nonEks = listOf("springboot-postgres", "ktor-dynamodb", "nodejs-s3", "fastapi-redis")
        for (id in nonEks) {
            val bp = svc.loadBlueprint(id)!!
            assertEquals(OutputType.TERRAFORM_ONLY, bp.outputType, "$id should be TERRAFORM_ONLY")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // providers.tf generation
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `buildProvidersContent LOCAL mode contains LocalStack endpoint`() {
        System.setProperty("GENTEPEDE_MODE_TEST", "LOCAL")
        val bp = svc.loadBlueprint("springboot-postgres")!!
        val content = callBuildProvidersContentLocal(bp, "test-project", emptyMap())
        assertTrue(content.contains("http://localhost:4566"), "LOCAL providers.tf must reference LocalStack")
        assertTrue(content.contains("skip_credentials_validation = true"))
        assertFalse(content.contains("backend \"s3\""), "LOCAL mode must not have S3 backend")
    }

    @Test
    fun `buildProvidersContent PRODUCTION mode contains S3 backend`() {
        val bp = svc.loadBlueprint("springboot-postgres")!!
        val content = callBuildProvidersContentProduction(bp, "my-project", emptyMap())
        assertTrue(content.contains("backend \"s3\""), "PRODUCTION must have S3 backend")
        assertTrue(content.contains("my-project-tfstate"), "S3 bucket name must contain project name")
        assertTrue(content.contains("dynamodb_table"), "Must have DynamoDB locking")
        assertFalse(content.contains("localhost:4566"), "PRODUCTION must not reference LocalStack")
    }

    @Test
    fun `provider version in providers_tf comes from blueprint field not hardcoded`() {
        val bp = svc.loadBlueprint("springboot-postgres")!!
        val expectedVersion = bp.terraformProviderVersion
        val localContent = callBuildProvidersContentLocal(bp, "proj", emptyMap())
        assertTrue(localContent.contains("= $expectedVersion"),
            "Provider version in providers.tf must match blueprint.terraformProviderVersion")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // terraform.tfvars generation
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `buildTfvarsContent merges blueprint defaults with user variables`() {
        val bp = svc.loadBlueprint("springboot-postgres")!!
        val userVars = mapOf(
            "container_image" to JsonPrimitive("my-ecr/app:1.0"),
            "certificate_arn" to JsonPrimitive("arn:aws:acm:us-east-1:123:certificate/abc")
        )
        val content = svc.buildTfvarsContent(bp, userVars)
        assertTrue(content.contains("my-ecr/app:1.0"), "User-supplied image should be in tfvars")
        assertTrue(content.contains("aws_region"), "Blueprint default aws_region should be in tfvars")
    }

    @Test
    fun `buildTfvarsContent includes blueprint ID comment`() {
        val bp = svc.loadBlueprint("ktor-dynamodb")!!
        val content = svc.buildTfvarsContent(bp, emptyMap())
        assertTrue(content.contains("# Blueprint: ktor-dynamodb"), "tfvars must include blueprint comment")
    }

    @Test
    fun `ecs blueprint tfvars enable only its own data tier`() {
        // springboot-postgres → RDS only
        svc.buildTfvarsContent(svc.loadBlueprint("springboot-postgres")!!, emptyMap()).let {
            assertTrue(it.contains("enable_rds = true"), "springboot-postgres must enable RDS")
            assertTrue(it.contains("enable_dynamodb = false"), "springboot-postgres must not enable DynamoDB")
            assertTrue(it.contains("enable_redis = false"), "springboot-postgres must not enable Redis")
        }
        // ktor-dynamodb → DynamoDB only
        svc.buildTfvarsContent(svc.loadBlueprint("ktor-dynamodb")!!, emptyMap()).let {
            assertTrue(it.contains("enable_dynamodb = true"), "ktor-dynamodb must enable DynamoDB")
            assertTrue(it.contains("enable_rds = false"), "ktor-dynamodb must not enable RDS")
            assertTrue(it.contains("enable_redis = false"), "ktor-dynamodb must not enable Redis")
        }
        // fastapi-redis → Redis only
        svc.buildTfvarsContent(svc.loadBlueprint("fastapi-redis")!!, emptyMap()).let {
            assertTrue(it.contains("enable_redis = true"), "fastapi-redis must enable Redis")
            assertTrue(it.contains("enable_rds = false"), "fastapi-redis must not enable RDS")
            assertTrue(it.contains("enable_dynamodb = false"), "fastapi-redis must not enable DynamoDB")
        }
    }

    @Test
    fun `eks blueprint tfvars gate RDS by declared resources`() {
        // springboot-eks declares RDS_POSTGRES → enabled
        val springboot = svc.buildTfvarsContent(svc.loadBlueprint("springboot-eks")!!, emptyMap())
        assertTrue(springboot.contains("enable_rds = true"), "springboot-eks must enable RDS")
        // nodejs-eks has no database → RDS disabled
        val nodejs = svc.buildTfvarsContent(svc.loadBlueprint("nodejs-eks")!!, emptyMap())
        assertTrue(nodejs.contains("enable_rds = false"), "nodejs-eks must not enable RDS")
    }

    @Test
    fun `lambda blueprint tfvars carry no data-tier toggles`() {
        val content = svc.buildTfvarsContent(svc.loadBlueprint("nodejs-s3")!!, emptyMap())
        assertFalse(content.contains("enable_rds"), "lambda family must not emit enable_rds")
        assertFalse(content.contains("enable_dynamodb"), "lambda family must not emit enable_dynamodb")
        assertFalse(content.contains("enable_redis"), "lambda family must not emit enable_redis")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helm values.yaml generation
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `buildHelmValues sets Spring Boot container port to 8080`() {
        val bp = svc.loadBlueprint("springboot-eks")!!
        val values = svc.buildHelmValues(bp, "my-project", emptyMap())
        assertTrue(values.contains("containerPort: 8080"), "Spring Boot must use port 8080")
        assertTrue(values.contains("/actuator/health"), "Spring Boot must use actuator health paths")
    }

    @Test
    fun `buildHelmValues sets Node_js container port to 3000`() {
        val bp = svc.loadBlueprint("nodejs-eks")!!
        val values = svc.buildHelmValues(bp, "my-project", emptyMap())
        assertTrue(values.contains("containerPort: 3000"), "Node.js must use port 3000")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Lock file
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `lock file round-trip preserves all fields`() {
        val lockFile = tempDir.resolve("gentepede.lock.json").toFile()
        val lock = GentepedeLock(
            blueprintId = "springboot-postgres",
            terraformProviderVersion = "5.82.0",
            plannedAt = "2025-06-14T10:00:00Z",
            planFileChecksum = "sha256:abc123"
        )
        val json = Json.encodeToString(GentepedeLock.serializer(), lock)
        lockFile.writeText(json)

        val decoded = Json { ignoreUnknownKeys = true }.decodeFromString<GentepedeLock>(lockFile.readText())
        assertEquals(lock.blueprintId, decoded.blueprintId)
        assertEquals(lock.planFileChecksum, decoded.planFileChecksum)
        assertEquals(lock.plannedAt, decoded.plannedAt)
        assertNull(decoded.lastApplied, "lastApplied should be null at plan time")
    }

    @Test
    fun `lock file does not contain variableHash`() {
        val lock = GentepedeLock(
            blueprintId = "test",
            terraformProviderVersion = "5.82.0"
        )
        val json = Json.encodeToString(GentepedeLock.serializer(), lock)
        assertFalse(json.contains("variableHash"), "variableHash must not appear in lock file")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // kind cluster pre-flight (EKS LOCAL)
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `EKS LOCAL operation aborts with setup instructions when kind cluster is missing`() {
        // The pre-flight only runs in LOCAL mode (the default when GENTEPEDE_MODE is unset).
        val modeField = InfrastructureService::class.java.getDeclaredField("mode")
        modeField.isAccessible = true
        Assumptions.assumeTrue(modeField.get(svc) == "LOCAL", "Pre-flight only applies in LOCAL mode")

        // A TERRAFORM_K8S workspace is identified by the presence of a helm/ subdirectory.
        val home = System.getProperty("user.home")
        val projectName = "kind-preflight-test-${System.nanoTime()}"
        val workspaceDir = Paths.get(home, ".gentepede", "workspaces", projectName)
        Files.createDirectories(workspaceDir.resolve("helm"))
        Files.createDirectories(workspaceDir.resolve("terraform"))
        try {
            // No gentepede-local kind cluster exists in the test environment, so the
            // pre-flight must abort before any terraform/helm subprocess runs.
            val ex = assertThrows(IllegalStateException::class.java) {
                svc.destroyWorkspace(projectName)
            }
            assertTrue(ex.message!!.contains("kind cluster 'gentepede-local' not found"),
                "EKS LOCAL operation must abort with kind setup instructions when the cluster is missing")
            assertTrue(ex.message!!.contains("kind create cluster --name gentepede-local"),
                "Abort message must include the exact cluster-creation command")
        } finally {
            workspaceDir.toFile().deleteRecursively()
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ProcessBuilder .directory() correctness
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `runProcess captures stdout and stderr separately`() {
        val result = svc.runProcess(
            listOf("java", "-version"),
            directory = tempDir.toFile(),
            allowedExitCodes = setOf(0)
        )
        // java -version outputs to stderr on most JVMs
        val combinedOutput = result.stdout + result.stderr
        assertTrue(combinedOutput.contains("version"), "Should capture Java version output")
    }

    @Test
    fun `runProcess throws ProcessExecutionException on non-zero exit when not in allowed codes`() {
        assertThrows(ProcessExecutionException::class.java) {
            svc.runProcess(
                listOf("java", "-invalid-flag-that-does-not-exist"),
                directory = tempDir.toFile(),
                allowedExitCodes = setOf(0)
            )
        }
    }

    @Test
    fun `runProcess sets working directory correctly`() {
        // Write a sentinel file to tempDir and check we can list it from the process CWD
        val sentinel = tempDir.resolve("sentinel.txt").toFile()
        sentinel.writeText("hello")

        val result = if (System.getProperty("os.name").lowercase().contains("windows")) {
            svc.runProcess(listOf("cmd", "/c", "dir", "sentinel.txt"), tempDir.toFile(), setOf(0))
        } else {
            svc.runProcess(listOf("ls", "sentinel.txt"), tempDir.toFile(), setOf(0))
        }
        assertTrue(result.stdout.contains("sentinel.txt"), "Process should be able to see files in .directory()")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers to call private methods via reflection for unit testing
    // ─────────────────────────────────────────────────────────────────────────

    private fun callBuildProvidersContentLocal(
        blueprint: Blueprint,
        projectName: String,
        userVariables: Map<String, JsonElement>
    ): String {
        // Temporarily override mode via reflection
        val modeField = InfrastructureService::class.java.getDeclaredField("mode")
        modeField.isAccessible = true
        val originalMode = modeField.get(svc) as String
        modeField.set(svc, "LOCAL")
        try {
            return svc.buildProvidersContent(blueprint, projectName, userVariables)
        } finally {
            modeField.set(svc, originalMode)
        }
    }

    private fun callBuildProvidersContentProduction(
        blueprint: Blueprint,
        projectName: String,
        userVariables: Map<String, JsonElement>
    ): String {
        val modeField = InfrastructureService::class.java.getDeclaredField("mode")
        modeField.isAccessible = true
        val originalMode = modeField.get(svc) as String
        modeField.set(svc, "PRODUCTION")
        try {
            return svc.buildProvidersContent(blueprint, projectName, userVariables)
        } finally {
            modeField.set(svc, originalMode)
        }
    }
}
