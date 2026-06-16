# Troubleshooting

## terraform not found in PATH

**Error:** `Process 'terraform ...' failed: No such file or directory`

**Root cause:** Terraform is not installed or not in the system PATH.

**Fix:**
```bash
# macOS
brew install terraform

# Ubuntu / Debian (requires HashiCorp APT repository — one-time setup)
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install terraform

# Windows
choco install terraform
# or: winget install HashiCorp.Terraform
```

Verify: `terraform -version`

---

## checkov not found in PATH

**Behaviour:** `validate_infrastructure_package` shows `checkov: SKIPPED (not installed)` — this is a graceful skip, not an error. No abort occurs.

**Fix:**
```bash
pip install checkov
```

Verify: `checkov --version`

---

## kube-score not found in PATH

**Behaviour:** `validate_infrastructure_package` shows `kube-score: SKIPPED (helm or kube-score not installed...)` — graceful skip.

**Fix:** Download the binary from https://github.com/zegl/kube-score/releases and place it in your PATH.

---

## helm not found in PATH

**Behaviour:** Helm commands are skipped gracefully. EKS blueprint deploys only Terraform resources; Helm chart is not installed.

**Fix:**
```bash
# macOS
brew install helm

# Windows
choco install kubernetes-helm

# Linux
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

---

## infracost not found in PATH

**Behaviour:** `plan_infrastructure_package` shows `Cost Estimate: SKIPPED (infracost not installed)` — graceful skip.

**Fix:**
```bash
# macOS
brew install infracost

# Others
curl -fsSL https://raw.githubusercontent.com/infracost/infracost/master/scripts/install.sh | sh
```

---

## kubectl not found in PATH

**Error:** `Process 'kubectl wait ...' failed` during destroy of TERRAFORM_K8S blueprint.

**Fix:**
```bash
# macOS
brew install kubectl

# Windows
choco install kubernetes-cli
```

---

## No AWS credentials

**Error:**
```
Error: AWS credential pre-flight failed. Ensure AWS credentials are configured.
For environment variables: export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
For named profiles: export AWS_PROFILE=...
Original error: Unable to locate credentials
```

**Fix:**
```bash
# Option A: environment variables
export AWS_ACCESS_KEY_ID=AKIA...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=us-east-1

# Option B: named profile
aws configure --profile my-profile
# then in claude_desktop_config.json: "AWS_PROFILE": "my-profile"
```

Verify: `aws sts get-caller-identity`

---

## Blueprint not found

**Error:** `Error: Blueprint 'springbot-posgres' not found. Run list_available_blueprints...`

**Root cause:** Typo in `blueprint_name`. Blueprint names are case-sensitive slugs.

**Fix:** Run `list_available_blueprints` to see the exact IDs, then retry with the correct name.

---

## Process timeout after 30 minutes

**Error:** `Process timed out after 30 minutes.`

**Root cause:** A Terraform apply is creating complex resources (EKS cluster, multi-AZ RDS) that genuinely take more than 30 minutes. This is rare but can happen for EKS cluster creation on slow days.

**Fix:** The 30-minute timeout is a safety limit. For EKS blueprints, allow up to 45 minutes for first apply. If timeout happens consistently:
1. Check AWS service health dashboard for issues
2. Check CloudFormation events for the EKS cluster for specific errors
3. Run `terraform apply gentepede.tfplan` manually in the workspace for an unlimited timeout

---

## kube-score hangs or times out during validate

**Behaviour:** `validate_infrastructure_package` on a `TERRAFORM_K8S` blueprint stalls for 5 minutes, then fails with a timeout error from kube-score.

**Root cause:** kube-score is started with a 5-minute hard timeout. If the Helm-rendered YAML is unusually large or the system is under heavy load, kube-score can exceed this limit.

**Fix:**
- Ensure `helm` and `kube-score` are up to date
- If the timeout is consistent, run kube-score manually to see the raw output:
  ```bash
  helm template my-project helm/ -f helm/values.yaml | kube-score score -
  ```
- If the cluster cannot be reached, check that `kubectl` is configured and pointing at the correct context

---

## checkov HIGH/CRITICAL abort

**Error:**
```
Error: Validation Report: my-api
checkov: FAILED (1 HIGH/CRITICAL findings)

Checkov Findings:
  [HIGH] CKV_AWS_17 — aws_db_instance.postgres
    RDS publicly accessible
    Remediation: Set publicly_accessible = false

✗ Validation failed.
```

**Root cause:** The generated Terraform has a security misconfiguration. This should not happen with unmodified Gentepede templates — it indicates either a template bug or manual modification.

**Fix:** Run `audit_infrastructure_package` for the full findings list with remediation guidance. Fix the Terraform file, then re-run `validate_infrastructure_package`.

---

## kube-score CRITICAL abort

**Error:** `Error: kube-score found [CRITICAL] findings`

**Root cause:** The Helm chart has a Kubernetes security misconfiguration.

**Fix:** Run `audit_infrastructure_package` for the full kube-score findings with detail.

---

## Plan file missing or checksum mismatch

**Error:**
```
Error: No valid plan file found. Run plan_infrastructure_package first.
```
or
```
Error: Plan file checksum mismatch. The plan may have been modified or regenerated.
```

**Root cause:**
- Plan file missing: `plan_infrastructure_package` was not run, or `gentepede.tfplan` was deleted
- Checksum mismatch: `generate_infrastructure_package` was re-run after the plan (regenerates variables, changing plan output), or the plan file was manually modified

**Fix:** Run `plan_infrastructure_package` again to generate a fresh plan, then review and apply.

---

## Remote state S3 bucket / DynamoDB table not found (first apply)

**Error:** Terraform fails with `BucketNotFound` or `ResourceNotFoundException`

**Root cause:** The S3 state bucket and DynamoDB lock table must exist before the first `terraform apply`. They cannot be created by Terraform themselves (chicken-and-egg problem).

**Fix:** See `docs/12-end-to-end-walkthrough.md` Phase 3 for the exact setup commands. Create them once per project via the AWS CLI.

---

## ProcessExecutionException: how to read stdout/stderr

When a process fails, the error message includes both stdout and stderr:

```
Error: Plan failed:
Process 'terraform plan -out=...' failed with exit code 1.
STDOUT:
  Error: Error creating VPC: VpcLimitExceeded
STDERR:
  ...
```

The `STDOUT` section contains the human-readable Terraform error. The `STDERR` section contains raw diagnostic output. Focus on `STDOUT` first for actionable error messages.
