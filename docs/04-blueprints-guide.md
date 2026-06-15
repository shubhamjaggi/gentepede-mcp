# Blueprints Guide

## All Blueprints at a Glance

| Blueprint ID | Framework | Template Family | Output Type | Data Tier | Required Variables |
|---|---|---|---|---|---|
| `springboot-postgres` | Spring Boot | ecs | TERRAFORM_ONLY | RDS PostgreSQL | `container_image`, `certificate_arn` |
| `ktor-dynamodb` | Ktor | ecs | TERRAFORM_ONLY | DynamoDB | `container_image`, `certificate_arn` |
| `nodejs-s3` | Node.js | lambda | TERRAFORM_ONLY | S3 + CloudFront | `lambda_zip_path` |
| `fastapi-redis` | FastAPI | ecs | TERRAFORM_ONLY | ElastiCache Redis | `container_image`, `certificate_arn` |
| `springboot-eks` | Spring Boot | eks | TERRAFORM_K8S | RDS PostgreSQL | `container_image`, `certificate_arn` |
| `nodejs-eks` | Node.js | eks | TERRAFORM_K8S | S3 + CloudFront | `container_image`, `s3_bucket_name` |

All six blueprints provision VPC, KMS, and VPC flow logs. `TERRAFORM_K8S` blueprints also generate a Helm chart in `helm/` and a `kind-config.yaml` for local cluster creation.

**How does Gentepede know which services to create for each blueprint?** See [docs/15-blueprint-to-resource-map.md](15-blueprint-to-resource-map.md) for the complete derivation chain (blueprint JSON → InfrastructureService → terraform.tfvars → `count = var.enable_X ? 1 : 0`) and a full per-blueprint resource breakdown.

---

## Which Blueprint Should I Use?

Use this guide to pick the right blueprint for your application before generating anything.

### Step 1: What is your compute layer?

```
Serverless function (no persistent process)?
  └─► nodejs-s3 (Lambda + API Gateway + S3 + CloudFront)

Containerised application?
  └─► Step 2
```

### Step 2: Do you need Kubernetes?

```
No — I want the simplest path
  └─► Step 3 (ECS Fargate blueprints)

Yes — I need Helm, HPA, NetworkPolicy, multi-container pods, or GitOps tooling
  └─► Step 4 (EKS blueprints)
```

### Step 3: ECS — What is your data tier?

```
Relational database (SQL, transactions, joins)?
  └─► springboot-postgres (Spring Boot + RDS PostgreSQL)
         or any ECS blueprint + custom data tier (see docs/10-adding-blueprints.md)

Key-value / NoSQL, no schema migrations?
  └─► ktor-dynamodb (Ktor + DynamoDB)

In-memory cache / session store / pub-sub?
  └─► fastapi-redis (FastAPI + ElastiCache Redis)

No persistent database needed?
  └─► Use springboot-postgres or ktor-dynamodb and omit the data tier
       by not declaring it in awsResources (see docs/10-adding-blueprints.md)
```

### Step 4: EKS — What is your data tier?

```
Relational database?
  └─► springboot-eks (Spring Boot + EKS + RDS PostgreSQL)

Object storage + global CDN?
  └─► nodejs-eks (Node.js + EKS + S3 + CloudFront)
```

---

## What Is a Blueprint?

A blueprint is a JSON file in `src/main/resources/blueprints/` that describes:
1. What AWS infrastructure a given application tech stack needs
2. Which Terraform template family to copy into the workspace
3. What variables the user must supply

A blueprint is NOT Terraform code. It is metadata. InfrastructureService reads the blueprint and uses it to select and configure the right template family.

The analogy: the blueprint is a **recipe card**; the Terraform template is the **actual recipe**. The recipe card tells you what ingredients you need and which recipe to follow. It doesn't cook the meal itself.

---

## Field-by-Field Schema

Below is a complete example blueprint JSON, followed by a field-by-field explanation of every key.

### Complete Example

```json
{
  "blueprintId": "springboot-postgres",
  "displayName": "Spring Boot + PostgreSQL (ECS Fargate)",
  "description": "Deploys a Spring Boot application on ECS Fargate with RDS PostgreSQL...",
  "outputType": "TERRAFORM_ONLY",
  "templateFamily": "ecs",
  "terraformProviderVersion": "5.82.0",
  "lastVerifiedDate": "2026-06",
  "techStack": {
    "language": "Java/Kotlin",
    "framework": "Spring Boot",
    "database": "PostgreSQL"
  },
  "awsResources": [
    { "type": "VPC",          "required": true,  "defaultConfig": {} },
    { "type": "ALB",          "required": true,  "defaultConfig": { "https_only": true } },
    { "type": "ECS_FARGATE",  "required": true,  "defaultConfig": { "cpu": 512, "memory": 1024 } },
    { "type": "RDS_POSTGRES", "required": true,  "defaultConfig": {} },
    { "type": "KMS",          "required": true,  "defaultConfig": {} }
  ],
  "variables": [
    { "name": "project_name",    "description": "Unique deployment name", "type": "string",  "default": null,        "required": true  },
    { "name": "aws_region",      "description": "AWS region",             "type": "string",  "default": "us-east-1", "required": false },
    { "name": "container_image", "description": "ECR image URI",          "type": "string",  "default": null,        "required": true  },
    { "name": "certificate_arn", "description": "ACM certificate ARN",    "type": "string",  "default": null,        "required": true  },
    { "name": "db_name",         "description": "Database name",          "type": "string",  "default": "appdb",     "required": false }
  ],
  "securityBaseline": {
    "enableVpcFlowLogs": true,
    "enforceHttps": true
  }
}
```

---

### `blueprintId`

```json
"blueprintId": "springboot-postgres"
```

**Slug** used to reference this blueprint in `generate_infrastructure_package` (`blueprint_name` parameter). Must match the filename exactly (without `.json`). Alphanumeric + hyphens only.

```
src/main/resources/blueprints/springboot-postgres.json  →  blueprint_name="springboot-postgres"
```

---

### `displayName`

```json
"displayName": "Spring Boot + PostgreSQL (ECS Fargate)"
```

Human-readable name shown in the `list_available_blueprints` output. Not used programmatically.

---

### `description`

```json
"description": "Deploys a Spring Boot application on ECS Fargate..."
```

One-sentence description of what this blueprint provisions. Shown in `list_available_blueprints`. Not used programmatically.

---

### `outputType`

```json
"outputType": "TERRAFORM_ONLY"
```

Controls the workspace layout and which tools run during validate/plan/apply. Two possible values:

| Value | Workspace layout | Helm chart? | kube-score? | helm upgrade? |
|---|---|---|---|---|
| `TERRAFORM_ONLY` | Flat (all files at workspace root) | No | No | No |
| `TERRAFORM_K8S` | Subdirs: `terraform/` + `helm/` | Yes | Yes | Yes |

All ECS and Lambda blueprints use `TERRAFORM_ONLY`. All EKS blueprints use `TERRAFORM_K8S`.

---

### `templateFamily`

```json
"templateFamily": "ecs"
```

Drives which `templates/{family}/` directory InfrastructureService copies into the workspace. One of:

| Value | Directory | Blueprints that use it |
|---|---|---|
| `ecs` | `templates/ecs/` | springboot-postgres, ktor-dynamodb, fastapi-redis |
| `lambda` | `templates/lambda/` | nodejs-s3 |
| `eks` | `templates/eks/` | springboot-eks, nodejs-eks |

This is how three very different AWS architectures share one code path in InfrastructureService without conditional bloat. InfrastructureService does not inspect the blueprintId — it only looks at `templateFamily` to decide which files to copy.

---

### `terraformProviderVersion`

```json
"terraformProviderVersion": "5.82.0"
```

The exact `hashicorp/aws` provider version to pin in the generated `providers.tf`:
```hcl
aws = { source = "hashicorp/aws", version = "= 5.82.0" }
```

Using `= 5.82.0` (not `~> 5.0`) prevents provider-level drift between your generate and apply. When AWS releases a breaking provider change, you update this field and run the CI weekly job to verify all blueprints still pass.

**All blueprints must use the same version.** See [docs/17-contributor-sync-guide.md §6](17-contributor-sync-guide.md#6-bump-the-terraform-provider-version) when bumping.

---

### `lastVerifiedDate`

```json
"lastVerifiedDate": "2026-06"
```

The most recent `YYYY-MM` when the CI job ran `terraform validate` and checkov against this blueprint successfully. The weekly GitHub Actions workflow updates this field automatically. If this date is more than a month old, the blueprint may be stale — check the CI badge.

---

### `techStack`

```json
"techStack": {
  "language": "Java/Kotlin",
  "framework": "Spring Boot",
  "database": "PostgreSQL"
}
```

**Two uses:**

1. **Display only** — shown in `list_available_blueprints` so users can find the right blueprint for their stack.

2. **Runtime — EKS health check paths** — For `TERRAFORM_K8S` blueprints, InfrastructureService reads `techStack.framework` to set the correct container port and health check paths in the generated `helm/values.yaml`:

   | Framework | Container Port | Liveness Path | Readiness Path |
   |---|---|---|---|
   | Spring Boot | 8080 | `/actuator/health` | `/actuator/health/readiness` |
   | Node.js | 3000 | `/health` | `/ready` |
   | FastAPI | 8000 | `/health` | `/ready` |
   | Ktor | 8080 | `/health` | `/ready` |
   | (other) | 8080 | `/health` | `/ready` |

   This is why the `framework` string matters — using `"framework": "Spring Boot"` vs `"framework": "My App"` will produce different health paths in the Helm chart. Match the framework string exactly to the table above.

`database` is descriptive only — the actual database resources are controlled by `awsResources[].type`, not by this field.

---

### `awsResources`

```json
"awsResources": [
  { "type": "VPC",          "required": true, "defaultConfig": {} },
  { "type": "ECS_FARGATE",  "required": true, "defaultConfig": { "cpu": 512, "memory": 1024 } },
  { "type": "RDS_POSTGRES", "required": true, "defaultConfig": {} }
]
```

Declarative list of AWS services this blueprint provisions. This array has two purposes:

1. **Shown to users** in `generate_infrastructure_package` output so users know what will be created before they run plan.
2. **Controls data-tier resource creation** — InfrastructureService's `injectDataTierToggles()` reads this list and writes boolean flags to `terraform.tfvars` (`enable_rds`, `enable_dynamodb`, `enable_redis`). The Terraform template uses `count = var.enable_X ? 1 : 0` to create or skip each data-tier resource.

**All valid `type` strings:**

| Type String | AWS Resource | Template Families That Support It |
|---|---|---|
| `VPC` | VPC with public/private subnets, NAT Gateway, IGW | ecs, eks, lambda |
| `ALB` | Application Load Balancer with HTTPS listener + 80→443 redirect | ecs, eks |
| `ECS_FARGATE` | ECS cluster, task definition, and Fargate service | ecs |
| `RDS_POSTGRES` | RDS PostgreSQL instance (private subnet, encrypted) | ecs, eks |
| `DYNAMODB_TABLE` | DynamoDB table (PAY_PER_REQUEST billing, KMS encryption) | ecs |
| `ELASTICACHE_REDIS` | ElastiCache Redis replication group (encrypted at rest + in transit) | ecs |
| `KMS` | Customer-managed KMS key for all encryption in the blueprint | ecs, eks, lambda |
| `EKS` | EKS cluster + managed node group + IAM roles | eks |
| `S3` | S3 bucket (versioned, private, KMS-encrypted) | eks, lambda |
| `CLOUDFRONT` | CloudFront distribution (HTTPS-only, TLS 1.2+) | eks, lambda |
| `LAMBDA` | Lambda function + CloudWatch log group + execution role | lambda |
| `API_GATEWAY` | API Gateway HTTP API v2 + Lambda integration + stage | lambda |

`defaultConfig` is metadata only — it documents the defaults used by the Terraform template. It does not affect resource creation directly; the Terraform variables control that.

---

### `variables`

```json
"variables": [
  { "name": "container_image", "description": "...", "type": "string", "default": null, "required": true  },
  { "name": "aws_region",      "description": "...", "type": "string", "default": "us-east-1", "required": false }
]
```

The variables users must (or may) provide in `generate_infrastructure_package`'s `variables` object.

| Field | Meaning |
|---|---|
| `name` | The Terraform variable name. Also the key in `generate_infrastructure_package`'s `variables` object. |
| `description` | Shown in `list_available_blueprints` output. |
| `type` | `"string"` or `"number"`. Used when writing `terraform.tfvars`. |
| `default: null` | **Required** — must be supplied in `variables`. |
| `default: "us-east-1"` | **Optional** — use this value if not supplied. |
| `required: true` | Must be in `variables`. If missing, `generate_infrastructure_package` uses the `default` (even if null, which means an empty string in tfvars — likely causing a Terraform error). |

**What happens when a required variable is missing?** Gentepede does not validate required variables at generation time — it trusts the blueprint definition and writes whatever is available to `terraform.tfvars`. If a required variable is omitted, `terraform validate` will fail with a message like:
```
Error: No value for required variable
  on variables.tf line 5, in variable "container_image":
  5: variable "container_image" {}
```
The remedy is to re-run `generate_infrastructure_package` with the missing variable included.

**How variables flow through the system:**
```
generate_infrastructure_package variables={...}
        │
        ▼
InfrastructureService merges user values over blueprint defaults
        │
        ▼
terraform.tfvars written (key = "value" format)
        │
        ▼
For EKS (TERRAFORM_K8S): helm/values.yaml also written with
  containerPort, liveness/readiness paths, image URI from variables
        │
        ▼
terraform plan reads terraform.tfvars automatically (no -var-file flag needed)
```

---

### `securityBaseline`

```json
"securityBaseline": {
  "enableVpcFlowLogs": true,
  "enforceHttps": true
}
```

Documents the security guarantees enforced by this blueprint's template family. Both are always `true` — these are not runtime switches you can toggle off. They declare intent (what the template does) rather than controlling behaviour.

| Field | Where it is actually enforced in the Terraform template |
|---|---|
| `enableVpcFlowLogs: true` | `aws_flow_log` resource in every template family, writing to an S3 bucket |
| `enforceHttps: true` | `aws_lb_listener` port-80→443 redirect in ECS/EKS; `viewer_protocol_policy = "redirect-to-https"` in CloudFront (Lambda family) |

Note: `enableWaf` is intentionally absent. WAF (Web Application Firewall) requires per-application rule tuning that cannot be automated safely — it is not templated by Gentepede.

---

## TERRAFORM_ONLY vs TERRAFORM_K8S

| Feature | TERRAFORM_ONLY | TERRAFORM_K8S |
|---|---|---|
| Workspace layout | Flat (`~/.gentepede/workspaces/{project}/`) | Subdirs: `terraform/` + `helm/` |
| Containers | ECS Fargate (managed by AWS) | EKS (Kubernetes pods, managed by user) |
| Helm chart | Not generated | Generated at `helm/` with per-project values.yaml |
| kind-config.yaml | Not generated | Generated in workspace root |
| kube-score | Not run | Run during validate and plan |
| helm upgrade | Not run | Run during apply |
| Blueprints | springboot-postgres, ktor-dynamodb, nodejs-s3, fastapi-redis | springboot-eks, nodejs-eks |

## How securityBaseline Maps to Terraform

The `securityBaseline` fields in the blueprint JSON are declarations, not code. The actual enforcement happens in the Terraform templates:

| securityBaseline field | Where it's enforced in Terraform |
|---|---|
| `enableVpcFlowLogs: true` | `aws_flow_log` resource in every template family |
| `enforceHttps: true` | `aws_lb_listener` port-80→443 redirect; `viewer_protocol_policy = "redirect-to-https"` in CloudFront |
