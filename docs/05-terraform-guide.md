# Terraform Guide

## Why Terraform Instead of Clicking in the Console?

Manual AWS console configuration:
- Is not reproducible — you cannot recreate the same environment exactly
- Is not reviewable — no PR, no diff, no audit trail
- Is not testable — you cannot verify settings without deploying
- Accumulates drift — manual changes are forgotten and conflict with future automation

Terraform solves all four: every resource is declared in code, changes produce a diff (plan), the plan can be reviewed before applying, and drift can be detected via `terraform plan -detailed-exitcode`.

## Template Families

Gentepede has three template families, each a complete standalone Terraform project:

| Family | Blueprints | Resources |
|---|---|---|
| `templates/ecs/` | springboot-postgres, ktor-dynamodb, fastapi-redis | VPC, ALB, ECS Fargate, RDS or DynamoDB or ElastiCache |
| `templates/lambda/` | nodejs-s3 | Lambda, API Gateway v2, S3, CloudFront |
| `templates/eks/` | springboot-eks, nodejs-eks | VPC, EKS Cluster, Node Group, RDS or (S3 + CloudFront) |

There is no shared `main.tf` with `if blueprint == "eks"` conditionals across families — InfrastructureService selects the directory via the blueprint's `templateFamily` field. This prevents architecture-level conditional bloat and makes each template readable in isolation.

### Per-Blueprint Resource Gating

Within a family, blueprints share one `main.tf` but differ in their data tier. The ECS family is used by three blueprints that each need a *different* backend (RDS **or** DynamoDB **or** ElastiCache), and the EKS family is used by one blueprint with a database (RDS) and one without. Each optional data resource is therefore gated by a boolean toggle:

```hcl
resource "aws_db_instance" "postgres" {
  count = var.enable_rds ? 1 : 0
  # ...
}
```

InfrastructureService derives `enable_rds`, `enable_dynamodb`, and `enable_redis` from the blueprint's declared `awsResources` list and writes them into `terraform.tfvars` — you never set them by hand. So `springboot-postgres` provisions RDS only, `ktor-dynamodb` provisions DynamoDB only, `fastapi-redis` provisions ElastiCache only, and `nodejs-eks` (no `RDS_POSTGRES` in its `awsResources`) provisions no database at all. The EKS S3 bucket and its CloudFront distribution are likewise gated on whether the blueprint supplies an `s3_bucket_name`.

## Resource-by-Resource Walkthrough (ECS family)

### aws_kms_key

**What it is:** A customer-managed encryption key in AWS KMS.

**What it does:** All encryption in the ECS template uses this key: RDS at-rest encryption, CloudWatch log encryption, and the S3 bucket for flow logs.

**Why a dedicated key?** The alternative is the AWS-managed default key (`aws/rds`, `aws/s3`, etc.). AWS-managed keys cannot be audited for usage independently per project, and you cannot revoke them without calling AWS support. With a project-specific key, you can independently audit which services are using it, and you can schedule key deletion to revoke all access in 30 days if needed.

**Bad practice (without dedicated key):**
```hcl
resource "aws_db_instance" "bad" {
  storage_encrypted = true
  # No kms_key_id — uses the AWS-managed default key
  # Cannot be independently audited or revoked
}
```

### aws_vpc + subnets

**What it is:** An isolated virtual network with public subnets (for ALB) and private subnets (for ECS tasks and RDS).

**Why public/private split?** If ECS tasks were in public subnets, an attacker who found a way to assign a public IP to a task (or misconfigure a security group) could reach it directly. Private subnets prevent this at the network layer — tasks have no public IP and no direct internet route.

**Bad practice:**
```hcl
resource "aws_subnet" "ecs" {
  map_public_ip_on_launch = true  # Allows ECS tasks to be assigned public IPs
  # ...
}
```

### aws_flow_log (CKV_AWS_66)

**What it is:** A VPC-level network traffic log.

**What it does:** Captures source IP, destination IP, port, protocol, and bytes for every connection through the VPC.

**Why it matters:** Without flow logs, a security incident cannot be investigated retroactively. When an alert fires "unusual outbound traffic at 3 AM", you need flow logs to answer "which IP did it connect to, and how much data was sent?"

**What happens without it:** CKV_AWS_66 fails; incident response is blind.

### aws_security_group.alb vs aws_security_group.ecs_tasks

The ALB security group is the only one that accepts inbound traffic from `0.0.0.0/0` (the internet) — and only on port 443. The ECS tasks security group only accepts traffic _from the ALB security group_, not from the internet. This means even if a misconfiguration somehow assigned a public IP to an ECS task, the security group would still block all inbound traffic.

**Bad practice:**
```hcl
ingress {
  from_port   = 0
  to_port     = 65535
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]  # Allows any IP to connect to any port
}
```

### aws_lb_listener.http (port 80 → 443 redirect) (CKV_AWS_2)

**What it does:** Returns an HTTP 301 redirect to HTTPS for all HTTP requests. No plain HTTP traffic is ever forwarded to backend services.

**Why the redirect instead of just disabling port 80?** Users who type a URL without `https://` get redirected rather than receiving a "connection refused" error. It is user-friendly while still enforcing HTTPS.

**Bad practice:**
```hcl
resource "aws_lb_listener" "bad" {
  port     = 80
  protocol = "HTTP"
  default_action {
    type             = "forward"  # Forwards HTTP to backend — no encryption in transit
    target_group_arn = aws_lb_target_group.app.arn
  }
}
```

### aws_db_instance (CKV_AWS_17, CKV_AWS_23)

**What it is:** An RDS PostgreSQL instance.

**`publicly_accessible = false` (CKV_AWS_17):** Prevents the RDS instance from getting a public IP or DNS name reachable from the internet. Without this, an attacker who knows the endpoint can attempt direct database connections — even if the security group restricts access, defense-in-depth means both layers should prevent exposure.

**`storage_encrypted = true` with `kms_key_id` (CKV_AWS_23):** Encrypts the EBS volumes underlying the RDS instance. Without it, an attacker who gains access to the AWS account at the storage level (e.g. via a compromised snapshot) can read all data.

**`manage_master_user_password = true`:** RDS generates a random password and stores it in AWS Secrets Manager. You never see the master password in Terraform state, variables, or environment variables.

### aws_s3_bucket_public_access_block

Four flags together prevent every public S3 access path:
- `block_public_acls`: prevents setting ACLs that allow public access
- `block_public_policy`: blocks bucket policies that allow public access
- `ignore_public_acls`: ignores existing public ACLs even if they exist
- `restrict_public_buckets`: prevents cross-account public access

All four must be set. Setting only `block_public_acls` still allows public access via bucket policy.

### aws_iam_role_policy (CKV_AWS_111)

The ECS task IAM policy uses explicit action lists — no wildcard `*` actions:
```hcl
actions = [
  "dynamodb:GetItem",
  "dynamodb:PutItem",
  # ... explicit list
]
```

**Bad practice:**
```hcl
actions = ["dynamodb:*"]  # Allows DynamoDB table deletion, admin operations
resources = ["*"]          # Applies to ALL DynamoDB tables in the account
```

## providers.tf — Why Runtime Generation?

`providers.tf` is written at workspace creation time by InfrastructureService, not included in `templates/`. This enables the same template files to be used in both LOCAL and PRODUCTION mode by swapping the provider configuration. The alternative — two copies of each template — would double the maintenance burden and risk the copies diverging.

The provider version comes from `terraformProviderVersion` in the blueprint JSON. Using exact version pinning (`= 5.82.0`, not `~> 5.0`) prevents the provider from being upgraded automatically, which could change resource behaviour between your generate and apply.

## Remote State (PRODUCTION mode)

In LOCAL mode, Terraform state is stored in `terraform.tfstate` in the workspace directory.

In PRODUCTION mode, `providers.tf` includes an S3 backend:
```hcl
backend "s3" {
  bucket         = "{project_name}-tfstate"
  key            = "gentepede/{project_name}/terraform.tfstate"
  region         = "{aws_region}"
  dynamodb_table = "{project_name}-tfstate-lock"
  encrypt        = true
}
```

**Why S3?** Local state files cannot be shared across team members or CI jobs. If two engineers run `terraform apply` simultaneously from local state files, they corrupt each other's state.

**Why DynamoDB locking?** Without it, two concurrent `terraform apply` runs would both succeed but produce conflicting state — resulting in orphaned resources or incorrect state. DynamoDB provides a distributed lock: the second apply waits until the first releases the lock.

**Prerequisites:** The S3 bucket and DynamoDB table must exist before the first `terraform apply` in PRODUCTION mode. See `docs/12-end-to-end-walkthrough.md` Phase 7 for setup commands.

## State Backups

Before every `apply` and `destroy`, Gentepede copies `terraform.tfstate` to:
```
~/.gentepede/backups/{project_name}/{ISO-timestamp}.tfstate
```

Backups are never automatically deleted. If an apply partially fails and corrupts state, you can restore manually:
```bash
cp ~/.gentepede/backups/my-api/2025-06-14T10-30-00Z.tfstate \
   ~/.gentepede/workspaces/my-api/terraform.tfstate
```

## Plan File Integrity

`plan_infrastructure_package` saves a binary plan to `gentepede.tfplan` and computes its SHA-256 checksum, storing it in `gentepede.lock.json`.

`apply_infrastructure_package` recomputes the SHA-256 of `gentepede.tfplan` and compares it to the stored checksum before applying. If they differ, apply aborts.

**Why?** Without this check, it is possible (though rare) that:
- The plan file was overwritten by a second `plan_infrastructure_package` call
- The plan file was corrupted
- A `generate_infrastructure_package` re-run changed variables after the plan was reviewed

The checksum ensures you always apply exactly the plan you reviewed.
