## Summary

What does this PR change, and why?

Fixes #<!-- issue number, if applicable -->

## Type of Change

- [ ] Bug fix
- [ ] New feature / new blueprint
- [ ] Documentation
- [ ] Refactor / internal change
- [ ] CI / build

## Checklist

- [ ] `./gradlew build` passes locally (compile + tests green)
- [ ] Added/updated tests for the change
- [ ] Updated documentation (KDoc, HCL/Helm comments, and the relevant `docs/` file)
- [ ] Preserved the architecture separation (Main / Engine / InfrastructureService / Validator / Models)
- [ ] No secrets, credentials, or personal paths committed

### If this adds or changes a blueprint

- [ ] Followed the checklist in [docs/10-adding-blueprints.md](../docs/10-adding-blueprints.md)
- [ ] Blueprint registered in `InfrastructureService.listBlueprints()`
- [ ] README "Supported Blueprints" table and `docs/04-blueprints-guide.md` updated

## Notes for Reviewers

Anything reviewers should focus on, test manually, or be aware of.
