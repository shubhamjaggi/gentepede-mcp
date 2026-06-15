# GitHub Actions Guide

This document explains every automated check in this repo in plain English: what it does, when it runs, why it exists, and how it is structured to avoid redundancy.

---

## Overview

Four workflows protect the codebase, plus Dependabot for automated dependency updates:

| Workflow | Trigger | Purpose |
|---|---|---|
| `ci.yml` | Every push and pull request to `main` | Build, unit tests, MCP smoke test, blueprint validate, link check |
| `integration-local.yml` | Every push and pull request to `main` | Full end-to-end test using LocalStack (free, no real AWS) |
| `blueprint-verify.yml` | Weekly (Monday 09:00 UTC) + manual | Long-form verification; updates `lastVerifiedDate` on success |
| Dependabot | Weekly (Monday) | Opens PRs to bump Gradle deps and GitHub Actions versions |

`ci.yml` and `integration-local.yml` run in parallel on every merge. Together they catch most regressions within minutes, at zero cost.

---

## `ci.yml` — Build, Test, Smoke Test, Blueprint Validate

**File:** `.github/workflows/ci.yml`
**Runs on:** Every push to `main` and every pull request targeting `main`.

This workflow has two jobs that run sequentially.

### Job 1: `build-and-test`

What it does, in order:

1. **`./gradlew build`** — Compiles all Kotlin source files and runs every unit test (`InfrastructureServiceTest`, `ValidatorTest`, `EngineTest`). If any test fails or the code does not compile, the rest of the workflow does not run. JaCoCo generates a coverage report as a by-product of this step.

2. **Upload coverage report** — The JaCoCo HTML and XML coverage reports are uploaded as a workflow artifact (`coverage-report`) retained for 7 days. This gives contributors a downloadable coverage breakdown for any given run without needing to build locally.

3. **`./gradlew shadowJar`** — Builds the fat JAR (`build/libs/gentepede-mcp-all.jar`) that bundles Kotlin bytecode, blueprint JSON files, Terraform template files, and the Helm chart into a single runnable file.

4. **Upload fat JAR** — Uploads the JAR as a workflow artifact (`gentepede-jar`) so Job 2 can download it without rebuilding.

5. **MCP protocol smoke test** (`python3 .github/scripts/mcp-smoke-test.py`) — Starts the fat JAR, completes the JSON-RPC `initialize` handshake, calls `tools/list`, and verifies all 8 expected tools are registered. This is the only CI check that exercises `Main.kt` and `Engine.kt` at the protocol level — unit tests never start the actual MCP server.

6. **Check internal markdown links** — Runs `lychee --offline` on every `*.md` file in the repo. Checks that all relative file links (like `[docs/04-blueprints-guide.md](docs/04-blueprints-guide.md)`) resolve to real files. Uses offline mode to skip external URLs and avoid rate-limit failures. Catches broken cross-references between doc files as the repo evolves.

### Job 2: `blueprint-validate` (runs after Job 1)

What it does:

1. Downloads the fat JAR produced by Job 1 (no rebuild needed).
2. Installs Terraform and checkov.
3. For each of the 6 blueprints, runs `BlueprintVerifierKt`:
   - `generateWorkspace` — copies the Terraform template family into a temporary workspace
   - `terraform init` — downloads the pinned provider version
   - `terraform validate` — checks HCL syntax without making AWS API calls
   - `checkov` — checks security posture (blocks on HIGH or CRITICAL findings)

If any blueprint fails, the entire job fails and lists which blueprints broke.

**Why this matters:** Blueprint validation runs `terraform validate` on every merge, not just weekly. A broken template or blueprint JSON is caught immediately rather than waiting up to 7 days for the weekly run.

---

## `integration-local.yml` — LocalStack End-to-End

**File:** `.github/workflows/integration-local.yml`
**Runs on:** Every push to `main` and every pull request targeting `main`, **in parallel** with `ci.yml`.

This workflow starts a real LocalStack Community container as a Docker service and runs the complete 7-step tool flow against it for the `ktor-dynamodb` blueprint:

```
generate → validate → plan → apply → detect_drift → audit → destroy
```

Each step calls the actual `InfrastructureService` method. Terraform runs against LocalStack's mock AWS APIs. The test passes only if all 7 steps complete without error.

### Why `ktor-dynamodb`?

`ktor-dynamodb` is the only blueprint where all AWS services it provisions (VPC, ALB, ECS, DynamoDB, KMS, IAM, CloudWatch) are supported by LocalStack Community (the free tier). The other blueprints require LocalStack Pro:

| Blueprint | Why not covered here |
|---|---|
| `springboot-postgres` | Full RDS multi-AZ apply is limited on Community |
| `fastapi-redis` | ElastiCache replication group requires Pro |
| `springboot-eks` | EKS control plane requires Pro |
| `nodejs-eks` | EKS control plane requires Pro |
| `nodejs-s3` | CloudFront OAC support varies by Community version |

These blueprints are still protected by `terraform validate` + checkov in `ci.yml`'s `blueprint-validate` job.

### What this catches that unit tests cannot

- Regressions in workspace wiring (wrong directory structure → Terraform init fails)
- `providers.tf` generation bugs (invalid endpoint config → plan fails)
- Lock file integrity (plan checksum written at plan time, verified at apply time)
- The destroy path (workspace deleted, state backed up)

Unit tests mock or skip all external CLI calls. The integration test runs the real CLI calls against a real (mocked) AWS endpoint.

---

## `blueprint-verify.yml` — Weekly Blueprint Verification

**File:** `.github/workflows/blueprint-verify.yml`
**Runs on:** Every Monday at 09:00 UTC, and on-demand via "Run workflow" in the GitHub Actions UI.

This workflow runs the same `terraform validate` + checkov check that `ci.yml`'s `blueprint-validate` job runs, but with two additional responsibilities:

1. **Failure → open GitHub issue:** If any blueprint fails, a GitHub issue is automatically created with the blueprint ID, provider version, and a reproduction command so contributors know exactly what broke and how to reproduce it.

2. **Success → update `lastVerifiedDate`:** When all blueprints pass, the `lastVerifiedDate` field in every blueprint JSON file is updated to the current year-month (e.g. `2026-06`) and committed back to `main`. This timestamp is displayed in the README and `docs/04-blueprints-guide.md` so users can see how recently each blueprint was verified against its pinned provider version.

### Why run this weekly if `ci.yml` already validates blueprints on every merge?

The merge-time check and the weekly check have different jobs:
- The merge-time check (in `ci.yml`) catches regressions you introduce.
- The weekly check catches drift from **external** changes: a new minor version of the AWS provider might deprecate an attribute; a new checkov rule might flag something that wasn't flagged before. Neither would show up in a code change.

The `lastVerifiedDate` field is only updated by the weekly job, not by the merge-time job. This keeps the timestamp meaningful: it records the last full scheduled verification, not the last code change.

---

## Dependabot — Automated Dependency Updates

**File:** `.github/dependabot.yml`
**Runs on:** Every Monday (GitHub manages scheduling).

Dependabot automatically opens pull requests to keep two types of dependencies current:

| Ecosystem | What it updates |
|---|---|
| `gradle` | MCP SDK, kotlinx-serialization, kotlinx-coroutines, JUnit |
| `github-actions` | `actions/checkout`, `actions/setup-java`, `hashicorp/setup-terraform`, etc. |

Each update PR runs the full `ci.yml` and `integration-local.yml` workflows, so regressions from a dependency update are caught before merging.

At most 5 open Dependabot PRs at a time per ecosystem, to avoid queue buildup.

---

## Coverage Reports

JaCoCo generates coverage reports as part of `./gradlew build` (the test task runs coverage as a finalizer). Coverage artifacts are uploaded by `ci.yml` and available under "Artifacts" on each GitHub Actions run page.

To view coverage locally:
```bash
./gradlew test
# Open: build/reports/jacoco/test/html/index.html
```

---

## Adding a New CI Check

Before adding a new workflow step or job:

1. **Check for redundancy** — Does the check already run in one of the existing jobs? For example, blueprint validation already runs in both `ci.yml` and `blueprint-verify.yml`; adding a third place would be redundant.

2. **Free tier only** — All checks in this repo run on `ubuntu-latest` GitHub-hosted runners (free for public repos). Do not add steps that require external paid services (Snyk, SonarCloud, NVD API keys).

3. **Add to an existing job if possible** — Adding a step to `build-and-test` is cheaper than adding a new parallel job, because jobs incur startup overhead.

4. **Document it here** — Update this file to explain what the new check does, when it runs, and why it's not redundant with existing checks.

---

## Scripts

### `.github/scripts/mcp-smoke-test.py`

A Python script that acts as a minimal MCP client. It:
1. Starts the fat JAR as a subprocess
2. Sends `initialize` via Content-Length-framed JSON-RPC (same protocol as the Language Server Protocol)
3. Sends `notifications/initialized` (required by the MCP spec before calling any tool)
4. Sends `tools/list` and asserts all 8 expected tools are present

Exit 0 = pass. Exit 1 = any tool missing, protocol error, or server crash.

This is the only CI check that tests the JSON-RPC framing layer in `Main.kt`. Unit tests call `Engine` and `InfrastructureService` directly, bypassing the stdio transport entirely.
