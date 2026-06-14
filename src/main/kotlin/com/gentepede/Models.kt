package com.gentepede

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/**
 * All shared data classes for Gentepede MCP.
 *
 * Centralised here so InfrastructureService, Validator, Engine, and test code share
 * one canonical type definition — no duplication, no divergence.
 * This file does NOT contain business logic; it only defines shapes.
 */

// ─────────────────────────────────────────────
// Enums
// ─────────────────────────────────────────────

/** Whether a blueprint produces only Terraform or both Terraform and a Helm chart. */
enum class OutputType {
    TERRAFORM_ONLY,
    TERRAFORM_K8S
}

/**
 * Template family drives which `templates/{family}/` directory InfrastructureService copies
 * into the workspace. One family per incompatible AWS architecture — no conditional bloat.
 */
enum class TemplateFamily {
    ecs,
    lambda,
    eks
}

// ─────────────────────────────────────────────
// Blueprint schema (mirrors blueprints/*.json)
// ─────────────────────────────────────────────

@Serializable
data class TechStack(
    val language: String,
    val framework: String,
    val database: String? = null
)

@Serializable
data class AwsResource(
    val type: String,
    val required: Boolean,
    val defaultConfig: JsonObject = JsonObject(emptyMap())
)

@Serializable
data class BlueprintVariable(
    val name: String,
    val description: String,
    val type: String,
    val default: kotlinx.serialization.json.JsonElement? = null,
    val required: Boolean
)

@Serializable
data class SecurityBaseline(
    val enableVpcFlowLogs: Boolean,
    val enforceHttps: Boolean
)

/**
 * Represents one blueprint file from `src/main/resources/blueprints/`.
 *
 * A blueprint is a declarative description of an application's AWS infrastructure:
 * which cloud services to create, which Terraform template family to use, and what
 * security baseline to enforce. It does NOT contain Terraform code itself — that
 * lives in `templates/{templateFamily}/`.
 */
@Serializable
data class Blueprint(
    val blueprintId: String,
    val displayName: String,
    val description: String,
    val outputType: OutputType,
    val templateFamily: TemplateFamily,
    val terraformProviderVersion: String,
    val lastVerifiedDate: String,
    val techStack: TechStack,
    val awsResources: List<AwsResource>,
    val variables: List<BlueprintVariable>,
    val securityBaseline: SecurityBaseline
)

// ─────────────────────────────────────────────
// Lock file schema
// ─────────────────────────────────────────────

/**
 * Written to `gentepede.lock.json` in the workspace root.
 *
 * Phase 1 (plan time): blueprintId, terraformProviderVersion, plannedAt, planFileChecksum.
 * Phase 2 (apply time): adds lastApplied and stateBackupPath.
 * The two-phase write ties each apply to the exact plan that was reviewed.
 */
@Serializable
data class GentepedeLock(
    val blueprintId: String,
    val terraformProviderVersion: String,
    val plannedAt: String? = null,
    val planFileChecksum: String? = null,
    val lastApplied: String? = null,
    val stateBackupPath: String? = null
)

// ─────────────────────────────────────────────
// Result types returned by InfrastructureService
// ─────────────────────────────────────────────

/** Outcome of generate_infrastructure_package. */
data class GenerateResult(
    val workspacePath: String,
    val mode: String,
    val outputType: OutputType,
    val awsResources: List<String>,
    val nextStep: String,
    val warnings: List<String> = emptyList()
)

/** Outcome of validate_infrastructure_package. */
data class ValidationResult(
    val terraformValid: Boolean,
    val checkovPassed: Boolean,
    val checkovSkipped: Boolean,
    val checkovFindings: List<SecurityFinding> = emptyList(),
    val kubeScorePassed: Boolean = true,
    val kubeScoreSkipped: Boolean = true,
    val kubeScoreFindings: List<String> = emptyList(),
    val summary: String
)

/** One checkov or kube-score finding. */
data class SecurityFinding(
    val checkId: String,
    val resource: String,
    val severity: String,
    val message: String,
    val remediation: String = ""
)

/** Outcome of plan_infrastructure_package. */
data class PlanResult(
    val callerIdentity: CallerIdentity? = null,
    val toCreate: Int,
    val toModify: Int,
    val toDestroy: Int,
    val resources: List<PlannedResource>,
    val estimatedMonthlyCost: String? = null,
    val costSkipped: Boolean = false,
    val renderedHelmManifests: String? = null,
    val planFilePath: String,
    val lockFilePath: String
)

data class PlannedResource(
    val address: String,
    val action: String
)

/** AWS caller identity returned by `aws sts get-caller-identity`. */
data class CallerIdentity(
    val arn: String,
    val accountId: String,
    val userId: String
)

/** Outcome of apply_infrastructure_package. */
data class ApplyResult(
    val callerIdentity: CallerIdentity? = null,
    val applyOutput: String,
    val stateBackupPath: String,
    val helmOutput: String? = null,
    val lockFilePath: String
)

/** Outcome of detect_drift. */
data class DriftReport(
    val hasDrift: Boolean,
    val callerIdentity: CallerIdentity? = null,
    val terraformDrift: List<DriftItem> = emptyList(),
    val kubernetesDrift: String? = null,
    val kubernetesDriftSkipped: Boolean = false,
    val recommendation: String
)

data class DriftItem(
    val address: String,
    val change: String,
    val detail: String = ""
)

/** Outcome of destroy_infrastructure_package. */
data class DestroyResult(
    val callerIdentity: CallerIdentity? = null,
    val destroyOutput: String,
    val stateBackupPath: String,
    val workspaceDeleted: Boolean,
    val helmUninstallOutput: String? = null
)

/** Outcome of audit_infrastructure_package — never aborts, always full report. */
data class AuditReport(
    val terraformFindings: Map<String, List<AuditFinding>>,
    val kubernetesFindings: Map<String, List<KubeAuditFinding>>,
    val summary: String
)

data class AuditFinding(
    val checkId: String,
    val resource: String,
    val remediation: String
)

data class KubeAuditFinding(
    val objectName: String,
    val check: String,
    val comment: String
)

// ─────────────────────────────────────────────
// Exception type
// ─────────────────────────────────────────────

/**
 * Thrown by ProcessBuilder helpers when a subprocess times out or exits with a fatal
 * non-zero code. Carries both stdout and stderr so callers can surface all output.
 *
 * @param command  the command string that failed (for error messages)
 * @param exitCode the process exit code, or -1 on timeout
 * @param stdout   captured standard output up to the failure point
 * @param stderr   captured standard error up to the failure point
 */
class ProcessExecutionException(
    val command: String,
    val exitCode: Int,
    val stdout: String,
    val stderr: String
) : Exception(
    "Process '$command' failed with exit code $exitCode.\nSTDOUT:\n$stdout\nSTDERR:\n$stderr"
)
