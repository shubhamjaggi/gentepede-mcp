# Glossary

Plain-English definitions of every technical term used in the Gentepede MCP project.

---

## A

**ALB (Application Load Balancer)**
An AWS service that distributes incoming HTTPS traffic across multiple backend servers (e.g. ECS tasks or EKS pods). Gentepede configures ALBs with a port-80→443 redirect so all traffic is encrypted.

**AWS (Amazon Web Services)**
A cloud computing platform offering hundreds of managed services. Gentepede automates provisioning of a subset: ECS, EKS, Lambda, RDS, S3, DynamoDB, ElastiCache, CloudFront, ALB, VPC, IAM, KMS.

**AWS CLI**
The command-line interface for AWS. Gentepede calls it via ProcessBuilder to run `aws sts get-caller-identity` before production operations.

---

## B

**Blueprint**
A JSON file in `src/main/resources/blueprints/` that describes a complete AWS architecture for a given tech stack. Blueprints are NOT Terraform code — they are metadata that tells InfrastructureService which Terraform template family to copy and what variables to expose. Think of a blueprint as the "recipe card"; the template family is the actual "recipe".

---

## C

**checkov**
An open-source static analysis tool for Terraform (and other IaC formats) that checks for security misconfigurations. Gentepede runs it in `validate_infrastructure_package` (abort on HIGH/CRITICAL) and `audit_infrastructure_package` (report all). See `docs/09-security-model.md` for the full list of checks enforced.

**CloudFront**
AWS's global content delivery network (CDN). Gentepede places CloudFront in front of API Gateway (nodejs-s3 blueprint) to cache responses at edge locations and enforce HTTPS globally.

---

## D

**DynamoDB**
A fully managed AWS NoSQL database. Unlike RDS, it has no server to provision — you pay per request. Gentepede provisions DynamoDB tables with encryption at rest and point-in-time recovery.

**DynamoDB State Locking**
In PRODUCTION mode, Terraform stores state in S3 and uses a DynamoDB table to prevent two concurrent `terraform apply` runs from corrupting the state file by acquiring a distributed lock.

**Drift**
A difference between the infrastructure described in Terraform state and the infrastructure that actually exists in AWS. Drift happens when someone changes infrastructure manually (via the console or CLI) without updating Terraform. `detect_drift` surfaces this.

---

## E

**ECS Fargate (Elastic Container Service)**
A serverless container execution environment. You define how much CPU and memory a container needs, and AWS runs it without you managing servers. Gentepede deploys ECS Fargate tasks in private subnets behind an ALB.

**EKS (Elastic Kubernetes Service)**
AWS's managed Kubernetes control plane. You bring worker nodes; AWS manages the Kubernetes API server, etcd, and control plane HA. Gentepede provisions EKS clusters in private subnets with encrypted Kubernetes secrets.

**ElastiCache**
AWS's managed in-memory caching service. Gentepede provisions Redis clusters via ElastiCache with encryption at rest and in transit (TLS).

---

## F

**Fat JAR**
A single `.jar` file that includes both the application code and all its dependencies. Gentepede uses the Shadow plugin to build `build/libs/gentepede-mcp-all.jar`, which can be run with `java -jar` without any additional classpath setup.

---

## H

**Helm**
A package manager for Kubernetes. Helm charts are parameterised templates that produce Kubernetes YAML at deploy time. Gentepede generates a production-ready Helm chart for EKS blueprints, avoiding raw YAML which is harder to version and rollback.

**Helm chart**
A directory of Helm templates (`helm-chart/`) plus a `Chart.yaml` and `values.yaml`. When Gentepede runs `helm upgrade --install`, it renders the chart by merging `values.yaml` with the templates and applies the resulting Kubernetes objects.

---

## I

**IAM (Identity and Access Management)**
AWS's permission system. Every AWS API call must be made by an IAM principal (user, role, or service) with explicit permission. Gentepede creates IAM roles for ECS tasks and EKS nodes with the minimum permissions needed (no wildcard `*` actions).

**IaC (Infrastructure as Code)**
The practice of defining cloud infrastructure in code files (here, Terraform HCL) that can be version-controlled, reviewed, and automatically applied. The alternative is clicking in the AWS console, which is not reproducible and error-prone.

**Infracost**
A CLI tool that parses Terraform plan files and estimates the monthly AWS cost of the resources to be created. Gentepede calls it in `plan_infrastructure_package` if it is in PATH.

---

## J

**JSON-RPC**
A remote procedure call protocol that uses JSON for encoding. MCP uses JSON-RPC 2.0 over standard input/output. The MCP SDK handles all JSON-RPC framing; you never see raw Content-Length headers in Gentepede's code.

---

## K

**kind (Kubernetes IN Docker)**
A tool for running local Kubernetes clusters using Docker containers as nodes. It is free and requires only Docker Desktop. Gentepede uses it for LOCAL mode EKS blueprint testing. The user creates the cluster manually (`kind create cluster --name gentepede-local`); Gentepede checks for it and aborts with instructions if not found.

**KMS (Key Management Service)**
AWS's managed encryption key service. Gentepede creates a per-project KMS key used to encrypt RDS databases, S3 buckets, ElastiCache clusters, CloudWatch logs, and Kubernetes secrets. Per-project keys allow independent auditing and revocation.

**kube-score**
A CLI tool that analyses Kubernetes YAML manifests for security and reliability issues. Because Helm charts contain Go template syntax, Gentepede renders them with `helm template` first, then pipes the output to kube-score.

**Kubernetes**
An open-source container orchestration platform. It manages where containers run, how many replicas are active, health checks, rolling deployments, and networking between services. EKS is the AWS-managed version.

---

## L

**Lambda**
AWS's serverless function execution environment. You upload code and AWS runs it in response to events (HTTP requests via API Gateway, S3 uploads, etc.) without any servers. The nodejs-s3 blueprint uses Lambda.

**LocalStack**
A locally-running emulator for AWS services. It implements the same HTTP APIs as real AWS, so Terraform plans run against it identically to production — but no AWS account or real money is needed. Run it via Docker.

---

## M

**MCP (Model Context Protocol)**
An open standard for connecting AI models (like Claude) to external tools and data sources. MCP servers expose "tools" (functions) that AI models can call. Gentepede is an MCP server; Claude Desktop is the MCP client.

---

## P

**Plan file**
The binary output of `terraform plan -out=gentepede.tfplan`. It captures exactly what Terraform will do at apply time, including all resource diffs. Applying from a plan file guarantees that the exact reviewed changes are applied — no drift from re-planning.

**ProcessBuilder**
The Java/Kotlin API for launching external processes. Gentepede uses it to run terraform, checkov, kube-score, helm, kind, infracost, and kubectl. Every call sets `.directory()` explicitly — never relying on the JVM's inherited working directory.

---

## R

**RDS (Relational Database Service)**
AWS's managed relational database service. Gentepede provisions RDS PostgreSQL instances in private subnets with encryption at rest (KMS), automated backups, and no public accessibility.

**Remote state backend**
In PRODUCTION mode, Terraform state is stored in an S3 bucket with DynamoDB locking instead of a local `terraform.tfstate` file. This enables team collaboration and prevents concurrent applies from corrupting state.

---

## S

**S3 (Simple Storage Service)**
AWS's object storage service. Used in Gentepede for: Lambda deployment packages (nodejs-s3), static assets (nodejs-eks), Terraform remote state (PRODUCTION), and VPC flow logs.

**StdioServerTransport**
The MCP transport that reads JSON-RPC messages from stdin and writes responses to stdout. This is the standard transport for MCP servers started via `java -jar` — the client process manages the server's stdin/stdout pipes.

---

## T

**Terraform**
An open-source IaC tool by HashiCorp. You write `.tf` files describing AWS resources; Terraform computes the difference between desired and actual state and applies the minimum changes. Gentepede orchestrates Terraform via ProcessBuilder.

**Terraform state**
A JSON file (`terraform.tfstate`) that records which real AWS resources correspond to which Terraform resource definitions. Without state, Terraform cannot determine what already exists and would try to recreate everything.

**Template family**
One of three subdirectories under `templates/`: `ecs/`, `lambda/`, or `eks/`. Each is a complete, standalone Terraform project for its architecture family. InfrastructureService selects the family via the `templateFamily` field in the blueprint JSON.

---

## V

**VPC (Virtual Private Cloud)**
An isolated virtual network in AWS. All Gentepede compute and data resources run inside a VPC. Public subnets hold only the ALB; private subnets hold ECS tasks, EKS nodes, RDS, and ElastiCache.

**VPC flow logs**
Network traffic metadata (source IP, destination IP, port, bytes transferred) captured for all traffic through a VPC. Required by CKV_AWS_66. Stored in S3 for security investigations.
