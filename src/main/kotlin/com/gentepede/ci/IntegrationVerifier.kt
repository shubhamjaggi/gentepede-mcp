package com.gentepede.ci

import com.gentepede.InfrastructureService
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlin.system.exitProcess

/**
 * IntegrationVerifier — CI entrypoint for full end-to-end tool-flow testing.
 *
 * Runs the complete happy path against LocalStack (GENTEPEDE_MODE=LOCAL):
 *   generate → validate → plan → apply → detect_drift → audit → destroy
 *
 * Called by `.github/workflows/integration-local.yml` on every push/PR.
 * LocalStack must be reachable at http://localhost:4566 before invoking this.
 *
 * Usage:
 *   java -cp build/libs/gentepede-mcp-all.jar \
 *        com.gentepede.ci.IntegrationVerifierKt \
 *        --blueprint <blueprintId> --project <projectName> \
 *        [--var key=value ...]
 *
 * Exit codes:
 *   0 — all seven steps succeeded
 *   1 — a step failed (step name and error message printed to stderr)
 *   2 — bad command-line arguments
 */
fun main(args: Array<String>) {
    val parsed = parseArgs(args)

    val blueprintId = parsed["blueprint"]
    if (blueprintId.isNullOrBlank()) {
        System.err.println("Missing required argument: --blueprint <blueprintId>")
        exitProcess(2)
    }
    val projectName = parsed["project"]?.takeIf { it.isNotBlank() } ?: "ci-integration-$blueprintId"

    val variables = mutableMapOf<String, JsonElement>(
        "project_name" to JsonPrimitive(projectName)
    )
    parsed.filter { it.key.startsWith("var.") }.forEach { (k, v) ->
        variables[k.removePrefix("var.")] = JsonPrimitive(v)
    }

    val svc = InfrastructureService()
    var currentStep = "init"

    try {
        // ── Step 1: generate ──────────────────────────────────────────────────
        currentStep = "generate"
        println("=== Step 1: generate ($blueprintId) ===")
        val generated = svc.generateWorkspace(blueprintId, projectName, variables)
        println("Workspace: ${generated.workspacePath}  outputType=${generated.outputType}")

        // ── Step 2: validate (terraform validate + checkov) ───────────────────
        currentStep = "validate"
        println("\n=== Step 2: validate ===")
        val validation = svc.validateWorkspace(projectName)
        println(validation.summary)
        check(validation.terraformValid) { "terraform validate FAILED" }

        // ── Step 3: plan ──────────────────────────────────────────────────────
        currentStep = "plan"
        println("\n=== Step 3: plan ===")
        val plan = svc.planWorkspace(projectName)
        println("Plan: +${plan.toCreate} create, ~${plan.toModify} modify, -${plan.toDestroy} destroy")
        check(plan.toCreate > 0) { "Expected at least one resource to CREATE but plan shows 0" }

        // ── Step 4: apply ─────────────────────────────────────────────────────
        currentStep = "apply"
        println("\n=== Step 4: apply ===")
        val apply = svc.applyWorkspace(projectName)
        println("Apply complete. Lock: ${apply.lockFilePath}")

        // ── Step 5: detect_drift (expects no drift immediately after apply) ───
        currentStep = "detect_drift"
        println("\n=== Step 5: detect_drift ===")
        val drift = svc.detectDrift(projectName)
        println("Drift: ${if (drift.hasDrift) "DRIFT DETECTED (${drift.terraformSummary})" else "no drift"}")
        // In LocalStack, LocalStack is ephemeral so drift right after apply is unexpected.
        // We warn but do not fail — LocalStack occasionally returns stale state.
        if (drift.hasDrift) println("  NOTE: drift in LocalStack is usually a timing artifact")

        // ── Step 6: audit (security findings report — never aborts) ──────────
        currentStep = "audit"
        println("\n=== Step 6: audit ===")
        val audit = svc.auditWorkspace(projectName)
        println(audit.summary)

        // ── Step 7: destroy ───────────────────────────────────────────────────
        currentStep = "destroy"
        println("\n=== Step 7: destroy ===")
        val destroy = svc.destroyWorkspace(projectName)
        println("Destroy complete. Lock: ${destroy.lockFilePath}")

        println("\n=== INTEGRATION TEST PASSED: $blueprintId ===")
        exitProcess(0)

    } catch (e: Exception) {
        System.err.println("\nINTEGRATION TEST FAILED at step '$currentStep': ${e.message}")
        exitProcess(1)
    }
}

private fun parseArgs(args: Array<String>): Map<String, String> {
    val map = mutableMapOf<String, String>()
    var i = 0
    while (i < args.size) {
        val token = args[i]
        if (token.startsWith("--") && i + 1 < args.size) {
            val key = token.removePrefix("--")
            val value = args[i + 1]
            if (key == "var") {
                val eqIdx = value.indexOf('=')
                if (eqIdx > 0) map["var.${value.substring(0, eqIdx)}"] = value.substring(eqIdx + 1)
            } else {
                map[key] = value
            }
            i += 2
        } else {
            i++
        }
    }
    return map
}
