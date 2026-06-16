#!/usr/bin/env python3
"""
Fast structural validation of all blueprint JSON files.

Checks that every file in src/main/resources/blueprints/ satisfies the expected
schema before the full JVM-based BlueprintVerifierKt is even invoked. Fails with
a clear, specific error message per violation rather than a generic JAR crash.

Exit 0 = all blueprints valid.
Exit 1 = one or more structural violations found.
"""
import json
import re
import sys
from pathlib import Path

VALID_OUTPUT_TYPES = {"TERRAFORM_ONLY", "TERRAFORM_K8S"}
VALID_TEMPLATE_FAMILIES = {"ecs", "lambda", "eks"}
VALID_VARIABLE_TYPES = {"string", "number", "boolean", "bool"}

REQUIRED_TOP_LEVEL = [
    "blueprintId",
    "displayName",
    "description",
    "outputType",
    "templateFamily",
    "terraformProviderVersion",
    "lastVerifiedDate",
    "techStack",
    "awsResources",
    "variables",
    "securityBaseline",
]
REQUIRED_TECH_STACK = ["language", "framework", "database"]
REQUIRED_AWS_RESOURCE = ["type", "required", "defaultConfig"]
REQUIRED_VARIABLE = ["name", "description", "type", "default", "required"]
REQUIRED_SECURITY_BASELINE = ["enableVpcFlowLogs", "enforceHttps"]

VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
DATE_RE = re.compile(r"^\d{4}-\d{2}$")


def check_blueprint(path: Path) -> list[str]:
    errors: list[str] = []

    try:
        with open(path, encoding="utf-8") as f:
            bp = json.load(f)
    except json.JSONDecodeError as exc:
        return [f"Invalid JSON: {exc}"]

    # blueprintId must match the filename stem
    expected_id = path.stem
    actual_id = bp.get("blueprintId", "")
    if actual_id != expected_id:
        errors.append(
            f"blueprintId '{actual_id}' does not match filename '{expected_id}.json'"
        )

    # All required top-level fields must be present
    for field in REQUIRED_TOP_LEVEL:
        if field not in bp:
            errors.append(f"Missing required top-level field: '{field}'")

    # outputType must be a known enum value
    output_type = bp.get("outputType")
    if output_type not in VALID_OUTPUT_TYPES:
        errors.append(
            f"Invalid outputType: '{output_type}' (must be one of {sorted(VALID_OUTPUT_TYPES)})"
        )

    # templateFamily must be a known enum value
    template_family = bp.get("templateFamily")
    if template_family not in VALID_TEMPLATE_FAMILIES:
        errors.append(
            f"Invalid templateFamily: '{template_family}' (must be one of {sorted(VALID_TEMPLATE_FAMILIES)})"
        )

    # terraformProviderVersion must be X.Y.Z
    pv = bp.get("terraformProviderVersion", "")
    if pv and not VERSION_RE.match(pv):
        errors.append(
            f"Invalid terraformProviderVersion: '{pv}' (expected X.Y.Z, e.g. '5.82.0')"
        )

    # lastVerifiedDate must be YYYY-MM
    lvd = bp.get("lastVerifiedDate", "")
    if lvd and not DATE_RE.match(lvd):
        errors.append(
            f"Invalid lastVerifiedDate: '{lvd}' (expected YYYY-MM, e.g. '2026-06')"
        )

    # techStack must have required fields
    ts = bp.get("techStack")
    if isinstance(ts, dict):
        for field in REQUIRED_TECH_STACK:
            if field not in ts:
                errors.append(f"techStack missing field: '{field}'")
    elif ts is not None:
        errors.append("techStack must be a JSON object")

    # awsResources must be a non-empty list with required fields per entry
    aws_resources = bp.get("awsResources", [])
    if not isinstance(aws_resources, list) or len(aws_resources) == 0:
        errors.append("awsResources must be a non-empty JSON array")
    else:
        for i, res in enumerate(aws_resources):
            for field in REQUIRED_AWS_RESOURCE:
                if field not in res:
                    errors.append(
                        f"awsResources[{i}] (type='{res.get('type', '?')}') missing field: '{field}'"
                    )

    # variables must be a list; each entry needs required fields and a valid type
    variables = bp.get("variables", [])
    if not isinstance(variables, list):
        errors.append("variables must be a JSON array")
    else:
        for i, var in enumerate(variables):
            var_name = var.get("name", f"index {i}")
            for field in REQUIRED_VARIABLE:
                if field not in var:
                    errors.append(
                        f"variables[{i}] ('{var_name}') missing field: '{field}'"
                    )
            var_type = var.get("type")
            if var_type and var_type not in VALID_VARIABLE_TYPES:
                errors.append(
                    f"variables[{i}] ('{var_name}') invalid type: '{var_type}' "
                    f"(must be one of {sorted(VALID_VARIABLE_TYPES)})"
                )

    # securityBaseline must have required fields
    sb = bp.get("securityBaseline")
    if isinstance(sb, dict):
        for field in REQUIRED_SECURITY_BASELINE:
            if field not in sb:
                errors.append(f"securityBaseline missing field: '{field}'")
    elif sb is not None:
        errors.append("securityBaseline must be a JSON object")

    return errors


def main() -> int:
    blueprint_dir = Path("src/main/resources/blueprints")
    if not blueprint_dir.exists():
        print(
            f"ERROR: {blueprint_dir} not found — run this script from the repo root",
            file=sys.stderr,
        )
        return 1

    files = sorted(blueprint_dir.glob("*.json"))
    if not files:
        print(f"ERROR: No JSON files found in {blueprint_dir}", file=sys.stderr)
        return 1

    all_ok = True
    for path in files:
        errors = check_blueprint(path)
        if errors:
            print(f"FAIL  {path.name}")
            for err in errors:
                print(f"      • {err}")
            all_ok = False
        else:
            print(f"OK    {path.name}")

    if not all_ok:
        print("\nBlueprint schema validation FAILED — fix the errors above.")
        return 1

    print(f"\nAll {len(files)} blueprints passed schema validation.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
