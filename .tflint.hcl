# tflint configuration for Gentepede MCP Terraform templates.
#
# Runs on templates/ecs, templates/lambda, and templates/eks in CI.
# providers.tf is generated at runtime by InfrastructureService and is NOT
# present in the templates directory, so rules that require a static
# provider configuration or version constraint are disabled.

plugin "aws" {
  enabled = true
  version = "0.39.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# providers.tf is generated at runtime — no static required_providers block exists.
rule "terraform_required_providers" {
  enabled = false
}

# Same reason: terraform version constraint lives in CI config, not in the template.
rule "terraform_required_version" {
  enabled = false
}

# aws_profile and aws_region variables are consumed exclusively by the runtime-generated
# providers.tf that InfrastructureService writes into each workspace. tflint cannot see
# that generated file, so it would incorrectly report them as unused declarations.
rule "terraform_unused_declarations" {
  enabled = false
}

# No Terraform modules are used in any template family — this rule is not applicable.
rule "terraform_module_pinned_source" {
  enabled = false
}
