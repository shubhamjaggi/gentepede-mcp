# Blueprints Guide

## What Is a Blueprint?

A blueprint is a JSON file in `src/main/resources/blueprints/` that describes:
1. What AWS infrastructure a given application tech stack needs
2. Which Terraform template family to copy into the workspace
3. What variables the user must supply

A blueprint is NOT Terraform code. It is metadata. InfrastructureService reads the blueprint and uses it to select and configure the right template family.

The analogy: the blueprint is a **recipe card**; the Terraform template is the **actual recipe**. The recipe card tells you what ingredients you need and which recipe to follow. It doesn't cook the meal itself.

## Field-by-Field Schema

```json
{
  "blueprintId": "springboot-postgres",
```
**Slug** used to reference this blueprint in `generate_infrastructure_package`. Must match the filename (without `.json`).

```json
  "displayName": "Spring Boot + PostgreSQL (ECS Fargate)",
```
Human-readable name shown in `list_available_blueprints` output.

```json
  "outputType": "TERRAFORM_ONLY",
```
Either `TERRAFORM_ONLY` (flat Terraform workspace) or `TERRAFORM_K8S` (Terraform + Helm chart subdirs). Only EKS blueprints use `TERRAFORM_K8S`.

```json
  "templateFamily": "ecs",
```
Drives which `templates/{family}/` directory is copied. One of: `ecs`, `lambda`, `eks`. This is how three very different AWS architectures share one code path in InfrastructureService without conditional bloat.

```json
  "terraformProviderVersion": "5.82.0",
```
The exact `hashicorp/aws` provider version to pin in the generated `providers.tf`. Using `= 5.82.0` (not `~> 5.0`) prevents provider-level drift between your generate and apply. When AWS releases a breaking provider change, you update this field and run the CI weekly job to verify all blueprints still pass.

```json
  "lastVerifiedDate": "2025-06",
```
The most recent `YYYY-MM` when the CI job ran all blueprints through LocalStack successfully. The weekly GitHub Actions workflow updates this field automatically. If this date is more than a month old, the blueprint may be stale.

```json
  "techStack": { "language": "Java/Kotlin", "framework": "Spring Boot", "database": "PostgreSQL" },
```
Descriptive metadata only. Also used by InfrastructureService to set the right `containerPort` and health check paths in Helm `values.yaml` for EKS blueprints.

```json
  "awsResources": [
    { "type": "ECS_FARGATE", "required": true, "defaultConfig": { "cpu": 512, "memory": 1024 } }
  ],
```
Declarative list of AWS services this blueprint provisions. Shown in tool responses so users know what will be created before running terraform plan.

```json
  "variables": [
    { "name": "container_image", "description": "...", "type": "string", "default": null, "required": true }
  ],
```
The variables users must provide. `required: true` and `default: null` means the variable must be supplied in `generate_infrastructure_package`'s `variables` object. Variables with non-null defaults are optional.

```json
  "securityBaseline": { "enableVpcFlowLogs": true, "enforceHttps": true }
```
Documents the security guarantees enforced by this blueprint's template family. Both are always `true` — these are not runtime switches. They declare intent (what the template does) rather than controlling behavior.

Note: `enableWaf` is intentionally absent. WAF (Web Application Firewall) is not templated by Gentepede — it requires per-application rule tuning that cannot be automated safely.

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

## How Variables Flow

1. User calls `generate_infrastructure_package` with `variables: { "container_image": "...", "certificate_arn": "..." }`
2. InfrastructureService merges user variables with blueprint defaults
3. Result is written to `terraform.tfvars` (HCL key = value format)
4. For EKS: also used to set `containerPort`, health paths, and `image.tag` in `helm/values.yaml`
5. `terraform plan` reads `terraform.tfvars` automatically (no `-var-file` flag needed)

## How securityBaseline Maps to Terraform

The `securityBaseline` fields in the blueprint JSON are declarations, not code. The actual enforcement happens in the Terraform templates:

| securityBaseline field | Where it's enforced in Terraform |
|---|---|
| `enableVpcFlowLogs: true` | `aws_flow_log` resource in every template family |
| `enforceHttps: true` | `aws_lb_listener` port-80→443 redirect; `viewer_protocol_policy = "redirect-to-https"` in CloudFront |
