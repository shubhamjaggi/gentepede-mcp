# Contributor Sync Guide

This document answers one question: **"I am about to make change X — which other files in this repo must I also update?"**

Every part of Gentepede has dependencies: code that calls it, docs that describe it, tests that verify it, and CI that gates it. A contribution that changes one file without updating its dependents leaves the repo inconsistent — docs say one thing, code does another. This guide is the explicit map of those dependencies.

---

## Quick Reference

| Change Type | Jump To |
|---|---|
| Add a blueprint (reuses an existing template family) | [§1](#1-add-a-blueprint) |
| Add a new tech stack (requires a new template family) | [§2](#2-add-a-new-template-family) |
| Add a new MCP tool | [§3](#3-add-a-new-mcp-tool) |
| Modify an existing Terraform template | [§4](#4-modify-an-existing-terraform-template) |
| Modify the Helm chart | [§5](#5-modify-the-helm-chart) |
| Bump the Terraform provider version | [§6](#6-bump-the-terraform-provider-version) |
| Change a code layer (InfrastructureService, Engine, Validator, Models) | [§7](#7-change-a-code-layer) |

---

## The Dependency Map

Before the per-change checklists, here is a complete map of every "source of truth" in the repo and what depends on it. Use this if your change doesn't fit neatly into one category above.

### Blueprint JSON files (`src/main/resources/blueprints/`)

Every blueprint JSON file has these dependents:

| Dependent | What must change |
|---|---|
| `InfrastructureService.listBlueprints()` | Blueprint ID must appear in the hardcoded list |
| `README.md` Supported Blueprints table | One row per blueprint |
| `docs/04-blueprints-guide.md` "All Blueprints at a Glance" | One row per blueprint |
| `docs/15-blueprint-to-resource-map.md` | Per-blueprint resource breakdown section |
| `docs/00-glossary.md` | If any new AWS service is introduced that isn't already defined |
| `InfrastructureServiceTest.kt` | Blueprint loading test + data-tier toggle test + workspace generation test for the new ID |

### Template families (`templates/{family}/`)

Each template family directory (`templates/ecs/`, `templates/lambda/`, `templates/eks/`) has these dependents:

| Dependent | What must change |
|---|---|
| `TemplateFamily` enum in `Models.kt` | Enum value must exist for the family name |
| `InfrastructureService.injectDataTierToggles()` | Toggle derivation logic for new families |
| `InfrastructureService.buildProvidersContent()` | If provider endpoint additions are needed |
| `templates/{family}/variables.tf` | Every variable referenced in `main.tf` must be declared here |
| `docs/04-blueprints-guide.md` | `templateFamily` field values in the schema section |
| `docs/13-development-guide.md` project structure | New directory shown in the tree |
| `docs/15-blueprint-to-resource-map.md` | New template family section (resource table + toggle table) |

### Helm chart (`helm-chart/`)

| Dependent | What must change |
|---|---|
| `InfrastructureService.copyHelmChart()` | Explicit file list in the `helmFiles` list must include every file |
| `InfrastructureService.buildHelmValues()` | Keys in the generated `values.yaml` must match what the chart templates reference |
| `helm-chart/values.yaml` | Default values; generated per-project `values.yaml` overrides specific keys |
| `docs/06-kubernetes-guide.md` | If a new template is added or an existing one's behaviour changes |
| `docs/09-security-model.md` | If new kube-score checks are addressed by the chart |

### MCP tools (registered in `Main.kt`)

| Dependent | What must change |
|---|---|
| `Engine.kt` | Tool handler (extracts params, calls InfrastructureService, formats response) |
| `InfrastructureService.kt` | Business logic method for the tool |
| `docs/08-tools-reference.md` | Full input/output spec for the new tool |
| `docs/16-tool-architecture.md` | End-to-end architecture section (every layer, every CLI call) |
| `README.md` Deployment Workflow diagram | If the tool fits in the main workflow |
| `.github/PULL_REQUEST_TEMPLATE.md` | If the workflow changes |

### `Models.kt`

| Dependent | What must change |
|---|---|
| All callers | `Engine.kt`, `InfrastructureService.kt`, `Validator.kt`, `BlueprintVerifier.kt` |
| Tests | `InfrastructureServiceTest.kt`, `ValidatorTest.kt` |
| `docs/16-tool-architecture.md` | Any data class described in the architecture doc |

### Configuration (environment variables)

| Dependent | What must change |
|---|---|
| `README.md` Configuration Matrix table | New variable row |
| `docs/03-how-mcp-works.md` | If it appears in the Claude Desktop config example |

### Checkov security rules

| Dependent | What must change |
|---|---|
| `docs/09-security-model.md` checkov rules table | New check added or removed |
| All Terraform templates | Must pass (not trigger) the new check |

### kube-score security checks

| Dependent | What must change |
|---|---|
| `docs/09-security-model.md` kube-score table | New check added or removed |
| `helm-chart/templates/` | The specific field that satisfies (or would violate) the check |

### CI workflows (`.github/workflows/`) and scripts (`.github/scripts/`)

| Dependent | What must change |
|---|---|
| `docs/18-github-actions-guide.md` | Add/update the section for the new or modified workflow; describe what it does, when it runs, and which job/step it adds |
| `docs/13-development-guide.md` project structure tree | New workflow file or script must appear in the `.github/` tree |
| `docs/13-development-guide.md` CI Workflows section | If a new workflow is added, add its summary paragraph alongside `ci.yml`, `lint.yml`, etc. |
| `README.md` badges | If the new workflow runs on every push/PR, add a status badge so its health is visible at a glance |
| `docs/14-faq.md` "What do the CI badges in the README mean?" | Update if a new badge is added |

---

## 1. Add a Blueprint

Adding a blueprint that reuses an existing template family (`ecs`, `lambda`, or `eks`). If the new tech stack needs a new template family, see [§2](#2-add-a-new-template-family) instead.

**Full step-by-step guide:** `docs/10-adding-blueprints.md`

### Complete Sync Checklist

#### Code and Resources

- [ ] `src/main/resources/blueprints/{id}.json` — created; `blueprintId` matches filename without `.json`
- [ ] `terraformProviderVersion` — set to the same pinned version as the other blueprints (check `springboot-postgres.json`)
- [ ] `lastVerifiedDate` — set to current `YYYY-MM` before merging
- [ ] `InfrastructureService.listBlueprints()` — new blueprint ID added to the hardcoded list
- [ ] `InfrastructureServiceTest.kt` — two tests added:
  - Blueprint loads without error (the `loadBlueprint` assertion pattern)
  - Data-tier toggles are correct (`enable_rds`/`enable_dynamodb`/`enable_redis` for the new blueprint's declared resources)
- [ ] If `TERRAFORM_K8S`: `InfrastructureService.buildHelmValues()` — framework port/path triple added

#### Documentation

- [ ] `README.md` Supported Blueprints table — new row with all columns (ID, framework, output, resources, provider, verified, cost)
- [ ] `docs/04-blueprints-guide.md` "All Blueprints at a Glance" table — new row
- [ ] `docs/15-blueprint-to-resource-map.md` — new section under the relevant template family (resource table showing ✓/— per resource + why this tech stack needs its specific data tier)
- [ ] `docs/00-glossary.md` — new entry for any AWS service this blueprint introduces that is not already defined (e.g. if the blueprint uses SQS and no existing blueprint does)

#### Verification

- [ ] Local: `./gradlew shadowJar && java -cp build/libs/gentepede-mcp-all.jar com.gentepede.ci.BlueprintVerifierKt --blueprint {id} --project test-{id}` exits 0
- [ ] Local: checkov passes on the generated workspace (`validate_infrastructure_package` in Claude Desktop or via the verifier)
- [ ] CI: `./gradlew build` is green

---

## 2. Add a New Template Family

Adding a new tech stack that cannot be served by any existing template family. Examples: a serverless container orchestrator, a different cloud provider, or a fundamentally different AWS topology.

### Complete Sync Checklist

#### Code

- [ ] `templates/{new-family}/main.tf` — created; every resource block gated behind `count = var.enable_X ? 1 : 0` for optional resources
- [ ] `templates/{new-family}/variables.tf` — every variable referenced in `main.tf` declared here with type and description
- [ ] `Models.kt` `TemplateFamily` enum — new value added (e.g. `fargate_spot`)
- [ ] `InfrastructureService.injectDataTierToggles()` — new `when` branch for the new family deriving toggle variables from the blueprint's `awsResources` list
- [ ] `src/main/resources/blueprints/{id}.json` — at least one blueprint created that uses the new family
- [ ] `InfrastructureService.listBlueprints()` — new blueprint ID(s) added
- [ ] `InfrastructureServiceTest.kt` — tests for: blueprint loading, workspace generation writes correct files, toggle derivation for the new family
- [ ] If `TERRAFORM_K8S`: `InfrastructureService.buildHelmValues()` — framework port/path triple added; `InfrastructureService.copyHelmChart()` file list verified to include any new chart files

#### Documentation

- [ ] `README.md` Supported Blueprints table — new row(s)
- [ ] `docs/04-blueprints-guide.md` "All Blueprints at a Glance" table — new row(s) + the `templateFamily` field values list updated if a new value was added
- [ ] `docs/04-blueprints-guide.md` TERRAFORM_ONLY vs TERRAFORM_K8S table — updated if the new family introduces a different output type
- [ ] `docs/13-development-guide.md` project structure tree — new `templates/{new-family}/` directory shown
- [ ] `docs/13-development-guide.md` "Adding a New Blueprint" section — updated if new toggle pattern is needed
- [ ] `docs/15-blueprint-to-resource-map.md` — new template family section (resource table with ✓/— per resource, toggle variable table, and "why each stack needs its data tier" explanation)
- [ ] `docs/00-glossary.md` — new entries for any AWS service not already defined
- [ ] `docs/09-security-model.md` — if the new template family introduces new checkov rules that must pass (or if existing ones don't apply), update the table

#### Verification

- [ ] `./gradlew shadowJar` succeeds (no compile errors from new enum value, new `when` branch)
- [ ] `jar tf build/libs/gentepede-mcp-all.jar | grep "templates/{new-family}"` — confirms new template files are bundled
- [ ] `BlueprintVerifierKt --blueprint {id}` — `terraform validate` + checkov pass for every new blueprint
- [ ] CI `./gradlew build` green

---

## 3. Add a New MCP Tool

Adding a new callable tool beyond the existing eight (`list_available_blueprints`, `generate_infrastructure_package`, `validate_infrastructure_package`, `plan_infrastructure_package`, `apply_infrastructure_package`, `detect_drift`, `destroy_infrastructure_package`, `audit_infrastructure_package`).

### Complete Sync Checklist

#### Code

- [ ] `Main.kt` — `server.addTool(...)` registration with tool name, description, and input schema
- [ ] `Engine.kt` — tool handler: extract params from `JsonObject`, call the InfrastructureService method, format the result as a human-readable string. No business logic here.
- [ ] `InfrastructureService.kt` — business logic method; must not reference MCP types; must be testable in isolation
- [ ] `Models.kt` — new result data class if the return shape is distinct from existing results
- [ ] `InfrastructureServiceTest.kt` — tests for the new InfrastructureService method (success path, error path, workspace-not-found guard)
- [ ] `EngineTest.kt` — missing-parameter test and workspace-not-found test for the new Engine handler

#### Documentation

- [ ] `docs/08-tools-reference.md` — complete new section: when to use, inputs table, success response example, error response examples
- [ ] `docs/16-tool-architecture.md` — new tool section covering: plain-English paragraph, numbered steps (every CLI call, every file written), quick-reference table, "Why?" callouts for key decisions
- [ ] `README.md` Deployment Workflow diagram — add the new tool if it fits in the generate→validate→plan→apply flow, or note it as a standalone tool alongside `audit_infrastructure_package`
- [ ] `docs/14-faq.md` — consider whether the new tool answers a question users will ask; add an FAQ entry if so

#### Verification

- [ ] `./gradlew build` green (compile + tests)
- [ ] Manual end-to-end test in Claude Desktop — tool appears in tool list, success case works, error case returns clean message

---

## 4. Modify an Existing Terraform Template

Changes to `templates/ecs/main.tf`, `templates/eks/main.tf`, or `templates/lambda/main.tf` (or their `variables.tf`).

### Complete Sync Checklist

#### Code

- [ ] `templates/{family}/variables.tf` — any new variable in `main.tf` is declared here with `type`, `description`, and `default` (or `nullable = false` if required)
- [ ] `InfrastructureService.buildTfvarsContent()` logic — if the new variable needs a value derived at runtime (not user-supplied), does it appear in `injectDataTierToggles()` or `buildProvidersContent()`?
- [ ] `InfrastructureServiceTest.kt` — if the change affects which variables are set or how toggles work, add a test case

#### Constraint Reminders (easy mistakes)

- Security group descriptions must match `^[0-9A-Za-z_ .:/()#,@\[\]+=&;{}!$*-]*$` — em dashes (`—`) are invalid and cause `terraform validate` to fail with the AWS provider
- ElastiCache `at_rest_encryption_enabled` is only supported on `aws_elasticache_replication_group`, not `aws_elasticache_cluster`
- Every resource that should be encrypted must use the project's KMS key — checkov will catch missing encryption

#### Documentation

- [ ] HCL comments in the modified `main.tf` — the comment above the changed resource must still accurately describe the new behaviour. If you change how a resource works, update its concept banner.
- [ ] `docs/15-blueprint-to-resource-map.md` — if the change adds, removes, or gates a resource differently, the resource table for that template family needs updating
- [ ] `docs/09-security-model.md` checkov rules table — if the change is specifically to pass a new checkov rule, add that rule to the table with explanation

#### Verification

- [ ] `./gradlew shadowJar` (template files re-bundled into JAR)
- [ ] `BlueprintVerifierKt --blueprint {any blueprint using this family} --project test` — `terraform validate` + checkov pass
- [ ] `./gradlew build` green

---

## 5. Modify the Helm Chart

Changes to any file in `helm-chart/` (`Chart.yaml`, `values.yaml`, or any file under `helm-chart/templates/`).

### Complete Sync Checklist

#### Code

- [ ] If you add a **new file** to `helm-chart/templates/`: add it to the `helmFiles` list in `InfrastructureService.copyHelmChart()` — otherwise the file will not be copied into the workspace and Helm will not render it
- [ ] If you add a **new key** to `helm-chart/values.yaml` that must be set per-project: add it to `InfrastructureService.buildHelmValues()` so the generated per-project `values.yaml` includes the right value
- [ ] If a template file references `{{ .Values.someKey }}`: confirm `someKey` exists in both `helm-chart/values.yaml` (default) and `buildHelmValues()` output (per-project override)

#### Documentation

- [ ] HCL/YAML comments — every security-relevant field in the changed file must have an inline comment explaining why (following the existing pattern)
- [ ] `docs/06-kubernetes-guide.md` — if the change affects the Helm chart's visible behaviour (new template, changed probe paths, new security setting), update the Helm chart walkthrough section
- [ ] `docs/09-security-model.md` kube-score table — if the change is specifically to satisfy a kube-score check that was previously failing, add that check to the table

#### Verification

- [ ] `./gradlew shadowJar` (Helm chart re-bundled)
- [ ] `BlueprintVerifierKt --blueprint springboot-eks --project test` — kube-score passes (kube-score runs as part of `validateWorkspace` for TERRAFORM_K8S)
- [ ] `./gradlew build` green

---

## 6. Bump the Terraform Provider Version

Updating `terraformProviderVersion` in any blueprint JSON file.

### Why This Is a Coordinated Change

The provider version is the same across all blueprints — they all share the same `hashicorp/aws` provider. A version bump must be verified across **all blueprints**, not just the one you're focused on. A provider upgrade can break a template by removing a resource attribute, changing a default, or requiring a new attribute that the template doesn't set.

### Complete Sync Checklist

- [ ] Update `terraformProviderVersion` in **every** blueprint JSON in `src/main/resources/blueprints/` — they must all use the same version
- [ ] `BlueprintVerifierKt` run against **all six blueprints** — the weekly CI job does this, but run it locally first:
  ```bash
  ./gradlew shadowJar
  for id in springboot-postgres ktor-dynamodb nodejs-s3 fastapi-redis springboot-eks nodejs-eks; do
    java -cp build/libs/gentepede-mcp-all.jar \
      com.gentepede.ci.BlueprintVerifierKt --blueprint $id --project ci-test-$id
  done
  ```
- [ ] If any blueprint **fails** after the version bump: fix the template before merging — do not merge a bumped version that breaks a template
- [ ] `README.md` Supported Blueprints table `Provider` column — update all six rows to the new version
- [ ] `docs/04-blueprints-guide.md` `terraformProviderVersion` field example — update the example value in the schema section if it shows a specific version

---

## 7. Change a Code Layer

Changes to `InfrastructureService.kt`, `Engine.kt`, `Validator.kt`, or `Models.kt`. The layering is deliberate — see [Architecture Ground Rules](../CONTRIBUTING.md#architecture-ground-rules).

### Rules Per Layer

| Layer | What changes are allowed | What is forbidden |
|---|---|---|
| `Main.kt` | Tool registrations (name, description, input schema), server startup | Business logic, workspace operations, CLI calls |
| `Engine.kt` | MCP param extraction, output formatting, error message text | ProcessBuilder calls, file I/O, AWS operations |
| `InfrastructureService.kt` | All business logic: workspace creation, Terraform orchestration, Helm operations | MCP SDK types, JSON-RPC types |
| `Validator.kt` | CLI output parsing (checkov JSON, kube-score text, infracost JSON, caller identity) | Workspace logic, Terraform orchestration |
| `Models.kt` | `@Serializable` data class definitions, enums | Business logic, I/O operations |

### Complete Sync Checklist

#### If you change `Models.kt`

- [ ] All callers updated: `Engine.kt`, `InfrastructureService.kt`, `Validator.kt`, `BlueprintVerifier.kt`
- [ ] Tests updated: `InfrastructureServiceTest.kt`, `ValidatorTest.kt`
- [ ] If a data class is described in `docs/16-tool-architecture.md`: update that section

#### If you change a public method in `InfrastructureService.kt`

- [ ] `Engine.kt` updated (it calls every public method)
- [ ] `InfrastructureServiceTest.kt` updated (tests every public method)
- [ ] `docs/16-tool-architecture.md` updated for that tool's flow section (numbered steps)
- [ ] `docs/08-tools-reference.md` updated if the observable behaviour (inputs, outputs, error messages) changes

#### If you change `Validator.kt` output parsing

- [ ] `ValidatorTest.kt` updated
- [ ] If the change affects what checkov/kube-score findings look like in tool output: `docs/08-tools-reference.md` example responses

#### If you change `Engine.kt` output formatting

- [ ] `docs/08-tools-reference.md` success/error response examples updated (these examples are copied from real output)

#### If you change the architecture separation itself (adding a new public method, splitting a class)

- [ ] `CONTRIBUTING.md` Architecture Ground Rules section updated
- [ ] `docs/02-architecture.md` Technical Call Graph updated
- [ ] `docs/13-development-guide.md` "The Deliberate Layering" section updated
- [ ] `docs/16-tool-architecture.md` Layer explanations updated

---

## Verifying Your Change Before Opening a PR

Run these three commands in order. All three must be green:

```bash
# 1. Compile and run unit tests
./gradlew build

# 2. Re-bundle templates and Helm chart into the JAR
./gradlew shadowJar

# 3. MCP protocol smoke test — verifies all 8 tools register via JSON-RPC
python3 .github/scripts/mcp-smoke-test.py

# 4. Run the blueprint verifier against all blueprints (terraform validate + checkov)
for id in springboot-postgres ktor-dynamodb nodejs-s3 fastapi-redis springboot-eks nodejs-eks; do
  echo "=== $id ==="
  java -cp build/libs/gentepede-mcp-all.jar \
    com.gentepede.ci.BlueprintVerifierKt --blueprint $id --project ci-test-$id
done
```

If any step fails, resolve it before opening the PR. The CI workflows run steps 1–4 automatically on every push (see `docs/18-github-actions-guide.md` for a full description of each workflow).

---

## Checking What Was Bundled

If you add a new file (template, Helm chart, or blueprint JSON) and want to confirm it was included in the fat JAR:

```bash
./gradlew shadowJar
jar tf build/libs/gentepede-mcp-all.jar | grep -E "(blueprint|templates|helm-chart)"
```

If a file is missing from this output, it was not included in the `processResources` Gradle task and will not be found at runtime. Check `build.gradle.kts` to ensure the file's directory is in the `srcDir` include list.
