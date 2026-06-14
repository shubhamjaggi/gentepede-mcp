# End-to-End Walkthrough

A complete guide from a fresh machine to a running deployment.

---

## Phase 1 — Install Prerequisites

### Java 21

**macOS (SDKMAN):**
```bash
curl -s "https://get.sdkman.io" | bash
sdk install java 21.0.3-tem
```

**macOS (Homebrew):**
```bash
brew install --cask temurin@21
```

**Windows:**
```powershell
winget install EclipseAdoptium.Temurin.21.JDK
```

**Ubuntu/Debian:**
```bash
sudo apt install temurin-21-jdk
```

Verify: `java -version` → `openjdk 21...`

### Docker Desktop

Download from https://www.docker.com/products/docker-desktop/ and install for your OS.

Verify: `docker --version`

### Terraform

**macOS:** `brew install terraform`
**Windows:** `choco install terraform`
**Ubuntu:** `sudo apt-get install terraform` (after adding HashiCorp apt repository)

Verify: `terraform -version`

### checkov

```bash
pip install checkov
```

Verify: `checkov --version`

### kube-score

Download the binary for your OS from https://github.com/zegl/kube-score/releases and place it in a directory in your PATH.

Verify: `kube-score version`

### Helm

**macOS:** `brew install helm`
**Windows:** `choco install kubernetes-helm`
**Linux:** `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash`

Verify: `helm version`

### kind

**macOS:** `brew install kind`
**Windows:** `choco install kind`
**Linux:** Download from https://github.com/kubernetes-sigs/kind/releases

Verify: `kind version`

### infracost

**macOS:** `brew install infracost`
**Others:** `curl -fsSL https://raw.githubusercontent.com/infracost/infracost/master/scripts/install.sh | sh`

Verify: `infracost --version`

### kubectl

**macOS:** `brew install kubectl`
**Windows:** `choco install kubernetes-cli`
**Linux:** `sudo apt-get install kubectl`

Verify: `kubectl version --client`

### Optional: helm-diff plugin (for K8s drift detection)

```bash
helm plugin install https://github.com/databus23/helm-diff
```

Verify: `helm diff version`

---

## Phase 2 — Build

```bash
git clone https://github.com/your-org/gentepede-mcp
cd gentepede-mcp
./gradlew shadowJar
```

Output: `build/libs/gentepede-mcp-all.jar`

Verify:
```bash
java -jar build/libs/gentepede-mcp-all.jar --help
# Server starts and waits for stdin — Ctrl+C to exit
```

---

## Phase 3 — Start LocalStack

```bash
docker run -d --name localstack \
  -p 4566:4566 -p 4510-4559:4510-4559 \
  localstack/localstack

# Wait for it to start, then verify
curl http://localhost:4566/_localstack/health
```

Expected: `{"services": {"s3": "running", ...}}`

---

## Phase 4 — Configure Claude Desktop

**Configuration file location:**
- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`
- Linux: `~/.config/Claude/claude_desktop_config.json`

**Add this configuration** (replace `/absolute/path/to` with the actual path):

```json
{
  "mcpServers": {
    "gentepede": {
      "command": "java",
      "args": ["-jar", "/absolute/path/to/gentepede-mcp/build/libs/gentepede-mcp-all.jar"],
      "env": {
        "GENTEPEDE_MODE": "LOCAL"
      }
    }
  }
}
```

**Restart Claude Desktop** to apply the configuration.

**Verify the server connected:** In Claude Desktop, you should see a tools icon (🔧) indicating MCP tools are available. Hover over it to see "gentepede" listed.

---

## Phase 5 — First LOCAL Deployment (ECS: springboot-postgres)

In the Claude Desktop conversation:

### Step 1: List blueprints
**You:** "List the available Gentepede blueprints"
**Claude calls:** `list_available_blueprints`
**Response:** Shows 6 blueprints including `springboot-postgres`

### Step 2: Generate workspace
**You:** "Generate a Spring Boot + Postgres ECS workspace called 'my-api' with image my-ecr/app:1.0, cert ARN arn:aws:acm:us-east-1:123:certificate/test"
**Claude calls:** `generate_infrastructure_package` with blueprint_name="springboot-postgres", project_name="my-api", variables=...
**Response:**
```
Infrastructure Package Generated
Project: my-api
Mode: LOCAL
Workspace: /Users/you/.gentepede/workspaces/my-api
AWS Resources to Create: VPC, ALB, ECS_FARGATE, RDS_POSTGRES, KMS
Next Step: Run validate_infrastructure_package
```

### Step 3: Validate
**Claude calls:** `validate_infrastructure_package project_name="my-api"`
**Response:**
```
terraform validate: PASSED
checkov: PASSED
✓ All validation checks passed.
```

### Step 4: Plan
**Claude calls:** `plan_infrastructure_package project_name="my-api"`
**Response:**
```
Will CREATE 14 resources
Cost Estimate: $73.12/USD per month (estimated)
[CREATE] aws_kms_key.main
[CREATE] aws_vpc.main
...
Next Step: Review the plan, then run apply_infrastructure_package.
```

### Step 5: Apply
**Claude calls:** `apply_infrastructure_package project_name="my-api"`
**Response:**
```
Apply Complete: my-api
Apply successful.
State backup: /Users/you/.gentepede/backups/my-api/2025-06-14T10-30-00Z.tfstate
```

### Step 6: Detect drift
**Claude calls:** `detect_drift project_name="my-api"`
**Response:**
```
Has drift: false
Terraform: No drift detected.
Recommendation: Infrastructure matches desired state.
```

### Step 7: Full security audit
**Claude calls:** `audit_infrastructure_package project_name="my-api"`
**Response:** Full findings report grouped by severity.

---

## Phase 6 — First LOCAL EKS Deployment (springboot-eks)

### Step 1: Generate the workspace (includes kind-config.yaml)
```
generate_infrastructure_package
  blueprint_name: "springboot-eks"
  project_name: "my-eks-app"
  variables:
    container_image: "my-ecr/app:1.0"
    image_tag: "1.0"
    certificate_arn: "arn:aws:acm:us-east-1:123:certificate/test"
```

### Step 2: Create the kind cluster
```bash
kind create cluster --name gentepede-local \
  --config ~/.gentepede/workspaces/my-eks-app/kind-config.yaml

# Verify
kind get clusters        # → gentepede-local
kubectl get nodes        # → shows control-plane + 2 worker nodes
```

### Step 3: Validate, plan, apply (same as Phase 5)

The plan output for EKS blueprints also shows the rendered Helm manifests:
```
Rendered Kubernetes Manifests (Helm):
------------------------------------------------------------
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-eks-app
...
```

The apply output shows both Terraform and Helm results:
```
Apply Complete: my-eks-app
Helm Deploy Output:
Release "my-eks-app" does not exist. Installing it now.
NAME: my-eks-app
LAST DEPLOYED: ...
STATUS: deployed
```

### Step 4: Access the app locally
```bash
# Port-forward the service to your local machine
kubectl port-forward svc/my-eks-app 8080:80 -n my-eks-app

# Test
curl http://localhost:8080/health
```

---

## Phase 7 — Switch to PRODUCTION

### AWS Credentials
```bash
# Option A: environment variables (add to claude_desktop_config.json env block)
"AWS_ACCESS_KEY_ID": "AKIA...",
"AWS_SECRET_ACCESS_KEY": "...",

# Option B: named profile
"AWS_PROFILE": "my-aws-profile"
```

### Create Remote State Prerequisites (once per project)
```bash
PROJECT=my-api
REGION=us-east-1

# S3 state bucket
aws s3api create-bucket --bucket ${PROJECT}-tfstate --region ${REGION}
aws s3api put-bucket-encryption \
  --bucket ${PROJECT}-tfstate \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-bucket-versioning \
  --bucket ${PROJECT}-tfstate \
  --versioning-configuration Status=Enabled

# DynamoDB lock table
aws dynamodb create-table \
  --table-name ${PROJECT}-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ${REGION}
```

### Update Claude Desktop Config
```json
{
  "mcpServers": {
    "gentepede": {
      "command": "java",
      "args": ["-jar", "/path/to/gentepede-mcp-all.jar"],
      "env": {
        "GENTEPEDE_MODE": "PRODUCTION",
        "AWS_PROFILE": "my-profile",
        "AWS_DEFAULT_REGION": "us-east-1"
      }
    }
  }
}
```

Restart Claude Desktop.

### PRODUCTION vs LOCAL Differences in Tool Output

**plan_infrastructure_package (PRODUCTION):**
- Prepends caller identity:
  ```
  Acting as: arn:aws:iam::123456789012:role/deploy-role
  Account:   123456789012
  ```
- Takes longer (real AWS API calls, ~2-5 minutes for initial plan)
- Cost estimate reflects real AWS pricing

**apply_infrastructure_package (PRODUCTION):**
- ECS Fargate deploy: ~5-10 minutes
- EKS cluster creation: ~15-25 minutes (control plane provisioning)
- RDS instance: ~5-10 minutes
- State stored in S3 (accessible by team members)

**detect_drift (PRODUCTION):**
- Results are meaningful — reflects actual AWS resource state
- In LOCAL, LocalStack resets on Docker restart, so drift is expected after restart
