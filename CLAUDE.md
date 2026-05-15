# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AFT (Account Factory for Terraform) account customizations for AWS Control Tower. Applies IAM security governance (permission boundaries, deployment roles) and CDK bootstrap to newly vended AWS accounts. Executed by AWS CodeBuild as part of the AFT pipeline — there is no local build/test system.

## Customization Types

Three top-level directories, one per AFT customization stage. Each has the same shape: `terraform/` (IaC) + `api_helpers/` (pre/post shell scripts + python).

| Dir | Applied to | Status |
|-----|------------|--------|
| `baseline/` | Every vended account | Primary working area — all real IaC lives here |
| `core/` | Core/infrastructure accounts only | Skeleton only (jinja templates + empty helpers) |
| `workload/` | Application/workload accounts only | Skeleton only (jinja templates + empty helpers) |

When asked to add a new customization, ask whether it belongs in `baseline` (universal) or one of the scoped types before writing code.

## Execution Flow (CodeBuild Runtime)

1. AFT CodeBuild triggers on account vend with `CUSTOMIZATION` set to `baseline`, `core`, or `workload`
2. `pre-api-helpers.sh` runs — in `baseline/` this calls `shell_scripts/cdk-bootstrap.sh` to bootstrap CDK in the vended account with trust to the AFT automation account
3. AFT renders the `.jinja` files (`aft-providers.jinja`, `backend.jinja`, `locals-aft.tf.jinja`) into real `.tf` files using pipeline-supplied variables (`target_admin_role_arn`, `aft_admin_role_arn`, backend bucket, etc.)
4. `terraform init && terraform apply` runs against the vended account, assuming the rendered admin role
5. `post-api-helpers.sh` runs (currently a placeholder)

The provider, backend, and AFT-account-ID lookup do not exist as plain `.tf` files — they are generated from `.jinja` templates each run. Do not commit rendered `providers.tf` / `backend.tf` / `locals-aft.tf`.

## Security Architecture (Baseline)

Two layers enforce that workload roles can operate freely but cannot escalate privilege:

- **Layer 1 — SCP (org level, not in this repo):** all IAM roles must either use `org-*` prefix or have a `Boundary-*` permission boundary attached
- **Layer 2 — Permission Boundaries (this repo, `baseline/terraform/`):** `Boundary-*` policies deny creating `org-*` roles, modifying boundaries, billing changes, security service tampering, IdC changes, CloudTrail/Config changes, and log deletion

Resources deployed in every account:

| Resource | Built by | Notes |
|---|---|---|
| `Boundary-Default` / `Boundary-ReadOnly` IAM policies | `iam-permission-boundaries.tf` via `fileset()` over `boundary-policies/*.json` | Policy name is `${boundary_policy_prefix}-${filename-without-.json}` |
| `org-default-deployment-role` | `iam-deployment-roles.tf` | Platform deployments; admin policy; **no** permissions boundary currently (commented out) |
| `application-default-deployment-role` | `iam-deployment-roles.tf` | Application deployments; admin policy bounded by `Boundary-Default` |
| `crossplane-aws-iam` | `iam-oidc-federation.tf` | OIDC-federated workload role; trust bound to `system:serviceaccount:crossplane-provider-aws:provider-aws-iam`; permission boundary = `Boundary-Default`; created only when `var.oidc_federation_enabled = true` |
| CDK Toolkit stack | `baseline/api_helpers/shell_scripts/cdk-bootstrap.sh` | Trusts `AFT_MGMT_ACCOUNT` |

## Key Patterns to Preserve

- **Dynamic boundary discovery.** Drop a new `.json` file into `baseline/terraform/boundary-policies/` and it becomes `Boundary-<filename>` automatically via `for_each` on `fileset()`. Filenames must NOT include the `Boundary-` prefix — the prefix is added in `name = "${var.boundary_policy_prefix}-${each.key}"`. Renaming a JSON file changes the `for_each` key and forces destroy/recreate of the IAM policy.

- **Template variable injection in JSON.** Boundary policy JSON files are processed by `templatefile()` and may reference `${account_id}`, `${protected_role_prefix}`, `${boundary_policy_prefix}`, and `${boundary_name}` (the self-reference, set per policy in the `merge()` call).

- **Prefix vs pattern distinction (load-bearing).** `var.protected_role_prefix = "org"` and `var.boundary_policy_prefix = "Boundary"` are plain prefixes — NO wildcards. Wildcards (`org-*`, `Boundary-*`) are added only in JSON policy `Resource` strings, never in `.tf` resource names (AWS role/policy names disallow `*`). See `baseline/docs/variable-naming-convention.md`.

- **Dual trust pattern on deployment roles.** Each deployment role has two `sts:AssumeRole` statements: `TrustBrokerRole` (`StringEquals` on the specific broker role ARN) and `TrustCodeBuildServiceRoles` (`StringLike` on `CodeBuild-*-ServiceRole`). Both gated by `aws:PrincipalOrgID`. The `CodeBuild-*-ServiceRole` pattern is the terraform-pipelines naming convention — keep both statements when modifying trust policies.

- **12-hour session duration** (`max_session_duration = 43200`) on deployment roles is intentional — supports long-running Terraform/CDK applies. Don't shorten without checking with the user.

- **OIDC federation JSON-wrapper discovery.** When `var.oidc_federation_enabled = true`, `iam-oidc-federation.tf` uses `fileset()` over `baseline/terraform/oidc-federation-policies/*.json` — parallel to the boundary discovery pattern. Each file defines one federation role; the filename minus `.json` is the role key. Adding a federated workload is a one-file change. Filenames in `oidc-federation-policies/` are immutable post-deploy (rename changes the `for_each` key; `lifecycle { prevent_destroy = true }` blocks the resulting destroy at plan time). **Symmetric coupling**: renaming `boundary-policies/Default.json` breaks the `boundary_key = "Default"` lookup in every federation role that does not set an explicit `boundary_key` — the `precondition` block will fail at plan time. Both rename constraints must be preserved together.

## CodeBuild Runtime Environment Variables

The AFT pipeline injects these at runtime — use them in `api_helpers/` scripts and as data sources for Terraform decisions. Most important:

- `AFT_MGMT_ACCOUNT`, `AFT_ADMIN_ROLE_ARN`, `AFT_EXEC_ROLE_ARN` — AFT automation account
- `VENDED_ACCOUNT_ID`, `VENDED_EXEC_ROLE_ARN` — target account being customized
- `CUSTOMIZATION` — which directory is being applied (`baseline` | `core` | `workload`)
- `CT_MGMT_REGION`, `AWS_DEFAULT_REGION`, `TF_VERSION`

Full table in `README.md`. The AFT management account ID is also derivable inside Terraform from `local.aft_management_account_id` (extracted from `aft_admin_role_arn` in the rendered `locals-aft.tf`).

## Local Validation

No AWS credentials are available locally. Validation is limited to:

```bash
terraform -chdir=baseline/terraform fmt -check    # format check
terraform -chdir=baseline/terraform fmt           # apply formatting
terraform -chdir=baseline/terraform validate      # syntax — requires terraform init
```

`terraform init` will fail without backend credentials, so `validate` is typically only useful in CodeBuild. Real validation happens in the AFT CodeBuild pipeline on next account provisioning. State-impact changes (renaming `for_each` keys, changing logical IDs of stateful IAM resources) should be called out in PR descriptions.

## Project Instructions in `.claude/`

Several rule files in `.claude/rules/` are loaded automatically as project instructions: defensive coding protocol (epistemology, anti-slop, session management), Terraform best practices, CDK best practices, Kubernetes/Crossplane best practices, agent delegation matrix. Don't re-derive their guidance — assume it's already active. The `.claude/skills/` directory contains user-invokable slash commands (e.g., `/start-feature`, `/investigate`, `/update-docs-terraform`, `/test-terraform`, the various compliance assessments) — only invoke them when the user explicitly asks.

## Repository Hygiene

- `.gitignore` excludes `.terraform/`, state, plans, `*.tfvars`, and the `agents/` working directory (ephemeral session memory)
- Never use `git add .` — stage files individually
- The `.jinja` files ARE source of truth; never commit the rendered `.tf` outputs
