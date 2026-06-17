## Summary

What does this PR change, and why?

Fixes #<!-- issue number, if applicable -->

## Type of Change

- [ ] Bug fix
- [ ] New blueprint (reuses existing template family)
- [ ] New template family (new tech stack)
- [ ] New MCP tool
- [ ] Template or Helm chart change
- [ ] Documentation
- [ ] Refactor / internal code change
- [ ] CI / build
- [ ] Provider version bump

## Base Checklist (all PRs)

- [ ] `./gradlew build` passes locally (compile + tests green)
- [ ] `./gradlew shadowJar` succeeds (templates and Helm chart re-bundled)
- [ ] Added/updated tests for any behaviour change
- [ ] Updated inline documentation (KDoc on public APIs, HCL comment above every Terraform resource, inline comment on every security-relevant Helm field)
- [ ] Preserved the architecture separation (Main / Engine / InfrastructureService / Validator / Models)
- [ ] No secrets, credentials, or personal paths committed

## Change-Specific Sync Checklist

The items below only apply to the checked "Type of Change" above. See [docs/16-contributor-sync-guide.md](../docs/16-contributor-sync-guide.md) for the full dependency map.

### If this adds a blueprint

- [ ] `src/main/resources/blueprints/{id}.json` created with all required fields; `blueprintId` matches filename
- [ ] Blueprint added to `InfrastructureService.listBlueprints()`
- [ ] `InfrastructureServiceTest.kt` — blueprint load test + data-tier toggle test added
- [ ] `README.md` Supported Blueprints table updated
- [ ] `docs/04-blueprints-guide.md` "All Blueprints at a Glance" table updated
- [ ] `docs/14-blueprint-to-resource-map.md` updated with new blueprint section
- [ ] `docs/00-glossary.md` updated if any new AWS service introduced
- [ ] Full checklist: [docs/09-adding-blueprints.md](../docs/09-adding-blueprints.md)

### If this adds a new template family

- [ ] `templates/{family}/main.tf` + `variables.tf` created
- [ ] `TemplateFamily` enum in `Models.kt` updated
- [ ] `InfrastructureService.injectDataTierToggles()` updated with new family branch
- [ ] `docs/12-development-guide.md` project structure tree updated
- [ ] `docs/14-blueprint-to-resource-map.md` new template family section added
- [ ] Full checklist: [docs/16-contributor-sync-guide.md §2](../docs/16-contributor-sync-guide.md#2-add-a-new-template-family)

### If this adds a new MCP tool

- [ ] Registered in `Main.kt`; handler in `Engine.kt`; logic in `InfrastructureService.kt`
- [ ] `docs/07-tools-reference.md` new tool section added
- [ ] `docs/15-tool-architecture.md` new tool architecture section added
- [ ] `README.md` Deployment Workflow diagram updated if tool fits the main flow
- [ ] Full checklist: [docs/16-contributor-sync-guide.md §3](../docs/16-contributor-sync-guide.md#3-add-a-new-mcp-tool)

### If this modifies a Terraform template

- [ ] `variables.tf` updated for any new variables in `main.tf`
- [ ] HCL concept comments updated to match the new behaviour
- [ ] `docs/14-blueprint-to-resource-map.md` resource table updated if resources were added/removed
- [ ] `BlueprintVerifierKt` run against all blueprints using that template family

### If this modifies the Helm chart

- [ ] New files added to `helmFiles` list in `InfrastructureService.copyHelmChart()`
- [ ] New per-project values added to `InfrastructureService.buildHelmValues()`
- [ ] `docs/06-kubernetes-guide.md` updated if visible behaviour changed
- [ ] `kube-score` passes: run `BlueprintVerifierKt --blueprint springboot-eks`

### If this bumps the Terraform provider version

- [ ] Version updated in **all six** blueprint JSON files (not just one)
- [ ] `BlueprintVerifierKt` run against all six blueprints
- [ ] `README.md` Supported Blueprints table `Provider` column updated for all rows

## Notes for Reviewers

Anything reviewers should focus on, test manually, or be aware of.
