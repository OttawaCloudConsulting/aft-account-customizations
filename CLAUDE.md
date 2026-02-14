# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AFT (Account Factory for Terraform) account customizations for AWS Control Tower. Applies IAM security governance (permission boundaries, deployment roles) to newly vended AWS accounts. Runs via AWS CodeBuild pipeline triggered by AFT.

## Architecture

### Customization Types

- **baseline/** — Applied to every vended account (primary working area)
- **core/** — Core/infrastructure accounts only (minimal config)
- **workload/** — Application/workload accounts only (minimal config)

Each customization has: `terraform/` (IaC), `api_helpers/` (pre/post shell scripts + python)

### Execution Flow

1. CodeBuild triggers on account vend
2. `pre-api-helpers.sh` runs (CDK bootstrap)
3. Jinja2 templates (`.jinja` files) are rendered with env vars
4. `terraform init && terraform apply`
5. `post-api-helpers.sh` runs

### Security Model (Two-Layer Defense)

**Layer 1 — SCP (Organization):** All IAM roles must either use `org-*` prefix OR have a `Boundary-*` permission boundary attached.

**Layer 2 — Permission Boundaries (Account):** All `Boundary-*` policies deny privilege escalation (creating `org-*` roles, modifying boundaries, billing changes, security service tampering).

### Key Design Patterns

- **Dynamic policy discovery:** Drop a `.json` file in `baseline/terraform/boundary-policies/` — Terraform auto-discovers it via `fileset()` and creates the IAM policy as `Boundary-<filename>`. No code changes needed. Do NOT include the `Boundary-` prefix in the filename.
- **Template variable injection:** Boundary JSON policies use `${account_id}`, `${protected_role_prefix}`, `${boundary_policy_prefix}`, `${boundary_name}` — rendered by Terraform `templatefile()`.
- **Prefix vs Pattern distinction:** Variables hold prefixes (e.g., `org`), policies use patterns (e.g., `org-*`). AWS resource names don't allow `*`, but IAM policy resources do.
- **Cross-account trust:** Deployment roles support two trust patterns — broker role chaining (`org-automation-broker-role`) and direct CodeBuild assumption (`CodeBuild-*-ServiceRole`). Both use `aws:PrincipalOrgID` (org membership) + `aws:PrincipalArn` conditions.

### Important Files

| File | Purpose |
|------|---------|
| `baseline/terraform/iam-permission-boundaries.tf` | Dynamic boundary creation with `for_each` |
| `baseline/terraform/iam-deployment-roles.tf` | Platform & application deployment roles |
| `baseline/terraform/boundary-policies/*.json` | Permission boundary policy templates |
| `baseline/terraform/variables.tf` | `protected_role_prefix` ("org"), `boundary_policy_prefix` ("Boundary") |
| `baseline/terraform/locals.tf` | Common tags: `ManagedBy: AFT`, `AFTCustomization: Baseline` |
| `baseline/api_helpers/shell_scripts/cdk-bootstrap.sh` | CDK bootstrap for new accounts |

### Jinja Templates

`aft-providers.jinja`, `backend.jinja`, `locals-aft.tf.jinja` are processed by the AFT CodeBuild pipeline before Terraform runs. They are NOT standard Terraform files.

## Available CodeBuild Environment Variables

Key variables available at runtime: `VENDED_ACCOUNT_ID`, `AFT_MGMT_ACCOUNT`, `AFT_ADMIN_ROLE_ARN`, `VENDED_EXEC_ROLE_ARN`, `CUSTOMIZATION`, `CT_MGMT_REGION`, `TF_VERSION`. Full list in README.md.

## Commands

No local build/test system. Terraform runs in CodeBuild. For local validation:

```bash
# Format check
terraform -chdir=baseline/terraform fmt -check

# Validate syntax (requires init, which needs AWS credentials)
terraform -chdir=baseline/terraform validate

# Format all terraform files
terraform -chdir=baseline/terraform fmt
```

## Agent Protocol

See `agents/CLAUDE.md` for defensive coding protocol. Key rules:
- Pipe JSON-outputting commands through `jq`
- Use `git add <file>` individually, never `git add .`
- Session memory persists in `agents/memory/` as markdown files
- When something fails: stop, report to user, wait for confirmation before retrying
