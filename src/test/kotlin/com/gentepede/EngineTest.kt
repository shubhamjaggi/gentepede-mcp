package com.gentepede

import io.modelcontextprotocol.kotlin.sdk.CallToolResult
import io.modelcontextprotocol.kotlin.sdk.TextContent
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.jupiter.api.*
import org.junit.jupiter.api.Assertions.*

/**
 * Tests for [Engine] — the thin MCP handler layer.
 *
 * These tests verify:
 * - Required-parameter detection (returns error before calling InfrastructureService)
 * - project_name format validation (alphanumeric + hyphens only)
 * - Error response shape (isError=true, text starts with "Error:")
 * - listAvailableBlueprints success path (reads classpath resources, no external deps)
 * - Workspace-not-found handling for all stateful tools
 *
 * Engine methods are suspend functions; tests use runBlocking{}. No mocking is
 * required because missing-parameter and workspace-not-found checks return early
 * without running Terraform or touching AWS.
 */
class EngineTest {

    private val engine = Engine()

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    private fun text(result: CallToolResult): String =
        (result.content.first() as TextContent).text!!

    // ─────────────────────────────────────────────────────────────────────────
    // list_available_blueprints
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `listAvailableBlueprints returns success with all six blueprints`() = runBlocking<Unit> {
        val result = engine.listAvailableBlueprints()
        assertFalse(result.isError == true, "listAvailableBlueprints must not return an error")
        val t = text(result)
        listOf("springboot-postgres", "ktor-dynamodb", "nodejs-s3",
               "fastapi-redis", "springboot-eks", "nodejs-eks").forEach { id ->
            assertTrue(t.contains(id), "Blueprint '$id' must appear in the listing")
        }
    }

    @Test
    fun `listAvailableBlueprints output mentions 6 blueprints`() = runBlocking<Unit> {
        val result = engine.listAvailableBlueprints()
        assertTrue(text(result).contains("6"), "Output must mention the blueprint count (6)")
    }

    @Test
    fun `listAvailableBlueprints output includes provider version and output type`() = runBlocking<Unit> {
        val result = engine.listAvailableBlueprints()
        val t = text(result)
        assertTrue(t.contains("TERRAFORM_ONLY") || t.contains("TERRAFORM_K8S"),
            "Output must include output type for at least one blueprint")
        assertTrue(t.contains("5.82"), "Output must include the Terraform provider version")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // generate_infrastructure_package — parameter validation
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `generateInfrastructurePackage missing blueprint_name returns error`() = runBlocking<Unit> {
        val args = buildJsonObject {
            put("project_name", "test-proj")
            put("variables", buildJsonObject {})
        }
        val result = engine.generateInfrastructurePackage(args)
        assertTrue(result.isError == true, "Missing blueprint_name must return isError=true")
        assertTrue(text(result).contains("blueprint_name"), "Error must name the missing parameter")
    }

    @Test
    fun `generateInfrastructurePackage missing project_name returns error`() = runBlocking<Unit> {
        val args = buildJsonObject {
            put("blueprint_name", "springboot-postgres")
            put("variables", buildJsonObject {})
        }
        val result = engine.generateInfrastructurePackage(args)
        assertTrue(result.isError == true)
        assertTrue(text(result).contains("project_name"))
    }

    @Test
    fun `generateInfrastructurePackage project_name with space is rejected`() = runBlocking<Unit> {
        val args = buildJsonObject {
            put("blueprint_name", "springboot-postgres")
            put("project_name", "my project")
            put("variables", buildJsonObject {})
        }
        val result = engine.generateInfrastructurePackage(args)
        assertTrue(result.isError == true, "project_name with spaces must be rejected")
        assertTrue(text(result).contains("alphanumeric") || text(result).contains("project_name"),
            "Error must explain the naming constraint")
    }

    @Test
    fun `generateInfrastructurePackage project_name with underscore is rejected`() = runBlocking<Unit> {
        val args = buildJsonObject {
            put("blueprint_name", "springboot-postgres")
            put("project_name", "my_project")
            put("variables", buildJsonObject {})
        }
        val result = engine.generateInfrastructurePackage(args)
        assertTrue(result.isError == true, "Underscores are not allowed in project_name")
    }

    @Test
    fun `generateInfrastructurePackage project_name with special chars is rejected`() = runBlocking<Unit> {
        val args = buildJsonObject {
            put("blueprint_name", "springboot-postgres")
            put("project_name", "proj@2024!")
            put("variables", buildJsonObject {})
        }
        val result = engine.generateInfrastructurePackage(args)
        assertTrue(result.isError == true, "Special characters must be rejected")
    }

    @Test
    fun `generateInfrastructurePackage valid hyphenated project_name is accepted for unknown blueprint`() = runBlocking<Unit> {
        // A valid project_name passes the format check. The error shifts to "blueprint not found".
        val args = buildJsonObject {
            put("blueprint_name", "nonexistent-blueprint-xyz")
            put("project_name", "valid-name-123")
            put("variables", buildJsonObject {})
        }
        val result = engine.generateInfrastructurePackage(args)
        assertTrue(result.isError == true, "Unknown blueprint must return error")
        val t = text(result)
        // Error must be about the blueprint, not the name format
        assertTrue(
            t.contains("nonexistent-blueprint-xyz") || t.contains("not found") || t.contains("Blueprint"),
            "Error must mention the unknown blueprint, got: $t"
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // validate_infrastructure_package
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `validateInfrastructurePackage missing project_name returns error`() = runBlocking<Unit> {
        val result = engine.validateInfrastructurePackage(JsonObject(emptyMap()))
        assertTrue(result.isError == true)
        assertTrue(text(result).contains("project_name"))
    }

    @Test
    fun `validateInfrastructurePackage nonexistent workspace returns error`() = runBlocking<Unit> {
        val args = buildJsonObject { put("project_name", "no-such-workspace-abc999xyz") }
        val result = engine.validateInfrastructurePackage(args)
        assertTrue(result.isError == true, "Nonexistent workspace must return error")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // plan_infrastructure_package
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `planInfrastructurePackage missing project_name returns error`() = runBlocking<Unit> {
        val result = engine.planInfrastructurePackage(JsonObject(emptyMap()))
        assertTrue(result.isError == true)
        assertTrue(text(result).contains("project_name"))
    }

    @Test
    fun `planInfrastructurePackage nonexistent workspace returns error`() = runBlocking<Unit> {
        val args = buildJsonObject { put("project_name", "no-such-workspace-abc999xyz") }
        val result = engine.planInfrastructurePackage(args)
        assertTrue(result.isError == true)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // apply_infrastructure_package
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `applyInfrastructurePackage missing project_name returns error`() = runBlocking<Unit> {
        val result = engine.applyInfrastructurePackage(JsonObject(emptyMap()))
        assertTrue(result.isError == true)
        assertTrue(text(result).contains("project_name"))
    }

    @Test
    fun `applyInfrastructurePackage nonexistent workspace returns error`() = runBlocking<Unit> {
        val args = buildJsonObject { put("project_name", "no-such-workspace-abc999xyz") }
        val result = engine.applyInfrastructurePackage(args)
        assertTrue(result.isError == true)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // detect_drift
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `detectDrift missing project_name returns error`() = runBlocking<Unit> {
        val result = engine.detectDrift(JsonObject(emptyMap()))
        assertTrue(result.isError == true)
        assertTrue(text(result).contains("project_name"))
    }

    @Test
    fun `detectDrift nonexistent workspace returns error`() = runBlocking<Unit> {
        val args = buildJsonObject { put("project_name", "no-such-workspace-abc999xyz") }
        val result = engine.detectDrift(args)
        assertTrue(result.isError == true)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // destroy_infrastructure_package
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `destroyInfrastructurePackage missing project_name returns error`() = runBlocking<Unit> {
        val result = engine.destroyInfrastructurePackage(JsonObject(emptyMap()))
        assertTrue(result.isError == true)
        assertTrue(text(result).contains("project_name"))
    }

    @Test
    fun `destroyInfrastructurePackage nonexistent workspace returns error`() = runBlocking<Unit> {
        val args = buildJsonObject { put("project_name", "no-such-workspace-abc999xyz") }
        val result = engine.destroyInfrastructurePackage(args)
        assertTrue(result.isError == true)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // audit_infrastructure_package
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `auditInfrastructurePackage missing project_name returns error`() = runBlocking<Unit> {
        val result = engine.auditInfrastructurePackage(JsonObject(emptyMap()))
        assertTrue(result.isError == true)
        assertTrue(text(result).contains("project_name"))
    }

    @Test
    fun `auditInfrastructurePackage nonexistent workspace returns error`() = runBlocking<Unit> {
        val args = buildJsonObject { put("project_name", "no-such-workspace-abc999xyz") }
        val result = engine.auditInfrastructurePackage(args)
        assertTrue(result.isError == true)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Error response format invariants
    // ─────────────────────────────────────────────────────────────────────────

    @Test
    fun `all error responses start with Error prefix`() = runBlocking<Unit> {
        // Sample two error cases and verify the prefix is consistent
        val missingParam = engine.validateInfrastructurePackage(JsonObject(emptyMap()))
        val missingWorkspace = engine.auditInfrastructurePackage(
            buildJsonObject { put("project_name", "no-such-workspace-abc999xyz") }
        )
        assertTrue(text(missingParam).startsWith("Error:"),
            "Missing-parameter errors must start with 'Error:'")
        assertTrue(text(missingWorkspace).startsWith("Error:"),
            "Workspace-not-found errors must start with 'Error:'")
    }

    @Test
    fun `success responses do not have isError set`() = runBlocking<Unit> {
        val result = engine.listAvailableBlueprints()
        assertTrue(result.isError != true, "Success responses must not set isError=true")
    }
}
