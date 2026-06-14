# Security Model

## Shift-Left Philosophy

"Shift left" means catching security issues earlier in the development lifecycle — before they reach production, before they are reviewed by a security team, ideally before they are even committed.

Gentepede implements shift-left by:
1. Embedding security best practices directly in the Terraform templates — you cannot generate insecure infrastructure without modifying the template
2. Running checkov (static analysis) before any AWS API call is made
3. Running kube-score (Kubernetes manifest analysis) before any pod is deployed
4. Requiring plan review before apply (no `terraform apply -auto-approve` except in destroy)
5. Requiring credential confirmation before any PRODUCTION AWS operation

---

## checkov

checkov is a static analysis tool for Terraform (and other IaC formats). It reads your `.tf` files and checks for known security misconfigurations — no AWS API calls required.

**How Gentepede uses it:**
- In `validate_infrastructure_package`: aborts if any finding has severity HIGH or CRITICAL
- In `audit_infrastructure_package`: returns all findings but never aborts

**Why abort only on HIGH/CRITICAL (not LOW/MEDIUM)?**

LOW and MEDIUM findings are informational best-practice suggestions. Aborting a deployment pipeline on every LOW finding would make Gentepede unusable for most real-world templates (which always have some LOW findings). HIGH and CRITICAL findings represent exploitable misconfigurations with immediate security implications — these should always block deployment.

| Severity | Example | Abort in validate? |
|---|---|---|
| CRITICAL | Unencrypted EBS volume | Yes |
| HIGH | RDS publicly accessible | Yes |
| MEDIUM | CloudTrail log validation not enabled | No (audit only) |
| LOW | S3 lifecycle policy missing | No (audit only) |

### Checkov Rules Enforced by Gentepede Templates

Every Terraform template is designed to NOT trigger these checks:

| Check ID | Plain English | What a bad actor could do without it |
|---|---|---|
| CKV_AWS_2 | ALB must enforce HTTPS | Intercept HTTP traffic between clients and ALB; read credentials and tokens in plaintext |
| CKV_AWS_17 | RDS not publicly accessible | Connect directly to the database from the internet and brute-force credentials |
| CKV_AWS_19 | S3 SSE enabled | Read S3 object data from raw EBS snapshots if AWS storage is compromised |
| CKV_AWS_21 | S3 versioning enabled | Overwrite or delete objects with no recovery path |
| CKV_AWS_23 | RDS storage encrypted | Read database files from an EBS snapshot |
| CKV_AWS_66 | VPC flow logs enabled | Investigate a security incident with no network traffic records |
| CKV_AWS_111 | No wildcard IAM actions | Compromise one service role and use it to take over the entire AWS account |

**Failing example for CKV_AWS_17:**
```hcl
resource "aws_db_instance" "bad" {
  publicly_accessible = true  # ← violates CKV_AWS_17
}
```

**Gentepede's implementation:**
```hcl
resource "aws_db_instance" "postgres" {
  publicly_accessible = false  # ← CKV_AWS_17 passes
}
```

---

## kube-score

kube-score analyses rendered Kubernetes manifests for security and reliability issues. Because Helm charts use Go template syntax, Gentepede renders them first with `helm template` and pipes the output to kube-score.

**How Gentepede uses it:**
- In `validate_infrastructure_package`: aborts if any `[CRITICAL]` line appears in kube-score output
- In `audit_infrastructure_package`: returns all findings

### kube-score Checks Enforced by Gentepede Helm Charts

| Check | Gentepede's implementation | Risk without it |
|---|---|---|
| Container missing `runAsNonRoot` | `runAsNonRoot: true` in pod securityContext | Container runs as root; kernel escape = full host access |
| Missing resource requests/limits | Both set in `values.yaml` | One pod consumes all node CPU/memory; others starve |
| Missing liveness/readiness probes | Both configured per framework | Hung processes never restarted; traffic sent to unready pods |
| Image tag `latest` | `{{ .Values.image.tag }}` — never hardcoded | Non-reproducible deployments; unknown version in production |
| No `podAntiAffinity` | Preferred anti-affinity on `kubernetes.io/hostname` | All replicas on one node; node failure = full outage |
| Missing `NetworkPolicy` | deny-all default + explicit allow from ingress | Any compromised pod can reach any other service in the cluster |

---

## Credential Pre-flight

Before every PRODUCTION operation that contacts AWS:
```bash
aws sts get-caller-identity
```

The response is prepended to the tool output:
```
Acting as: arn:aws:iam::123456789012:role/deploy-role
Account:   123456789012
User ID:   AROAXXXXXXXXXXXXXXXXX
```

**Why this matters:**
1. Confirms you are using the intended AWS account (prevents accidental production deploys from dev credentials)
2. Creates an audit trail — you know which role performed the operation
3. Fast-fails on expired credentials or missing profiles before Terraform makes dozens of API calls that all return "Access Denied"

**Not run by:** `validate_infrastructure_package` (pure static analysis, zero AWS API calls).

---

## Plan File Checksum Integrity

`plan_infrastructure_package` saves `gentepede.tfplan` and computes its SHA-256 hash, stored in `gentepede.lock.json`.

`apply_infrastructure_package` recomputes the hash before applying. If it does not match, apply aborts:
```
Error: Plan file checksum mismatch. The plan may have been modified or regenerated.
Expected: sha256:abc123...
Actual:   sha256:xyz789...
Run plan_infrastructure_package again to create a fresh plan.
```

**What this prevents:**
- Applying a plan that was generated for different variables (e.g. someone ran `generate_infrastructure_package` again after the review)
- Applying a plan that was regenerated after infrastructure changes (the new plan might destroy/modify things you didn't review)
- Accidental file corruption

---

## Audit Mode vs Validate Mode

| Feature | `validate_infrastructure_package` | `audit_infrastructure_package` |
|---|---|---|
| Aborts on HIGH/CRITICAL | Yes | No |
| Returns ALL findings | No (aborts early) | Yes |
| Credential pre-flight | No (static only) | No |
| Purpose | Gate: block bad deploys | Report: understand posture |
| When to use | Before planning | Any time, independently |

Use `audit_infrastructure_package` when you want to understand the full security landscape of an existing workspace without affecting the deployment pipeline.
