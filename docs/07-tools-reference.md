# Tools Reference

This document covers each tool's inputs, outputs, and when to use it. For a deep dive into how each tool works under the hood — every code layer, every CLI command, every file written — see [docs/15-tool-architecture.md](15-tool-architecture.md).

## Workflow Order

```
generate_infrastructure_package
        │
        ▼
validate_infrastructure_package   ← static analysis, no AWS calls
        │
        ▼
plan_infrastructure_package       ← hits real AWS
        │
        ▼  (review the plan output)
        │
        ▼
apply_infrastructure_package      ← deploys infrastructure
        │
        ├── detect_drift          ← ongoing, run anytime after apply
        │
        └── destroy_infrastructure_package   ← when done

audit_infrastructure_package      ← standalone, run anytime
```

---

## Tool 1: `list_available_blueprints`

**When to use:** First step. Before generating anything, run this to see what blueprints are available.

**Inputs:** None

**Success response:**
```
Available Blueprints (6)
============================================================

Blueprint ID:       springboot-postgres
Display Name:       Spring Boot + PostgreSQL (ECS Fargate)
Description:        Deploys a Spring Boot application on ECS Fargate...
Output Type:        TERRAFORM_ONLY
Template Family:    ecs
Framework:          Spring Boot (Java/Kotlin)
Database:           PostgreSQL
AWS Resources:      VPC, ALB, ECS_FARGATE, RDS_POSTGRES, KMS
Provider Version:   5.82.0
Last Verified:      2026-06
------------------------------------------------------------
...
```

---

## Tool 2: `generate_infrastructure_package`

**When to use:** After choosing a blueprint. Generates all Terraform and Helm files into a workspace.

**Inputs:**
```json
{
  "blueprint_name": "springboot-postgres",
  "project_name":   "my-api",
  "variables": {
    "container_image":  "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-api:1.0.0",
    "certificate_arn":  "arn:aws:acm:us-east-1:123456789012:certificate/abc",
    "db_name":          "appdb",
    "environment":      "dev"
  }
}
```

`project_name` must be alphanumeric + hyphens only.
`variables` can be an empty object `{}` if all blueprint variables have defaults.

**Success response:**
```
Infrastructure Package Generated
============================================================
Project:        my-api
Blueprint:      springboot-postgres
Output Type:    TERRAFORM_ONLY
Workspace:      /Users/you/.gentepede/workspaces/my-api

AWS Resources to Create:
  - VPC
  - ALB
  - ECS_FARGATE
  - RDS_POSTGRES
  - KMS

Next Step: Run validate_infrastructure_package to check Terraform syntax and security posture.
```

**Warning (if existing state detected):**
```
⚠ Warning: existing state detected. Variables differ from previous generation.
Run plan_infrastructure_package first to review what will change.
```

**Error responses:**
- `Error: Blueprint 'bad-name' not found.` — blueprint_name typo
- `Error: project_name must contain only alphanumeric characters and hyphens` — invalid name

---

## Tool 3: `validate_infrastructure_package`

**When to use:** After generate, before plan. Pure static analysis — no AWS credentials needed.

**What it runs:**
1. `terraform init -backend=false -no-color` (idempotent; skips S3 backend init so no credentials needed)
2. `terraform validate -no-color`
3. `checkov -d . -o json --compact` (aborts on HIGH/CRITICAL)
4. `helm template | kube-score score -` (TERRAFORM_K8S only; aborts on CRITICAL)

**Inputs:**
```json
{ "project_name": "my-api" }
```

**Success response:**
```
Validation Report: my-api
============================================================
terraform validate: PASSED
checkov: PASSED (3 findings, none HIGH/CRITICAL)
kube-score: SKIPPED (not a TERRAFORM_K8S blueprint)

✓ All validation checks passed. Ready to run plan_infrastructure_package.
```

**Error response (checkov HIGH finding):**
```
Error: Validation Report: my-api
...
checkov: FAILED (1 HIGH/CRITICAL findings)

Checkov Findings:
  [HIGH] CKV_AWS_17 — aws_db_instance.postgres
    RDS publicly accessible
    Remediation: Set publicly_accessible = false

✗ Validation failed. Resolve the above findings before planning.
```

**Note:** This tool never calls `aws sts get-caller-identity`. It is pure static analysis.

---

## Tool 4: `plan_infrastructure_package`

**When to use:** After successful validate. Contacts real AWS.

**What it runs:**
1. `aws sts get-caller-identity` (credential pre-flight)
2. `terraform init -no-color`
3. `terraform plan -out=gentepede.tfplan -no-color`
4. `terraform show -json gentepede.tfplan` → writes `gentepede-plan.json`
5. SHA-256 checksum of `gentepede.tfplan` → written to `gentepede.lock.json`
6. `infracost breakdown --path=. --terraform-plan-file=gentepede-plan.json` (if installed)
7. TERRAFORM_K8S: `helm template {project} helm/ -f helm/values.yaml` (rendered for review)

**Inputs:**
```json
{ "project_name": "my-api" }
```

**Success response:**
```
Terraform Plan Summary: my-api
============================================================
Will CREATE  14 resources
Will MODIFY   0 resources
Will DESTROY  0 resources

Resource Changes:
  [CREATE] aws_kms_key.main
  [CREATE] aws_vpc.main
  [CREATE] aws_subnet.public[0]
  ... (14 total)

Cost Estimate: $73.12/USD per month (estimated)

Plan file: /Users/you/.gentepede/workspaces/my-api/gentepede.tfplan
Lock file: /Users/you/.gentepede/workspaces/my-api/gentepede.lock.json

Next Step: Review the plan above, then run apply_infrastructure_package.
```

---

## Tool 5: `apply_infrastructure_package`

**When to use:** After reviewing the plan output. WARNING: deploys real infrastructure.

**What it does:**
1. Credential pre-flight (`aws sts get-caller-identity`)
2. Verify `gentepede.tfplan` SHA-256 matches `gentepede.lock.json`
3. Backup `terraform.tfstate` to `~/.gentepede/backups/{project}/{timestamp}.tfstate`
4. `terraform apply gentepede.tfplan -no-color`
5. TERRAFORM_K8S: `helm upgrade --install ...` (targets current `~/.kube/config` context)
6. Update `gentepede.lock.json` with `lastApplied` + `stateBackupPath`

**Inputs:**
```json
{ "project_name": "my-api" }
```

**Success response:**
```
Apply Complete: my-api
============================================================
Apply successful. Resources created.
...

State backup: /Users/you/.gentepede/backups/my-api/2025-06-14T10-30-00Z.tfstate
Lock file updated: /Users/you/.gentepede/workspaces/my-api/gentepede.lock.json
```

For EKS (`TERRAFORM_K8S`) blueprints, the response also includes a "Helm Deploy Output:" section after the Terraform apply output.

**Error responses:**
- `Error: No valid plan file found. Run plan_infrastructure_package first.` — plan missing or checksum mismatch

---

## Tool 6: `detect_drift`

**When to use:** Any time after apply to check if manual changes were made to AWS resources.

**What it runs:**
1. Credential pre-flight (`aws sts get-caller-identity`)
2. `terraform plan -detailed-exitcode -out=gentepede-drift.tfplan`
   - Exit 0 = no drift
   - Exit 1 = terraform error
   - Exit 2 = drift detected
3. On exit 2: `terraform show -json gentepede-drift.tfplan` (stdout captured in-memory)
4. TERRAFORM_K8S: `helm diff upgrade {project} helm/ -f helm/values.yaml --namespace {project}`
   (skipped with informational message if helm-diff plugin not installed)

**Success response (no drift):**
```
Drift Detection Report: my-api
============================================================
Has drift: false
Terraform: No drift detected.
Kubernetes: No drift detected.

Recommendation: Infrastructure matches desired state. No action required.
```

---

## Tool 7: `destroy_infrastructure_package`

**When to use:** When you want to remove all infrastructure. IRREVERSIBLE.

**What it does:**
1. Credential pre-flight (`aws sts get-caller-identity`)
2. TERRAFORM_K8S: `helm uninstall {project} --namespace {project}` (graceful if not found)
3. TERRAFORM_K8S: `kubectl wait --for=delete pod --all -n {project} --timeout=300s`
4. Backup `terraform.tfstate`
5. `terraform destroy -auto-approve -no-color`
6. Delete workspace directory (NOT backup files)

**Inputs:**
```json
{ "project_name": "my-api" }
```

---

## Tool 8: `audit_infrastructure_package`

**When to use:** Any time. Standalone — does not abort, does not deploy. Returns full security report.

**Unlike `validate_infrastructure_package`:** Does NOT abort on HIGH/CRITICAL. Returns all findings grouped by severity so Claude can explain each one and suggest remediations.

**Inputs:**
```json
{ "project_name": "my-api" }
```

**Success response:**
```
Security Audit Report: my-api
============================================================
Summary: 0 critical, 1 high, 3 medium, 5 low findings

Terraform — HIGH (1):
  CKV_AWS_X1 — aws_s3_bucket.logs
    Remediation: Enable server-side encryption

Terraform — MEDIUM (3):
  ...

Kubernetes — WARNING (2):
  ...
```
