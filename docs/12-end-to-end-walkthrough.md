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

### Terraform

**macOS:** `brew install terraform`
**Windows:** `choco install terraform`
**Ubuntu/Debian:**
```bash
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install terraform
```

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
git clone https://github.com/shubhamjaggi/gentepede-mcp
cd gentepede-mcp
./gradlew shadowJar
```

Output: `build/libs/gentepede-mcp-all.jar`

Verify:
```bash
ls -lh build/libs/gentepede-mcp-all.jar

# To confirm it starts, run it briefly and kill it:
java -jar build/libs/gentepede-mcp-all.jar &
sleep 1 && kill %1
# No error = success. (It blocks on stdin — that is expected behaviour, not a hang.)
```

---

## Phase 3 — AWS Setup

### Credentials

Configure AWS credentials in your environment:

```bash
# Option A: environment variables
export AWS_ACCESS_KEY_ID=AKIA...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=us-east-1

# Option B: named profile (recommended)
aws configure --profile my-profile
# then set: export AWS_PROFILE=my-profile
```

Verify: `aws sts get-caller-identity`

### Create Remote State Prerequisites (once per project)

Gentepede uses an S3 bucket and DynamoDB table for Terraform remote state. Create these once before your first `plan`:

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
        "AWS_PROFILE": "my-profile",
        "AWS_DEFAULT_REGION": "us-east-1"
      }
    }
  }
}
```

**Restart Claude Desktop** to apply the configuration.

**Verify the server connected:** In Claude Desktop, you should see a tools icon (🔧) indicating MCP tools are available. Hover over it to see "gentepede" listed.

---

## Phase 5 — First Deployment (ECS: springboot-postgres)

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
Acting as: arn:aws:iam::123456789012:role/deploy-role
Account:   123456789012

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
Apply successful. (~5-10 minutes for ECS, ~15-25 for EKS)
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

## Phase 6 — EKS Deployment (springboot-eks)

### Step 1: Generate the workspace
```
generate_infrastructure_package
  blueprint_name: "springboot-eks"
  project_name: "my-eks-app"
  variables:
    container_image: "my-ecr/app:1.0"
    image_tag: "1.0"
    certificate_arn: "arn:aws:acm:us-east-1:123:certificate/test"
```

### Step 2: Validate, plan, apply

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

The apply output shows both Terraform and Helm results (EKS cluster creation takes ~15-25 minutes):
```
Apply Complete: my-eks-app
Helm Deploy Output:
Release "my-eks-app" does not exist. Installing it now.
NAME: my-eks-app
LAST DEPLOYED: ...
STATUS: deployed
```

After Terraform apply completes, Helm deploys to whatever EKS cluster is set as the current context in `~/.kube/config`. Before running apply, update your kubeconfig to point at the new cluster:

```bash
aws eks update-kubeconfig --name my-eks-app --region us-east-1
```

This sets the current context so `helm upgrade --install` (run by Gentepede inside `apply_infrastructure_package`) targets the right cluster.
