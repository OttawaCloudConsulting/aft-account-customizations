# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AFT account customizations for the OCC AWS Control Tower Landing Zone. This repo defines Terraform and shell-based customizations that are applied to AWS accounts after they are vended by Account Factory for Terraform (AFT). Customizations execute in CodeBuild pipelines triggered by the AFT orchestration framework.

Part of a larger monorepo; see the parent `CLAUDE.md` for full architecture context.

## Customization Tiers

Three tiers applied in order during account vending:

1. **baseline/** — Applied to EVERY vended account. Currently implements permission boundaries, IAM deployment roles, and CDK bootstrap.
2. **core/** — Applied to core/infrastructure accounts only. Skeleton structure ready for core-specific Terraform.
3. **workload/** — Applied to workload/application accounts only. Skeleton structure ready for workload-specific Terraform.

The `account_customizations_name` field in the account request (in `aft-account-request/`) determines which tier (core or workload) applies on top of baseline.

## Execution Environment

Customizations run in CodeBuild. The execution flow per tier is:

1. Jinja2 templates (`aft-providers.jinja`, `backend.jinja`, `locals-aft.tf.jinja`) are rendered with account-specific values
2. `pre-api-helpers.sh` runs (baseline does CDK bootstrap here)
3. `terraform init && terraform apply` executes
4. `post-api-helpers.sh` runs

Key environment variables available at runtime: `VENDED_ACCOUNT_ID`, `AFT_MGMT_ACCOUNT`, `CUSTOMIZATION` (baseline/core/workload), `CT_MGMT_REGION`. Full list in `README.md`.

## Common Commands

```bash
# Validate baseline Terraform
cd baseline/terraform && terraform validate

# Validate core/workload (requires Jinja2 templates to be rendered first)
cd core/terraform && terraform validate
cd workload/terraform && terraform validate

# Format check
terraform fmt -check -recursive baseline/terraform/

# Validate JSON policy templates
python3 -c "import json; json.load(open('baseline/terraform/boundary-policies/Boundary-Default.json'))"
```

There are no local test suites. Customizations are validated by pushing to the repo and observing CodeBuild execution via:
```bash
aws logs tail /aft/account-provisioning-framework --follow | jq
```

## Architecture: Baseline Security Model

### Two-Layer Defense

1. **SCPs** (Organization level) — Broad guardrails applied by Control Tower
2. **Permission Boundaries** (Account level) — Fine-grained privilege escalation prevention, implemented here

### Permission Boundaries (`baseline/terraform/iam-permission-boundaries.tf`)

Uses `fileset()` + `for_each` to auto-discover JSON templates in `baseline/terraform/boundary-policies/`. Adding a new boundary is done by dropping a `.json` file in that directory — no Terraform code changes needed.

Template variables injected: `${account_id}`, `${protected_role_prefix}`, `${boundary_policy_prefix}`, `${boundary_name}`.

Current policies:
- **Boundary-Default** — Deny-by-exception pattern. Blocks privilege escalation to `org-*` roles, boundary policy modification, security service tampering.
- **Boundary-ReadOnly** — Allow-only pattern. Restrictive read-only access for audit/security roles.

### IAM Deployment Roles (`baseline/terraform/iam-deployment-roles.tf`)

Two cross-account roles created in every vended account:

- **org-default-deployment-role** — Trusted by `org-automation-broker-role` in AFT automation account (`389068787156`). For platform/infrastructure deployments.
- **application-default-deployment-role** — Trusted by `application-automation-broker-role-{account_id}` in AFT automation account. For application workload deployments.

Both have AdministratorAccess bounded by Boundary-Default. Trust policies require `aws:PrincipalOrgID` match.

### Protected Namespaces

- `org-*` roles — Privileged, exempt from boundary requirements
- `Boundary-*` policies — Self-protecting permission boundaries
- All other roles — Must have a `Boundary-*` policy attached

## Key Conventions

- **Jinja2 templates** (`.jinja` files) are processed by AFT before Terraform runs. Do not rename or relocate them.
- **`api_helpers/`** directories contain pre/post hooks. `pre-api-helpers.sh` runs before Terraform; `post-api-helpers.sh` runs after.
- **`agents/`** directory is git-ignored. Contains AI agent protocol, design documents, and session memory. Not deployed.
- **JSON output must be piped to `jq`** to prevent terminal hangs.
- **`git add .` is forbidden.** Stage files individually.
- **Refer to the user as Q.** Follow the DOING/EXPECT/RESULT reasoning protocol from `agents/CLAUDE.md` before actions that could fail.
- **On failure, STOP.** Output reasoning to Q before taking further action.
- **Persist agent memory** in `agents/memory/` for cross-session continuity.
