# Adding Blueprints

## When to Add a Blueprint

Add a blueprint when you need an architecture pattern that is not covered by the existing six. The right signal is: "I keep creating this same AWS setup manually." Blueprints are the right tool for stable, repeatable architectures — not for one-off deployments.

## Step-by-Step: Adding `go-dynamodb`

This example adds a Go application on ECS Fargate backed by DynamoDB.

### Step 1: Create the Blueprint JSON

Create `src/main/resources/blueprints/go-dynamodb.json`:

```json
{
  "blueprintId": "go-dynamodb",
  "displayName": "Go + DynamoDB (ECS Fargate)",
  "description": "Deploys a Go application on ECS Fargate with DynamoDB.",
  "outputType": "TERRAFORM_ONLY",
  "templateFamily": "ecs",
  "terraformProviderVersion": "5.82.0",
  "lastVerifiedDate": "2025-06",
  "techStack": {
    "language": "Go",
    "framework": "Go net/http",
    "database": "DynamoDB"
  },
  "awsResources": [
    { "type": "VPC",            "required": true, "defaultConfig": {} },
    { "type": "ALB",            "required": true, "defaultConfig": {} },
    { "type": "ECS_FARGATE",    "required": true, "defaultConfig": { "cpu": 256, "memory": 512 } },
    { "type": "DYNAMODB_TABLE", "required": true, "defaultConfig": { "billing_mode": "PAY_PER_REQUEST" } }
  ],
  "variables": [
    { "name": "project_name",     "description": "Unique deployment name", "type": "string", "default": null, "required": true },
    { "name": "aws_region",       "description": "AWS region",             "type": "string", "default": "us-east-1", "required": false },
    { "name": "aws_profile",      "description": "AWS CLI profile",        "type": "string", "default": "default", "required": false },
    { "name": "environment",      "description": "Environment tag",        "type": "string", "default": "dev", "required": false },
    { "name": "container_image",  "description": "ECR image URI",          "type": "string", "default": null, "required": true },
    { "name": "container_port",   "description": "App listen port",        "type": "number", "default": 8080, "required": false },
    { "name": "certificate_arn",  "description": "ACM cert ARN",           "type": "string", "default": null, "required": true },
    { "name": "dynamodb_table_name", "description": "Table name",          "type": "string", "default": "go-table", "required": false },
    { "name": "dynamodb_hash_key",   "description": "Partition key name",  "type": "string", "default": "id", "required": false }
  ],
  "securityBaseline": {
    "enableVpcFlowLogs": true,
    "enforceHttps": true
  }
}
```

**Key decisions:**
- `templateFamily: "ecs"` — reuses the existing ECS template (which already handles DynamoDB resources via the `dynamodb_table_name` and `dynamodb_hash_key` variables)
- `outputType: "TERRAFORM_ONLY"` — no Kubernetes for ECS blueprints
- `terraformProviderVersion` — use the same version as other blueprints unless you need a specific fix

### Step 2: Register in InfrastructureService

Add `"go-dynamodb"` to the `blueprintIds` list in `InfrastructureService.listBlueprints()`:

```kotlin
val blueprintIds = listOf(
    "springboot-postgres",
    "ktor-dynamodb",
    "nodejs-s3",
    "fastapi-redis",
    "springboot-eks",
    "nodejs-eks",
    "go-dynamodb"  // ← add here
)
```

### Step 3: Decide if New Template Files Are Needed

The `go-dynamodb` blueprint uses `templateFamily: "ecs"`, so it reuses `templates/ecs/main.tf`. That template already contains all the resources needed: VPC, ALB, ECS Fargate, DynamoDB table.

**How the right data tier gets provisioned:** the ECS template gates its optional data resources (RDS, DynamoDB, ElastiCache) behind `enable_rds` / `enable_dynamodb` / `enable_redis` toggles. InfrastructureService derives these from the blueprint's `awsResources` list — declaring `DYNAMODB_TABLE` (as `go-dynamodb` does in Step 1) is what makes the DynamoDB table appear, while RDS and ElastiCache stay off. You do not add these toggles to the blueprint's `variables`; just declare the correct `awsResources` types.

**When you need new template files:** only if the new blueprint introduces a resource type not covered by any existing family. For example, if `go-dynamodb` needed SQS (not in any current template), you would add SQS resources to `templates/ecs/main.tf` (gated the same way, with a new `enable_sqs` toggle keyed off the `SQS` resource type) and the corresponding variable to `templates/ecs/variables.tf`.

### Step 4: Update Helm Chart (if TERRAFORM_K8S)

For `go-dynamodb` this step is skipped — it's `TERRAFORM_ONLY`.

For a new EKS blueprint (`outputType: "TERRAFORM_K8S"`), add framework-specific overrides to `InfrastructureService.buildHelmValues()`:
```kotlin
blueprint.techStack.framework.contains("Go", ignoreCase = true) ->
    Triple(8080, "/health", "/ready")
```

### Step 5: Verify Locally

```bash
# Start LocalStack
docker run -d --name localstack -p 4566:4566 localstack/localstack

# Build
./gradlew shadowJar

# Test the blueprint via the test harness
GENTEPEDE_MODE=LOCAL ./gradlew test --tests '*InfrastructureServiceTest*'
```

### Step 6: Verify End-to-End

In Claude Desktop with `GENTEPEDE_MODE=LOCAL`:
1. `list_available_blueprints` — confirm `go-dynamodb` appears
2. `generate_infrastructure_package blueprint_name="go-dynamodb" project_name="test-go" variables={...}`
3. `validate_infrastructure_package project_name="test-go"`
4. `plan_infrastructure_package project_name="test-go"`

### Step 7: Update lastVerifiedDate

After the CI workflow passes, `lastVerifiedDate` is updated automatically. Before merging, set it manually to the current month:
```json
"lastVerifiedDate": "2026-06"
```

## PR Checklist

### Code and Resources

- [ ] `src/main/resources/blueprints/{id}.json` created with all required fields
- [ ] `blueprintId` in JSON matches the filename (without `.json`)
- [ ] `terraformProviderVersion` set to the current pinned version (check other blueprints)
- [ ] `lastVerifiedDate` set to current `YYYY-MM`
- [ ] Blueprint added to `InfrastructureService.listBlueprints()` ID list
- [ ] `InfrastructureServiceTest.kt` — blueprint loading test added; data-tier toggle test added
- [ ] If new template family needed: see [docs/17-contributor-sync-guide.md §2](17-contributor-sync-guide.md#2-add-a-new-template-family) — additional code changes required
- [ ] If TERRAFORM_K8S: Helm values overrides added to `buildHelmValues()`

### Documentation (all four must be updated)

- [ ] `README.md` Supported Blueprints table — new row with all columns
- [ ] `docs/04-blueprints-guide.md` "All Blueprints at a Glance" table — new row
- [ ] `docs/15-blueprint-to-resource-map.md` — new section under the relevant template family (resource table + "why this tech stack" explanation)
- [ ] `docs/00-glossary.md` — new entry for any AWS service introduced that is not already defined

### Verification

- [ ] Local validate passes (checkov clean, terraform validate clean)
- [ ] Local plan produces expected resource list
- [ ] CI job passes (or is explicitly waived with explanation in PR description)

For the complete sync dependency map for all change types, see [docs/17-contributor-sync-guide.md](17-contributor-sync-guide.md).
