# What Is Gentepede MCP?

## The Problem

Setting up secure AWS infrastructure for a new application takes days of work:

- Manually creating VPCs, subnets, security groups, NAT gateways
- Configuring RDS with encryption, private subnets, and no public access
- Writing IAM policies with the exact permissions needed (not `*`)
- Setting up ALBs with HTTPS-only listeners and port-80 redirects
- Enabling VPC flow logs, CloudWatch metrics, and S3 encryption
- Remembering all the checkov rules before your security team finds the violations in a PR review

Even experienced engineers get it wrong on the first attempt. Junior engineers spend days debugging obscure Terraform errors. Security misconfigurations go unnoticed until a penetration test or audit.

## The Solution

Gentepede MCP is a Model Context Protocol server that maps your application's tech stack to a fully provisioned, secure AWS infrastructure package — without you writing a single line of Terraform.

You tell Claude which blueprint fits your application (e.g. `springboot-postgres`) and provide a few variables (your Docker image URI, ACM certificate ARN, etc.). Gentepede generates:

- A complete Terraform workspace with security best practices baked in from the start
- A `providers.tf` targeting real AWS with an S3 remote state backend
- For EKS blueprints: a production-ready Helm chart with hardened pod security contexts, NetworkPolicy, HPA, and ResourceQuota

Then you run a five-step workflow: **list → generate → validate → plan → apply**.

## A Concrete Example

Here is what a complete deployment looks like from inside Claude Desktop:

**Step 1 — Browse blueprints**
```
list_available_blueprints
```
Claude shows you 6 blueprints: springboot-postgres, ktor-dynamodb, nodejs-s3, fastapi-redis, springboot-eks, nodejs-eks.

**Step 2 — Generate workspace**
```
generate_infrastructure_package
  blueprint_name: "springboot-postgres"
  project_name: "my-api"
  variables:
    container_image: "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-api:1.0.0"
    certificate_arn: "arn:aws:acm:us-east-1:123456789012:certificate/abc"
    db_name: "appdb"
```
Gentepede writes `~/.gentepede/workspaces/my-api/` with main.tf, variables.tf, terraform.tfvars, and providers.tf.

**Step 3 — Validate**
```
validate_infrastructure_package
  project_name: "my-api"
```
Runs `terraform validate` (syntax check) and `checkov` (security scan). Returns a structured report. No AWS credentials needed — pure static analysis.

**Step 4 — Plan**
```
plan_infrastructure_package
  project_name: "my-api"
```
Runs `terraform plan`, shows you exactly what will be created (VPC, ALB, ECS cluster, RDS, KMS key), and estimates the monthly cost via Infracost.

**Step 5 — Apply**
```
apply_infrastructure_package
  project_name: "my-api"
```
Applies the exact plan you reviewed. Takes a state backup first. Confirms your AWS identity before touching any resource.

**Ongoing — Drift detection**
```
detect_drift
  project_name: "my-api"
```
Detects if someone changed something in the AWS console that Terraform doesn't know about.

## Who This Is For

- **Backend engineers** who want to ship to AWS quickly without spending days learning Terraform
- **Security-conscious teams** who want infrastructure that passes checkov on the first run
- **Developers learning cloud** who want to see real, production-quality Terraform as a reference
- **DevOps engineers** who want to standardise infrastructure patterns across teams via blueprints

## What This Is NOT

- A no-code platform that hides what it creates. Every file is visible in `~/.gentepede/workspaces/` and can be read, understood, and modified.
- A Terraform alternative. Gentepede generates Terraform and orchestrates it. Terraform does the actual infrastructure provisioning.
- An opinionated framework that locks you in. The generated Terraform is standard HCL that runs with the standard Terraform CLI.
- A production-ready solution for every AWS architecture. Six blueprints cover common patterns; see `docs/09-adding-blueprints.md` to add your own.
