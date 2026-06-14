# Gentepede MCP

[![CI](https://github.com/shubhamjaggi/gentepede-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/shubhamjaggi/gentepede-mcp/actions/workflows/ci.yml)
[![Blueprint Verification](https://github.com/shubhamjaggi/gentepede-mcp/actions/workflows/blueprint-verify.yml/badge.svg)](https://github.com/shubhamjaggi/gentepede-mcp/actions/workflows/blueprint-verify.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Java 21](https://img.shields.io/badge/Java-21-orange.svg)](https://adoptium.net/)
[![Kotlin](https://img.shields.io/badge/Kotlin-2.1-purple.svg)](https://kotlinlang.org/)

A Kotlin-based [MCP](docs/00-glossary.md#mcp-model-context-protocol) server that acts as a deterministic Knowledge Engine for enterprise cloud architectures. Maps application tech-stacks (Spring Boot, Ktor, Node.js, FastAPI) to fully provisioned, secure [AWS](docs/00-glossary.md#aws-amazon-web-services) infrastructure via [Terraform](docs/00-glossary.md#terraform) — and for EKS blueprints also generates a production-ready [Helm](docs/00-glossary.md#helm) chart alongside the Terraform. Features a full plan-review-apply pipeline, live cost estimation via [Infracost](docs/00-glossary.md#infracost), drift detection, credential transparency, and free local [K8s](docs/00-glossary.md#kubernetes) testing via [`kind`](docs/00-glossary.md#kind-kubernetes-in-docker).

---

## Architecture Diagram

```
MCP Client (Claude Desktop) → Gentepede Server → Blueprint Engine
                                                         │
                                      ┌──────────────────┴──────────────────┐
                                 Terraform                               Helm Chart
                                      │                                      │
                           ┌──────────┴──────────┐                kube-score lint
                      checkov lint          infracost                        │
                                      │                           helm upgrade --install
                               plan → apply                                  │
                                      │                         [kind cluster | EKS]
                           [LocalStack | AWS]
```

---

## Prerequisites

Install all of the following before building:

| Tool | Purpose | Install |
|---|---|---|
| Java 21 | JVM runtime for the server | [SDKMAN](https://sdkman.io/) / [Homebrew](https://brew.sh/) / [winget](https://learn.microsoft.com/en-us/windows/package-manager/) |
| Docker | LocalStack + kind backend | [Docker Desktop](https://www.docker.com/products/docker-desktop/) |
| Terraform | IaC provisioning | `brew install terraform` |
| checkov | Security linter | `pip install checkov` |
| Helm | Kubernetes packaging | `brew install helm` |
| kind | Local K8s cluster | `brew install kind` |
| kube-score | K8s manifest linter | [GitHub releases](https://github.com/zegl/kube-score/releases) |
| infracost | Cost estimation | `brew install infracost` |
| kubectl | Kubernetes CLI | `brew install kubectl` |
| helm-diff (optional) | K8s drift detection | `helm plugin install https://github.com/databus23/helm-diff` |

---

## Quick Start

```bash
# 1. Clone and build
git clone https://github.com/shubhamjaggi/gentepede-mcp
cd gentepede-mcp
./gradlew shadowJar

# 2. Start LocalStack (for LOCAL mode)
docker run -d --name localstack -p 4566:4566 localstack/localstack

# 3. Configure Claude Desktop
# Add to ~/Library/Application Support/Claude/claude_desktop_config.json:
# {
#   "mcpServers": {
#     "gentepede": {
#       "command": "java",
#       "args": ["-jar", "/path/to/build/libs/gentepede-mcp-all.jar"],
#       "env": { "GENTEPEDE_MODE": "LOCAL" }
#     }
#   }
# }

# 4. Restart Claude Desktop, then ask:
# "List available Gentepede blueprints"
# "Generate a Spring Boot + Postgres ECS infrastructure called 'my-api'"
```

See [docs/12-end-to-end-walkthrough.md](docs/12-end-to-end-walkthrough.md) for the complete guide.

---

## Deployment Workflow

```
generate_infrastructure_package   → Creates Terraform + Helm files in workspace
        ↓
validate_infrastructure_package   → terraform validate + checkov + kube-score (no AWS calls)
        ↓
plan_infrastructure_package       → terraform plan + infracost cost estimate
        ↓  (review the output)
apply_infrastructure_package      → terraform apply + helm upgrade --install
        ↓
detect_drift                      → Ongoing: check for manual AWS changes
        ↓
destroy_infrastructure_package    → terraform destroy + helm uninstall

audit_infrastructure_package      → Standalone security report (any time)
```

---

## Configuration Matrix

| Environment Variable | Default | Description |
|---|---|---|
| `GENTEPEDE_MODE` | `LOCAL` | `LOCAL` = LocalStack; `PRODUCTION` = real AWS |
| `AWS_REGION` | `us-east-1` | AWS region for PRODUCTION deployments |
| `AWS_PROFILE` | `default` | AWS CLI named profile for PRODUCTION |
| `TF_LOG` | (unset) | Set to `DEBUG` to see Terraform API calls |
| `KUBECONFIG` | `~/.kube/config` | Kubernetes config file location |

---

## Supported Blueprints

| Blueprint ID | Framework | Output | AWS Resources | Provider | Last Verified | Est. Monthly Cost |
|---|---|---|---|---|---|---|
| `springboot-postgres` | Spring Boot | Terraform only | ECS Fargate, RDS PostgreSQL, ALB, VPC, KMS | 5.82.0 | 2026-06 | ~$70-120 |
| `ktor-dynamodb` | Ktor | Terraform only | ECS Fargate, DynamoDB, ALB, VPC | 5.82.0 | 2026-06 | ~$40-80 |
| `nodejs-s3` | Node.js | Terraform only | Lambda, API Gateway, S3, CloudFront, KMS | 5.82.0 | 2026-06 | ~$5-30 |
| `fastapi-redis` | FastAPI | Terraform only | ECS Fargate, ElastiCache Redis, ALB, VPC | 5.82.0 | 2026-06 | ~$50-90 |
| `springboot-eks` | Spring Boot | Terraform + Helm | EKS Cluster, RDS PostgreSQL, ALB Ingress, VPC | 5.82.0 | 2026-06 | ~$150-250 |
| `nodejs-eks` | Node.js | Terraform + Helm | EKS Cluster, S3, CloudFront, ALB Ingress, VPC | 5.82.0 | 2026-06 | ~$100-200 |

---

## Security Model

Gentepede embeds security best practices directly in every Terraform template and Helm chart — you cannot generate insecure infrastructure without modifying the templates. checkov runs as a gate before planning (blocks on HIGH/CRITICAL); kube-score validates Kubernetes manifests. AWS credential identity is confirmed before every PRODUCTION operation, and plan file checksums prevent stale plan application. See [docs/09-security-model.md](docs/09-security-model.md).

---

## Documentation

| File | Description |
|---|---|
| [docs/00-glossary.md](docs/00-glossary.md) | Plain-English definitions of all technical terms |
| [docs/01-what-is-this.md](docs/01-what-is-this.md) | Problem, solution, example interaction, who it's for |
| [docs/02-architecture.md](docs/02-architecture.md) | Beginner diagram + technical call-graph + data flow |
| [docs/03-how-mcp-works.md](docs/03-how-mcp-works.md) | MCP protocol, stdio transport, Claude Desktop config |
| [docs/04-blueprints-guide.md](docs/04-blueprints-guide.md) | Blueprint schema field-by-field, outputType comparison |
| [docs/05-terraform-guide.md](docs/05-terraform-guide.md) | Resource-by-resource walkthrough, state management |
| [docs/06-kubernetes-guide.md](docs/06-kubernetes-guide.md) | ECS vs EKS, Helm chart walkthrough, kind setup |
| [docs/07-dual-mode-guide.md](docs/07-dual-mode-guide.md) | LOCAL vs PRODUCTION: providers.tf side-by-side |
| [docs/08-tools-reference.md](docs/08-tools-reference.md) | All 8 tools: full input/output, workflow diagram |
| [docs/09-security-model.md](docs/09-security-model.md) | checkov + kube-score tables, credential pre-flight |
| [docs/10-adding-blueprints.md](docs/10-adding-blueprints.md) | Worked example: adding `go-dynamodb` end-to-end |
| [docs/11-troubleshooting.md](docs/11-troubleshooting.md) | Every common error with exact message, cause, fix |
| [docs/12-end-to-end-walkthrough.md](docs/12-end-to-end-walkthrough.md) | Complete Phase 1-7 walkthrough from fresh machine |

---

## Contributing

Contributions welcome — especially new blueprints for additional tech stacks. Start with [CONTRIBUTING.md](CONTRIBUTING.md), and see [docs/10-adding-blueprints.md](docs/10-adding-blueprints.md) for the step-by-step blueprint guide and PR checklist.

The architecture deliberately separates concerns: Engine.kt (thin MCP handler), InfrastructureService.kt (business logic, fully testable without MCP server), Validator.kt (CLI output parsing), and Models.kt (shared types). Keep this separation when contributing.

This project follows a [Code of Conduct](CODE_OF_CONDUCT.md). To report a security vulnerability, see [SECURITY.md](SECURITY.md) — please do not open a public issue.

---

## License

MIT License. See [LICENSE](LICENSE) for details.
