package com.gentepede.ci

import com.gentepede.InfrastructureService
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlin.system.exitProcess

/**
 * BlueprintVerifier — CI entrypoint that generates and validates a single blueprint
 * end-to-end without starting the MCP server.
 *
 * Invoked once per blueprint by `.github/workflows/blueprint-verify.yml`:
 *
 *     java -cp build/libs/gentepede-mcp-all.jar \
 *          com.gentepede.ci.BlueprintVerifierKt \
 *          --blueprint <blueprintId> --project <projectName>
 *
 * It runs the same code path the MCP tools use ([InfrastructureService.generateWorkspace]
 * followed by [InfrastructureService.validateWorkspace]), so a green run proves the
 * blueprint still produces syntactically valid Terraform with its pinned provider
 * version. No MCP / JSON-RPC layer is involved.
 *
 * Exit codes:
 * - 0 — blueprint generated and `terraform validate` passed
 * - 1 — blueprint missing, generation failed, or `terraform validate` failed
 * - 2 — bad command-line arguments
 *
 * Note on variables: only `project_name` is injected. Other required variables are
 * intentionally left unset so Terraform treats them as unknown during `validate`.
 * `terraform validate` does not require variable values and makes no AWS calls, and
 * leaving paths (e.g. `lambda_zip_path`) unset avoids file-reading functions like
 * `filebase64sha256` trying to open a placeholder file that does not exist.
 */
fun main(args: Array<String>) {
    val parsed = parseArgs(args)

    val blueprintId = parsed["blueprint"]
    if (blueprintId.isNullOrBlank()) {
        System.err.println("Missing required argument: --blueprint <blueprintId>")
        exitProcess(2)
    }
    val projectName = parsed["project"]?.takeIf { it.isNotBlank() } ?: "ci-verify-$blueprintId"

    val svc = InfrastructureService()

    val blueprint = svc.loadBlueprint(blueprintId)
    if (blueprint == null) {
        System.err.println("Blueprint '$blueprintId' not found on the classpath.")
        exitProcess(1)
    }

    val variables = mutableMapOf<String, JsonElement>(
        "project_name" to JsonPrimitive(projectName)
    )

    try {
        val generated = svc.generateWorkspace(blueprintId, projectName, variables)
        println("Generated workspace at ${generated.workspacePath} (${generated.outputType})")

        val validation = svc.validateWorkspace(projectName)
        println(validation.summary)

        if (!validation.terraformValid) {
            System.err.println("terraform validate FAILED for '$blueprintId'")
            exitProcess(1)
        }

        println("OK: $blueprintId verified")
        exitProcess(0)
    } catch (e: Exception) {
        System.err.println("Verification FAILED for '$blueprintId': ${e.message}")
        exitProcess(1)
    }
}

/** Parses `--key value` pairs into a map. Flags without a following value are ignored. */
private fun parseArgs(args: Array<String>): Map<String, String> {
    val map = mutableMapOf<String, String>()
    var i = 0
    while (i < args.size) {
        val arg = args[i]
        if (arg.startsWith("--") && i + 1 < args.size) {
            map[arg.removePrefix("--")] = args[i + 1]
            i += 2
        } else {
            i += 1
        }
    }
    return map
}
