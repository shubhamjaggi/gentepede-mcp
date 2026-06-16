# GitHub Actions Guide

This document explains every automated check in this repo in plain English: what it does, when it runs, why it exists, and how it is structured to avoid redundancy.

---

## Overview

Four workflows protect the codebase, plus Dependabot for automated dependency updates:

| Workflow | Trigger | Purpose |
|---|---|---|
| `ci.yml` | Every push and PR to `main` | Build, unit tests, test annotation, coverage gate, MCP smoke test, blueprint validate, internal link check, dependency graph |
| `lint.yml` | Every push and PR to `main` | Terraform fmt + tflint, blueprint JSON schema, YAML lint |
| `blueprint-verify.yml` | Weekly (Monday 09:00 UTC) + manual | Long-form verification; external link check; updates `lastVerifiedDate` on success |
| `dependency-review.yml` | Every PR to `main` | Block PRs that introduce HIGH/CRITICAL vulnerability dependencies |
| Dependabot | Weekly (Monday) | Opens PRs to bump Gradle deps and GitHub Actions versions |

`ci.yml` and `lint.yml` run on every merge and catch most regressions within minutes, at zero cost — none of their checks make real AWS API calls.

---

## `ci.yml` — Build, Test, Blueprint Validate

**File:** `.github/workflows/ci.yml`
**Runs on:** Every push to `main` and every pull request targeting `main`.

This workflow has three jobs. Jobs 2 and 3 both depend on Job 1.

### Job 1: `build-and-test`

What it does, in order:

1. **`./gradlew build`** — Compiles all Kotlin source files and runs every unit test (`InfrastructureServiceTest`, `ValidatorTest`, `EngineTest`). JaCoCo generates a coverage report as a by-product.

2. **Annotate test results** — Uses `mikepenz/action-junit-report` to post a per-test pass/fail annotation directly in the GitHub PR check run and summary. Runs with `if: always()` so failing tests are visible even when the build step fails. Requires `checks: write` permission (set at the workflow level).

3. **Upload coverage report** — The JaCoCo HTML and XML coverage reports are uploaded as a workflow artifact (`coverage-report`) retained for 7 days. Gives contributors a downloadable coverage breakdown without needing to build locally.

4. **Check coverage threshold** — Parses `build/reports/jacoco/test/jacocoTestReport.xml` and fails if instruction coverage falls below 55%. The threshold is intentionally conservative; raise it in the inline Python script as test coverage improves.

5. **`./gradlew shadowJar`** — Builds the fat JAR (`build/libs/gentepede-mcp-all.jar`) that bundles Kotlin bytecode, blueprint JSON files, Terraform template files, and the Helm chart.

6. **Upload fat JAR** — Uploads the JAR as a workflow artifact (`gentepede-jar`) so Job 2 can download it without rebuilding.

7. **MCP protocol smoke test** (`python3 .github/scripts/mcp-smoke-test.py`) — Starts the fat JAR, completes the JSON-RPC `initialize` handshake, calls `tools/list`, and verifies all 8 expected tools are registered. This is the only CI check that exercises `Main.kt` and `Engine.kt` at the protocol level — unit tests never start the actual MCP server. The MCP Kotlin SDK v0.13.x uses newline-delimited JSON (NDJSON): one JSON object per line, no Content-Length headers.

8. **Check internal markdown links** — Runs `lychee --offline` on every `*.md` file. Checks that all relative file links resolve to real files. Uses `--offline` to skip external URLs and avoid rate-limit failures — external links are checked by the weekly `blueprint-verify.yml` job instead.

### Job 2: `blueprint-validate` (needs Job 1)

1. Downloads the fat JAR produced by Job 1.
2. Installs Terraform and checkov.
3. For each of the 6 blueprints, runs `BlueprintVerifierKt`:
   - `generateWorkspace` — copies the Terraform template family into a temporary workspace
   - `terraform init -backend=false` — downloads the pinned provider version without configuring the S3 backend (no credentials needed)
   - `terraform validate` — checks HCL syntax without making AWS API calls
   - `checkov` — checks security posture (blocks on HIGH or CRITICAL findings)

If any blueprint fails, the entire job fails and lists which blueprints broke.

**Why this matters:** Blueprint validation runs `terraform validate` on every merge, not just weekly. A broken template or blueprint JSON is caught immediately rather than waiting up to 7 days for the weekly run.

### Job 3: `submit-dependency-graph` (needs Job 1, push events only)

Runs `gradle/actions/dependency-submission` to post the complete Gradle dependency graph to GitHub's dependency API. This populates the data that `dependency-review.yml` uses when comparing dependencies in PRs. Only runs on pushes to `main` (fork PRs lack write permission for this).

Requires `contents: write` at the job level (not the workflow level, keeping the scope narrow).

---

## `lint.yml` — Terraform, JSON Schema, YAML

**File:** `.github/workflows/lint.yml`
**Runs on:** Every push to `main` and every pull request targeting `main`.

Three parallel jobs — none depends on the build. Lint jobs run independently so formatting/schema errors are visible immediately without waiting for the JVM build.

### Job 1: `terraform` — Terraform fmt + tflint

1. **`terraform fmt -check -recursive templates/`** — Fails if any `.tf` file is not correctly formatted. Fix locally with `terraform fmt -recursive templates/`.

2. **tflint with AWS ruleset** — Runs `tflint --chdir=templates/{ecs,lambda,eks}` to check each template family with the AWS provider ruleset. Catches deprecated arguments, invalid resource configurations, and HCL style issues that `terraform validate` does not. Configuration lives in `.tflint.hcl` at the repo root (tflint searches parent directories so `--chdir` picks it up automatically).

   Key rules disabled in `.tflint.hcl` because they don't apply to these templates:
   - `terraform_required_providers` / `terraform_required_version` — `providers.tf` is generated at runtime by `InfrastructureService`, not stored in the template directory.
   - `terraform_unused_declarations` — `aws_profile` and `aws_region` variables are consumed by the runtime-generated `providers.tf` that tflint cannot see.
   - `terraform_module_pinned_source` — no modules are used.

### Job 2: `blueprint-json` — Blueprint JSON Schema

Runs `.github/scripts/validate-blueprint-schemas.py` directly against the blueprint JSON files — no JVM required. Validates:
- All required fields are present (`blueprintId`, `displayName`, `description`, `outputType`, `templateFamily`, `terraformProviderVersion`, `lastVerifiedDate`, `techStack`, `awsResources`, `variables`, `securityBaseline`)
- `blueprintId` matches the JSON filename
- `outputType` is a valid enum (`TERRAFORM_ONLY` or `TERRAFORM_K8S`)
- `templateFamily` is a valid enum (`ecs`, `lambda`, or `eks`)
- `terraformProviderVersion` is in `X.Y.Z` format
- `lastVerifiedDate` is in `YYYY-MM` format
- Each variable and AWS resource has all required sub-fields
- Variable `type` values are valid (`string`, `number`, `boolean`)

**Why this matters:** Structural blueprint errors produce cryptic JVM stack traces from `BlueprintVerifierKt`. This step produces clear, specific error messages earlier in the pipeline.

### Job 3: `yaml` — YAML lint

Runs `yamllint` on all files under `.github/`. Catches YAML syntax errors, inconsistent indentation, and other structural issues in workflow files that can cause silent GitHub Actions failures.

Configuration lives in `.yamllint.yml` at the repo root. Key settings:
- Line length: 160 characters max, warning only (not error) — long `run:` blocks and `args:` strings are common in CI YAML.
- `truthy.check-keys: false` — allows `on:` as a GitHub Actions trigger key without being flagged as a non-boolean truthy value.

---

## `blueprint-verify.yml` — Weekly Blueprint Verification

**File:** `.github/workflows/blueprint-verify.yml`
**Runs on:** Every Monday at 09:00 UTC, and on-demand via "Run workflow" in the GitHub Actions UI.

This workflow runs the same `terraform validate` + checkov check that `ci.yml`'s `blueprint-validate` job runs, but with three additional responsibilities:

1. **Failure → open GitHub issue:** If any blueprint fails, a GitHub issue is automatically created with the blueprint ID, provider version, and a reproduction command.

2. **Success → update `lastVerifiedDate`:** When all blueprints pass, the `lastVerifiedDate` field in every blueprint JSON file is updated to the current year-month (e.g. `2026-06`) and committed back to `main` with `[skip ci]` in the message.

3. **Full external link check:** Runs `lychee` WITHOUT `--offline` to verify that all external URLs in Markdown docs are reachable. The 30-second timeout and 3 retries guard against transient network failures. Shield badges (img.shields.io) are excluded because they frequently return non-200 status codes for rate-limiting purposes. `ci.yml` uses `--offline` on every PR; this weekly run is the only place external URLs are verified.

### Why run this weekly if `ci.yml` already validates blueprints on every merge?

The merge-time check catches regressions you introduce. The weekly check catches drift from **external** changes: a new minor version of the AWS provider might deprecate an attribute; a new checkov rule might flag something that wasn't flagged before. Neither would show up in a code change.

The `lastVerifiedDate` field is only updated by the weekly job. This keeps the timestamp meaningful: it records the last full scheduled verification, not the last code change.

---

## `dependency-review.yml` — PR Dependency Security Review

**File:** `.github/workflows/dependency-review.yml`
**Runs on:** Every pull request targeting `main`.

Uses GitHub's built-in `actions/dependency-review-action` to compare the dependencies introduced by a PR against the existing dependency graph. Fails if any new dependency has a known HIGH or CRITICAL severity CVE. Posts a summary comment on the PR with the full dependency diff.

The dependency graph is populated by the `submit-dependency-graph` job in `ci.yml`, which runs `gradle/actions/dependency-submission` on every push to `main`. This ensures the baseline is always current.

**Cost:** Free for all public repositories. No third-party service or API key required.

---

## Dependabot — Automated Dependency Updates

**File:** `.github/dependabot.yml`
**Runs on:** Every Monday (GitHub manages scheduling).

Dependabot automatically opens pull requests to keep two types of dependencies current:

| Ecosystem | What it updates |
|---|---|
| `gradle` | MCP SDK, kotlinx-serialization, kotlinx-coroutines, JUnit |
| `github-actions` | `actions/checkout`, `actions/setup-java`, `hashicorp/setup-terraform`, etc. |

Each update PR runs the full `ci.yml` and `lint.yml` workflows, so regressions from a dependency update are caught before merging.

At most 5 open Dependabot PRs at a time per ecosystem, to avoid queue buildup.

**Note:** Dependabot does not update the `tflint_version` parameter inside the `setup-tflint` action step, or the `tflint-ruleset-aws` version inside `.tflint.hcl`. Update those manually when new versions are released.

---

## Coverage Reports

JaCoCo generates coverage reports as part of `./gradlew build`. Coverage artifacts are uploaded by `ci.yml` and available under "Artifacts" on each GitHub Actions run page.

To view coverage locally:
```bash
./gradlew test
# Open: build/reports/jacoco/test/html/index.html
```

The CI threshold is currently set at 55% instruction coverage. To raise it, edit the `threshold = 55` line in the `Check coverage threshold` step in `ci.yml`.

---

## Scripts

### `.github/scripts/mcp-smoke-test.py`

A Python script that acts as a minimal MCP client. It:
1. Starts the fat JAR as a subprocess
2. Sends `initialize` via newline-delimited JSON (NDJSON) — one JSON object per line, no Content-Length headers. This is the wire format used by the MCP Kotlin SDK v0.13.x.
3. Sends `notifications/initialized` (required by the MCP spec before calling any tool)
4. Sends `tools/list` and asserts all 8 expected tools are present

Exit 0 = pass. Exit 1 = any tool missing, protocol error, or server crash.

### `.github/scripts/validate-blueprint-schemas.py`

A Python script that validates every blueprint JSON file against the expected structural schema. Runs in `lint.yml`'s `blueprint-json` job and completes in under 2 seconds. Exit 0 = all blueprints structurally valid. Exit 1 = one or more violations with specific error messages.

---

## Adding a New CI Check

Before adding a new workflow step or job:

1. **Check for redundancy** — Does the check already run in one of the existing jobs? For example, blueprint schema validation runs in `lint.yml` and full blueprint validation runs in `ci.yml`; adding a third place would be redundant.

2. **Free tier only** — All checks run on `ubuntu-latest` GitHub-hosted runners (free for public repos). Do not add steps that require external paid services (Snyk, SonarCloud, NVD API keys).

3. **Assign to the right workflow:**
   - Code correctness (tests, build, functional checks) → `ci.yml`
   - Formatting, linting, static analysis → `lint.yml`
   - Scheduled health checks with external state → `blueprint-verify.yml`
   - PR security gates → `dependency-review.yml`

4. **Document it here** — Update this file to explain what the new check does, when it runs, and why it's not redundant with existing checks.
