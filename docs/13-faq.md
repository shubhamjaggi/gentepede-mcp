# Frequently Asked Questions

---

## For Users

### Why would I use this instead of writing Terraform myself?

Writing production-quality Terraform from scratch takes hours to days for each new project and requires deep knowledge of AWS networking, IAM, encryption, and checkov compliance rules. Gentepede embeds that knowledge into its templates — you get the same output instantly, and it passes checkov on the first run. The generated files are standard Terraform, so you can read, understand, and modify them freely.

### Does Gentepede lock me in to anything?

No. The generated workspace (`~/.gentepede/workspaces/{project}/`) contains plain Terraform HCL and a standard Helm chart. You can take those files and use them with the Terraform CLI directly, without the MCP server, indefinitely. There is no proprietary state format, no hosted service, and no runtime dependency on Gentepede once the files are generated.

### Can I use Gentepede with AI models other than Claude?

Yes. Gentepede implements the Model Context Protocol standard. Any MCP-compatible client can use it. Claude Desktop is the reference client, but the protocol is open and other clients exist.

### Do I need AWS credentials to use all tools?

`validate_infrastructure_package` and `generate_infrastructure_package` make zero AWS API calls — no credentials required. `plan_infrastructure_package`, `apply_infrastructure_package`, `detect_drift`, and `destroy_infrastructure_package` contact real AWS and require valid credentials configured in your environment.

### What happens if I modify the generated Terraform files?

The generated files are yours. You can modify them. Be aware that:
1. Re-running `generate_infrastructure_package` on the same project will overwrite `terraform.tfvars` and `providers.tf`, but not `main.tf` or `variables.tf` — those are overwritten too. If you have local modifications to template files, re-generation will clobber them.
2. After modifying `terraform.tfvars`, the plan checksum in `gentepede.lock.json` is stale — you must run `plan_infrastructure_package` again before applying.
3. `checkov` may flag modifications that violate security checks. Run `validate_infrastructure_package` after any edit.

### Why does apply take so long for EKS blueprints?

EKS cluster provisioning (the control plane) takes 10–15 minutes on AWS. This is an AWS limitation — the control plane involves multi-AZ EC2 instances, etcd clusters, and networking setup. RDS Multi-AZ also takes 5–10 minutes. There is nothing Gentepede can do to speed this up. The 30-minute process timeout covers the worst-case scenario.

### Can I deploy to multiple AWS regions?

Each workspace is pinned to one region (set in `terraform.tfvars` via `aws_region`). To deploy to multiple regions, generate separate workspaces with different `project_name` values and different `aws_region` variables.

### What is the `gentepede.lock.json` file for?

It ties each `apply` to the exact `plan` that was reviewed. It stores:
- `blueprintId` and `terraformProviderVersion` for traceability
- `plannedAt` timestamp
- `planFileChecksum`: SHA-256 of `gentepede.tfplan`

Before applying, `apply_infrastructure_package` recomputes the SHA-256 of the plan file and compares it against `planFileChecksum`. If they differ (e.g. because `generate_infrastructure_package` was re-run with different variables after the plan was reviewed), apply aborts. You never accidentally apply a plan you did not review.

### Why does `validate_infrastructure_package` not check my credentials?

It is pure static analysis. `terraform validate` reads your `.tf` files and checks syntax and type correctness — it never calls AWS. `checkov` reads the same files for security misconfigurations. Neither tool needs credentials. This is intentional: you can validate on a laptop with no internet access or AWS account at all.

### Can I add my own blueprints without forking the repo?

Not currently — blueprints must be bundled inside the JAR at build time. If you want custom blueprints, fork the repo, add your JSON files to `src/main/resources/blueprints/`, register them in `InfrastructureService.listBlueprints()`, and build your own JAR. See `docs/09-adding-blueprints.md`.

---

## For Contributors

### Where should I put new business logic?

In `InfrastructureService.kt`. Engine.kt is only for MCP parameter extraction and output formatting. Validator.kt is only for CLI output parsing. New logic that touches workspaces, blueprints, Terraform, or Helm belongs in InfrastructureService.

### How do I test a change to InfrastructureService without running Claude Desktop?

Use the unit tests: `./gradlew test`. For a more realistic test, use `BlueprintVerifierKt` directly:
```bash
./gradlew shadowJar
java -cp build/libs/gentepede-mcp-all.jar \
  com.gentepede.ci.BlueprintVerifierKt \
  --blueprint springboot-postgres \
  --project test-springboot
```
This runs `generateWorkspace` + `validateWorkspace` with your changes, including real `terraform validate` and checkov.

### Why is `providers.tf` generated at runtime instead of being in the template directory?

Because `providers.tf` contains project-specific values — the S3 backend bucket name, DynamoDB lock table name, and AWS region — that come from the user's variables at generate time. Generating it at runtime from `InfrastructureService.buildProvidersContent()` is simpler than templating it and keeps the static template files free of placeholder tokens.

### Why does InfrastructureService use `check()` instead of `require()` for workspace guards?

`check()` throws `IllegalStateException`; `require()` throws `IllegalArgumentException`. Engine.kt's catch blocks catch `IllegalStateException` for workspace-not-found errors (which are precondition failures on internal state) and `IllegalArgumentException` for invalid-input errors (e.g. bad blueprint name). Using `require()` for workspace guards would mean the exception bypasses the catch block and surfaces as an unhandled exception rather than a clean error response. See Engine.kt's `validateInfrastructurePackage` for the pattern.

### Why does `buildValidationSummary` use a `skipped = true` result for TERRAFORM_ONLY blueprints?

Because the `skipped` field drives the output line. `skipped = true` → `kube-score: SKIPPED (not a TERRAFORM_K8S blueprint)`. `skipped = false` → `kube-score: PASSED` (or FAILED). For TERRAFORM_ONLY blueprints, kube-score was never run — it would be misleading to say PASSED.

### Can I add a new template family (e.g. `fargate-spot/`)?

Yes. The full sync checklist is in [docs/16-contributor-sync-guide.md §2](16-contributor-sync-guide.md#2-add-a-new-template-family). In summary:

**Code changes:**
1. Create `templates/{new-family}/main.tf` and `variables.tf`
2. Add the new family to the `TemplateFamily` enum in `Models.kt`
3. Add data-tier toggle derivation to `injectDataTierToggles()` in InfrastructureService
4. Create at least one blueprint JSON using `"templateFamily": "{new-family}"` and register it in `listBlueprints()`
5. Add tests to `InfrastructureServiceTest.kt` for the new blueprint and toggle behaviour
6. Run `BlueprintVerifierKt` to confirm `terraform validate` + checkov pass

**Documentation changes (all required — not optional):**
7. Update `docs/12-development-guide.md` project structure tree to show the new directory
8. Update `docs/04-blueprints-guide.md` "All Blueprints at a Glance" table with the new blueprint(s)
9. Add a new template family section to `docs/14-blueprint-to-resource-map.md` (resource table + why the data tier fits)
10. Update `docs/00-glossary.md` if the new family uses AWS services not already defined
11. Update `README.md` Supported Blueprints table with new blueprint row(s)

Missing the documentation steps means the repo is internally inconsistent: the code supports the new family but the docs don't describe it, which breaks the "docs are a first-class deliverable" principle.

### What do the CI badges in the README mean?

- **CI badge**: build + unit tests pass on every push to `main`
- **Lint badge**: Terraform fmt, tflint, blueprint JSON schema, and YAML lint all pass on every push to `main`
- **Blueprint Verification badge**: all 6 blueprints pass `terraform validate` + checkov weekly

If the blueprint verification badge is red, check the GitHub Actions workflow run for which blueprint failed. The workflow auto-opens a GitHub issue with the failing blueprint and a reproduction command.

### Why does the blueprint verifier run `terraform validate` but not `terraform plan`?

`terraform plan` contacts AWS to check what currently exists. `terraform validate` is purely local — it checks HCL syntax and variable type correctness. The weekly job is designed to catch provider schema changes that make a template invalid (e.g. a resource argument that was removed in a provider upgrade), not to deploy anything. Running it purely statically means it works without credentials and finishes in minutes.

### Why pin the AWS provider to an exact version (`= 5.82.0`) instead of a range (`~> 5.0`)?

The AWS provider has a history of schema changes that are technically backwards-compatible (e.g. a new required argument, a changed default) but break existing templates in practice. Pinning to an exact version means your `validate`, `plan`, and `apply` all use the same provider schema. If you use `~> 5.0`, a provider upgrade between your plan and your apply could change the plan — you would apply something you did not review. The weekly blueprint verification job is the right place to test against newer provider versions; templates should only be updated when that test passes.
