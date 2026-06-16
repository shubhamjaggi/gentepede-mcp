# Contributing to Gentepede MCP

Thanks for your interest in contributing! This project welcomes bug reports, fixes,
documentation improvements, and new infrastructure blueprints.

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By participating,
you are expected to uphold it.

## Getting Started

```bash
git clone https://github.com/shubhamjaggi/gentepede-mcp
cd gentepede-mcp
./gradlew build      # compiles + runs the full test suite
./gradlew shadowJar  # builds build/libs/gentepede-mcp-all.jar
```

Requirements: **Java 21**. The external CLIs (terraform, checkov, helm,
kube-score, infracost, kubectl) are only needed at runtime — the unit tests run
without them (they gracefully skip when a binary is absent). See the
[README prerequisites](README.md#prerequisites) for install links.

## Architecture Ground Rules

The codebase deliberately separates concerns — please preserve this when contributing:

- **`Main.kt`** — thin entry point: `StdioServerTransport` + tool registrations only.
- **`Engine.kt`** — thin MCP handler: extracts params, calls `InfrastructureService`, formats responses. No business logic.
- **`InfrastructureService.kt`** — all business logic, fully testable without a running MCP server.
- **`Validator.kt`** — all external-CLI output parsing.
- **`Models.kt`** — shared `@Serializable` data classes only.

See [docs/02-architecture.md](docs/02-architecture.md) for the full call graph.

## Keeping the Repo in Sync

Every change in Gentepede has dependents: code that calls it, docs that describe it, tests that verify it. **Before opening a PR, consult [docs/17-contributor-sync-guide.md](docs/17-contributor-sync-guide.md)** to find your change type and follow its complete sync checklist.

Quick map:
- Adding a blueprint → update 4 docs + register in InfrastructureService + add tests
- New template family → update Models.kt + 5 docs + add tests
- New MCP tool → update Engine.kt + InfrastructureService + 2 docs
- Terraform template change → update HCL comments + resource map doc + re-run verifier
- Helm chart change → update copyHelmChart() file list + buildHelmValues() + kubernetes guide
- Provider version bump → update all 6 blueprints + run verifier against all

## Adding a Blueprint

Adding support for a new tech stack is the most welcome kind of contribution.
Follow the end-to-end worked example in
[docs/10-adding-blueprints.md](docs/10-adding-blueprints.md), which includes the
full PR checklist.

## Making Changes

1. Create a topic branch off `main`.
2. Keep changes focused; match the surrounding code style, comment density, and KDoc conventions.
3. **Document as you go** — KDoc on public APIs, an HCL comment above every Terraform resource, and an inline comment on every security-relevant Helm field. Documentation is a first-class deliverable here.
4. Add or update tests in `InfrastructureServiceTest` / `ValidatorTest` for any behavior change.
5. Run `./gradlew build` and ensure it is green before opening a PR.

## Pull Requests

- Fill out the [pull request template](.github/PULL_REQUEST_TEMPLATE.md).
- Describe **what** changed and **why**; link any related issue.
- Ensure CI (the weekly blueprint verification, plus the build) passes, or explain why a waiver is appropriate.
- One logical change per PR keeps review fast.

## Reporting Bugs / Requesting Features

Use the [issue templates](https://github.com/shubhamjaggi/gentepede-mcp/issues/new/choose).
For **security vulnerabilities**, do not open a public issue — follow
[SECURITY.md](SECURITY.md) instead.

## License

By contributing, you agree that your contributions will be licensed under the
[MIT License](LICENSE) that covers this project.
