# Development Guide

For contributors and anyone who wants to understand or modify the Gentepede MCP codebase.

---

## Project Structure

```
gentepede-mcp/
├── src/
│   ├── main/
│   │   ├── kotlin/com/gentepede/
│   │   │   ├── Main.kt                  ← MCP server entry point; registers all 8 tools
│   │   │   ├── Engine.kt                ← Thin MCP handler; extracts params, formats output
│   │   │   ├── InfrastructureService.kt ← All business logic; fully testable without MCP
│   │   │   ├── Validator.kt             ← CLI output parsing (checkov, kube-score, infracost)
│   │   │   ├── Models.kt                ← All shared data classes; no business logic here
│   │   │   └── ci/
│   │   │       └── BlueprintVerifier.kt ← CI entrypoint for weekly blueprint verification
│   │   └── resources/
│   │       └── blueprints/              ← Blueprint JSON files (one per blueprint ID)
│   └── test/
│       └── kotlin/com/gentepede/
│           ├── InfrastructureServiceTest.kt
│           └── ValidatorTest.kt
├── templates/
│   ├── ecs/                             ← Terraform files for ECS-family blueprints
│   │   ├── main.tf
│   │   └── variables.tf
│   ├── lambda/                          ← Terraform files for Lambda-family blueprints
│   │   ├── main.tf
│   │   └── variables.tf
│   └── eks/                             ← Terraform files for EKS-family blueprints
│       ├── main.tf
│       └── variables.tf
├── helm-chart/                          ← Helm chart source; bundled into the fat JAR
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── hpa.yaml
│       ├── network-policy.yaml
│       └── resource-quota.yaml
├── docs/                                ← All documentation
├── .github/
│   └── workflows/
│       ├── ci.yml                       ← Build + test on every push/PR
│       └── blueprint-verify.yml         ← Weekly terraform validate + checkov on all blueprints
├── build.gradle.kts
└── gradlew
```

### The Deliberate Layering

```
Main.kt → Engine.kt → InfrastructureService.kt → Validator.kt
                                                 → Models.kt
```

- **Main.kt** knows about the MCP SDK. It registers tool names, descriptions, and input schemas. No logic.
- **Engine.kt** knows about MCP request/response types. It extracts parameters and formats human-readable output. No process execution.
- **InfrastructureService.kt** knows about workspaces, blueprints, and Terraform. It runs all external processes. No MCP types.
- **Validator.kt** knows about CLI output formats (checkov JSON, kube-score text, infracost JSON). No workspace logic.
- **Models.kt** knows nothing — it only defines data shapes.

This layering means you can test `InfrastructureService` in isolation without a running MCP server or a real Claude Desktop connection.

---

## Build

```bash
# Compile and run tests
./gradlew build

# Build only the fat JAR (faster; skips test report generation)
./gradlew shadowJar

# Output: build/libs/gentepede-mcp-all.jar
```

The `shadowJar` task bundles:
- All Kotlin/Java bytecode
- All dependencies (MCP SDK, kotlinx-serialization, coroutines)
- `src/main/resources/blueprints/*.json`
- `templates/**` (via the custom `processResources` task)
- `helm-chart/**` (via the same `processResources` task)

The `archiveVersion.set("")` setting strips the version from the filename so the output is always `gentepede-mcp-all.jar`, not `gentepede-mcp-1.0.0-all.jar`. All docs and CI workflows reference this fixed name.

---

## Running Tests

```bash
# Run all tests
./gradlew test

# Run a specific test class
./gradlew test --tests 'com.gentepede.InfrastructureServiceTest'
./gradlew test --tests 'com.gentepede.ValidatorTest'

# Run a single test method
./gradlew test --tests 'com.gentepede.InfrastructureServiceTest.springboot-postgres sets enable_rds to true'

# Show test output in terminal (not just in the HTML report)
./gradlew test --info
```

Test reports (HTML): `build/reports/tests/test/index.html`

### What the Tests Cover

`InfrastructureServiceTest` tests the business logic layer directly — no MCP server, no actual Terraform, no LocalStack:

- **Blueprint loading** — all 6 blueprint IDs load correctly, required fields are present
- **Workspace generation** — `generateWorkspace` creates the expected files in the right directories
- **tfvars content** — variables are merged correctly; `buildTfvarsContent` produces valid HCL
- **Data-tier toggles** — `enable_rds`, `enable_dynamodb`, `enable_redis` are set correctly per blueprint
- **Kind pre-flight** — `preflightKindClusterIfLocalK8s` throws `IllegalStateException` with the expected message when the kind cluster is missing and `GENTEPEDE_MODE=LOCAL`

`ValidatorTest` tests output parsing and CLI availability logic in isolation — no external tools need to be installed:

- **checkov severity thresholds** — HIGH/CRITICAL sets `passed=false` in validate mode; LOW/MEDIUM does not
- **checkov audit mode** — `abortOnHighCritical=false` always returns `passed=true` even for HIGH findings, but findings still appear in the report
- **kube-score output parsing** — `[CRITICAL]` lines are detected; `[OK]`/`[SKIPPED]` only means a passing result
- **plan file checksum** — same content produces identical checksums; different content produces different checksums; missing plan file pre-condition is confirmed
- **`isCommandAvailable`** — returns `false` for non-existent binaries; returns `true` for `java`
- **validate has no credential pre-flight** — confirms `validateWorkspace` does not call `aws sts get-caller-identity`
- **credential error wrapping** — `ProcessExecutionException` carries the original AWS error message

---

## Running the Server Locally

The server reads MCP JSON-RPC from stdin and writes to stdout. To interact with it manually:

```bash
# Build first
./gradlew shadowJar

# Start in LOCAL mode
GENTEPEDE_MODE=LOCAL java -jar build/libs/gentepede-mcp-all.jar
```

The server blocks on stdin. You can send a raw MCP initialize message to test:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}}}' | \
  GENTEPEDE_MODE=LOCAL java -jar build/libs/gentepede-mcp-all.jar
```

The response will be a JSON-RPC result containing the server's capabilities and the 8 registered tools.

For real end-to-end testing, configure Claude Desktop (see `docs/03-how-mcp-works.md`).

---

## Running the Blueprint Verifier Directly

The weekly CI job uses `BlueprintVerifierKt` to validate each blueprint without Claude Desktop. You can run it locally:

```bash
./gradlew shadowJar

GENTEPEDE_MODE=LOCAL java -cp build/libs/gentepede-mcp-all.jar \
  com.gentepede.ci.BlueprintVerifierKt \
  --blueprint springboot-postgres \
  --project ci-test-sp
```

Exit codes: 0 = pass, 1 = verification failed, 2 = bad arguments.

This requires `terraform` and `checkov` in PATH. It runs `generateWorkspace` + `validateWorkspace` without any AWS calls.

---

## Adding a New Blueprint

See `docs/10-adding-blueprints.md` for the step-by-step guide and `docs/17-contributor-sync-guide.md` for the complete list of files that must stay in sync. In summary:

1. Create `src/main/resources/blueprints/{id}.json`
2. Add the ID to `InfrastructureService.listBlueprints()`
3. If the blueprint's `awsResources` include a new type not handled by an existing family, add a new toggle in `injectDataTierToggles()` and gate the resource in the corresponding `main.tf` with `count = var.enable_X ? 1 : 0`
4. If the blueprint is `TERRAFORM_K8S` with a new framework, add a port/path triple to `buildHelmValues()`
5. Update four documentation files: `README.md`, `docs/04-blueprints-guide.md`, `docs/15-blueprint-to-resource-map.md`, and `docs/00-glossary.md` (if new services introduced)
6. Run `./gradlew shadowJar && GENTEPEDE_MODE=LOCAL java -cp ... com.gentepede.ci.BlueprintVerifierKt --blueprint {id} --project test-{id}`

---

## Modifying Terraform Templates

Templates live in `templates/{family}/main.tf` and `templates/{family}/variables.tf`. After editing:

1. **Rebuild the JAR** — templates are bundled at build time: `./gradlew shadowJar`
2. **Run the verifier** against any blueprint using that family:
   ```bash
   GENTEPEDE_MODE=LOCAL java -cp build/libs/gentepede-mcp-all.jar \
     com.gentepede.ci.BlueprintVerifierKt --blueprint springboot-postgres --project test
   ```
3. **Security group descriptions** must match `^[0-9A-Za-z_ .:/()#,@\[\]+=&;{}!$*-]*$` — em dashes (`—`) are invalid and cause `terraform validate` to fail with the AWS provider.
4. **ElastiCache encryption** (`at_rest_encryption_enabled`) is only supported on `aws_elasticache_replication_group`, not `aws_elasticache_cluster`. The ECS template uses `replication_group`.

---

## Modifying the Helm Chart

The source Helm chart is in `helm-chart/`. After editing:

1. Rebuild: `./gradlew shadowJar`
2. Run a blueprint verifier on any EKS blueprint:
   ```bash
   GENTEPEDE_MODE=LOCAL java -cp build/libs/gentepede-mcp-all.jar \
     com.gentepede.ci.BlueprintVerifierKt --blueprint springboot-eks --project test
   ```
3. `kube-score` runs as part of `validateWorkspace` for TERRAFORM_K8S blueprints. Any `[CRITICAL]` finding will block. Run `audit_infrastructure_package` for the full report.

---

## CI Workflows

### ci.yml — Build and Test

Triggers on every push to `main` and every pull request.

Steps:
1. Checkout
2. Set up Java 21 (Temurin) with Gradle cache
3. `./gradlew build` — compiles, runs all tests
4. `./gradlew shadowJar` — builds the fat JAR

This workflow catches compilation errors, test failures, and mismatched imports.

### blueprint-verify.yml — Weekly Verification

Runs every Monday at 09:00 UTC. Can also be triggered manually via GitHub Actions → "Run workflow".

Steps:
1. Checkout, set up Java 21, install Terraform + checkov
2. Build fat JAR
3. For each blueprint JSON in `src/main/resources/blueprints/`: call `BlueprintVerifierKt`, which runs `generateWorkspace` + `validateWorkspace` (`terraform init` + `terraform validate` + checkov)
4. On failure: open a GitHub issue with the failing blueprint and reproduction command
5. On success: update `lastVerifiedDate` in all blueprint JSONs and push the change

**Important:** This workflow does NOT use LocalStack. `terraform validate` makes zero AWS API calls and is a purely static check.

---

## Debugging Tips

### "Workspace '$projectName' not found" from an IllegalStateException

All 6 `check(...)` calls in `InfrastructureService` use `IllegalStateException` (via Kotlin's `check()`), which is caught by the `catch (e: IllegalStateException)` blocks in `Engine.kt`. If you see "Workspace not found" in a tool error, trace back to the `check(workspaceDir.toFile().exists())` call in the relevant method.

### "require() vs check()" pitfall

Kotlin's `require()` throws `IllegalArgumentException`; `check()` throws `IllegalStateException`. Engine.kt catches `IllegalStateException` for workspace-guard errors and `IllegalArgumentException` for invalid-input errors (e.g. bad blueprint name). Using `require()` where `check()` is needed means the exception is uncaught and surfaces as an unhandled error rather than a clean error response.

### ProcessBuilder pipe deadlock

If you add a new `runProcess()` call and the process hangs forever, it is likely a pipe-buffer deadlock: the process fills its stdout buffer waiting for it to be consumed, but your code is waiting to read stderr (or vice versa). The fix is always the same: start separate threads for stdout and stderr before calling `waitFor()`. See the existing `runProcess()` implementation in `InfrastructureService.kt`.

### Checking what goes into the fat JAR

```bash
./gradlew shadowJar
jar tf build/libs/gentepede-mcp-all.jar | grep -E "(blueprint|template|helm)"
# Should show: blueprints/springboot-postgres.json, templates/ecs/main.tf, helm-chart/Chart.yaml, etc.
```

If a file is missing from this list, it was not included in the `processResources` task and will not be found at runtime.
