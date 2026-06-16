# Architecture

## Simple View (Beginner)

```
You (via Claude Desktop)
        │
        │  "generate_infrastructure_package"
        ▼
  Claude (LLM)
        │
        │  JSON-RPC tool call over stdin/stdout
        ▼
Gentepede MCP Server (JVM process, gentepede-mcp-all.jar)
        │
        ├── Reads blueprint JSON from JAR classpath
        ├── Creates workspace at ~/.gentepede/workspaces/{project}/
        ├── Writes Terraform files (main.tf, variables.tf, providers.tf, terraform.tfvars)
        │   └── For EKS: also Helm chart
        │
        └── When you run validate / plan / apply:
            ├── Spawns terraform CLI via ProcessBuilder
            ├── Spawns checkov for security scan
            ├── Spawns infracost for cost estimate
            └── For EKS: spawns helm, kubectl, kube-score
```

The server reads from stdin and writes to stdout. This is called `StdioServerTransport` — the same pattern all MCP servers use. Claude Desktop manages the server process lifetime.

---

## Technical Call Graph (Advanced)

### 1. MCP Initialize Handshake

When Claude Desktop starts, it launches the Gentepede server:
```
java -jar gentepede-mcp-all.jar
```

The SDK sends an `initialize` request over stdin:
```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"Claude"}}}
```

The server responds with its capabilities (the 8 tools). The client then sends `initialized` to confirm. This handshake is handled entirely by the MCP SDK — you never see it in Engine.kt or Main.kt.

### 2. Tool Call Flow

When you ask Claude "generate infrastructure for my Spring Boot app":

1. **Claude** decides to call `generate_infrastructure_package` and sends:
   ```json
   {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"generate_infrastructure_package","arguments":{"blueprint_name":"springboot-postgres","project_name":"my-api","variables":{...}}}}
   ```

2. **Main.kt** receives this via the tool handler lambda registered in `server.addTool(...)`.

3. **Engine.kt** extracts `blueprint_name`, `project_name`, and `variables` from the JSON arguments.

4. **Engine.kt** calls `InfrastructureService.generateWorkspace(...)`.

5. **InfrastructureService** does all the work:
   - Loads `blueprints/springboot-postgres.json` from the JAR classpath
   - Creates `~/.gentepede/workspaces/my-api/`
   - Reads `templateFamily: "ecs"` → copies `templates/ecs/main.tf` and `variables.tf`
   - Builds `terraform.tfvars` from merged defaults + user variables
   - Writes `providers.tf` (real AWS provider + S3 remote state backend)
   - Returns a `GenerateResult`

6. **Engine.kt** formats the `GenerateResult` as a human-readable string.

7. **Main.kt / MCP SDK** wraps it in a JSON-RPC response and writes to stdout.

8. **Claude Desktop** receives the response and shows it to you.

### 3. ProcessBuilder Flow (terraform validate example)

When `validate_infrastructure_package` is called:

```
Engine.kt
    │
    ▼
InfrastructureService.validateWorkspace("my-api")
    │
    ├── resolveTerraformDir() → ~/.gentepede/workspaces/my-api/ (TERRAFORM_ONLY)
    │
    ├── runProcess(["terraform", "init", "-backend=false", "-no-color"], directory=terraformDir)
    │      ├── ProcessBuilder starts subprocess
    │      ├── stdout thread: reads terraform's output into StringBuilder
    │      ├── stderr thread: reads terraform's errors into StringBuilder  ← separate threads
    │      ├── waitFor(30 minutes)                                            prevent deadlock
    │      └── returns ProcessResult(exitCode, stdout, stderr)
    │
    ├── runProcess(["terraform", "validate", "-no-color"], directory=terraformDir)
    │
    └── Validator.runCheckov(terraformDir)
           ├── isCommandAvailable("checkov") → checks PATH
           ├── runProcess(["checkov", "-d", ".", "-o", "json", "--compact"])
           └── parseCheckovOutput(stdout) → CheckovResult
```

### 4. State Management Data Flow

```
plan_infrastructure_package
    │
    ├── terraform plan -out=gentepede.tfplan
    │       └── binary plan file saved in workspace
    │
    ├── terraform show -json gentepede.tfplan
    │       └── JSON representation captured to gentepede-plan.json
    │           via FileOutputStream (NOT shell > redirection)
    │
    ├── SHA-256(gentepede.tfplan bytes) → planFileChecksum
    │
    └── gentepede.lock.json written:
            { blueprintId, terraformProviderVersion, plannedAt, planFileChecksum }

apply_infrastructure_package
    │
    ├── Read gentepede.lock.json → planFileChecksum
    ├── SHA-256(gentepede.tfplan) == planFileChecksum? → abort if not
    ├── Copy terraform.tfstate → ~/.gentepede/backups/{project}/{timestamp}.tfstate
    │
    ├── terraform apply gentepede.tfplan  (exact reviewed plan)
    │
    └── gentepede.lock.json updated:
            adds { lastApplied, stateBackupPath }
```

### 5. Workspace Layout

```
~/.gentepede/
├── workspaces/
│   └── my-api/                        ← TERRAFORM_ONLY (springboot-postgres)
│       ├── main.tf                    (copied from templates/ecs/)
│       ├── variables.tf               (copied from templates/ecs/)
│       ├── providers.tf               (written at runtime — real AWS provider + S3 backend)
│       ├── terraform.tfvars           (merged blueprint defaults + user variables)
│       ├── gentepede.lock.json        (plan checksum → apply integrity)
│       ├── gentepede.tfplan           (binary plan file)
│       ├── gentepede-plan.json        (JSON plan for parsing + infracost)
│       └── .terraform/                (terraform init cache)
│
│   └── my-eks-app/                    ← TERRAFORM_K8S (springboot-eks)
│       ├── terraform/
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   ├── providers.tf
│       │   ├── terraform.tfvars
│       │   ├── gentepede.tfplan
│       │   └── gentepede-plan.json
│       ├── helm/
│       │   ├── Chart.yaml
│       │   ├── values.yaml            (generated per-project)
│       │   └── templates/
│       │       ├── deployment.yaml
│       │       ├── service.yaml
│       │       ├── hpa.yaml
│       │       ├── network-policy.yaml
│       │       └── resource-quota.yaml
│       └── gentepede.lock.json
│
└── backups/
    └── my-api/
        └── 2025-06-14T10-30-00Z.tfstate   ← retained indefinitely
```
