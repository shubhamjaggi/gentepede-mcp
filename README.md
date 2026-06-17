# Gentepede MCP

[![CI](https://github.com/shubhamjaggi/gentepede-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/shubhamjaggi/gentepede-mcp/actions/workflows/ci.yml)
[![Lint](https://github.com/shubhamjaggi/gentepede-mcp/actions/workflows/lint.yml/badge.svg)](https://github.com/shubhamjaggi/gentepede-mcp/actions/workflows/lint.yml)
[![Blueprint Verification](https://github.com/shubhamjaggi/gentepede-mcp/actions/workflows/blueprint-verify.yml/badge.svg)](https://github.com/shubhamjaggi/gentepede-mcp/actions/workflows/blueprint-verify.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Java 21](https://img.shields.io/badge/Java-21-orange.svg)](https://adoptium.net/)
[![Kotlin](https://img.shields.io/badge/Kotlin-2.4-purple.svg)](https://kotlinlang.org/)

A Kotlin-based [MCP](docs/00-glossary.md#mcp-model-context-protocol) server that acts as a deterministic Knowledge Engine for enterprise cloud architectures. Maps application tech-stacks (Spring Boot, Ktor, Node.js, FastAPI) to fully provisioned, secure [AWS](docs/00-glossary.md#aws-amazon-web-services) infrastructure via [Terraform](docs/00-glossary.md#terraform) — and for EKS blueprints also generates a production-ready [Helm](docs/00-glossary.md#helm) chart alongside the Terraform. Features a full plan-review-apply pipeline, live cost estimation via [Infracost](docs/00-glossary.md#infracost), drift detection, and credential transparency.

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
                                      │                              EKS (real AWS)
                                   real AWS
```

---

## Prerequisites

Install all of the following before building:

| Tool | Purpose | Install |
|---|---|---|
| Java 21 | JVM runtime for the server | [SDKMAN](https://sdkman.io/) / [Homebrew](https://brew.sh/) / [winget](https://learn.microsoft.com/en-us/windows/package-manager/) |
| Terraform | IaC provisioning | `brew install terraform` |
| checkov | Security linter | `pip install checkov` |
| Helm | Kubernetes packaging | `brew install helm` |
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

# 2. Configure Claude Desktop
# Add to ~/Library/Application Support/Claude/claude_desktop_config.json:
# {
#   "mcpServers": {
#     "gentepede": {
#       "command": "java",
#       "args": ["-jar", "/path/to/build/libs/gentepede-mcp-all.jar"],
#       "env": { "AWS_PROFILE": "my-profile", "AWS_DEFAULT_REGION": "us-east-1" }
#     }
#   }
# }

# 3. Restart Claude Desktop, then ask:
# "List available Gentepede blueprints"
# "Generate a Spring Boot + Postgres ECS infrastructure called 'my-api'"
```

See [docs/11-end-to-end-walkthrough.md](docs/11-end-to-end-walkthrough.md) for the complete guide.

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
| `AWS_DEFAULT_REGION` | `us-east-1` | AWS region for deployments |
| `AWS_PROFILE` | `default` | AWS CLI named profile |
| `TF_LOG` | (unset) | Set to `DEBUG` to see Terraform API calls |
| `KUBECONFIG` | `~/.kube/config` | Kubernetes config file location |

---

## Supported Blueprints

| Blueprint ID | Framework | Output | AWS Resources | Provider | Last Verified | Est. Monthly Cost |
|---|---|---|---|---|---|---|
| `springboot-postgres` | Spring Boot | Terraform only | ECS Fargate, RDS PostgreSQL, ALB, VPC, KMS | 5.82.0 | 2026-06 | ~$70-120 |
| `ktor-dynamodb` | Ktor | Terraform only | ECS Fargate, DynamoDB, ALB, VPC, KMS | 5.82.0 | 2026-06 | ~$40-80 |
| `nodejs-s3` | Node.js | Terraform only | Lambda, API Gateway, S3, CloudFront, KMS | 5.82.0 | 2026-06 | ~$5-30 |
| `fastapi-redis` | FastAPI | Terraform only | ECS Fargate, ElastiCache Redis, ALB, VPC, KMS | 5.82.0 | 2026-06 | ~$50-90 |
| `springboot-eks` | Spring Boot | Terraform + Helm | EKS Cluster, RDS PostgreSQL, ALB Ingress, VPC | 5.82.0 | 2026-06 | ~$150-250 |
| `nodejs-eks` | Node.js | Terraform + Helm | EKS Cluster, S3, CloudFront, ALB Ingress, VPC | 5.82.0 | 2026-06 | ~$100-200 |

---

## Security Model

Gentepede embeds security best practices directly in every Terraform template and Helm chart — you cannot generate insecure infrastructure without modifying the templates. checkov runs as a gate before planning (blocks on HIGH/CRITICAL); kube-score validates Kubernetes manifests. AWS credential identity is confirmed before every operation that contacts AWS, and plan file checksums prevent stale plan application. See [docs/08-security-model.md](docs/08-security-model.md).

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
| [docs/06-kubernetes-guide.md](docs/06-kubernetes-guide.md) | ECS vs EKS, Helm chart walkthrough, Kubernetes resources |
| [docs/07-tools-reference.md](docs/07-tools-reference.md) | All 8 tools: full input/output, workflow diagram |
| [docs/08-security-model.md](docs/08-security-model.md) | checkov + kube-score tables, credential pre-flight |
| [docs/09-adding-blueprints.md](docs/09-adding-blueprints.md) | Worked example: adding `go-dynamodb` end-to-end |
| [docs/10-troubleshooting.md](docs/10-troubleshooting.md) | Every common error with exact message, cause, fix |
| [docs/11-end-to-end-walkthrough.md](docs/11-end-to-end-walkthrough.md) | Complete Phase 1-6 walkthrough from fresh machine to AWS deployment |
| [docs/12-development-guide.md](docs/12-development-guide.md) | Build, test, debug, project structure for contributors |
| [docs/13-faq.md](docs/13-faq.md) | Common questions from users and contributors |
| [docs/14-blueprint-to-resource-map.md](docs/14-blueprint-to-resource-map.md) | Full mapping: which blueprint provisions which AWS services and why |
| [docs/15-tool-architecture.md](docs/15-tool-architecture.md) | End-to-end architecture of all 8 tools: every layer, every CLI call, every file |
| [docs/16-contributor-sync-guide.md](docs/16-contributor-sync-guide.md) | Complete sync checklist for every contributor change type (blueprint, template family, tool, Helm chart, provider bump) |
| [docs/17-github-actions-guide.md](docs/17-github-actions-guide.md) | Plain-English explanation of every CI workflow: what it does, when it runs, and why |

---

## Contributing

Contributions welcome — especially new blueprints for additional tech stacks. Start with [CONTRIBUTING.md](CONTRIBUTING.md), and see [docs/09-adding-blueprints.md](docs/09-adding-blueprints.md) for the step-by-step blueprint guide and PR checklist.

The architecture deliberately separates concerns: Engine.kt (thin MCP handler), InfrastructureService.kt (business logic, fully testable without MCP server), Validator.kt (CLI output parsing), and Models.kt (shared types). Keep this separation when contributing.

This project follows a [Code of Conduct](CODE_OF_CONDUCT.md). To report a security vulnerability, see [SECURITY.md](SECURITY.md) — please do not open a public issue.

---

## License

MIT License. See [LICENSE](LICENSE) for details.
