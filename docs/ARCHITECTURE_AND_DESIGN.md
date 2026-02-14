# Architecture and Design: Backport Cross-Account Role Fixes

## Overview

Three targeted fixes to existing baseline resources. No new resources, no new patterns. All changes align the AFT-managed Terraform with the manually-applied hotfixes documented in `baseline/docs/external-references/CROSS_ACCOUNT_ROLES.md`.

## Files Modified

| # | File | Change |
|---|------|--------|
| 1 | `baseline/terraform/boundary-policies/Boundary-Default.json` | Rename to `Default.json`, add `AllowAllServices`, remove redundant `AllowOrganizationVisibility` |
| 2 | `baseline/terraform/boundary-policies/Boundary-ReadOnly.json` | Rename to `ReadOnly.json` |
| 3 | `baseline/terraform/iam-deployment-roles.tf` | Add `TrustCodeBuildServiceRoles` statement to both roles, update session duration |
| 4 | `baseline/terraform/iam-deployment-roles.tf` | Update `max_session_duration` to 43200 (12 hours) |

## Dependency Graph

```
Feature 1 (rename files) ──┐
                            ├──> Feature 3 (add AllowAllServices to renamed Default.json)
                            │
Feature 2 (add CodeBuild trust) ──> independent
Feature 4 (session duration) ──> independent
```

Feature 1 and 3 touch the same file — implement together.

## Design Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Rename JSON files instead of changing the `name` expression in HCL | Simpler. The `name = "${prefix}-${key}"` pattern is correct — the filenames were wrong. Future boundary files should be named without the prefix (e.g., `NetworkRestricted.json` → `Boundary-NetworkRestricted`). |
| 2 | Hardcode `CodeBuild-*-ServiceRole` pattern | This is the terraform-pipelines module naming convention. Adding a variable would over-parameterize for a single consumer. Can be extracted later if a second pattern emerges. |
| 3 | Apply CodeBuild trust to both deployment roles | Both roles are used by terraform-pipelines. External doc confirms both were manually updated. |
| 4 | Accept destroy/recreate (no `moved` blocks) | The `for_each` key change means Terraform can't correlate old and new resources. The brief boundary gap during apply is acceptable per user confirmation. |
| 5 | Remove `AllowOrganizationVisibility` statement | Redundant under `Allow *:*`. Reducing statement count saves policy size budget (6,144 char limit). |
| 6 | Use `StringLike` (not `StringEquals`) for CodeBuild role ARN | Wildcard `CodeBuild-*-ServiceRole` requires `StringLike`. Consistent with external reference. |
| 7 | Max session duration 43200s (12 hours) | User decision. Supports long-running Terraform applies and CDK deployments. |

## Security Review

| Concern | Status | Notes |
|---------|--------|-------|
| `Allow *:*` in boundary | Already deployed | Manually applied 2026-02-12. Deny statements provide the security envelope. This is the standard deny-list boundary pattern. |
| CodeBuild trust pattern breadth | Acceptable | Scoped to: automation account only + org ID + `CodeBuild-*-ServiceRole` naming convention. More restrictive than trusting account root. |
| 12-hour session duration | Acceptable | Deployment roles are assumed by automation, not humans. Long sessions support large infrastructure applies. |
| Destroy/recreate gap | Low risk | AFT applies per-account atomically. Window is seconds. Roles without boundaries are still constrained by SCP. |

## Terraform State Impact

### Before (current `for_each` keys)
```
aws_iam_policy.boundaries["Boundary-Default"]
aws_iam_policy.boundaries["Boundary-ReadOnly"]
```

### After (new `for_each` keys)
```
aws_iam_policy.boundaries["Default"]
aws_iam_policy.boundaries["ReadOnly"]
```

### Deployment Role Boundary Reference

`iam-deployment-roles.tf` currently references:
```hcl
boundary_policy_name = "Boundary-Default"
```

This must change to:
```hcl
boundary_policy_name = "Default"
```

Because the lookup `aws_iam_policy.boundaries["Boundary-Default"]` will no longer exist.

## Trust Policy Structure (After Change)

Both deployment roles will have:

```
assume_role_policy:
  Statement[0]: TrustBrokerRole
    - Principal: automation account root
    - Condition: PrincipalOrgID + PrincipalArn (exact broker role)
    - Uses: StringEquals

  Statement[1]: TrustCodeBuildServiceRoles
    - Principal: automation account root
    - Condition: PrincipalOrgID (StringEquals) + PrincipalArn (StringLike: CodeBuild-*-ServiceRole)
    - Uses: StringLike for wildcard pattern
```

## Validation

No remote validation possible (no AWS credentials locally). Validation is limited to:

```bash
terraform -chdir=baseline/terraform fmt -check
```

Full validation happens in the AFT CodeBuild pipeline on next account provisioning.
