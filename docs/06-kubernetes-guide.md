# Kubernetes Guide

## ECS vs EKS: When to Choose Which

| | ECS Fargate | EKS |
|---|---|---|
| Kubernetes knowledge required | No | Yes |
| Container scheduling | AWS-managed | Kubernetes |
| Scaling | CloudWatch + ECS autoscaling | HPA + Cluster Autoscaler |
| Networking | VPC-native, ALB target groups | Pod networking (VPC CNI), Ingress |
| Cost (small apps) | Lower (no control plane fee) | +$72/month EKS control plane |
| Portability | AWS-specific | Runs anywhere Kubernetes runs |
| Helm / GitOps | Not applicable | Full Helm + ArgoCD support |

**Choose ECS if:** You want the simplest path and don't already know Kubernetes.
**Choose EKS if:** You need multi-cloud portability, GitOps tooling (ArgoCD, Flux), or advanced scheduling (affinity, taints, custom schedulers).

## Why Helm Over Raw YAML?

Raw Kubernetes YAML manifests have a critical problem: they are not parameterised. If you want the same application deployed to three environments (dev, staging, prod), you either duplicate three sets of YAML files or write a brittle `sed` replacement script.

Helm charts use Go templates (`{{ .Values.image.tag }}`) that are filled in from `values.yaml` at deploy time. This means:
- One chart, many environments (different values files per environment)
- `helm upgrade --install` is idempotent — you can run it repeatedly
- `helm rollback` undoes a deployment in seconds
- `helm diff upgrade` shows what will change before you apply (like `terraform plan`)

## Helm Chart Walkthrough

### Chart.yaml

Metadata: chart name, version, app version. Static — no Go template syntax allowed here.

### values.yaml

The "inputs" to the chart. InfrastructureService generates a per-project `helm/values.yaml` that overrides the defaults in `helm-chart/values.yaml`. Everything in `values.yaml` is referenced in templates as `{{ .Values.key }}`.

### templates/deployment.yaml

The most security-relevant file. Key fields explained:

**`securityContext.runAsNonRoot: true`**
The container's main process must not run as UID 0 (root). A root process inside a container has the same capabilities as root on the host if the container escapes via a kernel vulnerability. Running as a non-root user limits the blast radius.

Bad practice:
```yaml
securityContext:
  # runAsNonRoot absent — container defaults to root
```

**`readOnlyRootFilesystem: true`**
The container cannot write to its own filesystem outside of declared volume mounts. An attacker who gains code execution cannot write a cron job, modify binaries, or create a persistence mechanism. Any writes must go through an `emptyDir` or `persistentVolumeClaim` that is explicitly declared.

Bad practice:
```yaml
readOnlyRootFilesystem: false  # Malware can write to /usr/bin, /etc/cron.d, etc.
```

**`capabilities.drop: ["ALL"]`**
Drops all Linux capabilities by default. Without this, containers retain inherited capabilities like:
- `NET_RAW`: allows creating raw sockets (packet sniffing, ARP spoofing)
- `SYS_PTRACE`: allows attaching to other processes (credential theft)
- `DAC_OVERRIDE`: allows bypassing file permission checks

Bad practice:
```yaml
securityContext:
  # capabilities block absent — inherits all kernel capabilities
```

**`allowPrivilegeEscalation: false`**
Prevents the process from gaining more privileges than its parent, even via setuid/setgid binaries. Without this, a container running as UID 1000 could use a setuid binary to escalate to root.

**`livenessProbe` and `readinessProbe`**
- Without a `livenessProbe`, Kubernetes never restarts a hung process (e.g. deadlocked Spring Boot app).
- Without a `readinessProbe`, Kubernetes sends traffic to pods that haven't finished starting up, causing 5xx errors during deployments.
- The `initialDelaySeconds: 30` on liveness prevents Kubernetes from killing pods that are still in the JVM startup phase.

**`podAntiAffinity`**
Without this, Kubernetes might schedule all replicas on the same node. A node failure would then take down the entire service. The `preferredDuringSchedulingIgnoredDuringExecution` rule prefers spreading pods but does not hard-fail if only one node is available (unlike `requiredDuringScheduling...`).

### templates/service.yaml

Uses `ClusterIP` (not `LoadBalancer`). External traffic enters via the ALB Ingress Controller. Exposing a `LoadBalancer` service would create an additional AWS load balancer per service, increasing cost and complexity.

### templates/hpa.yaml

Horizontal Pod Autoscaler scales the Deployment between `minReplicas: 2` and `maxReplicas: 10` based on CPU utilisation. Setting `minReplicas: 2` ensures there is always more than one pod — a single pod is a single point of failure.

### templates/network-policy.yaml

Kubernetes NetworkPolicy objects restrict pod-to-pod traffic at the network layer. Without a NetworkPolicy, any pod in any namespace can reach any other pod — a compromised service in one namespace can pivot to all other services in the cluster.

Gentepede's default NetworkPolicy:
- **Ingress**: allows traffic only from pods in the `ingress-nginx` or `kube-system` namespace
- **Egress**: allows DNS (port 53), HTTPS (port 443 for AWS API calls), PostgreSQL (5432), and Redis (6379)
- All other traffic is denied by default

### templates/resource-quota.yaml

Without ResourceQuota, a misbehaving deployment can exhaust all cluster CPU and memory, causing other services to be evicted or throttled. The quota caps total resources in the namespace:
- `requests.cpu: "2"` / `limits.cpu: "4"`
- `requests.memory: "2Gi"` / `limits.memory: "4Gi"`
- `pods: "20"`: prevents runaway pod creation from a broken autoscaler

## Local Testing with kind

For LOCAL mode EKS blueprints, Gentepede generates a `kind-config.yaml` in the workspace root. The user creates the cluster manually:

```bash
kind create cluster --name gentepede-local \
  --config ~/.gentepede/workspaces/my-eks-app/kind-config.yaml
```

**Why does the user create it manually?** InfrastructureService checks for the cluster's existence via `kind get clusters` and aborts with setup instructions if not found. It intentionally does NOT auto-create it. Rationale:
1. Keeps Engine.kt simple — no cluster lifecycle management
2. Makes the user explicitly own their local environment
3. A kind cluster that persists across Gentepede invocations is more useful than one that is recreated on every generate

**After cluster creation**, verify:
```bash
kind get clusters        # should show: gentepede-local
kubectl get nodes        # should show nodes from the kind cluster
```

Helm targets the cluster via the `kind-gentepede-local` kubeconfig context, which kind creates automatically on cluster creation.

## kube-score: Helm Template Rendering First

kube-score cannot parse Go template syntax (`{{ .Values.image.tag }}`). Gentepede renders the templates first:

```
helm template {project_name} helm/ -f helm/values.yaml → rendered YAML
rendered YAML → kube-score score -
```

This runs as two separate processes. ProcessBuilder does not support shell pipes (`|`), so Gentepede starts `kube-score`, writes the helm template output to `kube-score`'s stdin via `process.outputStream`, then reads its stdout on a separate thread.
