package com.gentepede

import io.modelcontextprotocol.kotlin.sdk.*
import io.modelcontextprotocol.kotlin.sdk.server.*
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.io.asSink
import kotlinx.io.asSource
import kotlinx.io.buffered
import kotlinx.serialization.json.*

/**
 * Main entry point for the Gentepede MCP server.
 *
 * Initialises the MCP server using [StdioServerTransport], which reads JSON-RPC
 * messages from stdin and writes responses to stdout. This transport is what Claude
 * Desktop (and other MCP clients) use to communicate with the server.
 *
 * All 8 tools are registered here with their input schemas and descriptions.
 * Actual tool logic is in [Engine], which delegates to [InfrastructureService].
 *
 * The MCP SDK handles:
 * - The `initialize` handshake and capability negotiation
 * - JSON-RPC framing (Content-Length headers + newline-delimited JSON)
 * - Error response formatting
 * - Tool listing via the `tools/list` method
 *
 * This file does NOT contain business logic. Any change to what a tool does
 * belongs in [Engine] or [InfrastructureService].
 */
fun main() = runBlocking {
    val engine = Engine()

    val server = Server(
        serverInfo = Implementation(name = "gentepede-mcp", version = "1.0.0"),
        options = ServerOptions(
            capabilities = ServerCapabilities(
                tools = ServerCapabilities.Tools(listChanged = false)
            )
        )
    )

    // ─────────────────────────────────────────────────────────────────────────
    // Tool 1: list_available_blueprints
    // ─────────────────────────────────────────────────────────────────────────

    server.addTool(
        name = "list_available_blueprints",
        description = "Lists all available infrastructure blueprints. Each blueprint describes " +
                "a complete AWS architecture (ECS/EKS/Lambda) with security best practices " +
                "pre-configured. Use this first to choose a blueprint before calling " +
                "generate_infrastructure_package.",
        inputSchema = Tool.Input(
            properties = JsonObject(emptyMap()),
            required = emptyList()
        )
    ) { _: CallToolRequest ->
        engine.listAvailableBlueprints()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tool 2: generate_infrastructure_package
    // ─────────────────────────────────────────────────────────────────────────

    server.addTool(
        name = "generate_infrastructure_package",
        description = "Generates a complete infrastructure workspace from a blueprint. " +
                "Creates Terraform files (main.tf, variables.tf, terraform.tfvars, providers.tf) " +
                "and for EKS blueprints also a production-ready Helm chart. " +
                "Workspace is created at ~/.gentepede/workspaces/{project_name}/. " +
                "In LOCAL mode, routes to LocalStack. In PRODUCTION mode, uses real AWS " +
                "with an S3 remote state backend.",
        inputSchema = Tool.Input(
            properties = buildJsonObject {
                put("blueprint_name", buildJsonObject {
                    put("type", "string")
                    put("description", "Blueprint ID from list_available_blueprints (e.g. 'springboot-postgres')")
                })
                put("project_name", buildJsonObject {
                    put("type", "string")
                    put("description", "Unique project name (alphanumeric and hyphens only). Used for workspace directories and AWS resource names.")
                })
                put("variables", buildJsonObject {
                    put("type", "object")
                    put("description", "Blueprint variable values. Required variables must be supplied. See blueprint's 'variables' field for the full list.")
                })
            },
            required = listOf("blueprint_name", "project_name", "variables")
        )
    ) { request: CallToolRequest ->
        engine.generateInfrastructurePackage(request.arguments ?: JsonObject(emptyMap()))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tool 3: validate_infrastructure_package
    // ─────────────────────────────────────────────────────────────────────────

    server.addTool(
        name = "validate_infrastructure_package",
        description = "Runs static analysis on an existing workspace. Executes: " +
                "terraform init, terraform validate, checkov (aborts on HIGH/CRITICAL), " +
                "and for EKS blueprints: kube-score (aborts on CRITICAL). " +
                "Makes zero AWS API calls — no credentials required. " +
                "Run this after generate_infrastructure_package and before planning.",
        inputSchema = Tool.Input(
            properties = buildJsonObject {
                put("project_name", buildJsonObject {
                    put("type", "string")
                    put("description", "Project name identifying the workspace to validate")
                })
            },
            required = listOf("project_name")
        )
    ) { request: CallToolRequest ->
        engine.validateInfrastructurePackage(request.arguments ?: JsonObject(emptyMap()))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tool 4: plan_infrastructure_package
    // ─────────────────────────────────────────────────────────────────────────

    server.addTool(
        name = "plan_infrastructure_package",
        description = "Runs terraform plan and generates a human-readable summary of what will " +
                "be created, modified, or destroyed. In PRODUCTION mode, verifies AWS credentials " +
                "first. Writes a plan file checksum to gentepede.lock.json for integrity checking " +
                "at apply time. Also runs infracost for cost estimation (skipped if not installed). " +
                "For EKS blueprints, renders Helm manifests for review alongside the Terraform plan.",
        inputSchema = Tool.Input(
            properties = buildJsonObject {
                put("project_name", buildJsonObject {
                    put("type", "string")
                    put("description", "Project name identifying the workspace to plan")
                })
            },
            required = listOf("project_name")
        )
    ) { request: CallToolRequest ->
        engine.planInfrastructurePackage(request.arguments ?: JsonObject(emptyMap()))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tool 5: apply_infrastructure_package
    // ─────────────────────────────────────────────────────────────────────────

    server.addTool(
        name = "apply_infrastructure_package",
        description = "Applies the previously reviewed plan. Verifies the plan file checksum " +
                "before applying to prevent stale plan application. Creates a timestamped state " +
                "backup before applying. For EKS blueprints, runs helm upgrade --install after " +
                "Terraform completes. In PRODUCTION mode, verifies AWS credentials first. " +
                "WARNING: this deploys real infrastructure. Run plan_infrastructure_package first " +
                "and review the output carefully.",
        inputSchema = Tool.Input(
            properties = buildJsonObject {
                put("project_name", buildJsonObject {
                    put("type", "string")
                    put("description", "Project name identifying the workspace to apply")
                })
            },
            required = listOf("project_name")
        )
    ) { request: CallToolRequest ->
        engine.applyInfrastructurePackage(request.arguments ?: JsonObject(emptyMap()))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tool 6: detect_drift
    // ─────────────────────────────────────────────────────────────────────────

    server.addTool(
        name = "detect_drift",
        description = "Detects drift between the Terraform state and actual AWS resources. " +
                "Uses terraform plan -detailed-exitcode: exit 0 = no drift, exit 2 = drift detected. " +
                "For EKS blueprints, also runs helm diff upgrade (requires helm-diff plugin). " +
                "In PRODUCTION mode, verifies AWS credentials first. " +
                "Note: meaningful primarily in PRODUCTION — LocalStack state is ephemeral and " +
                "all resources appear as drift if Docker restarts.",
        inputSchema = Tool.Input(
            properties = buildJsonObject {
                put("project_name", buildJsonObject {
                    put("type", "string")
                    put("description", "Project name identifying the workspace to check for drift")
                })
            },
            required = listOf("project_name")
        )
    ) { request: CallToolRequest ->
        engine.detectDrift(request.arguments ?: JsonObject(emptyMap()))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tool 7: destroy_infrastructure_package
    // ─────────────────────────────────────────────────────────────────────────

    server.addTool(
        name = "destroy_infrastructure_package",
        description = "Destroys all infrastructure in the workspace. " +
                "For EKS blueprints: uninstalls the Helm release first and waits for pods to " +
                "terminate before Terraform destroys the node group. " +
                "Creates a state backup before destroying. " +
                "Deletes the workspace directory but NEVER deletes backup files. " +
                "WARNING: this destroys real infrastructure. This action cannot be undone.",
        inputSchema = Tool.Input(
            properties = buildJsonObject {
                put("project_name", buildJsonObject {
                    put("type", "string")
                    put("description", "Project name identifying the workspace to destroy")
                })
            },
            required = listOf("project_name")
        )
    ) { request: CallToolRequest ->
        engine.destroyInfrastructurePackage(request.arguments ?: JsonObject(emptyMap()))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tool 8: audit_infrastructure_package
    // ─────────────────────────────────────────────────────────────────────────

    server.addTool(
        name = "audit_infrastructure_package",
        description = "Runs a full security audit on an existing workspace. Unlike validate, " +
                "this never aborts — it returns ALL findings (checkov + kube-score) grouped by " +
                "severity (critical, high, medium, low) with remediation guidance. " +
                "Use this to get a complete security posture report at any point in the workflow.",
        inputSchema = Tool.Input(
            properties = buildJsonObject {
                put("project_name", buildJsonObject {
                    put("type", "string")
                    put("description", "Project name identifying the workspace to audit")
                })
            },
            required = listOf("project_name")
        )
    ) { request: CallToolRequest ->
        engine.auditInfrastructurePackage(request.arguments ?: JsonObject(emptyMap()))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Start the server
    // ─────────────────────────────────────────────────────────────────────────

    val done = CompletableDeferred<Unit>()
    server.onClose { done.complete(Unit) }

    val bufferedOut = System.out.asSink().buffered()
    val transport = StdioServerTransport(
        System.`in`.asSource().buffered(),
        bufferedOut
    )

    // StdioServerTransport wraps our Sink in a second RealBufferedSink internally
    // and calls flush() after every send(). That flush propagates through our
    // bufferedOut layer to System.out, so an extra periodic flusher is needed to
    // cover any writes the SDK may produce outside of send() (e.g. keepalives).
    val flusher = launch(Dispatchers.IO) {
        while (isActive) {
            delay(10)
            runCatching { bufferedOut.flush() }
        }
    }

    server.connect(transport)
    done.await()
    flusher.cancel()
}
