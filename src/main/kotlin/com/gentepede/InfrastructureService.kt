package com.gentepede

import kotlinx.serialization.json.*
import java.io.*
import java.nio.file.*
import java.security.MessageDigest
import java.time.Instant
import java.util.concurrent.TimeUnit

/**
 * InfrastructureService — all business logic for the Gentepede MCP server.
 *
 * This class knows nothing about the MCP protocol. Engine.kt is the thin MCP
 * handler that extracts tool parameters and calls this service. Keeping business
 * logic here makes it testable without a running MCP server — CI calls it
 * directly via the JVM classpath.
 *
 * Responsibilities:
 * - Load and parse blueprint JSON from the JAR classpath
 * - Create and manage workspaces under `~/.gentepede/workspaces/`
 * - Generate `providers.tf` at runtime for LOCAL or PRODUCTION mode
 * - Copy template families (ecs, lambda, eks) into the workspace
 * - Generate Helm `values.yaml` and `kind-config.yaml` for TERRAFORM_K8S blueprints
 * - Read and write `gentepede.lock.json`
 * - Create timestamped state backups before every apply or destroy
 * - Run external CLI tools (terraform, helm, checkov, kube-score, infracost, kind, kubectl)
 *   via ProcessBuilder with stream gobbling and a 30-minute timeout
 *
 * Does NOT:
 * - Handle JSON-RPC framing (that's the MCP SDK + Engine.kt)
 * - Parse checkov/kube-score output (that's Validator.kt)
 * - Store any state in memory between calls (all state lives on disk)
 */
class InfrastructureService {

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
    }

    private val mode: String = System.getenv("GENTEPEDE_MODE") ?: "LOCAL"
    private val homeDir: String = System.getProperty("user.home")
    private val gentepedeRoot = Paths.get(homeDir, ".gentepede")
    private val workspacesRoot = gentepedeRoot.resolve("workspaces")
    private val backupsRoot = gentepedeRoot.resolve("backups")

    // ─────────────────────────────────────────────────────────────────────────
    // BLUEPRINT LOADING
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Loads all blueprints bundled in the JAR under `blueprints/`.
     *
     * Blueprints are stored as classpath resources so they are included in the
     * shadow JAR and do not require an external file path to locate at runtime.
     *
     * @return list of all [Blueprint] objects; empty list only if the JAR is malformed
     */
    fun listBlueprints(): List<Blueprint> {
        val blueprintIds = listOf(
            "springboot-postgres",
            "ktor-dynamodb",
            "nodejs-s3",
            "fastapi-redis",
            "springboot-eks",
            "nodejs-eks"
        )
        return blueprintIds.mapNotNull { id ->
            loadBlueprint(id)
        }
    }

    /**
     * Loads a single blueprint by its [blueprintId] slug.
     *
     * @param blueprintId the slug matching a file at `blueprints/{id}.json` in the JAR
     * @return the parsed [Blueprint], or null if the resource is not found
     */
    fun loadBlueprint(blueprintId: String): Blueprint? {
        val resourcePath = "blueprints/$blueprintId.json"
        val stream = Thread.currentThread().contextClassLoader
            .getResourceAsStream(resourcePath) ?: return null
        val text = stream.bufferedReader().use { it.readText() }
        return json.decodeFromString<Blueprint>(text)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // WORKSPACE GENERATION
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Creates a workspace for [projectName] based on [blueprintId] and [userVariables].
     *
     * For TERRAFORM_ONLY blueprints the workspace is flat: all Terraform files
     * live in `~/.gentepede/workspaces/{projectName}/`.
     *
     * For TERRAFORM_K8S blueprints the workspace has subdirectories:
     * - `terraform/` — all Terraform files
     * - `helm/` — the Helm chart with a generated `values.yaml`
     * - `kind-config.yaml` in the workspace root
     *
     * @param blueprintId     slug identifying the blueprint to use
     * @param projectName     name used for workspace directories and resource names
     * @param userVariables   map of variable name → JSON value supplied by the caller
     * @return [GenerateResult] describing what was created and what to do next
     * @throws IllegalArgumentException if the blueprint is not found
     */
    fun generateWorkspace(
        blueprintId: String,
        projectName: String,
        userVariables: Map<String, JsonElement>
    ): GenerateResult {
        val blueprint = loadBlueprint(blueprintId)
            ?: throw IllegalArgumentException("Blueprint '$blueprintId' not found. Run list_available_blueprints to see available options.")

        val workspaceDir = workspacesRoot.resolve(projectName)
        Files.createDirectories(workspaceDir)

        val warnings = mutableListOf<String>()

        // Detect existing state before overwriting
        val tfStateFile = workspaceDir.resolve("terraform.tfstate")
        val dotTerraformDir = workspaceDir.resolve(".terraform")
        val tfVarsFile = workspaceDir.resolve("terraform.tfvars")

        if (tfStateFile.toFile().exists() || dotTerraformDir.toFile().exists()) {
            val newVarsContent = buildTfvarsContent(blueprint, userVariables)
            val existingVarsContent = if (tfVarsFile.toFile().exists())
                tfVarsFile.toFile().readText() else ""

            if (newVarsContent.trim() != existingVarsContent.trim()) {
                warnings.add(
                    "Warning: existing state detected. Variables differ from previous generation.\n" +
                    "Run plan_infrastructure_package first to review what will change."
                )
            }
        }

        return when (blueprint.outputType) {
            OutputType.TERRAFORM_ONLY -> generateTerraformOnly(
                blueprint, projectName, workspaceDir, userVariables, warnings
            )
            OutputType.TERRAFORM_K8S -> generateTerraformK8s(
                blueprint, projectName, workspaceDir, userVariables, warnings
            )
        }
    }

    private fun generateTerraformOnly(
        blueprint: Blueprint,
        projectName: String,
        workspaceDir: Path,
        userVariables: Map<String, JsonElement>,
        warnings: MutableList<String>
    ): GenerateResult {
        // Copy template family files into workspace root
        copyTemplateFamily(blueprint.templateFamily, workspaceDir)

        // Write terraform.tfvars
        val tfvarsContent = buildTfvarsContent(blueprint, userVariables)
        workspaceDir.resolve("terraform.tfvars").toFile().writeText(tfvarsContent)

        // Write runtime-generated providers.tf
        val providersContent = buildProvidersContent(blueprint, projectName, userVariables)
        workspaceDir.resolve("providers.tf").toFile().writeText(providersContent)

        return GenerateResult(
            workspacePath = workspaceDir.toString(),
            mode = mode,
            outputType = blueprint.outputType,
            awsResources = blueprint.awsResources.map { it.type },
            nextStep = "Run validate_infrastructure_package to check Terraform syntax and security posture.",
            warnings = warnings
        )
    }

    private fun generateTerraformK8s(
        blueprint: Blueprint,
        projectName: String,
        workspaceDir: Path,
        userVariables: Map<String, JsonElement>,
        warnings: MutableList<String>
    ): GenerateResult {
        val terraformDir = workspaceDir.resolve("terraform")
        val helmDir = workspaceDir.resolve("helm")
        Files.createDirectories(terraformDir)
        Files.createDirectories(helmDir)

        // Copy EKS template family into terraform/
        copyTemplateFamily(blueprint.templateFamily, terraformDir)

        // Write terraform.tfvars into terraform/
        val tfvarsContent = buildTfvarsContent(blueprint, userVariables)
        terraformDir.resolve("terraform.tfvars").toFile().writeText(tfvarsContent)

        // Write runtime-generated providers.tf into terraform/
        val providersContent = buildProvidersContent(blueprint, projectName, userVariables)
        terraformDir.resolve("providers.tf").toFile().writeText(providersContent)

        // Copy helm-chart/ into helm/ and generate per-project values.yaml
        copyHelmChart(helmDir)
        val helmValues = buildHelmValues(blueprint, projectName, userVariables)
        helmDir.resolve("values.yaml").toFile().writeText(helmValues)

        // Generate kind-config.yaml in workspace root for local cluster creation
        val kindConfig = buildKindConfig(projectName)
        workspaceDir.resolve("kind-config.yaml").toFile().writeText(kindConfig)

        return GenerateResult(
            workspacePath = workspaceDir.toString(),
            mode = mode,
            outputType = blueprint.outputType,
            awsResources = blueprint.awsResources.map { it.type },
            nextStep = if (mode == "LOCAL") {
                "Start kind cluster: kind create cluster --name gentepede-local --config ${workspaceDir}/kind-config.yaml\n" +
                "Then run validate_infrastructure_package."
            } else {
                "Run validate_infrastructure_package to check Terraform syntax, checkov, and kube-score."
            },
            warnings = warnings
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // VALIDATION
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Runs static analysis on an existing workspace: terraform init/validate,
     * checkov (abort on HIGH+CRITICAL), and kube-score (TERRAFORM_K8S only).
     *
     * No credential pre-flight — this tool makes zero AWS API calls.
     *
     * @param projectName the workspace to validate
     * @return [ValidationResult] describing passed/failed checks
     * @throws IllegalStateException if the workspace does not exist
     */
    fun validateWorkspace(projectName: String): ValidationResult {
        val workspaceDir = workspacesRoot.resolve(projectName)
        check(workspaceDir.toFile().exists()) {
            "Workspace '$projectName' not found. Run generate_infrastructure_package first."
        }

        val terraformDir = resolveTerraformDir(workspaceDir)

        // terraform init — required before validate; safe to run multiple times
        runProcess(
            listOf("terraform", "init", "-no-color"),
            directory = terraformDir.toFile(),
            allowedExitCodes = setOf(0)
        )

        // terraform validate
        val validateResult = runProcess(
            listOf("terraform", "validate", "-no-color"),
            directory = terraformDir.toFile(),
            allowedExitCodes = setOf(0)
        )

        if (validateResult.exitCode != 0) {
            return ValidationResult(
                terraformValid = false,
                checkovPassed = false,
                checkovSkipped = false,
                summary = "terraform validate failed:\n${validateResult.stderr}"
            )
        }

        // checkov scan
        val checkovResult = Validator.runCheckov(terraformDir.toFile())

        // kube-score (TERRAFORM_K8S only)
        val isK8s = workspaceDir.resolve("helm").toFile().exists()
        val kubeScoreResult = if (isK8s) {
            Validator.runKubeScore(workspaceDir.toFile(), projectName)
        } else {
            KubeScoreResult(passed = true, skipped = true, findings = emptyList())
        }

        val summary = buildValidationSummary(validateResult, checkovResult, kubeScoreResult)

        return ValidationResult(
            terraformValid = true,
            checkovPassed = checkovResult.passed,
            checkovSkipped = checkovResult.skipped,
            checkovFindings = checkovResult.findings,
            kubeScorePassed = kubeScoreResult.passed,
            kubeScoreSkipped = kubeScoreResult.skipped,
            kubeScoreFindings = kubeScoreResult.findings,
            summary = summary
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PLANNING
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Runs `terraform plan`, generates a cost estimate, and writes the plan checksum
     * to `gentepede.lock.json`.
     *
     * The plan is saved as `gentepede.tfplan` (binary). A JSON representation is
     * written to `gentepede-plan.json` via FileOutputStream — not shell redirection,
     * because ProcessBuilder has no shell.
     *
     * @param projectName the workspace to plan
     * @return [PlanResult] with resource changes, cost estimate, and K8s manifests
     * @throws ProcessExecutionException if terraform fails
     */
    fun planWorkspace(projectName: String): PlanResult {
        val workspaceDir = workspacesRoot.resolve(projectName)
        check(workspaceDir.toFile().exists()) {
            "Workspace '$projectName' not found. Run generate_infrastructure_package first."
        }

        val terraformDir = resolveTerraformDir(workspaceDir)

        // PRODUCTION: confirm identity before any AWS API call
        val callerIdentity = if (mode == "PRODUCTION") {
            Validator.getCallerIdentity()
        } else null

        // terraform init (idempotent)
        runProcess(
            listOf("terraform", "init", "-no-color"),
            directory = terraformDir.toFile(),
            allowedExitCodes = setOf(0)
        )

        // terraform plan — saves binary plan to gentepede.tfplan
        runProcess(
            listOf("terraform", "plan", "-out=gentepede.tfplan", "-no-color"),
            directory = terraformDir.toFile(),
            allowedExitCodes = setOf(0)
        )

        // terraform show -json — capture stdout into gentepede-plan.json (NOT shell >)
        val showResult = runProcess(
            listOf("terraform", "show", "-json", "gentepede.tfplan"),
            directory = terraformDir.toFile(),
            allowedExitCodes = setOf(0)
        )
        val planJsonFile = terraformDir.resolve("gentepede-plan.json").toFile()
        FileOutputStream(planJsonFile).use { it.write(showResult.stdout.toByteArray()) }

        // Parse plan JSON for human-readable summary
        val planJson = Json.parseToJsonElement(showResult.stdout).jsonObject
        val (toCreate, toModify, toDestroy, resources) = parsePlanChanges(planJson)

        // Compute SHA-256 of the binary plan file
        val planFile = terraformDir.resolve("gentepede.tfplan").toFile()
        val checksum = "sha256:" + sha256Hex(planFile.readBytes())

        // Write plan-time lock file
        val lock = GentepedeLock(
            blueprintId = resolveCurrentBlueprintId(workspaceDir),
            terraformProviderVersion = resolveCurrentProviderVersion(workspaceDir),
            plannedAt = Instant.now().toString(),
            planFileChecksum = checksum
        )
        writeLockFile(workspaceDir, lock)

        // infracost (graceful skip if not in PATH)
        val costEstimate = Validator.runInfracost(terraformDir.toFile(), planJsonFile.name)

        // Rendered Helm manifests (TERRAFORM_K8S only)
        val helmManifests = if (workspaceDir.resolve("helm").toFile().exists()) {
            runHelmTemplate(workspaceDir.toFile(), projectName)
        } else null

        return PlanResult(
            callerIdentity = callerIdentity,
            toCreate = toCreate,
            toModify = toModify,
            toDestroy = toDestroy,
            resources = resources,
            estimatedMonthlyCost = costEstimate.cost,
            costSkipped = costEstimate.skipped,
            renderedHelmManifests = helmManifests,
            planFilePath = planFile.absolutePath,
            lockFilePath = workspaceDir.resolve("gentepede.lock.json").toString()
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // APPLY
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Applies the previously reviewed plan. Verifies the plan file checksum before
     * applying, backs up the state file, then runs `terraform apply gentepede.tfplan`.
     *
     * For TERRAFORM_K8S blueprints, also runs `helm upgrade --install` after
     * Terraform succeeds.
     *
     * @param projectName the workspace to apply
     * @return [ApplyResult] with apply output, backup path, and optional Helm status
     * @throws ProcessExecutionException if checksum mismatch, plan missing, or apply fails
     */
    fun applyWorkspace(projectName: String): ApplyResult {
        val workspaceDir = workspacesRoot.resolve(projectName)
        check(workspaceDir.toFile().exists()) {
            "Workspace '$projectName' not found. Run generate_infrastructure_package first."
        }

        val terraformDir = resolveTerraformDir(workspaceDir)

        // EKS LOCAL: confirm the kind cluster exists before deploying to it
        preflightKindClusterIfLocalK8s(workspaceDir)

        // PRODUCTION: confirm identity
        val callerIdentity = if (mode == "PRODUCTION") {
            Validator.getCallerIdentity()
        } else null

        // Verify plan file checksum against lock file
        val lock = readLockFile(workspaceDir)
            ?: throw ProcessExecutionException("apply", -1, "", "No valid plan file found. Run plan_infrastructure_package first.")

        val planFile = terraformDir.resolve("gentepede.tfplan").toFile()
        if (!planFile.exists()) {
            throw ProcessExecutionException("apply", -1, "", "No valid plan file found. Run plan_infrastructure_package first.")
        }

        val actualChecksum = "sha256:" + sha256Hex(planFile.readBytes())
        if (actualChecksum != lock.planFileChecksum) {
            throw ProcessExecutionException(
                "apply", -1, "",
                "Plan file checksum mismatch. The plan may have been modified or regenerated.\n" +
                "Expected: ${lock.planFileChecksum}\nActual: $actualChecksum\n" +
                "Run plan_infrastructure_package again to create a fresh plan."
            )
        }

        // Backup current state
        val backupPath = backupState(workspaceDir, projectName)

        // terraform apply using the exact reviewed plan
        val applyResult = runProcess(
            listOf("terraform", "apply", "gentepede.tfplan", "-no-color"),
            directory = terraformDir.toFile(),
            allowedExitCodes = setOf(0)
        )

        // Update lock file with apply timestamp and backup path
        val updatedLock = lock.copy(
            lastApplied = Instant.now().toString(),
            stateBackupPath = backupPath
        )
        writeLockFile(workspaceDir, updatedLock)

        // Helm deploy (TERRAFORM_K8S only)
        val helmOutput = if (workspaceDir.resolve("helm").toFile().exists()) {
            val context = if (mode == "LOCAL") "--kube-context=kind-gentepede-local" else null
            runHelmUpgrade(workspaceDir.toFile(), projectName, context)
        } else null

        return ApplyResult(
            callerIdentity = callerIdentity,
            applyOutput = applyResult.stdout,
            stateBackupPath = backupPath,
            helmOutput = helmOutput,
            lockFilePath = workspaceDir.resolve("gentepede.lock.json").toString()
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DRIFT DETECTION
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Detects drift between the Terraform state and real AWS resources.
     *
     * Uses `terraform plan -detailed-exitcode`: exit 0 = no drift, 1 = error, 2 = drift.
     * For TERRAFORM_K8S blueprints, also runs `helm diff upgrade` (graceful skip if
     * the helm-diff plugin is not installed).
     *
     * Drift detection is meaningful primarily in PRODUCTION. In LOCAL mode, LocalStack
     * state is ephemeral — if Docker restarts, all resources appear as drift.
     *
     * @param projectName the workspace to check for drift
     * @return [DriftReport] with Terraform and optional Kubernetes drift details
     */
    fun detectDrift(projectName: String): DriftReport {
        val workspaceDir = workspacesRoot.resolve(projectName)
        check(workspaceDir.toFile().exists()) {
            "Workspace '$projectName' not found."
        }

        val terraformDir = resolveTerraformDir(workspaceDir)

        // EKS LOCAL: confirm the kind cluster exists before any cluster-targeting work
        preflightKindClusterIfLocalK8s(workspaceDir)

        val callerIdentity = if (mode == "PRODUCTION") {
            Validator.getCallerIdentity()
        } else null

        // terraform init if needed
        if (!terraformDir.resolve(".terraform").toFile().exists()) {
            runProcess(
                listOf("terraform", "init", "-no-color"),
                directory = terraformDir.toFile(),
                allowedExitCodes = setOf(0)
            )
        }

        // terraform plan -detailed-exitcode
        // Exit 0 = no changes, exit 1 = error, exit 2 = changes present (drift)
        val planResult = runProcess(
            listOf("terraform", "plan", "-detailed-exitcode", "-out=gentepede-drift.tfplan", "-no-color"),
            directory = terraformDir.toFile(),
            allowedExitCodes = setOf(0, 2) // 2 = drift, not an error
        )

        val hasTerraformDrift = planResult.exitCode == 2
        val terraformDrift = if (hasTerraformDrift) {
            // Capture terraform show -json output in memory (no shell > redirection)
            val showResult = runProcess(
                listOf("terraform", "show", "-json", "gentepede-drift.tfplan"),
                directory = terraformDir.toFile(),
                allowedExitCodes = setOf(0)
            )
            parseDriftChanges(Json.parseToJsonElement(showResult.stdout).jsonObject)
        } else emptyList()

        // Kubernetes drift (TERRAFORM_K8S only)
        val isK8s = workspaceDir.resolve("helm").toFile().exists()
        var kubernetesDrift: String? = null
        var kubernetesDriftSkipped = false

        if (isK8s) {
            val helmDiffResult = Validator.runHelmDiff(workspaceDir.toFile(), projectName)
            kubernetesDrift = helmDiffResult.diff
            kubernetesDriftSkipped = helmDiffResult.skipped
        }

        val hasDrift = hasTerraformDrift || (!kubernetesDriftSkipped && kubernetesDrift?.isNotBlank() == true)

        return DriftReport(
            hasDrift = hasDrift,
            callerIdentity = callerIdentity,
            terraformDrift = terraformDrift,
            kubernetesDrift = kubernetesDrift,
            kubernetesDriftSkipped = kubernetesDriftSkipped,
            recommendation = if (hasDrift) {
                "Run plan_infrastructure_package then apply_infrastructure_package to reconcile."
            } else {
                "Infrastructure matches desired state. No action required."
            }
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DESTROY
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Destroys all infrastructure managed by this workspace.
     *
     * For TERRAFORM_K8S: uninstalls the Helm release and waits for pods to terminate
     * before running `terraform destroy`. Terraform cannot destroy an EKS node group
     * that still has running pods.
     *
     * State backup is created before destroy. Backup files are NEVER deleted.
     * The workspace directory is deleted on success; backups are retained indefinitely.
     *
     * @param projectName the workspace to destroy
     * @return [DestroyResult] with destroy logs and backup path
     */
    fun destroyWorkspace(projectName: String): DestroyResult {
        val workspaceDir = workspacesRoot.resolve(projectName)
        check(workspaceDir.toFile().exists()) {
            "Workspace '$projectName' not found."
        }

        val terraformDir = resolveTerraformDir(workspaceDir)

        // EKS LOCAL: confirm the kind cluster exists before uninstalling from it
        preflightKindClusterIfLocalK8s(workspaceDir)

        val callerIdentity = if (mode == "PRODUCTION") {
            Validator.getCallerIdentity()
        } else null

        var helmOutput: String? = null

        // Uninstall Helm release first (TERRAFORM_K8S only)
        if (workspaceDir.resolve("helm").toFile().exists()) {
            val uninstallResult = runProcess(
                listOf("helm", "uninstall", projectName, "--namespace", projectName),
                directory = workspaceDir.toFile(),
                allowedExitCodes = setOf(0, 1) // 1 = release not found (graceful)
            )
            helmOutput = uninstallResult.stdout

            // Wait for all pods to terminate before Terraform destroys the node group
            runProcess(
                listOf(
                    "kubectl", "wait", "--for=delete", "pod", "--all",
                    "-n", projectName, "--timeout=300s"
                ),
                directory = workspaceDir.toFile(),
                allowedExitCodes = setOf(0, 1) // 1 = no pods found (already gone)
            )
        }

        // Backup current state
        val backupPath = backupState(workspaceDir, projectName)

        // terraform destroy — intentional and explicit (-auto-approve is correct here)
        val destroyResult = runProcess(
            listOf("terraform", "destroy", "-auto-approve", "-no-color"),
            directory = terraformDir.toFile(),
            allowedExitCodes = setOf(0)
        )

        // Delete workspace directory only — backups are retained
        workspaceDir.toFile().deleteRecursively()

        return DestroyResult(
            callerIdentity = callerIdentity,
            destroyOutput = destroyResult.stdout,
            stateBackupPath = backupPath,
            workspaceDeleted = true,
            helmUninstallOutput = helmOutput
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AUDIT
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Runs checkov and kube-score in report-only mode — never aborts, returns all findings.
     *
     * Unlike [validateWorkspace], this does not abort on HIGH or CRITICAL findings.
     * The full report is returned so the LLM can explain findings and suggest remediations.
     *
     * @param projectName the workspace to audit
     * @return [AuditReport] grouped by severity (terraform) and type (kubernetes)
     */
    fun auditWorkspace(projectName: String): AuditReport {
        val workspaceDir = workspacesRoot.resolve(projectName)
        check(workspaceDir.toFile().exists()) {
            "Workspace '$projectName' not found."
        }

        val terraformDir = resolveTerraformDir(workspaceDir)
        val isK8s = workspaceDir.resolve("helm").toFile().exists()

        val checkovAudit = Validator.runCheckovAudit(terraformDir.toFile())
        val kubeAudit = if (isK8s) {
            Validator.runKubeScoreAudit(workspaceDir.toFile(), projectName)
        } else KubeAuditResult(findings = emptyMap())

        val criticalCount = (checkovAudit.findings["critical"]?.size ?: 0) +
                (kubeAudit.findings["critical"]?.size ?: 0)
        val highCount = checkovAudit.findings["high"]?.size ?: 0
        val mediumCount = checkovAudit.findings["medium"]?.size ?: 0
        val lowCount = checkovAudit.findings["low"]?.size ?: 0

        return AuditReport(
            terraformFindings = checkovAudit.findings,
            kubernetesFindings = kubeAudit.findings,
            summary = "$criticalCount critical, $highCount high, $mediumCount medium, $lowCount low findings"
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Determines the Terraform working directory within the workspace.
     *
     * TERRAFORM_ONLY: the workspace root itself.
     * TERRAFORM_K8S: the `terraform/` subdirectory.
     */
    private fun resolveTerraformDir(workspaceDir: Path): Path {
        val terraformSubdir = workspaceDir.resolve("terraform")
        return if (terraformSubdir.toFile().exists()) terraformSubdir else workspaceDir
    }

    /**
     * For EKS (TERRAFORM_K8S) workspaces in LOCAL mode, verifies the `gentepede-local`
     * kind cluster exists before any operation that targets it (apply, drift, destroy).
     *
     * InfrastructureService never auto-creates the cluster — the user owns its lifecycle.
     * Aborting here with setup instructions is clearer than letting helm/kubectl fail
     * later with a cryptic "context not found" error. No-op in PRODUCTION mode and for
     * TERRAFORM_ONLY workspaces (which have no `helm/` directory).
     *
     * @throws IllegalStateException if the cluster (or `kind` itself) is missing
     */
    private fun preflightKindClusterIfLocalK8s(workspaceDir: Path) {
        val isK8s = workspaceDir.resolve("helm").toFile().exists()
        if (mode == "LOCAL" && isK8s && !Validator.kindClusterExists()) {
            throw IllegalStateException(
                "kind cluster 'gentepede-local' not found.\n" +
                "Run: kind create cluster --name gentepede-local\n" +
                "Then re-run this tool."
            )
        }
    }

    /** Copies `templates/{family}/` from the project classpath into [targetDir]. */
    private fun copyTemplateFamily(templateFamily: TemplateFamily, targetDir: Path) {
        val files = listOf("main.tf", "variables.tf")
        for (file in files) {
            val resourcePath = "templates/${templateFamily.name}/$file"
            val stream = Thread.currentThread().contextClassLoader
                .getResourceAsStream(resourcePath)

            if (stream != null) {
                val target = targetDir.resolve(file).toFile()
                target.outputStream().use { out -> stream.copyTo(out) }
            } else {
                // Fall back to reading from the project working directory (test environments)
                val sourceFile = Paths.get("templates", templateFamily.name, file).toFile()
                if (sourceFile.exists()) {
                    sourceFile.copyTo(targetDir.resolve(file).toFile(), overwrite = true)
                }
            }
        }
    }

    /**
     * Copies the Helm chart template into [helmDir].
     *
     * Tries the JAR classpath first (fat JAR execution), then falls back to the
     * project working directory (IDE / test execution where helm-chart/ is on disk).
     */
    private fun copyHelmChart(helmDir: Path) {
        // Classpath path (inside fat JAR — bundled by Gradle via srcDir(".") + include("helm-chart/**"))
        val helmFiles = listOf(
            "helm-chart/Chart.yaml",
            "helm-chart/values.yaml",
            "helm-chart/templates/deployment.yaml",
            "helm-chart/templates/service.yaml",
            "helm-chart/templates/hpa.yaml",
            "helm-chart/templates/network-policy.yaml",
            "helm-chart/templates/resource-quota.yaml"
        )

        var usedClasspath = false
        for (resourcePath in helmFiles) {
            val stream = Thread.currentThread().contextClassLoader.getResourceAsStream(resourcePath)
            if (stream != null) {
                val relativePath = resourcePath.removePrefix("helm-chart/")
                val target = helmDir.resolve(relativePath).toFile()
                target.parentFile.mkdirs()
                target.outputStream().use { out -> stream.copyTo(out) }
                usedClasspath = true
            }
        }

        // Fallback: copy from project working directory (test / development)
        if (!usedClasspath) {
            val helmSource = Paths.get("helm-chart")
            if (helmSource.toFile().exists()) {
                helmSource.toFile().copyRecursively(helmDir.toFile(), overwrite = true)
            }
        }
    }

    /**
     * Builds the `terraform.tfvars` content by merging blueprint defaults with
     * user-supplied variables.
     *
     * @param blueprint     the blueprint providing default values
     * @param userVariables caller-supplied overrides
     * @return HCL tfvars file content as a string
     */
    internal fun buildTfvarsContent(
        blueprint: Blueprint,
        userVariables: Map<String, JsonElement>
    ): String {
        val merged = mutableMapOf<String, JsonElement>()

        // Start with blueprint defaults
        for (variable in blueprint.variables) {
            variable.default?.let { merged[variable.name] = it }
        }

        // Override with user-supplied values
        merged.putAll(userVariables)

        // Derive data-tier toggles (enable_rds / enable_dynamodb / enable_redis) from
        // the blueprint's declared awsResources so a shared template family provisions
        // only the data tier the blueprint actually asks for. Caller-supplied values win.
        injectDataTierToggles(blueprint, merged)

        val sb = StringBuilder()
        sb.appendLine("# Generated by Gentepede MCP — do not edit manually")
        sb.appendLine("# Blueprint: ${blueprint.blueprintId}")
        sb.appendLine()

        for ((key, value) in merged) {
            when (value) {
                is JsonPrimitive -> {
                    val v = value.content
                    if (value.isString) {
                        sb.appendLine("""$key = "$v"""")
                    } else {
                        sb.appendLine("$key = $v")
                    }
                }
                else -> sb.appendLine("$key = ${value.toString()}")
            }
        }

        return sb.toString()
    }

    /**
     * Adds `enable_rds` / `enable_dynamodb` / `enable_redis` toggles to [merged],
     * derived from the blueprint's declared [Blueprint.awsResources].
     *
     * Only the flags the blueprint's template family actually declares are added, so no
     * undeclared variable ever reaches `terraform.tfvars`. Entries already present
     * (caller-supplied) are left untouched. The lambda family provisions all of its
     * declared resources unconditionally, so it gets no toggles.
     */
    private fun injectDataTierToggles(
        blueprint: Blueprint,
        merged: MutableMap<String, JsonElement>
    ) {
        val types = blueprint.awsResources.map { it.type }.toSet()
        when (blueprint.templateFamily) {
            TemplateFamily.ecs -> {
                merged.putIfAbsent("enable_rds", JsonPrimitive("RDS_POSTGRES" in types))
                merged.putIfAbsent("enable_dynamodb", JsonPrimitive("DYNAMODB_TABLE" in types))
                merged.putIfAbsent("enable_redis", JsonPrimitive("ELASTICACHE_REDIS" in types))
            }
            TemplateFamily.eks -> {
                merged.putIfAbsent("enable_rds", JsonPrimitive("RDS_POSTGRES" in types))
            }
            TemplateFamily.lambda -> {
                // lambda blueprints provision every declared resource — no toggles needed
            }
        }
    }

    /**
     * Generates `providers.tf` content at runtime based on [mode].
     *
     * LOCAL: LocalStack endpoints at http://localhost:4566.
     * PRODUCTION: Standard AWS provider + S3 remote state backend with DynamoDB locking.
     * The provider version comes from [blueprint.terraformProviderVersion] — never hardcoded.
     */
    internal fun buildProvidersContent(
        blueprint: Blueprint,
        projectName: String,
        userVariables: Map<String, JsonElement>
    ): String {
        val version = blueprint.terraformProviderVersion
        val region = (userVariables["aws_region"] as? JsonPrimitive)?.content ?: "us-east-1"

        return if (mode == "LOCAL") {
            """
# providers.tf — LOCAL mode (generated by Gentepede MCP)
# Routes all AWS API calls to LocalStack running at http://localhost:4566.
# NEVER commit this file — it is regenerated at workspace creation time.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= $version"
    }
  }
}

provider "aws" {
  region                      = var.aws_region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    s3          = "http://localhost:4566"
    ec2         = "http://localhost:4566"
    iam         = "http://localhost:4566"
    rds         = "http://localhost:4566"
    dynamodb    = "http://localhost:4566"
    ecs         = "http://localhost:4566"
    ecr         = "http://localhost:4566"
    eks         = "http://localhost:4566"
    elasticache = "http://localhost:4566"
    kms         = "http://localhost:4566"
    cloudwatch  = "http://localhost:4566"
    lambda      = "http://localhost:4566"
    apigateway  = "http://localhost:4566"
    cloudfront  = "http://localhost:4566"
    sts         = "http://localhost:4566"
  }
}
""".trimIndent()
        } else {
            """
# providers.tf — PRODUCTION mode (generated by Gentepede MCP)
# Uses real AWS credentials from the environment or named profile.
# The S3 backend and DynamoDB lock table must exist before first apply.
# See docs/12-end-to-end-walkthrough.md Phase 7 for setup commands.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= $version"
    }
  }

  backend "s3" {
    bucket         = "$projectName-tfstate"
    key            = "gentepede/$projectName/terraform.tfstate"
    region         = "$region"
    dynamodb_table = "$projectName-tfstate-lock"
    encrypt        = true
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}
""".trimIndent()
        }
    }

    /**
     * Generates a per-project `helm/values.yaml` with blueprint-specific overrides.
     *
     * InfrastructureService sets containerPort and health paths based on the blueprint's
     * framework: Spring Boot gets port 8080 and /actuator/health paths; others get
     * their framework defaults.
     */
    internal fun buildHelmValues(
        blueprint: Blueprint,
        projectName: String,
        userVariables: Map<String, JsonElement>
    ): String {
        val image = (userVariables["container_image"] as? JsonPrimitive)?.content ?: ""
        val tag = (userVariables["image_tag"] as? JsonPrimitive)?.content ?: ""
        val env = (userVariables["environment"] as? JsonPrimitive)?.content ?: "dev"

        val (containerPort, livenessPath, readinessPath) = when {
            blueprint.techStack.framework.contains("Spring Boot", ignoreCase = true) ->
                Triple(8080, "/actuator/health", "/actuator/health/readiness")
            blueprint.techStack.framework.contains("Node.js", ignoreCase = true) ->
                Triple(3000, "/health", "/ready")
            blueprint.techStack.framework.contains("FastAPI", ignoreCase = true) ->
                Triple(8000, "/health", "/ready")
            blueprint.techStack.framework.contains("Ktor", ignoreCase = true) ->
                Triple(8080, "/health", "/ready")
            else -> Triple(8080, "/health", "/ready")
        }

        return """
# values.yaml — generated by Gentepede MCP for project '$projectName'
# Blueprint: ${blueprint.blueprintId}
# Do not edit manually — regenerate via generate_infrastructure_package.

replicaCount: 2

image:
  repository: "${image.substringBeforeLast(":")}"
  tag: "${tag.ifEmpty { image.substringAfterLast(":") }}"
  pullPolicy: IfNotPresent

containerPort: $containerPort

health:
  liveness:
    path: $livenessPath
  readiness:
    path: $readinessPath

resources:
  requests:
    cpu: "250m"
    memory: "256Mi"
  limits:
    cpu: "500m"
    memory: "512Mi"

autoscaling:
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70

servicePort: 80

projectName: "$projectName"
environment: "$env"
namespace: "$projectName"
""".trimIndent()
    }

    /** Generates a `kind-config.yaml` for creating a local Kubernetes cluster. */
    private fun buildKindConfig(projectName: String): String {
        return """
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: gentepede-local
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 8080
        protocol: TCP
      - containerPort: 443
        hostPort: 8443
        protocol: TCP
  - role: worker
  - role: worker
""".trimIndent()
    }

    /**
     * Creates a timestamped backup of `terraform.tfstate` before apply or destroy.
     *
     * @param workspaceDir the workspace containing the state file
     * @param projectName  used to construct the backup directory path
     * @return absolute path to the backup file (included in tool responses)
     */
    private fun backupState(workspaceDir: Path, projectName: String): String {
        val stateFile = resolveTerraformDir(workspaceDir).resolve("terraform.tfstate").toFile()
        val timestamp = Instant.now().toString().replace(":", "-")
        val backupDir = backupsRoot.resolve(projectName)
        Files.createDirectories(backupDir)
        val backupFile = backupDir.resolve("$timestamp.tfstate").toFile()

        if (stateFile.exists()) {
            stateFile.copyTo(backupFile, overwrite = false)
        } else {
            backupFile.writeText("{}") // empty state placeholder
        }

        return backupFile.absolutePath
    }

    /** Reads `gentepede.lock.json` from the workspace root. Returns null if missing. */
    private fun readLockFile(workspaceDir: Path): GentepedeLock? {
        val lockFile = workspaceDir.resolve("gentepede.lock.json").toFile()
        if (!lockFile.exists()) return null
        return json.decodeFromString<GentepedeLock>(lockFile.readText())
    }

    /** Writes [lock] to `gentepede.lock.json` in the workspace root (not in terraform/). */
    private fun writeLockFile(workspaceDir: Path, lock: GentepedeLock) {
        val lockFile = workspaceDir.resolve("gentepede.lock.json").toFile()
        lockFile.writeText(Json.encodeToString(GentepedeLock.serializer(), lock))
    }

    /** Computes the SHA-256 hex digest of [bytes]. */
    private fun sha256Hex(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
        return digest.digest(bytes).joinToString("") { "%02x".format(it) }
    }

    /** Parses blueprint ID from the lock file or from the providers.tf content. */
    private fun resolveCurrentBlueprintId(workspaceDir: Path): String {
        val existingLock = readLockFile(workspaceDir)
        if (existingLock != null) return existingLock.blueprintId
        // Fall back: read from terraform.tfvars comment
        val tfvarsFile = resolveTerraformDir(workspaceDir).resolve("terraform.tfvars").toFile()
        if (tfvarsFile.exists()) {
            val comment = tfvarsFile.readLines().find { it.startsWith("# Blueprint:") }
            if (comment != null) return comment.removePrefix("# Blueprint:").trim()
        }
        return "unknown"
    }

    /** Resolves the Terraform provider version from the lock file or providers.tf. */
    private fun resolveCurrentProviderVersion(workspaceDir: Path): String {
        val existingLock = readLockFile(workspaceDir)
        if (existingLock != null) return existingLock.terraformProviderVersion
        val providersFile = resolveTerraformDir(workspaceDir).resolve("providers.tf").toFile()
        if (providersFile.exists()) {
            val line = providersFile.readLines().find { it.contains("version =") }
            if (line != null) {
                return line.substringAfter("\"").substringBefore("\"").removePrefix("= ").trim()
            }
        }
        return "unknown"
    }

    /** Parses the `resource_changes` array in a Terraform plan JSON. */
    private fun parsePlanChanges(planJson: JsonObject): PlanChanges {
        val changes = planJson["resource_changes"]?.jsonArray ?: return PlanChanges(0, 0, 0, emptyList())
        var toCreate = 0; var toModify = 0; var toDestroy = 0
        val resources = mutableListOf<PlannedResource>()

        for (change in changes) {
            val obj = change.jsonObject
            val address = obj["address"]?.jsonPrimitive?.content ?: continue
            val actions = obj["change"]?.jsonObject?.get("actions")?.jsonArray
                ?.mapNotNull { it.jsonPrimitive.content } ?: continue

            val action = when {
                "create" in actions -> "CREATE"
                "delete" in actions && "create" in actions -> "REPLACE"
                "update" in actions -> "MODIFY"
                "delete" in actions -> "DESTROY"
                "no-op" in actions -> continue
                else -> continue
            }
            when (action) {
                "CREATE" -> toCreate++
                "MODIFY" -> toModify++
                "DESTROY", "REPLACE" -> toDestroy++
            }
            resources.add(PlannedResource(address, action))
        }
        return PlanChanges(toCreate, toModify, toDestroy, resources)
    }

    private data class PlanChanges(
        val toCreate: Int,
        val toModify: Int,
        val toDestroy: Int,
        val resources: List<PlannedResource>
    )

    /** Parses drift changes from a `terraform show -json` output. */
    private fun parseDriftChanges(planJson: JsonObject): List<DriftItem> {
        val changes = planJson["resource_changes"]?.jsonArray ?: return emptyList()
        return changes.mapNotNull { change ->
            val obj = change.jsonObject
            val address = obj["address"]?.jsonPrimitive?.content ?: return@mapNotNull null
            val actions = obj["change"]?.jsonObject?.get("actions")?.jsonArray
                ?.mapNotNull { it.jsonPrimitive.content } ?: return@mapNotNull null
            if ("no-op" in actions) return@mapNotNull null
            val changeType = when {
                "create" in actions -> "CREATE"
                "delete" in actions && "create" in actions -> "REPLACE"
                "update" in actions -> "MODIFIED"
                "delete" in actions -> "DESTROY"
                else -> return@mapNotNull null
            }
            DriftItem(address = address, change = changeType)
        }
    }

    /** Runs `helm template {project} helm/ -f helm/values.yaml` from workspaceDir. */
    private fun runHelmTemplate(workspaceDir: File, projectName: String): String? {
        return try {
            val result = runProcess(
                listOf("helm", "template", projectName, "helm/", "-f", "helm/values.yaml"),
                directory = workspaceDir,
                allowedExitCodes = setOf(0)
            )
            result.stdout
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Runs `helm upgrade --install` targeting the correct cluster.
     *
     * LOCAL: targets `kind-gentepede-local` kubeconfig context.
     * PRODUCTION: targets the current KUBECONFIG context.
     */
    private fun runHelmUpgrade(workspaceDir: File, projectName: String, context: String?): String {
        val cmd = mutableListOf(
            "helm", "upgrade", "--install", projectName, "helm/",
            "--namespace", projectName,
            "--create-namespace"
        )
        if (context != null) cmd.add(context)

        val result = runProcess(cmd, directory = workspaceDir, allowedExitCodes = setOf(0))
        return result.stdout
    }

    private fun buildValidationSummary(
        validateResult: ProcessResult,
        checkovResult: CheckovResult,
        kubeScoreResult: KubeScoreResult
    ): String {
        val lines = mutableListOf<String>()
        lines.add("terraform validate: ${if (validateResult.exitCode == 0) "PASSED" else "FAILED"}")
        lines.add("checkov: ${when {
            checkovResult.skipped -> "SKIPPED (not installed)"
            checkovResult.passed -> "PASSED (${checkovResult.findings.size} findings, none HIGH/CRITICAL)"
            else -> "FAILED (${checkovResult.findings.count { it.severity in listOf("HIGH","CRITICAL") }} HIGH/CRITICAL findings)"
        }}")
        if (!kubeScoreResult.skipped) {
            lines.add("kube-score: ${if (kubeScoreResult.passed) "PASSED" else "FAILED (CRITICAL finding)"}")
        } else {
            lines.add("kube-score: SKIPPED (helm or kube-score not installed, or not a TERRAFORM_K8S blueprint)")
        }
        return lines.joinToString("\n")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PROCESSBUILDER
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Runs an external command via ProcessBuilder.
     *
     * Design notes:
     * - Stdout and stderr are consumed on separate threads to prevent pipe-buffer deadlock:
     *   if one stream fills its OS buffer while the process waits to write the other,
     *   and we read sequentially, we deadlock.
     * - 30-minute timeout: complex Terraform applies on real AWS (multi-AZ RDS, EKS
     *   cluster creation) can exceed 20 minutes.
     * - JVM shutdown hook: if the JVM exits while a process is running (e.g. Ctrl+C),
     *   the child process is destroyed so it does not continue running orphaned.
     * - .directory() must be set on every call — never rely on the JVM's inherited CWD,
     *   which is the MCP server launch path, not the workspace.
     *
     * @param command          the command and its arguments as a list (no shell — no >, |, &&)
     * @param directory        working directory for the process (required — never null)
     * @param allowedExitCodes exit codes that are not treated as failures
     * @return [ProcessResult] with exit code, stdout, and stderr
     * @throws ProcessExecutionException on timeout or unexpected exit code
     */
    internal fun runProcess(
        command: List<String>,
        directory: File,
        allowedExitCodes: Set<Int> = setOf(0)
    ): ProcessResult {
        val pb = ProcessBuilder(command)
            .directory(directory)
            .redirectErrorStream(false)

        val process = pb.start()

        // Register shutdown hook so the child process does not outlive the JVM
        val hook = Thread { process.destroyForcibly() }
        Runtime.getRuntime().addShutdownHook(hook)

        // Consume stdout and stderr on separate threads to prevent pipe-buffer deadlock
        val stdoutBuilder = StringBuilder()
        val stderrBuilder = StringBuilder()

        val stdoutThread = Thread {
            process.inputStream.bufferedReader().use { reader ->
                reader.lines().forEach { stdoutBuilder.appendLine(it) }
            }
        }
        val stderrThread = Thread {
            process.errorStream.bufferedReader().use { reader ->
                reader.lines().forEach { stderrBuilder.appendLine(it) }
            }
        }

        stdoutThread.start()
        stderrThread.start()

        // 30-minute timeout — complex AWS Terraform applies can take 20+ minutes
        val finished = process.waitFor(30, TimeUnit.MINUTES)

        stdoutThread.join()
        stderrThread.join()

        // Remove shutdown hook — process has completed normally
        Runtime.getRuntime().removeShutdownHook(hook)

        if (!finished) {
            process.destroyForcibly()
            throw ProcessExecutionException(
                command.joinToString(" "),
                -1,
                stdoutBuilder.toString(),
                "Process timed out after 30 minutes."
            )
        }

        val exitCode = process.exitValue()
        if (exitCode !in allowedExitCodes) {
            throw ProcessExecutionException(
                command.joinToString(" "),
                exitCode,
                stdoutBuilder.toString(),
                stderrBuilder.toString()
            )
        }

        return ProcessResult(
            exitCode = exitCode,
            stdout = stdoutBuilder.toString(),
            stderr = stderrBuilder.toString()
        )
    }
}

/** Result of a subprocess execution. */
data class ProcessResult(val exitCode: Int, val stdout: String, val stderr: String)

/** Result of a checkov scan. */
data class CheckovResult(
    val passed: Boolean,
    val skipped: Boolean,
    val findings: List<SecurityFinding>
)

/** Result of a kube-score scan. */
data class KubeScoreResult(
    val passed: Boolean,
    val skipped: Boolean,
    val findings: List<String>
)

/** Result of `helm diff upgrade`. */
data class HelmDiffResult(val diff: String?, val skipped: Boolean)

/** Result of a checkov audit (full report, all severities). */
data class CheckovAuditResult(val findings: Map<String, List<AuditFinding>>)

/** Result of a kube-score audit (full report). */
data class KubeAuditResult(val findings: Map<String, List<KubeAuditFinding>>)

/** Result of `infracost breakdown`. */
data class InfracostResult(val cost: String?, val skipped: Boolean)
