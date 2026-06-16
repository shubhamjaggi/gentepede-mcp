package com.gentepede

import kotlinx.serialization.json.*
import java.io.File
import java.io.OutputStream

/**
 * Validator — all CLI output parsing for external security and cost tools.
 *
 * Centralises the logic for:
 * - checkov JSON output parsing (abort on HIGH/CRITICAL in validate mode; full report in audit mode)
 * - kube-score output parsing (requires `helm template` pipe first — uses Process.outputStream)
 * - infracost cost estimation (graceful skip if not in PATH)
 * - AWS credential pre-flight (`aws sts get-caller-identity`)
 * - `helm diff upgrade` output (graceful skip if helm-diff plugin not installed)
 *
 * Runs kube-score directly via its own ProcessBuilder (piped stdin requires bypassing
 * [InfrastructureService.runProcess]). All other external calls go through [svc.runProcess].
 *
 * Every binary absence is handled with a graceful skip and informational message
 * rather than a hard failure.
 */
object Validator {

    private val svc = InfrastructureService()

    // ─────────────────────────────────────────────────────────────────────────
    // CREDENTIAL PRE-FLIGHT
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Runs `aws sts get-caller-identity` and parses the JSON response.
     *
     * Called before every operation that contacts AWS (plan, apply, drift detection,
     * destroy). If this call fails, the calling tool aborts immediately — never
     * proceed to Terraform without confirmed identity.
     *
     * @return [CallerIdentity] with ARN, account ID, and user ID
     * @throws ProcessExecutionException if `aws sts get-caller-identity` fails
     */
    fun getCallerIdentity(): CallerIdentity {
        val result = try {
            svc.runProcess(
                listOf("aws", "sts", "get-caller-identity"),
                directory = File(System.getProperty("user.home")),
                allowedExitCodes = setOf(0)
            )
        } catch (e: ProcessExecutionException) {
            throw ProcessExecutionException(
                "aws sts get-caller-identity",
                e.exitCode,
                e.stdout,
                "AWS credential pre-flight failed. Ensure AWS credentials are configured.\n" +
                "For environment variables: export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...\n" +
                "For named profiles: export AWS_PROFILE=...\n" +
                "Original error: ${e.stderr}"
            )
        }

        val responseJson = Json.parseToJsonElement(result.stdout).jsonObject
        return CallerIdentity(
            arn = responseJson["Arn"]?.jsonPrimitive?.content ?: "unknown",
            accountId = responseJson["Account"]?.jsonPrimitive?.content ?: "unknown",
            userId = responseJson["UserId"]?.jsonPrimitive?.content ?: "unknown"
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CHECKOV — Validate mode (aborts on HIGH + CRITICAL)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Runs `checkov -d <dir> -o json --compact` and parses results.
     *
     * Abort condition: any finding with severity HIGH or CRITICAL.
     * Rationale: LOW and MEDIUM findings are informational for a shift-left scan but
     * should not block a deployment pipeline — they are better surfaced via
     * `audit_infrastructure_package`. HIGH/CRITICAL represent exploitable misconfigurations
     * like publicly accessible databases or unencrypted storage.
     *
     * Graceful skip if checkov is not in PATH — returns passed=true, skipped=true.
     *
     * @param terraformDir the directory containing Terraform HCL files
     * @return [CheckovResult] with pass/fail decision and finding details
     */
    fun runCheckov(terraformDir: File): CheckovResult {
        if (!isCommandAvailable("checkov")) {
            return CheckovResult(passed = true, skipped = true, findings = emptyList())
        }

        val result = try {
            svc.runProcess(
                listOf("checkov", "-d", ".", "-o", "json", "--compact"),
                directory = terraformDir,
                allowedExitCodes = setOf(0, 1) // checkov exits 1 when it finds issues
            )
        } catch (e: ProcessExecutionException) {
            return CheckovResult(passed = false, skipped = false, findings = listOf(
                SecurityFinding("CHECKOV_RUN_ERROR", "checkov", "ERROR", e.stderr)
            ))
        }

        return parseCheckovOutput(result.stdout, abortOnHighCritical = true)
    }

    /**
     * Runs checkov in audit mode — never aborts, returns all findings grouped by severity.
     *
     * @param terraformDir the directory containing Terraform HCL files
     * @return [CheckovAuditResult] with all findings grouped by severity
     */
    fun runCheckovAudit(terraformDir: File): CheckovAuditResult {
        if (!isCommandAvailable("checkov")) {
            return CheckovAuditResult(findings = emptyMap())
        }

        val result = try {
            svc.runProcess(
                listOf("checkov", "-d", ".", "-o", "json", "--compact"),
                directory = terraformDir,
                allowedExitCodes = setOf(0, 1)
            )
        } catch (_: ProcessExecutionException) {
            return CheckovAuditResult(findings = emptyMap())
        }

        val allFindings = parseCheckovJsonFindings(result.stdout)
        val grouped = allFindings.groupBy { it.severity.lowercase() }
            .mapValues { (_, findings) ->
                findings.map { AuditFinding(it.checkId, it.resource, it.message) }
            }

        return CheckovAuditResult(findings = grouped)
    }

    /**
     * Parses checkov JSON output into a [CheckovResult].
     *
     * checkov outputs an array of check results when scanning multiple files.
     * Each element has `results.failed_checks[]` with severity information.
     */
    private fun parseCheckovOutput(jsonOutput: String, abortOnHighCritical: Boolean): CheckovResult {
        if (jsonOutput.isBlank()) {
            return CheckovResult(passed = true, skipped = false, findings = emptyList())
        }

        val findings = parseCheckovJsonFindings(jsonOutput)
        val criticalOrHigh = findings.filter { it.severity in listOf("HIGH", "CRITICAL") }

        return CheckovResult(
            passed = if (abortOnHighCritical) criticalOrHigh.isEmpty() else true,
            skipped = false,
            findings = findings
        )
    }

    /** Extracts all failed checks from checkov JSON output. */
    private fun parseCheckovJsonFindings(jsonOutput: String): List<SecurityFinding> {
        if (jsonOutput.isBlank()) return emptyList()

        return try {
            val parsed = Json { ignoreUnknownKeys = true }.parseToJsonElement(jsonOutput)
            val findings = mutableListOf<SecurityFinding>()

            // checkov output can be a single object or an array when scanning multiple check types
            val elements = if (parsed is JsonArray) parsed.toList() else listOf(parsed)

            for (element in elements) {
                val obj = element.jsonObject
                val failedChecks = obj["results"]?.jsonObject
                    ?.get("failed_checks")?.jsonArray ?: continue

                for (check in failedChecks) {
                    val checkObj = check.jsonObject
                    val checkId = checkObj["check_id"]?.jsonPrimitive?.content ?: continue
                    val resource = checkObj["resource"]?.jsonPrimitive?.content ?: "unknown"
                    val severity = checkObj["severity"]?.jsonPrimitive?.content?.uppercase() ?: "UNKNOWN"
                    val guideline = checkObj["guideline"]?.jsonPrimitive?.content ?: ""
                    val checkName = checkObj["check"]?.jsonObject?.get("name")?.jsonPrimitive?.content ?: checkId

                    findings.add(SecurityFinding(
                        checkId = checkId,
                        resource = resource,
                        severity = severity,
                        message = checkName,
                        remediation = guideline
                    ))
                }
            }
            findings
        } catch (_: Exception) {
            emptyList()
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // KUBE-SCORE — Validate mode (aborts on CRITICAL)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Renders Helm templates first, then pipes output to kube-score.
     *
     * kube-score cannot parse Go template syntax (`{{ .Values.* }}`), so we must
     * render with `helm template` first, then feed the rendered YAML to kube-score
     * via its stdin. ProcessBuilder has no shell, so we run them as two separate
     * processes and pipe between them programmatically.
     *
     * @param workspaceDir workspace root (helm/ is a relative path from here)
     * @param projectName  Helm release name (matches what helm upgrade --install uses)
     * @return [KubeScoreResult] with pass/fail and any CRITICAL findings
     */
    fun runKubeScore(workspaceDir: File, projectName: String): KubeScoreResult {
        if (!isCommandAvailable("helm") || !isCommandAvailable("kube-score")) {
            return KubeScoreResult(passed = true, skipped = true, findings = emptyList())
        }

        val helmOutput = renderHelmTemplates(workspaceDir, projectName)
            ?: return KubeScoreResult(passed = true, skipped = true, findings = emptyList())

        val kubeScoreOutput = runKubeScoreWithInput(helmOutput, workspaceDir)
        val criticalLines = kubeScoreOutput.lines().filter { it.contains("[CRITICAL]") }

        return KubeScoreResult(
            passed = criticalLines.isEmpty(),
            skipped = false,
            findings = criticalLines
        )
    }

    /**
     * Runs kube-score in audit mode — returns all findings, never aborts.
     *
     * @param workspaceDir workspace root
     * @param projectName  Helm release name
     * @return [KubeAuditResult] grouped by severity
     */
    fun runKubeScoreAudit(workspaceDir: File, projectName: String): KubeAuditResult {
        if (!isCommandAvailable("helm") || !isCommandAvailable("kube-score")) {
            return KubeAuditResult(findings = emptyMap())
        }

        val helmOutput = renderHelmTemplates(workspaceDir, projectName)
            ?: return KubeAuditResult(findings = emptyMap())

        val kubeScoreOutput = runKubeScoreWithInput(helmOutput, workspaceDir)
        val critical = mutableListOf<KubeAuditFinding>()
        val warning = mutableListOf<KubeAuditFinding>()

        for (line in kubeScoreOutput.lines()) {
            val finding = parseKubeScoreLine(line) ?: continue
            if (line.contains("[CRITICAL]")) critical.add(finding)
            else warning.add(finding)
        }

        return KubeAuditResult(
            findings = mapOf(
                "critical" to critical,
                "warning" to warning
            )
        )
    }

    /** Runs `helm template {projectName} helm/ -f helm/values.yaml` and returns stdout. */
    private fun renderHelmTemplates(workspaceDir: File, projectName: String): String? {
        return try {
            val result = svc.runProcess(
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
     * Runs `kube-score score -` with [helmYaml] written to its stdin.
     *
     * ProcessBuilder does not use a shell, so pipe (`|`) is unavailable.
     * We start kube-score and write to its stdin via [Process.outputStream].
     */
    private fun runKubeScoreWithInput(helmYaml: String, workspaceDir: File): String {
        val pb = ProcessBuilder(listOf("kube-score", "score", "-"))
            .directory(workspaceDir)
            .redirectErrorStream(false)

        val process = pb.start()
        val hook = Thread { process.destroyForcibly() }
        Runtime.getRuntime().addShutdownHook(hook)

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

        // Write Helm-rendered YAML to kube-score stdin, then close
        process.outputStream.use { it.write(helmYaml.toByteArray()) }

        process.waitFor(5, java.util.concurrent.TimeUnit.MINUTES)
        stdoutThread.join()
        stderrThread.join()

        Runtime.getRuntime().removeShutdownHook(hook)

        return stdoutBuilder.toString()
    }

    /** Parses one kube-score output line into a [KubeAuditFinding]. */
    private fun parseKubeScoreLine(line: String): KubeAuditFinding? {
        if (line.isBlank() || (!line.contains("[CRITICAL]") && !line.contains("[WARNING]"))) return null
        return KubeAuditFinding(
            objectName = line.substringBefore(" ").trim(),
            check = line.substringAfter("[CRITICAL]").substringAfter("[WARNING]").trim().take(80),
            comment = line.trim()
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INFRACOST
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Runs `infracost breakdown` on the saved plan JSON file.
     *
     * Uses `--terraform-plan-file` which points at `gentepede-plan.json` generated by
     * `terraform show -json`. This avoids re-running terraform plan inside infracost.
     *
     * Graceful skip if infracost is not in PATH.
     *
     * @param terraformDir    the directory containing `gentepede-plan.json`
     * @param planJsonFilename the name of the plan JSON file (typically `gentepede-plan.json`)
     * @return [InfracostResult] with formatted cost string, or skipped=true
     */
    fun runInfracost(terraformDir: File, planJsonFilename: String): InfracostResult {
        if (!isCommandAvailable("infracost")) {
            return InfracostResult(cost = null, skipped = true)
        }

        return try {
            val result = svc.runProcess(
                listOf(
                    "infracost", "breakdown",
                    "--path=.",
                    "--terraform-plan-file=$planJsonFilename",
                    "--format=json"
                ),
                directory = terraformDir,
                allowedExitCodes = setOf(0)
            )

            val parsed = Json { ignoreUnknownKeys = true }.parseToJsonElement(result.stdout).jsonObject
            val monthlyCost = parsed["totalMonthlyCost"]?.jsonPrimitive?.content
            val currency = parsed["currency"]?.jsonPrimitive?.content ?: "USD"

            if (monthlyCost != null) {
                InfracostResult(cost = "$$monthlyCost/$currency per month (estimated)", skipped = false)
            } else {
                InfracostResult(cost = "Cost breakdown unavailable", skipped = false)
            }
        } catch (_: Exception) {
            InfracostResult(cost = null, skipped = true)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // HELM DIFF
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Runs `helm diff upgrade` to detect Kubernetes drift.
     *
     * Requires the `helm-diff` plugin (`helm plugin install ...`).
     * Gracefully skips with an informational message if the plugin is not installed.
     *
     * @param workspaceDir workspace root
     * @param projectName  Helm release name and namespace
     * @return [HelmDiffResult] with diff output or skipped flag
     */
    fun runHelmDiff(workspaceDir: File, projectName: String): HelmDiffResult {
        if (!isCommandAvailable("helm")) {
            return HelmDiffResult(diff = null, skipped = true)
        }

        return try {
            val result = svc.runProcess(
                listOf(
                    "helm", "diff", "upgrade", projectName, "helm/",
                    "-f", "helm/values.yaml",
                    "--namespace", projectName
                ),
                directory = workspaceDir,
                allowedExitCodes = setOf(0, 1)
            )
            HelmDiffResult(
                diff = result.stdout.ifBlank { null },
                skipped = false
            )
        } catch (e: ProcessExecutionException) {
            if (e.stderr.contains("plugin not found") || e.stderr.contains("diff: not found")) {
                HelmDiffResult(diff = null, skipped = true)
            } else {
                HelmDiffResult(diff = "helm diff failed: ${e.stderr}", skipped = false)
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // UTILITY
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Checks whether a command is available in the system PATH.
     *
     * Used to implement graceful skip behavior: if a required tool (checkov, kube-score,
     * infracost, helm) is not installed, the tool skips that check with a warning rather
     * than aborting the entire operation.
     */
    fun isCommandAvailable(command: String): Boolean {
        return try {
            val pb = ProcessBuilder(
                if (System.getProperty("os.name").lowercase().contains("windows"))
                    listOf("where", command) else listOf("which", command)
            ).redirectErrorStream(true)
            val p = pb.start()
            p.waitFor(5, java.util.concurrent.TimeUnit.SECONDS)
            p.exitValue() == 0
        } catch (_: Exception) {
            false
        }
    }
}
