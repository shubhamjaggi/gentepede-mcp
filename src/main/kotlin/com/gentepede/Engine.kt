package com.gentepede

import io.modelcontextprotocol.kotlin.sdk.types.*
import kotlinx.serialization.json.*

/**
 * Engine — thin MCP tool handler that delegates all business logic to [InfrastructureService].
 *
 * Responsibilities:
 * - Extract and validate parameters from MCP tool call arguments
 * - Call the appropriate [InfrastructureService] method
 * - Format the result as a human-readable [CallToolResult] string
 * - Translate [ProcessExecutionException], [IllegalStateException], and
 *   [IllegalArgumentException] into error [CallToolResult] responses
 *
 * Does NOT:
 * - Contain any business logic (that lives in [InfrastructureService])
 * - Parse CLI output (that lives in [Validator])
 * - Manage state (all state lives on disk via [InfrastructureService])
 *
 * Design note: keeping Engine.kt as a thin handler makes [InfrastructureService] fully
 * testable without starting the MCP server. CI can instantiate [InfrastructureService]
 * directly to verify blueprints without any JSON-RPC overhead.
 */
class Engine(private val svc: InfrastructureService = InfrastructureService()) {

    // ─────────────────────────────────────────────────────────────────────────
    // Tool 1: list_available_blueprints
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Lists all bundled blueprints with their metadata.
     *
     * @return [CallToolResult] containing a formatted table of available blueprints
     */
    suspend fun listAvailableBlueprints(): CallToolResult {
        return try {
            val blueprints = svc.listBlueprints()
            val sb = StringBuilder()
            sb.appendLine("Available Blueprints (${blueprints.size})")
            sb.appendLine("=".repeat(60))
            for (bp in blueprints) {
                sb.appendLine()
                sb.appendLine("Blueprint ID:       ${bp.blueprintId}")
                sb.appendLine("Display Name:       ${bp.displayName}")
                sb.appendLine("Description:        ${bp.description}")
                sb.appendLine("Output Type:        ${bp.outputType}")
                sb.appendLine("Template Family:    ${bp.templateFamily}")
                sb.appendLine("Framework:          ${bp.techStack.framework} (${bp.techStack.language})")
                bp.techStack.database?.let { sb.appendLine("Database:           $it") }
                sb.appendLine("AWS Resources:      ${bp.awsResources.map { it.type }.joinToString(", ")}")
                sb.appendLine("Provider Version:   ${bp.terraformProviderVersion}")
                sb.appendLine("Last Verified:      ${bp.lastVerifiedDate}")
                sb.appendLine("-".repeat(60))
            }
            success(sb.toString())
        } catch (e: Exception) {
            error("Failed to list blueprints: ${e.message}")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tool 2: generate_infrastructure_package
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Generates a workspace from a blueprint.
     *
     * @param args must contain: blueprint_name (string), project_name (string), variables (object)
     * @return [CallToolResult] describing the created workspace and next steps
     */
    suspend fun generateInfrastructurePackage(args: JsonObject): CallToolResult {
        val blueprintName = args["blueprint_name"]?.jsonPrimitive?.content
            ?: return error("Missing required parameter: blueprint_name")
        val projectName = args["project_name"]?.jsonPrimitive?.content
            ?: return error("Missing required parameter: project_name")

        if (!projectName.matches(Regex("[a-zA-Z0-9-]+"))) {
            return error("project_name must contain only alphanumeric characters and hyphens")
        }

        val userVariables = args["variables"]?.jsonObject?.toMutableMap() ?: mutableMapOf()
        // Inject project_name into variables so terraform.tfvars includes it
        userVariables["project_name"] = JsonPrimitive(projectName)

        return try {
            val result = svc.generateWorkspace(blueprintName, projectName, userVariables)
            val sb = StringBuilder()

            for (warning in result.warnings) {
                sb.appendLine("⚠ $warning")
                sb.appendLine()
            }

            sb.appendLine("Infrastructure Package Generated")
            sb.appendLine("=".repeat(60))
            sb.appendLine("Project:        $projectName")
            sb.appendLine("Blueprint:      $blueprintName")
            sb.appendLine("Output Type:    ${result.outputType}")
            sb.appendLine("Workspace:      ${result.workspacePath}")
            sb.appendLine()
            sb.appendLine("AWS Resources to Create:")
            for (resource in result.awsResources) {
                sb.appendLine("  - $resource")
            }
            sb.appendLine()
            sb.appendLine("Next Step: ${result.nextStep}")

            success(sb.toString())
        } catch (e: IllegalArgumentException) {
            error(e.message ?: "Invalid arguments")
        } catch (e: ProcessExecutionException) {
            error("Workspace generation failed:\n${e.message}")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tool 3: validate_infrastructure_package
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Runs terraform validate, checkov, and kube-score on an existing workspace.
     *
     * No credential pre-flight — this tool is pure static analysis.
     *
     * @param args must contain: project_name (string)
     * @return [CallToolResult] with structured validation report
     */
    suspend fun validateInfrastructurePackage(args: JsonObject): CallToolResult {
        val projectName = args["project_name"]?.jsonPrimitive?.content
            ?: return error("Missing required parameter: project_name")

        return try {
            val result = svc.validateWorkspace(projectName)
            val sb = StringBuilder()

            sb.appendLine("Validation Report: $projectName")
            sb.appendLine("=".repeat(60))
            sb.appendLine(result.summary)

            if (result.checkovFindings.isNotEmpty()) {
                sb.appendLine()
                sb.appendLine("Checkov Findings:")
                for (f in result.checkovFindings) {
                    sb.appendLine("  [${f.severity}] ${f.checkId} — ${f.resource}")
                    sb.appendLine("    ${f.message}")
                    if (f.remediation.isNotBlank()) sb.appendLine("    Remediation: ${f.remediation}")
                }
            }

            if (result.kubeScoreFindings.isNotEmpty()) {
                sb.appendLine()
                sb.appendLine("kube-score Findings:")
                for (f in result.kubeScoreFindings) {
                    sb.appendLine("  $f")
                }
            }

            val overallPassed = result.terraformValid &&
                    result.checkovPassed &&
                    result.kubeScorePassed

            if (overallPassed) {
                sb.appendLine()
                sb.appendLine("✓ All validation checks passed. Ready to run plan_infrastructure_package.")
            } else {
                sb.appendLine()
                sb.appendLine("✗ Validation failed. Resolve the above findings before planning.")
            }

            if (overallPassed) success(sb.toString()) else error(sb.toString())
        } catch (e: IllegalStateException) {
            error(e.message ?: "Workspace not found")
        } catch (e: ProcessExecutionException) {
            error("Validation failed:\n${e.message}")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tool 4: plan_infrastructure_package
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Runs `terraform plan`, writes the plan checksum, and optionally estimates cost.
     *
     * Prepends caller identity to the response.
     *
     * @param args must contain: project_name (string)
     * @return [CallToolResult] with plan summary, resource list, cost, and K8s manifests
     */
    suspend fun planInfrastructurePackage(args: JsonObject): CallToolResult {
        val projectName = args["project_name"]?.jsonPrimitive?.content
            ?: return error("Missing required parameter: project_name")

        return try {
            val result = svc.planWorkspace(projectName)
            val sb = StringBuilder()

            result.callerIdentity?.let { identity ->
                sb.appendLine("Acting as: ${identity.arn}")
                sb.appendLine("Account:   ${identity.accountId}")
                sb.appendLine("User ID:   ${identity.userId}")
                sb.appendLine()
            }

            sb.appendLine("Terraform Plan Summary: $projectName")
            sb.appendLine("=".repeat(60))
            sb.appendLine("Will CREATE  ${result.toCreate} resources")
            sb.appendLine("Will MODIFY  ${result.toModify} resources")
            sb.appendLine("Will DESTROY ${result.toDestroy} resources")
            sb.appendLine()

            if (result.resources.isNotEmpty()) {
                sb.appendLine("Resource Changes:")
                for (r in result.resources) {
                    sb.appendLine("  [${r.action}] ${r.address}")
                }
            }

            sb.appendLine()
            if (result.costSkipped) {
                sb.appendLine("Cost Estimate: SKIPPED (infracost not installed)")
            } else {
                sb.appendLine("Cost Estimate: ${result.estimatedMonthlyCost ?: "unavailable"}")
            }

            sb.appendLine()
            sb.appendLine("Plan file: ${result.planFilePath}")
            sb.appendLine("Lock file: ${result.lockFilePath}")

            result.renderedHelmManifests?.let { manifests ->
                sb.appendLine()
                sb.appendLine("Rendered Kubernetes Manifests (Helm):")
                sb.appendLine("-".repeat(60))
                sb.appendLine(manifests.take(4000)) // cap manifest output length
                if (manifests.length > 4000) sb.appendLine("... (truncated — run `helm template <project> helm/` in the workspace directory to view the full output)")
            }

            sb.appendLine()
            sb.appendLine("Next Step: Review the plan above, then run apply_infrastructure_package.")

            success(sb.toString())
        } catch (e: IllegalStateException) {
            error(e.message ?: "Workspace not found")
        } catch (e: ProcessExecutionException) {
            error("Plan failed:\n${e.message}")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tool 5: apply_infrastructure_package
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Applies the previously reviewed plan.
     *
     * Verifies plan file checksum before applying. Creates a state backup.
     * For TERRAFORM_K8S blueprints, also runs helm upgrade --install.
     *
     * @param args must contain: project_name (string)
     * @return [CallToolResult] with apply output, backup path, and Helm status
     */
    suspend fun applyInfrastructurePackage(args: JsonObject): CallToolResult {
        val projectName = args["project_name"]?.jsonPrimitive?.content
            ?: return error("Missing required parameter: project_name")

        return try {
            val result = svc.applyWorkspace(projectName)
            val sb = StringBuilder()

            result.callerIdentity?.let { identity ->
                sb.appendLine("Acting as: ${identity.arn}")
                sb.appendLine("Account:   ${identity.accountId}")
                sb.appendLine()
            }

            sb.appendLine("Apply Complete: $projectName")
            sb.appendLine("=".repeat(60))
            sb.appendLine(result.applyOutput.take(3000))

            sb.appendLine()
            sb.appendLine("State backup: ${result.stateBackupPath}")
            sb.appendLine("Lock file updated: ${result.lockFilePath}")

            result.helmOutput?.let {
                sb.appendLine()
                sb.appendLine("Helm Deploy Output:")
                sb.appendLine(it)
            }

            success(sb.toString())
        } catch (e: ProcessExecutionException) {
            error("Apply failed:\n${e.message}")
        } catch (e: IllegalStateException) {
            error(e.message ?: "Workspace error")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tool 6: detect_drift
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Detects infrastructure drift between Terraform state and real AWS.
     *
     * @param args must contain: project_name (string)
     * @return [CallToolResult] with combined Terraform and Kubernetes drift report
     */
    suspend fun detectDrift(args: JsonObject): CallToolResult {
        val projectName = args["project_name"]?.jsonPrimitive?.content
            ?: return error("Missing required parameter: project_name")

        return try {
            val result = svc.detectDrift(projectName)
            val sb = StringBuilder()

            result.callerIdentity?.let { identity ->
                sb.appendLine("Acting as: ${identity.arn}")
                sb.appendLine("Account:   ${identity.accountId}")
                sb.appendLine()
            }

            sb.appendLine("Drift Detection Report: $projectName")
            sb.appendLine("=".repeat(60))
            sb.appendLine("Has drift: ${result.hasDrift}")

            if (result.terraformDrift.isNotEmpty()) {
                sb.appendLine()
                sb.appendLine("Terraform Drift:")
                for (d in result.terraformDrift) {
                    sb.appendLine("  [${d.change}] ${d.address}")
                    if (d.detail.isNotBlank()) sb.appendLine("    ${d.detail}")
                }
            } else {
                sb.appendLine("Terraform: No drift detected.")
            }

            if (result.kubernetesDriftSkipped) {
                sb.appendLine()
                sb.appendLine("Kubernetes: SKIPPED (helm-diff plugin not installed)")
                sb.appendLine("  Install with: helm plugin install https://github.com/databus23/helm-diff")
            } else {
                result.kubernetesDrift?.let { diff ->
                    if (diff.isNotBlank()) {
                        sb.appendLine()
                        sb.appendLine("Kubernetes Drift:")
                        sb.appendLine(diff)
                    } else {
                        sb.appendLine()
                        sb.appendLine("Kubernetes: No drift detected.")
                    }
                }
            }

            sb.appendLine()
            sb.appendLine("Recommendation: ${result.recommendation}")

            success(sb.toString())
        } catch (e: IllegalStateException) {
            error(e.message ?: "Workspace not found")
        } catch (e: ProcessExecutionException) {
            error("Drift detection failed:\n${e.message}")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tool 7: destroy_infrastructure_package
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Destroys all infrastructure in the workspace.
     *
     * For TERRAFORM_K8S: uninstalls Helm release and waits for pods to terminate first.
     * Backs up state before destroying. Deletes workspace directory but NOT backups.
     *
     * @param args must contain: project_name (string)
     * @return [CallToolResult] with destroy output and backup path
     */
    suspend fun destroyInfrastructurePackage(args: JsonObject): CallToolResult {
        val projectName = args["project_name"]?.jsonPrimitive?.content
            ?: return error("Missing required parameter: project_name")

        return try {
            val result = svc.destroyWorkspace(projectName)
            val sb = StringBuilder()

            result.callerIdentity?.let { identity ->
                sb.appendLine("Acting as: ${identity.arn}")
                sb.appendLine("Account:   ${identity.accountId}")
                sb.appendLine()
            }

            sb.appendLine("Destroy Complete: $projectName")
            sb.appendLine("=".repeat(60))

            result.helmUninstallOutput?.let {
                sb.appendLine("Helm Uninstall:")
                sb.appendLine(it)
                sb.appendLine()
            }

            sb.appendLine(result.destroyOutput.take(3000))
            sb.appendLine()
            sb.appendLine("Workspace deleted: ${result.workspaceDeleted}")
            sb.appendLine("State backup retained: ${result.stateBackupPath}")
            sb.appendLine("(Backup files are never automatically deleted.)")

            success(sb.toString())
        } catch (e: ProcessExecutionException) {
            error("Destroy failed:\n${e.message}")
        } catch (e: IllegalStateException) {
            error(e.message ?: "Workspace not found")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tool 8: audit_infrastructure_package
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Runs checkov and kube-score in report-only mode — never aborts.
     *
     * Returns all findings grouped by severity so the LLM can explain them
     * and suggest remediations interactively. Unlike validate, this does not
     * abort on HIGH/CRITICAL findings.
     *
     * @param args must contain: project_name (string)
     * @return [CallToolResult] with full structured audit report
     */
    suspend fun auditInfrastructurePackage(args: JsonObject): CallToolResult {
        val projectName = args["project_name"]?.jsonPrimitive?.content
            ?: return error("Missing required parameter: project_name")

        return try {
            val report = svc.auditWorkspace(projectName)
            val sb = StringBuilder()

            sb.appendLine("Security Audit Report: $projectName")
            sb.appendLine("=".repeat(60))
            sb.appendLine("Summary: ${report.summary}")

            for ((severity, findings) in report.terraformFindings) {
                if (findings.isEmpty()) continue
                sb.appendLine()
                sb.appendLine("Terraform — ${severity.uppercase()} (${findings.size}):")
                for (f in findings) {
                    sb.appendLine("  ${f.checkId} — ${f.resource}")
                    if (f.remediation.isNotBlank()) sb.appendLine("    Remediation: ${f.remediation}")
                }
            }

            for ((type, findings) in report.kubernetesFindings) {
                if (findings.isEmpty()) continue
                sb.appendLine()
                sb.appendLine("Kubernetes — ${type.uppercase()} (${findings.size}):")
                for (f in findings) {
                    sb.appendLine("  ${f.objectName}: ${f.check}")
                    sb.appendLine("    ${f.comment}")
                }
            }

            if (report.terraformFindings.isEmpty() && report.kubernetesFindings.isEmpty()) {
                sb.appendLine()
                sb.appendLine("No findings. All security checks passed.")
            }

            success(sb.toString())
        } catch (e: IllegalStateException) {
            error(e.message ?: "Workspace not found")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    private fun success(text: String): CallToolResult =
        CallToolResult(content = listOf(TextContent(text = text)), isError = false)

    private fun error(text: String): CallToolResult =
        CallToolResult(content = listOf(TextContent(text = "Error: $text")), isError = true)
}
