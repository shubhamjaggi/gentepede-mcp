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
    // Workspace generation — file structure
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `generateWorkspace TERRAFORM_ONLY creates flat file structure`() {
        val projectName = "gen-test-flat-${System.nanoTime()}"
        val home = System.getProperty("user.home")
        val workspaceDir = Paths.get(home, ".gentepede", "workspaces", projectName)
        try {
            val result = svc.generateWorkspace("springboot-postgres", projectName, emptyMap())
            assertEquals(workspaceDir.toString(), result.workspacePath)
            assertEquals(OutputType.TERRAFORM_ONLY, result.outputType)
            // Terraform files must be at workspace root (not in a subdirectory)
            assertTrue(workspaceDir.resolve("main.tf").toFile().exists(), "main.tf must exist at workspace root")
            assertTrue(workspaceDir.resolve("variables.tf").toFile().exists(), "variables.tf must exist at workspace root")
            assertTrue(workspaceDir.resolve("terraform.tfvars").toFile().exists(), "terraform.tfvars must exist")
            assertTrue(workspaceDir.resolve("providers.tf").toFile().exists(), "providers.tf must exist")
            // TERRAFORM_ONLY must NOT create a terraform/ subdirectory
            assertFalse(workspaceDir.resolve("terraform").toFile().exists(),
                "TERRAFORM_ONLY workspace must not have a terraform/ subdirectory")
        } finally {
            workspaceDir.toFile().deleteRecursively()
        }
    }

    @Test
    fun `generateWorkspace TERRAFORM_K8S creates terraform and helm subdirectories`() {
        val projectName = "gen-test-k8s-${System.nanoTime()}"
        val home = System.getProperty("user.home")
        val workspaceDir = Paths.get(home, ".gentepede", "workspaces", projectName)
        try {
            val result = svc.generateWorkspace("springboot-eks", projectName, emptyMap())
            assertEquals(workspaceDir.toString(), result.workspacePath)
            assertEquals(OutputType.TERRAFORM_K8S, result.outputType)
            // Terraform files must be in terraform/ subdirectory
            assertTrue(workspaceDir.resolve("terraform/main.tf").toFile().exists(), "terraform/main.tf must exist")
            assertTrue(workspaceDir.resolve("terraform/variables.tf").toFile().exists())
            assertTrue(workspaceDir.resolve("terraform/terraform.tfvars").toFile().exists())
            assertTrue(workspaceDir.resolve("terraform/providers.tf").toFile().exists())
            // Helm chart must be in helm/ subdirectory
            assertTrue(workspaceDir.resolve("helm/Chart.yaml").toFile().exists(), "helm/Chart.yaml must exist")
            assertTrue(workspaceDir.resolve("helm/values.yaml").toFile().exists(), "helm/values.yaml must exist")
            // kind-config.yaml in workspace root
            assertTrue(workspaceDir.resolve("kind-config.yaml").toFile().exists(), "kind-config.yaml must exist at workspace root")
        } finally {
            workspaceDir.toFile().deleteRecursively()
        }
    }

    @Test
    fun `generateWorkspace returns list of aws resource types from blueprint`() {
        val projectName = "gen-test-resources-${System.nanoTime()}"
        val home = System.getProperty("user.home")
        val workspaceDir = Paths.get(home, ".gentepede", "workspaces", projectName)
        try {
            val result = svc.generateWorkspace("ktor-dynamodb", projectName, emptyMap())
            assertTrue(result.awsResources.contains("DYNAMODB_TABLE"), "ktor-dynamodb must list DYNAMODB_TABLE")
            assertTrue(result.awsResources.contains("ECS_FARGATE"), "ktor-dynamodb must list ECS_FARGATE")
            assertTrue(result.awsResources.contains("VPC"), "ktor-dynamodb must list VPC")
        } finally {
            workspaceDir.toFile().deleteRecursively()
        }
    }

    @Test
    fun `generateWorkspace unknown blueprint throws IllegalArgumentException`() {
        assertThrows(IllegalArgumentException::class.java) {
            svc.generateWorkspace("nonexistent-blueprint-xyz", "test-proj", emptyMap())
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // resolveTerraformDir
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `resolveTerraformDir returns workspace root when no terraform subdir exists`() {
        val method = InfrastructureService::class.java.getDeclaredMethod("resolveTerraformDir", Path::class.java)
        method.isAccessible = true
        val result = method.invoke(svc, tempDir) as Path
        assertEquals(tempDir, result, "TERRAFORM_ONLY: should return workspace root when terraform/ does not exist")
    }

    @Test
    fun `resolveTerraformDir returns terraform subdir when it exists`() {
        val terraformSubdir = tempDir.resolve("terraform")
        Files.createDirectories(terraformSubdir)
        val method = InfrastructureService::class.java.getDeclaredMethod("resolveTerraformDir", Path::class.java)
        method.isAccessible = true
        val result = method.invoke(svc, tempDir) as Path
        assertEquals(terraformSubdir, result, "TERRAFORM_K8S: should return terraform/ subdir")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // buildKindConfig
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `buildKindConfig contains cluster name and port mappings`() {
        val method = InfrastructureService::class.java.getDeclaredMethod("buildKindConfig", String::class.java)
        method.isAccessible = true
        val config = method.invoke(svc, "my-project") as String
        assertTrue(config.contains("name: gentepede-local"), "Kind config must set cluster name to gentepede-local")
        assertTrue(config.contains("containerPort: 80"), "Kind config must map port 80")
        assertTrue(config.contains("containerPort: 443"), "Kind config must map port 443")
        assertTrue(config.contains("hostPort: 8080"), "Kind config must expose host port 8080")
        assertTrue(config.contains("role: control-plane"), "Kind config must declare a control-plane node")
        assertTrue(config.contains("role: worker"), "Kind config must declare worker nodes")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // sha256Hex
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `sha256Hex matches known digest for hello`() {
        val method = InfrastructureService::class.java.getDeclaredMethod("sha256Hex", ByteArray::class.java)
        method.isAccessible = true
        val result = method.invoke(svc, "hello".toByteArray()) as String
        // SHA-256("hello") is well-known and stable across JVM implementations
        assertEquals("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", result)
    }

    @Test
    fun `sha256Hex is deterministic for the same input`() {
        val method = InfrastructureService::class.java.getDeclaredMethod("sha256Hex", ByteArray::class.java)
        method.isAccessible = true
        val bytes = "determinism-test".toByteArray()
        val hash1 = method.invoke(svc, bytes) as String
        val hash2 = method.invoke(svc, bytes) as String
        assertEquals(hash1, hash2, "Same input must always produce the same SHA-256 digest")
    }

    @Test
    fun `sha256Hex produces different digests for different inputs`() {
        val method = InfrastructureService::class.java.getDeclaredMethod("sha256Hex", ByteArray::class.java)
        method.isAccessible = true
        val hash1 = method.invoke(svc, "input-a".toByteArray()) as String
        val hash2 = method.invoke(svc, "input-b".toByteArray()) as String
        assertNotEquals(hash1, hash2, "Different inputs must produce different digests")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // parsePlanChanges
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `parsePlanChanges counts creates modifies and destroys excluding no-op`() {
        val method = InfrastructureService::class.java.getDeclaredMethod("parsePlanChanges", JsonObject::class.java)
        method.isAccessible = true

        val planJson = buildJsonObject {
            put("resource_changes", buildJsonArray {
                add(buildJsonObject {
                    put("address", "aws_vpc.main")
                    put("change", buildJsonObject { put("actions", buildJsonArray { add("create") }) })
                })
                add(buildJsonObject {
                    put("address", "aws_instance.app")
                    put("change", buildJsonObject { put("actions", buildJsonArray { add("update") }) })
                })
                add(buildJsonObject {
                    put("address", "aws_security_group.old")
                    put("change", buildJsonObject { put("actions", buildJsonArray { add("delete") }) })
                })
                add(buildJsonObject {
                    put("address", "data.aws_ami.ubuntu")
                    put("change", buildJsonObject { put("actions", buildJsonArray { add("no-op") }) })
                })
            })
        }

        val result = method.invoke(svc, planJson)!!
        val cls = result.javaClass
        val toCreate = cls.getDeclaredField("toCreate").also { it.isAccessible = true }.getInt(result)
        val toModify = cls.getDeclaredField("toModify").also { it.isAccessible = true }.getInt(result)
        val toDestroy = cls.getDeclaredField("toDestroy").also { it.isAccessible = true }.getInt(result)
        @Suppress("UNCHECKED_CAST")
        val resources = cls.getDeclaredField("resources").also { it.isAccessible = true }.get(result) as List<*>

        assertEquals(1, toCreate, "Should count exactly 1 CREATE")
        assertEquals(1, toModify, "Should count exactly 1 MODIFY")
        assertEquals(1, toDestroy, "Should count exactly 1 DESTROY")
        assertEquals(3, resources.size, "no-op resources must be excluded from the list")
    }

    @Test
    fun `parsePlanChanges returns zeroes for empty resource_changes`() {
        val method = InfrastructureService::class.java.getDeclaredMethod("parsePlanChanges", JsonObject::class.java)
        method.isAccessible = true
        val planJson = buildJsonObject { put("resource_changes", buildJsonArray {}) }

        val result = method.invoke(svc, planJson)!!
        val cls = result.javaClass
        val toCreate = cls.getDeclaredField("toCreate").also { it.isAccessible = true }.getInt(result)
        assertEquals(0, toCreate, "Empty plan should have 0 creates")
    }

    @Test
    fun `parsePlanChanges returns zeroes when resource_changes key is absent`() {
        val method = InfrastructureService::class.java.getDeclaredMethod("parsePlanChanges", JsonObject::class.java)
        method.isAccessible = true
        val planJson = buildJsonObject {}

        val result = method.invoke(svc, planJson)!!
        val cls = result.javaClass
        val toCreate = cls.getDeclaredField("toCreate").also { it.isAccessible = true }.getInt(result)
        assertEquals(0, toCreate, "Missing resource_changes key should be handled gracefully")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // parseDriftChanges
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `parseDriftChanges identifies modified and destroyed resources`() {
        val method = InfrastructureService::class.java.getDeclaredMethod("parseDriftChanges", JsonObject::class.java)
        method.isAccessible = true

        val planJson = buildJsonObject {
            put("resource_changes", buildJsonArray {
                add(buildJsonObject {
                    put("address", "aws_security_group.app")
                    put("change", buildJsonObject { put("actions", buildJsonArray { add("update") }) })
                })
                add(buildJsonObject {
                    put("address", "aws_eip.nat")
                    put("change", buildJsonObject { put("actions", buildJsonArray { add("delete") }) })
                })
                add(buildJsonObject {
                    put("address", "data.aws_caller_identity.current")
                    put("change", buildJsonObject { put("actions", buildJsonArray { add("no-op") }) })
                })
            })
        }

        @Suppress("UNCHECKED_CAST")
        val result = method.invoke(svc, planJson) as List<DriftItem>
        assertEquals(2, result.size, "no-op items must be excluded from drift list")
        assertTrue(result.any { it.address == "aws_security_group.app" && it.change == "MODIFIED" })
        assertTrue(result.any { it.address == "aws_eip.nat" && it.change == "DESTROY" })
    }

    @Test
    fun `parseDriftChanges returns empty list for no-op only plan`() {
        val method = InfrastructureService::class.java.getDeclaredMethod("parseDriftChanges", JsonObject::class.java)
        method.isAccessible = true

        val planJson = buildJsonObject {
            put("resource_changes", buildJsonArray {
                add(buildJsonObject {
                    put("address", "data.aws_ami.ubuntu")
                    put("change", buildJsonObject { put("actions", buildJsonArray { add("no-op") }) })
                })
            })
        }

        @Suppress("UNCHECKED_CAST")
        val result = method.invoke(svc, planJson) as List<DriftItem>
        assertTrue(result.isEmpty(), "All no-op plan should produce empty drift list")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // buildValidationSummary
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `buildValidationSummary shows PASSED for all green inputs`() {
        val method = InfrastructureService::class.java.getDeclaredMethod(
            "buildValidationSummary",
            ProcessResult::class.java,
            CheckovResult::class.java,
            KubeScoreResult::class.java
        )
        method.isAccessible = true

        val validateResult = ProcessResult(exitCode = 0, stdout = "Success!", stderr = "")
        val checkovResult = CheckovResult(passed = true, skipped = false, findings = emptyList())
        val kubeScoreResult = KubeScoreResult(passed = true, skipped = true, findings = emptyList())

        val summary = method.invoke(svc, validateResult, checkovResult, kubeScoreResult) as String
        assertTrue(summary.contains("PASSED"), "Summary must say PASSED when all checks succeed")
        assertFalse(summary.contains("FAILED"), "Summary must not say FAILED when all checks pass")
    }

    @Test
    fun `buildValidationSummary shows FAILED when terraform validate fails`() {
        val method = InfrastructureService::class.java.getDeclaredMethod(
            "buildValidationSummary",
            ProcessResult::class.java,
            CheckovResult::class.java,
            KubeScoreResult::class.java
        )
        method.isAccessible = true

        val validateResult = ProcessResult(exitCode = 1, stdout = "", stderr = "Error in config")
        val checkovResult = CheckovResult(passed = true, skipped = false, findings = emptyList())
        val kubeScoreResult = KubeScoreResult(passed = true, skipped = true, findings = emptyList())

        val summary = method.invoke(svc, validateResult, checkovResult, kubeScoreResult) as String
        assertTrue(summary.contains("FAILED"), "Summary must say FAILED when terraform validate exits non-zero")
    }

    @Test
    fun `buildValidationSummary shows SKIPPED when checkov is not installed`() {
        val method = InfrastructureService::class.java.getDeclaredMethod(
            "buildValidationSummary",
            ProcessResult::class.java,
            CheckovResult::class.java,
            KubeScoreResult::class.java
        )
        method.isAccessible = true

        val validateResult = ProcessResult(exitCode = 0, stdout = "Success!", stderr = "")
        val checkovResult = CheckovResult(passed = true, skipped = true, findings = emptyList())
        val kubeScoreResult = KubeScoreResult(passed = true, skipped = true, findings = emptyList())

        val summary = method.invoke(svc, validateResult, checkovResult, kubeScoreResult) as String
        assertTrue(summary.contains("SKIPPED"), "Summary must say SKIPPED when checkov is not installed")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Lock file read/write round-trip
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `writeLockFile and readLockFile preserve all fields`() {
        val writeLock = InfrastructureService::class.java.getDeclaredMethod("writeLockFile", Path::class.java, GentepedeLock::class.java)
        writeLock.isAccessible = true
        val readLock = InfrastructureService::class.java.getDeclaredMethod("readLockFile", Path::class.java)
        readLock.isAccessible = true

        val lock = GentepedeLock(
            blueprintId = "ktor-dynamodb",
            terraformProviderVersion = "5.82.0",
            plannedAt = "2025-06-14T10:00:00Z",
            planFileChecksum = "sha256:abc123def456",
            lastApplied = null,
            stateBackupPath = null
        )
        writeLock.invoke(svc, tempDir, lock)
        val restored = readLock.invoke(svc, tempDir) as GentepedeLock

        assertEquals(lock.blueprintId, restored.blueprintId)
        assertEquals(lock.terraformProviderVersion, restored.terraformProviderVersion)
        assertEquals(lock.plannedAt, restored.plannedAt)
        assertEquals(lock.planFileChecksum, restored.planFileChecksum)
        assertNull(restored.lastApplied)
        assertNull(restored.stateBackupPath)
    }

    @Test
    fun `readLockFile returns null when no lock file exists`() {
        val readLock = InfrastructureService::class.java.getDeclaredMethod("readLockFile", Path::class.java)
        readLock.isAccessible = true
        val result = readLock.invoke(svc, tempDir)
        assertNull(result, "readLockFile must return null when gentepede.lock.json does not exist")
    }

    @Test
    fun `writeLockFile creates file in workspace root not terraform subdir`() {
        val writeLock = InfrastructureService::class.java.getDeclaredMethod("writeLockFile", Path::class.java, GentepedeLock::class.java)
        writeLock.isAccessible = true
        val lock = GentepedeLock(blueprintId = "test", terraformProviderVersion = "5.82.0")
        writeLock.invoke(svc, tempDir, lock)

        val lockFile = tempDir.resolve("gentepede.lock.json").toFile()
        assertTrue(lockFile.exists(), "Lock file must be in the workspace root")
        assertTrue(lockFile.readText().contains("test"), "Lock file must contain the blueprintId")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // resolveCurrentBlueprintId
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `resolveCurrentBlueprintId reads from lock file when it exists`() {
        val writeLock = InfrastructureService::class.java.getDeclaredMethod("writeLockFile", Path::class.java, GentepedeLock::class.java)
        writeLock.isAccessible = true
        val resolve = InfrastructureService::class.java.getDeclaredMethod("resolveCurrentBlueprintId", Path::class.java)
        resolve.isAccessible = true

        writeLock.invoke(svc, tempDir, GentepedeLock(blueprintId = "fastapi-redis", terraformProviderVersion = "5.82.0"))
        val id = resolve.invoke(svc, tempDir) as String
        assertEquals("fastapi-redis", id)
    }

    @Test
    fun `resolveCurrentBlueprintId falls back to tfvars comment when no lock file`() {
        val resolve = InfrastructureService::class.java.getDeclaredMethod("resolveCurrentBlueprintId", Path::class.java)
        resolve.isAccessible = true

        tempDir.resolve("terraform.tfvars").toFile().writeText(
            "# Blueprint: nodejs-s3\nproject_name = \"test\"\n"
        )
        val id = resolve.invoke(svc, tempDir) as String
        assertEquals("nodejs-s3", id)
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
