# Tool Architecture: How Everything Works Under the Hood

This document explains what actually happens when Claude calls a Gentepede tool — from the moment you type a message to the moment AWS creates a resource. Every layer, every file, every CLI command, and every decision is covered.

**Who this is for:** Developers who want to understand the codebase, contributors adding new tools or blueprints, and anyone curious about how an MCP server actually works in practice.

---

## Before You Read: Four Things to Know

These four concepts underpin everything else in this document.

### 1. Claude only sees text

Claude Desktop never sees Terraform files, workspace directories, or AWS API responses directly. It only sees the formatted text string that Gentepede returns after running everything. This is why the tool responses include phrases like "Next Step: Run validate_infrastructure_package" — Claude reads those instructions in the text and decides what to call next.

### 2. The workspace is just a folder on your disk

When you generate infrastructure for a project called `my-api`, Gentepede creates a folder at `~/.gentepede/workspaces/my-api/` and puts all the Terraform files in it. Then every subsequent tool (`validate`, `plan`, `apply`) operates on that folder. Think of the workspace as the "project folder" for a Terraform deployment.

### 3. Everything runs locally on your machine

Gentepede doesn't have a server in the cloud. It runs as a Java process on your machine. When it runs `terraform plan`, that's a real `terraform` binary on your machine talking to AWS (or to LocalStack, a fake AWS running in Docker, when you're in LOCAL mode). No Gentepede code ever runs on AWS.

### 4. The JAR is self-contained

The built JAR file (`gentepede-mcp-all.jar`) contains everything: the Kotlin code, all 6 blueprint JSON files, all 3 Terraform template families, and the Helm chart templates. When Gentepede generates a workspace, it's copying files out of its own JAR onto disk — not reading from the source repo.

---

## The Big Picture: What Happens When You Ask Claude Something

Here is the complete journey for a single tool call, in plain English:

```
You type: "Generate Spring Boot + Postgres ECS infrastructure for my-api"
                │
                ▼
Claude Desktop reads your message.
Claude decides to call generate_infrastructure_package with these arguments:
  blueprint_name = "springboot-postgres"
  project_name   = "my-api"
  variables      = { container_image: "...", certificate_arn: "..." }
                │
                ▼ (sent as JSON through a pipe to the Gentepede process)
                │
The Gentepede Java process is running on your machine,
reading from stdin and writing to stdout.
                │
                ▼
Main.kt receives the tool call and routes it to Engine.kt
                │
                ▼
Engine.kt validates the arguments
(Is blueprint_name known? Is project_name alphanumeric?)
                │
                ▼
InfrastructureService.kt does the real work:
  - Reads springboot-postgres.json from the JAR
  - Creates ~/.gentepede/workspaces/my-api/
  - Copies main.tf and variables.tf from the JAR templates
  - Writes terraform.tfvars with enable_rds=true, enable_dynamodb=false
  - Writes providers.tf pointing to LocalStack or real AWS
                │
                ▼
Engine.kt formats the result as a human-readable string
                │
                ▼ (sent back as JSON through stdout)
                │
Claude Desktop receives and displays the text.
Claude reads "Next Step: Run validate_infrastructure_package"
and calls that tool next.
```

That's the whole loop. Now let's go layer by layer.

---

## The 7-Layer Stack

```
┌─────────────────────────────────────────────────────────────────────────┐
│  LAYER 1 — You + Claude Desktop (MCP Client)                            │
│  You write natural language. Claude decides which tool to call.         │
│  Claude never sees files or AWS state — only the text Gentepede returns.│
└────────────────────────────┬────────────────────────────────────────────┘
                             │ JSON message sent through a pipe (stdin)
                             ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  LAYER 2 — stdio Transport (Main.kt + MCP SDK)                          │
│  Reads messages from stdin, writes responses to stdout.                 │
│  Handles the low-level framing protocol (JSON-RPC 2.0).                 │
│  Routes each tool call to the right handler.                            │
└────────────────────────────┬────────────────────────────────────────────┘
                             │ CallToolRequest object (in-memory)
                             ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  LAYER 3 — Engine.kt (Thin Handler)                                     │
│  Extracts parameters from the JSON Claude sent.                         │
│  Validates them. Calls InfrastructureService. Formats the response.     │
│  Catches errors and converts them to readable error messages.           │
└────────────────────────────┬────────────────────────────────────────────┘
                             │ Typed method call (e.g. svc.validateWorkspace("my-api"))
                             ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  LAYER 4 — InfrastructureService.kt (All Business Logic)                │
│  Reads blueprints from the JAR. Manages workspace directories on disk.  │
│  Generates all config files. Runs external CLI tools (terraform, helm). │
│  Reads and writes the lock file. Creates state backups.                 │
└────────────────────────────┬────────────────────────────────────────────┘
                             │ Delegates CLI output interpretation
                             ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  LAYER 5 — Validator.kt (CLI Output Interpreter)                        │
│  Parses checkov's JSON security findings.                               │
│  Pipes Helm output to kube-score and parses the results.                │
│  Parses infracost's cost estimate JSON.                                 │
│  Checks AWS credentials via `aws sts get-caller-identity`.              │
│  Checks kind cluster existence for local EKS testing.                  │
└────────────────────────────┬────────────────────────────────────────────┘
                             │ Subprocess invocations
                             ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  LAYER 6 — External CLI Tools (run as subprocesses)                     │
│  terraform  — init, validate, plan, apply, show, destroy                │
│  checkov    — security analysis of Terraform files                      │
│  helm       — Kubernetes package management                             │
│  kube-score — Kubernetes manifest quality checks                        │
│  infracost  — monthly cost estimation                                   │
│  kind       — local Kubernetes cluster management                       │
│  kubectl    — wait for pods to terminate (destroy sequence)             │
│  aws        — verify AWS credentials before production operations       │
└────────────────────────────┬────────────────────────────────────────────┘
                             │ API calls (HTTP)
                             ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  LAYER 7 — AWS or LocalStack                                            │
│  LOCAL mode:      LocalStack running in Docker at localhost:4566        │
│  PRODUCTION mode: Real AWS cloud endpoints                              │
│  Note: generate and validate never reach this layer (no cloud calls)   │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Layer 1 — You and Claude (The MCP Client)

Claude Desktop is an **MCP client** — software that knows how to call MCP servers. When you describe what you want in natural language, Claude:

1. Reads the tool descriptions that Gentepede registered at startup (defined in `Main.kt`'s `server.addTool(name = ..., description = ...)` calls)
2. Decides which tool matches your intent and what arguments to provide
3. Sends a tool call message to Gentepede

**The critical constraint:** Claude's entire view of what Gentepede does is limited to what Gentepede writes back as text. Claude cannot "look" at the `~/.gentepede/workspaces/` folder, cannot read Terraform files, and cannot see AWS state directly. Every piece of information Claude uses to decide its next action must appear in the text response Gentepede returns.

This is why Gentepede's responses include next-step instructions, resource lists, and explicit warnings — Claude needs all of this context to assist you intelligently.

---

## Layer 2 — The Transport Layer: JSON-RPC over stdio (Main.kt)

**How Claude and Gentepede talk to each other:**

Claude Desktop launches the Gentepede process with a command like:
```
java -jar gentepede-mcp-all.jar
```

From that point, they communicate by sending text messages through the process's stdin and stdout pipes — exactly like how you'd pipe output between shell commands, but for a structured protocol called **JSON-RPC 2.0**.

Every message is framed with a Content-Length header (similar to HTTP headers) followed by a JSON body:

```
Content-Length: 135\r\n
\r\n
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"validate_infrastructure_package","arguments":{"project_name":"my-api"}}}
```

The MCP SDK (the Kotlin library Gentepede uses) handles all of this automatically:
- It reads the `Content-Length` header to know how many bytes to read
- It parses the JSON and figures out what kind of message it is (`tools/call`, `tools/list`, etc.)
- It routes `tools/call` messages to the handler registered in `Main.kt`
- It serializes the response back to JSON and writes it with the correct headers

**Main.kt's only job:** Register the 8 tools with their names, descriptions, and input schemas, then start the server. The tool descriptions are what Claude reads to understand what each tool does.

**The server never exits.** It blocks on stdin, waiting for the next message. This is correct behavior — MCP servers are long-lived processes, not request-response scripts.

---

## Layer 3 — Engine.kt: The Thin Handler

Engine.kt sits between the MCP protocol layer and the business logic. It's intentionally kept thin — it only does four things:

**1. Extract parameters from JSON**

Claude sends tool arguments as a JSON object. Engine.kt pulls out the values:
```kotlin
val projectName = args["project_name"]?.jsonPrimitive?.content
    ?: return error("Missing required parameter: project_name")
```

**2. Validate inputs before touching disk**

Simple checks happen here — does the blueprint name exist? Does the project name contain only alphanumeric characters and hyphens? If not, fail immediately with a clear message.

**3. Call one InfrastructureService method and get a typed result**

Engine.kt delegates all real work:
```kotlin
val result: ValidationResult = svc.validateWorkspace(projectName)
```

**4. Format the result into readable text**

InfrastructureService returns a typed Kotlin data class. Engine.kt converts that into the text Claude will see:
```
Validation Report: my-api
============================================================
terraform validate: PASSED
checkov: PASSED (3 findings, none HIGH/CRITICAL)
kube-score: SKIPPED (not a TERRAFORM_K8S blueprint)

✓ All checks passed. Ready to run plan_infrastructure_package.
```

**Why this separation matters:**

InfrastructureService can be called directly from tests and from the CI blueprint verifier (`BlueprintVerifierKt`), without starting an MCP server. If all the logic were inside Engine.kt (mixed with the MCP protocol handling), it couldn't be tested in isolation. Keeping Engine.kt thin is what makes the whole system testable.

**Error handling:**
- `IllegalArgumentException` → bad user input (e.g., unknown blueprint name). Engine.kt catches this and returns it as an error message to Claude.
- `IllegalStateException` → a precondition failed (e.g., workspace not found, kind cluster not running). Same handling.
- `ProcessExecutionException` → a CLI tool failed (terraform, checkov, etc.). Engine.kt includes the full stdout/stderr in the error so Claude can see exactly what went wrong.

---

## Layer 4 — InfrastructureService.kt: Where Everything Real Happens

This single class contains all of Gentepede's business logic. Key behaviors:

### Blueprint loading

Blueprint JSON files live inside the JAR, not on disk. Loading works by reading from the JAR's classpath:
```kotlin
val stream = Thread.currentThread().contextClassLoader
    .getResourceAsStream("blueprints/$blueprintId.json")
```
This is why blueprints are always available — they travel with the JAR. You can run Gentepede from any directory and it finds its blueprints.

### The workspace and backup directories

```
~/.gentepede/workspaces/{projectName}/   ← all Terraform/Helm files
~/.gentepede/backups/{projectName}/      ← state file snapshots before destroy/apply
```

### How CLI tools are run

All external tools (terraform, checkov, helm, etc.) are invoked via `ProcessBuilder` — Java's way to launch a subprocess:
```kotlin
ProcessBuilder(listOf("terraform", "plan", "-out=gentepede.tfplan", "-no-color"))
    .directory(workspaceDir.toFile())
    .start()
```

Key behaviors of every subprocess call:
- **Two threads drain stdout and stderr simultaneously** before calling `waitFor()`. This prevents a deadlock: if you wait for the process to finish before reading its output, and the process fills up the OS pipe buffer waiting for you to read, both sides freeze. Two drain threads prevent this.
- **30-minute timeout** on all processes. EKS cluster creation can take 15+ minutes.
- **Allowed exit codes** are checked — some tools use non-zero exit codes for normal results (checkov uses exit 1 to mean "findings found"), so unexpected codes throw `ProcessExecutionException`.
- **No shell** — commands are literal argument lists, not shell strings. Explained in full in the "ProcessBuilder: No Shell" section below.

### Mode detection

```kotlin
private val mode: String = System.getenv("GENTEPEDE_MODE") ?: "LOCAL"
```

Every LOCAL vs PRODUCTION branch in the code traces back to this one line.

---

## Layer 5 — Validator.kt: CLI Output Interpreter

Validator.kt knows how to read the output that external tools produce. InfrastructureService knows how to *run* tools; Validator knows how to *understand* their output.

| What it does | How |
|---|---|
| **checkov findings** | checkov outputs JSON. Validator parses `results.failed_checks[]`, extracts severity, check ID, resource name, and remediation link. |
| **kube-score findings** | Runs two separate processes: `helm template` renders YAML, then writes it to `kube-score score -` stdin. Filters output for `[CRITICAL]` lines. |
| **infracost cost estimate** | Reads `gentepede-plan.json`. Parses `totalMonthlyCost` and `currency` from infracost's JSON output. |
| **AWS credential check** | Runs `aws sts get-caller-identity`, parses the JSON for Arn, Account, UserId. |
| **Helm drift detection** | Runs `helm diff upgrade`, checks if stderr says "plugin not found" (graceful skip if not installed). |
| **kind cluster check** | Runs `kind get clusters`, checks if `gentepede-local` appears in the output. |

**Graceful skips:** If checkov, infracost, kube-score, helm-diff, or kind are not installed, Validator returns a "skipped" result rather than throwing an error. The tool call still succeeds. This means Gentepede works on a minimal machine with only `terraform` installed.

---

## Layer 6 — The Workspace Directory

This is the folder on your disk that holds everything Terraform needs.

**For TERRAFORM_ONLY blueprints (ECS, Lambda):**
```
~/.gentepede/workspaces/my-api/
├── main.tf                 ← copied from JAR: templates/ecs/main.tf
├── variables.tf            ← copied from JAR: templates/ecs/variables.tf
├── terraform.tfvars        ← generated: project_name, image, enable_rds, etc.
├── providers.tf            ← generated: LocalStack endpoints OR real AWS + S3 backend
│
├── .terraform/             ← created by terraform init (provider plugin binaries)
├── .terraform.lock.hcl     ← provider version pinfile (created by terraform init)
│
├── gentepede.tfplan         ← binary plan file (created by terraform plan)
├── gentepede-plan.json     ← JSON form of plan (created by terraform show -json)
│
├── terraform.tfstate        ← state file tracking deployed resources (created by apply)
└── gentepede.lock.json     ← Gentepede's own integrity file (checksum + timestamps)
```

**For TERRAFORM_K8S blueprints (EKS):**
```
~/.gentepede/workspaces/my-api/
├── terraform/              ← same files as above, but in a subdirectory
│   ├── main.tf
│   ├── variables.tf
│   ├── terraform.tfvars
│   ├── providers.tf
│   ├── .terraform/
│   ├── gentepede.tfplan
│   ├── gentepede-plan.json
│   └── terraform.tfstate
│
├── helm/                   ← Kubernetes packaging (copied from JAR, values.yaml overwritten)
│   ├── Chart.yaml
│   ├── values.yaml         ← project-specific: image, port, health paths, replicas
│   └── templates/
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── hpa.yaml
│       ├── network-policy.yaml
│       └── resource-quota.yaml
│
├── kind-config.yaml        ← local cluster spec (used with: kind create cluster --config kind-config.yaml)
└── gentepede.lock.json
```

**State backups** are stored separately so they survive workspace deletion:
```
~/.gentepede/backups/my-api/2026-06-14T10-30-00Z.tfstate
```

---

## The 8 Tools: Full Flow for Each

---

### Tool 1: `list_available_blueprints`

**In plain English:** Reads the 6 blueprint JSON files from the JAR and formats their contents as readable text. No files are written, no tools are run, no AWS calls are made.

**Step-by-step:**

1. Engine.kt receives the tool call (no arguments needed)
2. Calls `svc.listBlueprints()`
3. InfrastructureService loops over the 6 known blueprint IDs
4. For each: reads the JSON from the JAR classpath, deserializes it into a `Blueprint` object
5. Engine.kt formats each blueprint as a text block (ID, name, description, output type, AWS resources, etc.)
6. Returns the formatted text to Claude

**Quick reference:**

| | |
|---|---|
| Files read | 6 blueprint JSONs from the JAR (not from disk) |
| Files written | None |
| CLI tools run | None |
| AWS calls | None |
| Can fail? | Only if the JAR itself is corrupted (a build issue, not a runtime issue) |

---

### Tool 2: `generate_infrastructure_package`

**In plain English:** Creates the workspace folder and writes all the files Terraform needs. No AWS calls — this is purely file generation. After this tool runs, you have everything needed to start validating and planning.

**Step-by-step:**

1. Engine.kt validates: Is `blueprint_name` one of the 6 known blueprints? Does `project_name` contain only alphanumeric characters and hyphens?

2. Loads the blueprint JSON from the JAR (e.g., `blueprints/springboot-postgres.json`)

3. Creates the workspace directory at `~/.gentepede/workspaces/my-api/`

4. Checks for existing state: if `terraform.tfstate` or `.terraform/` already exist **and** the variables you're passing now differ from last time, adds a warning: "Existing state detected — run plan first to review what will change."

5. **Branches based on blueprint output type:**

   **For TERRAFORM_ONLY (ECS, Lambda blueprints):**

   a. Copies `main.tf` and `variables.tf` from the JAR into the workspace root

   b. Builds `terraform.tfvars`: merges your provided variables (container image, certificate ARN, etc.) with blueprint defaults, then calls `injectDataTierToggles()` to derive the data-tier booleans:
   ```
   springboot-postgres → enable_rds=true,  enable_dynamodb=false, enable_redis=false
   ktor-dynamodb       → enable_rds=false, enable_dynamodb=true,  enable_redis=false
   fastapi-redis       → enable_rds=false, enable_dynamodb=false, enable_redis=true
   ```

   c. Builds `providers.tf`:
   - LOCAL mode → AWS provider pointing to `http://localhost:4566` (LocalStack), no S3 backend
   - PRODUCTION mode → standard AWS provider with real endpoints, adds S3 backend block for remote state

   **For TERRAFORM_K8S (EKS blueprints):** Same steps a–c but files go into the `terraform/` subdirectory. Then additionally:

   d. Copies the entire `helm-chart/` from the JAR into `helm/`

   e. Overwrites `helm/values.yaml` with project-specific values: container image, port (8080 for Spring Boot, 3000 for Node.js), health probe paths (`/actuator/health` for Spring Boot), replica count, resource limits

   f. Generates `kind-config.yaml` (a local Kubernetes cluster spec with 1 control-plane + 2 worker nodes)

6. Returns the result including the workspace path, mode, output type, and list of AWS resources that will be created

**Key design decision — why `providers.tf` is generated at runtime:**
The same `main.tf` must work with both LocalStack and real AWS. The only difference between LOCAL and PRODUCTION is `providers.tf` (endpoint URLs, backend config). By generating it at runtime, there's one copy of each template family instead of two nearly-identical copies.

**Quick reference:**

| | |
|---|---|
| Files read | Blueprint JSON from JAR |
| Files written | `main.tf`, `variables.tf`, `terraform.tfvars`, `providers.tf`, plus (EKS) `helm/*`, `kind-config.yaml` |
| CLI tools run | None |
| AWS calls | None |

---

### Tool 3: `validate_infrastructure_package`

**In plain English:** Checks your generated files for correctness and security problems — without touching AWS. This catches most mistakes cheaply (no cloud costs, no waiting for resources to create). It runs three passes: Terraform syntax check, security analysis (checkov), and Kubernetes manifest quality check (kube-score, EKS only). Stops and returns an error if HIGH or CRITICAL security findings are found.

**Step-by-step:**

1. Checks that the workspace exists (throws an error if `generate` hasn't been run yet)

2. Determines the Terraform directory:
   - TERRAFORM_ONLY: `~/.gentepede/workspaces/my-api/`
   - TERRAFORM_K8S: `~/.gentepede/workspaces/my-api/terraform/`

3. **Runs `terraform init`**: Downloads the AWS provider plugin (or the LocalStack provider in LOCAL mode) into `.terraform/`. This is safe to run multiple times — it's idempotent. The first run takes ~30 seconds; subsequent runs are instant (plugins are cached).

4. **Runs `terraform validate`**: Checks that the HCL syntax is valid and that resource argument types are correct. Makes zero AWS API calls — purely local analysis. Fails fast if there's a typo in `main.tf` or a variable reference that doesn't exist.

5. **Runs checkov** (security analysis):
   - Skipped gracefully if checkov is not installed
   - checkov reads all `.tf` files and checks them against 1000+ security rules (e.g., "is RDS publicly accessible?", "is S3 bucket encryption enabled?")
   - Returns JSON output — Validator.kt parses `results.failed_checks[]`
   - **Important:** checkov exits with code `1` when it finds issues (not code `0`). This is normal for linters. Gentepede allows exit codes `{0, 1}` so it doesn't mistake findings for a crash.
   - If any HIGH or CRITICAL findings exist: return an error listing them with remediation steps. The pipeline stops here.

6. **Runs kube-score** (Kubernetes manifest quality check, EKS/TERRAFORM_K8S blueprints only):
   - Skipped if this is a TERRAFORM_ONLY blueprint (no Kubernetes manifests)
   - Skipped gracefully if helm or kube-score are not installed
   - Step 1: Run `helm template my-api helm/ -f helm/values.yaml` — this renders all the Kubernetes YAML files by substituting the Helm template variables (like `{{ .Release.Name }}`). The rendered YAML is captured as a string in memory.
   - Step 2: Start `kube-score score -` as a subprocess. Write the rendered YAML to kube-score's stdin. Read kube-score's stdout for findings. (This two-process approach is needed because ProcessBuilder doesn't support shell pipes — more on this below.)
   - If any CRITICAL findings exist: return an error. The pipeline stops.

7. Returns the full validation report

**Quick reference:**

| | |
|---|---|
| Files read | `main.tf`, `variables.tf`, `terraform.tfvars`, `providers.tf`, `helm/values.yaml`, `helm/templates/*` |
| Files written | `.terraform/` directory (provider plugins), `.terraform.lock.hcl` (version lockfile) |
| CLI tools run | `terraform init`, `terraform validate`, `checkov -d . -o json --compact`, `helm template`, `kube-score score -` |
| AWS calls | None — terraform validate is purely local |

---

### Tool 4: `plan_infrastructure_package`

**In plain English:** This is the first tool that contacts AWS (or LocalStack). Terraform compares your desired configuration against what actually exists in AWS and produces a plan: "I will create 14 resources, modify 0, destroy 0." Gentepede captures this plan file, computes a checksum of it (for integrity), estimates costs, and returns everything for your review. **Review the plan before running apply.**

**Step-by-step:**

1. Checks workspace exists

2. **Credential pre-flight (PRODUCTION only):** Runs `aws sts get-caller-identity` to verify AWS credentials are configured and valid. If this fails, stops immediately with instructions for setting up credentials. This check runs *before* any Terraform commands so a credential problem produces a clear message rather than a cryptic Terraform error.

3. Runs `terraform init` (idempotent — safe to run again)

4. **Runs `terraform plan -out=gentepede.tfplan`:** Terraform contacts AWS (or LocalStack) to read the current state of all resources, compares that against what your `.tf` files declare, and computes the difference. The result is saved as a binary plan file at `gentepede.tfplan`. This can take 2–5 minutes for large infrastructures.

5. **Runs `terraform show -json gentepede.tfplan`:** Converts the binary plan file into JSON so Gentepede can read it programmatically. The JSON output is captured from stdout and written to `gentepede-plan.json` via a FileOutputStream (not via a shell `>` redirect — more on this in the ProcessBuilder section below).

6. **Parses the plan JSON:** Extracts `resource_changes[]` — each entry has an `action` (create, update, delete, no-op). Counts creates, modifies, and destroys to produce the summary line: "Will CREATE 14 resources, MODIFY 0, DESTROY 0."

7. **Computes a SHA-256 checksum of the binary plan file:** The plan file represents exactly what will happen at apply time. If anything changes between now and when you run apply (new generate call, manual tfvars edit, etc.), the plan is stale. The checksum catches this.

8. **Writes `gentepede.lock.json`** (Phase 1):
   ```json
   {
     "blueprintId": "springboot-postgres",
     "terraformProviderVersion": "5.82.0",
     "plannedAt": "2026-06-14T10:30:00Z",
     "planFileChecksum": "sha256:abc123..."
   }
   ```

9. **Runs infracost** (optional): If infracost is installed, reads `gentepede-plan.json` and returns a monthly cost estimate. Skipped gracefully if not installed.

10. **Renders Helm manifests for preview (EKS only):** Runs `helm template` to show you the Kubernetes YAML that will be deployed. This is for review only — no K8s API calls are made here.

11. Returns the plan summary, resource list, cost estimate, and (for EKS) rendered manifests

**Quick reference:**

| | |
|---|---|
| Files read | `main.tf`, `variables.tf`, `terraform.tfvars`, `providers.tf`, `terraform.tfstate` (if exists) |
| Files written | `gentepede.tfplan` (binary plan), `gentepede-plan.json` (JSON plan), `gentepede.lock.json` |
| CLI tools run | `terraform init`, `terraform plan`, `terraform show -json`, `infracost breakdown`, `helm template` |
| AWS calls | Yes — `terraform plan` reads current AWS resource state to compute the diff |

---

### Tool 5: `apply_infrastructure_package`

**In plain English:** Deploys the infrastructure. Before doing anything, it verifies that the plan you reviewed is exactly the plan it's about to apply (via the checksum), backs up your current state file, then runs `terraform apply`. For EKS blueprints, also deploys the Kubernetes resources via Helm.

**Step-by-step:**

1. Checks workspace exists

2. **EKS LOCAL pre-flight:** For EKS blueprints in LOCAL mode, checks that the `gentepede-local` kind cluster is running (`kind get clusters`). If it's not running, stops with instructions on how to create it. There's no point applying EKS infrastructure if there's no local Kubernetes cluster to deploy pods to.

3. **Credential pre-flight (PRODUCTION only):** Same `aws sts get-caller-identity` check as plan.

4. **Reads `gentepede.lock.json`:** If the lock file doesn't exist, it means `plan` was never run — stops with "No valid plan file found. Run plan_infrastructure_package first."

5. **Verifies the plan file checksum:**
   - Reads `gentepede.tfplan` from disk
   - Computes its SHA-256 hash
   - Compares to the `planFileChecksum` stored in `gentepede.lock.json`
   - **If they don't match:** stops and explains why. This prevents applying a stale plan. Common causes: you ran `generate` again after planning (which rewrote `terraform.tfvars`), or someone manually edited the files.

6. **Backs up the current state file:**
   - Copies `terraform.tfstate` → `~/.gentepede/backups/my-api/2026-06-14T10-30-00Z.tfstate`
   - If no state file exists yet (first apply): backup step is a no-op

7. **Runs `terraform apply gentepede.tfplan`:** Applies the exact plan that was reviewed — Terraform does not re-plan. This is the command that creates real AWS resources (or LocalStack resources). Can take 5–25 minutes depending on the blueprint (EKS clusters take the longest).

8. **Updates `gentepede.lock.json`** (Phase 2 — adds apply info):
   ```json
   {
     "blueprintId": "springboot-postgres",
     "terraformProviderVersion": "5.82.0",
     "plannedAt": "2026-06-14T10:30:00Z",
     "planFileChecksum": "sha256:abc123...",
     "lastApplied": "2026-06-14T10:31:45Z",
     "stateBackupPath": "/Users/you/.gentepede/backups/my-api/2026-06-14T10-30-00Z.tfstate"
   }
   ```

9. **Helm deploy (EKS blueprints only):**
   - Determines the Kubernetes context: `kind-gentepede-local` in LOCAL mode, current `~/.kube/config` context in PRODUCTION
   - Runs `helm upgrade --install my-api helm/ -f helm/values.yaml --namespace my-api --create-namespace`
   - This deploys the Deployment, Service, HPA, NetworkPolicy, and ResourceQuota to the cluster
   - Creates the namespace if it doesn't exist

10. Returns the apply output (capped at 3000 characters to avoid response overflow) plus Helm deploy output

**Why `terraform apply gentepede.tfplan` and not `terraform apply -auto-approve`:**
Using the plan file means Terraform applies *exactly* the changes you reviewed — no re-planning at apply time. `terraform apply -auto-approve` without a plan file would re-plan and could apply changes that happened after your review.

**Quick reference:**

| | |
|---|---|
| Files read | `gentepede.lock.json`, `gentepede.tfplan` |
| Files written | `terraform.tfstate`, `gentepede.lock.json` (updated), `~/.gentepede/backups/my-api/{timestamp}.tfstate` |
| CLI tools run | `kind get clusters`, `aws sts get-caller-identity`, `terraform apply`, `helm upgrade --install` |
| AWS calls | Yes — creates/modifies real AWS resources (or LocalStack) |

---

### Tool 6: `detect_drift`

**In plain English:** Checks whether what's currently deployed in AWS still matches what Terraform last applied. "Drift" means someone manually changed something in AWS (deleted a security group, changed an instance type) without going through Terraform. For EKS, also checks whether the Kubernetes resources match what's in your Helm values. Returns a report of what changed.

**Step-by-step:**

1. Checks workspace exists

2. EKS LOCAL pre-flight (kind cluster check)

3. Credential pre-flight (PRODUCTION only)

4. Runs `terraform init` if `.terraform/` doesn't exist

5. **Runs `terraform plan -detailed-exitcode`:** The `-detailed-exitcode` flag changes what the exit code means:
   - Exit `0` = no changes (no drift)
   - Exit `1` = terraform error (something went wrong)
   - Exit `2` = changes exist (drift detected)

   Gentepede allows exit codes `{0, 2}` — exit 2 is not treated as an error, it's how Terraform signals drift.

6. **If drift was detected (exit 2):** Runs `terraform show -json gentepede-drift.tfplan` and parses `resource_changes[]` to show exactly which resources changed and how.

7. **Kubernetes drift check (EKS blueprints only):** Runs `helm diff upgrade my-api helm/ -f helm/values.yaml --namespace my-api`. This compares the currently deployed release against your local Helm values and shows any differences. Skipped gracefully if the helm-diff plugin isn't installed.

8. Returns the drift report with a recommendation ("No action required" or "Run plan_infrastructure_package to see the full plan for reverting drift")

**Important note about LOCAL mode:** LocalStack stores all state in memory inside the Docker container. If Docker restarts, all resources are gone — but `terraform.tfstate` still thinks they exist. In LOCAL mode, every resource will show as drift after a Docker restart. This is expected behavior. Drift detection is only meaningful in PRODUCTION.

**Quick reference:**

| | |
|---|---|
| Files read | `terraform.tfstate`, `helm/values.yaml` |
| Files written | `gentepede-drift.tfplan` (temporary) |
| CLI tools run | `terraform plan -detailed-exitcode`, `terraform show -json`, `helm diff upgrade` |
| AWS calls | Yes — terraform plan reads current AWS state to detect changes |

---

### Tool 7: `destroy_infrastructure_package`

**In plain English:** Tears everything down in the correct order and cleans up the workspace. For EKS, pods must be fully terminated before Terraform can delete the node group — Gentepede handles this sequencing automatically. Always backs up the state file before destroying. **This is irreversible.**

**Step-by-step:**

1. Checks workspace exists

2. EKS LOCAL pre-flight (kind cluster check)

3. Credential pre-flight (PRODUCTION only)

4. **Helm uninstall (EKS blueprints only):** Runs `helm uninstall my-api --namespace my-api`. This tells Kubernetes to delete all the pods, services, and other resources that Helm deployed. Exit codes `{0, 1}` are allowed — exit 1 means the release wasn't found (already deleted), which is fine.

5. **Wait for pods to terminate (EKS blueprints only):** Runs `kubectl wait --for=delete pod --all -n my-api --timeout=300s`. Blocks until all pods in the namespace are gone (up to 5 minutes). Exit codes `{0, 1}` are allowed — exit 1 means no pods were found (already gone).

   **Why this wait is required:** Terraform cannot delete an EKS node group while pods are still running on the worker nodes. The EKS node group is an EC2 Auto Scaling Group. EC2 won't terminate instances that have pods scheduled on them without going through Kubernetes drain procedures first. Helm uninstall starts the termination; `kubectl wait` ensures it's complete before Terraform proceeds.

6. **Backs up the current state file** to `~/.gentepede/backups/my-api/{timestamp}.tfstate`

7. **Runs `terraform destroy -auto-approve`:** Deletes all resources tracked in `terraform.tfstate`. The `-auto-approve` flag skips the interactive confirmation prompt — the user already confirmed by calling this tool. Can take 5–15 minutes.

8. **Deletes the workspace directory** (`~/.gentepede/workspaces/my-api/` and everything inside it). **Does NOT delete backups** — those live at `~/.gentepede/backups/my-api/` and are retained forever.

9. Returns the destroy output and the backup path

**Quick reference:**

| | |
|---|---|
| Files read | `terraform.tfstate`, `helm/values.yaml` |
| Files written | `~/.gentepede/backups/my-api/{timestamp}.tfstate` |
| Files deleted | Entire workspace directory |
| CLI tools run | `helm uninstall`, `kubectl wait --for=delete pod`, `terraform destroy -auto-approve` |
| AWS calls | Yes — deletes real AWS resources (or LocalStack) |

---

### Tool 8: `audit_infrastructure_package`

**In plain English:** Runs the same security analysis tools as `validate`, but never blocks on findings. Returns every finding at every severity level (CRITICAL, HIGH, MEDIUM, LOW) grouped for easy reading. The purpose is to give Claude a complete security picture it can explain and discuss with you — not to gate the pipeline.

**Step-by-step:**

1. Checks workspace exists

2. **Runs checkov in audit mode:**
   - Same execution as validate: `checkov -d . -o json --compact`
   - Difference: all findings are returned regardless of severity. The tool never returns an error even if there are 10 CRITICAL findings.
   - Findings are grouped by severity: `{"critical": [...], "high": [...], "medium": [...], "low": [...]}`

3. **Runs kube-score in audit mode (EKS blueprints only):**
   - Same two-process pipe as validate (helm template → kube-score)
   - Difference: returns both CRITICAL and WARNING findings (validate only surfaces CRITICAL)

4. Returns the complete audit report

**How audit differs from validate:**

| | validate | audit |
|---|---|---|
| Returns error on HIGH/CRITICAL? | Yes — blocks the pipeline | No — always returns success |
| Severity levels reported | Only HIGH and CRITICAL | All severities |
| kube-score findings | CRITICAL only | CRITICAL + WARNING |
| Purpose | Gate: stop bad code from deploying | Report: full security picture for review |

**Quick reference:**

| | |
|---|---|
| Files read | `main.tf`, `variables.tf`, `terraform.tfvars`, `helm/values.yaml`, `helm/templates/*` |
| Files written | None |
| CLI tools run | `checkov`, `helm template`, `kube-score score -` |
| AWS calls | None |

---

## Design Decisions Explained

### The Lock File: Ensuring What You Plan Is What You Apply

`gentepede.lock.json` solves a specific problem: the time between when you run `plan` and when you run `apply` could be hours. If anything changed the Terraform configuration in the meantime (a re-run of `generate`, a manual edit to `terraform.tfvars`), the plan you reviewed is no longer valid.

**How the checksum works:**

1. At plan time: Gentepede computes `SHA-256(gentepede.tfplan)` and stores it in the lock file
2. At apply time: Gentepede recomputes `SHA-256(gentepede.tfplan)` and compares
3. If they match: the plan file hasn't changed since you reviewed it — safe to apply
4. If they don't match: stops with an explanation

The plan file is deterministic — the same `.tf` files + the same AWS state always produce the same binary plan. Any change to inputs produces a different plan with a different checksum.

**What triggers a mismatch:**
- `generate_infrastructure_package` was re-run (writes a new `terraform.tfvars`)
- `main.tf` or `terraform.tfvars` were manually edited after planning
- The plan file was manually replaced or corrupted

---

### ProcessBuilder: Why Gentepede Doesn't Use a Shell

When you run a shell command like `terraform show -json gentepede.tfplan > gentepede-plan.json`, the shell handles the `>` redirect. Gentepede uses `ProcessBuilder` directly — no shell — so shell operators don't work.

**What this means in practice:**

| Shell approach | Gentepede's approach |
|---|---|
| `cmd1 \| cmd2` (pipe) | Two ProcessBuilder instances; write cmd1's stdout to cmd2's stdin programmatically |
| `cmd > file` (redirect) | Capture stdout as a string, write to file via FileOutputStream |
| `cmd1 && cmd2` (chain) | Two separate `runProcess()` calls in sequence |

**Why no shell?**
- **Security:** Shell injection is impossible. Arguments are literal strings in a list, not a string that gets parsed by bash. A project name with spaces or semicolons can't break out of the command.
- **Portability:** Works on Windows without Cygwin or WSL. There's no bash requirement.
- **Predictability:** No PATH surprises, no shell alias interference, no environment variable inheritance issues.

**The pipe deadlock problem and the two-thread solution:**

When a process writes a lot to stdout while your code is waiting for it to finish (`waitFor()`), and the OS pipe buffer fills up, both sides freeze: the process can't write more output until you read it, and you won't read it until the process finishes. Deadlock.

The solution: start two goroutine-like threads immediately after launching the subprocess — one draining stdout, one draining stderr. Both run concurrently with the process. Only after both drain threads complete does the code call `waitFor()`. The buffers never fill up because they're being continuously emptied.

---

### LOCAL vs PRODUCTION: Per-Tool Differences

| Tool | LOCAL mode | PRODUCTION mode |
|---|---|---|
| `list_blueprints` | Identical — reads from JAR | Identical — reads from JAR |
| `generate` | `providers.tf` → LocalStack endpoint, no S3 backend | `providers.tf` → real AWS endpoints + S3 backend for remote state |
| `validate` | Identical — pure static analysis, no cloud contact | Identical — pure static analysis, no cloud contact |
| `plan` | No credential pre-flight. Terraform contacts LocalStack. | Credential pre-flight runs first. Terraform contacts real AWS. |
| `apply` | EKS: targets kind cluster. Terraform applies to LocalStack. | EKS: targets real EKS. Terraform applies to real AWS. |
| `detect_drift` | LocalStack state is ephemeral — drift expected after Docker restart. | Meaningful — reflects actual AWS state. |
| `destroy` | Destroys LocalStack resources + (EKS) kind cluster resources. | Destroys real AWS resources. |
| `audit` | Identical — pure static analysis | Identical — pure static analysis |

The mode switch is a single environment variable: `GENTEPEDE_MODE=LOCAL` or `GENTEPEDE_MODE=PRODUCTION`. All branching in the code traces back to `private val mode = System.getenv("GENTEPEDE_MODE") ?: "LOCAL"` in InfrastructureService.kt.

---

### The Helm Chart Pipeline for EKS Blueprints

The Helm chart bundled in the JAR goes through several transformations before it reaches a Kubernetes cluster:

```
Step 1 — generate:
  JAR classpath: helm-chart/
    │  (copyHelmChart)
    ▼
  workspace: helm/
    ├── Chart.yaml        (copied verbatim from JAR)
    ├── templates/*.yaml  (copied verbatim from JAR)
    └── values.yaml       (OVERWRITTEN with project-specific values)

  values.yaml after generation contains:
    image.repository: "123456789.dkr.ecr.us-east-1.amazonaws.com/my-api"
    containerPort: 8080
    health.liveness.path: "/actuator/health"
    replicaCount: 2
    ...

Step 2 — validate:
  helm template my-api helm/ -f helm/values.yaml
    → substitutes {{ .Release.Name }} etc. → rendered YAML
  kube-score score -
    → checks rendered YAML for security issues
    → (e.g., "missing readiness probe", "no resource limits set")

Step 3 — plan:
  helm template my-api helm/ -f helm/values.yaml
    → same rendering, shown to you for review before apply

Step 4 — apply:
  helm upgrade --install my-api helm/ -f helm/values.yaml --namespace my-api
    → sends rendered YAML to Kubernetes API
    → creates: Deployment, Service, HPA, NetworkPolicy, ResourceQuota

Step 5 — destroy:
  helm uninstall my-api --namespace my-api
    → deletes all Kubernetes resources Helm created
```

**Important:** If you modify `helm-chart/templates/*.yaml` in the source repo, you must rebuild the JAR (`./gradlew shadowJar`) before the changes appear at runtime. The JAR is the source of truth for templates — the raw files are the source of truth for development.

---

## Summary: A Full Deployment from Start to Finish

Here's every external command and file operation in order for a complete `springboot-postgres` deployment in PRODUCTION mode:

```
1. list_available_blueprints
   Read: blueprints/*.json from JAR
   Run:  (nothing)
   AWS:  (none)

2. generate_infrastructure_package(springboot-postgres, my-api, {...})
   Read: blueprints/springboot-postgres.json from JAR
         templates/ecs/main.tf from JAR
         templates/ecs/variables.tf from JAR
   Write: ~/.gentepede/workspaces/my-api/main.tf
          ~/.gentepede/workspaces/my-api/variables.tf
          ~/.gentepede/workspaces/my-api/terraform.tfvars  ← enable_rds=true, enable_dynamodb=false
          ~/.gentepede/workspaces/my-api/providers.tf      ← real AWS + S3 backend
   Run:  (nothing)
   AWS:  (none)

3. validate_infrastructure_package(my-api)
   Write: .terraform/  (provider plugin download, ~30s first run)
          .terraform.lock.hcl
   Run:  terraform init      (~30s first time, instant after)
         terraform validate  (~2s, zero AWS calls)
         checkov             (~10s, zero AWS calls)
   AWS:  (none)

4. plan_infrastructure_package(my-api)
   Run:  aws sts get-caller-identity   (confirm credentials)
         terraform init                (idempotent)
         terraform plan                (~2–5 min, contacts AWS)
         terraform show -json          (~2s)
         infracost breakdown           (~10s)
   Write: gentepede.tfplan        (binary plan, ~50–500KB)
          gentepede-plan.json     (JSON plan)
          gentepede.lock.json     (checksum + timestamp)
   AWS:  terraform plan reads current AWS resource state

5. [You review the plan — 14 creates, 0 modifies, 0 destroys — and proceed]

6. apply_infrastructure_package(my-api)
   Run:  aws sts get-caller-identity     (credential check)
         terraform apply gentepede.tfplan (~5–15 min, creates resources)
   Read: gentepede.lock.json, gentepede.tfplan
   Write: terraform.tfstate                               (tracks deployed resources)
          gentepede.lock.json                             (adds lastApplied timestamp)
          ~/.gentepede/backups/my-api/{timestamp}.tfstate (state backup)
   AWS:  Creates VPC, subnets, IGW, NAT Gateway, ALB, ECS Fargate cluster,
         ECS task definition, ECS service, RDS PostgreSQL, KMS key, IAM roles,
         CloudWatch log groups, S3 bucket (flow logs), VPC flow logs

7. detect_drift(my-api)         [run any time after apply]
   Run:  terraform plan -detailed-exitcode (~2–5 min)
   AWS:  terraform plan reads current AWS state and compares to terraform.tfstate

8. destroy_infrastructure_package(my-api)
   Run:  terraform destroy -auto-approve (~5–15 min, deletes all resources)
   Write: ~/.gentepede/backups/my-api/{timestamp}.tfstate (pre-destroy backup)
   Delete: ~/.gentepede/workspaces/my-api/ (entire directory)
   Retain: ~/.gentepede/backups/my-api/ (backups kept forever)
   AWS:  Deletes all 14 resources in the correct dependency order
```
