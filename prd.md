# PRD: Backport Cross-Account Role Fixes from External Reference

## Summary

Backport three fixes to the AFT baseline customization that were discovered and manually applied during a terraform-pipelines integration. An external project documented these issues in `baseline/docs/external-references/CROSS_ACCOUNT_ROLES.md`. Without these fixes, the next AFT provisioning cycle will revert the manual changes, breaking deployment pipelines.

## Goals

- Fix double-prefix naming bug (`Boundary-Boundary-Default` → `Boundary-Default`)
- Add CodeBuild direct trust pattern to deployment roles for terraform-pipelines module compatibility
- Add `AllowAllServices` statement to Boundary-Default so deployments can actually create resources
- Ensure AFT-managed state is the source of truth (no more manual hotfixes)

## Non-Goals

- Creating new boundary policies or deployment roles
- Changing the broker trust pattern (it stays as-is)
- Modifying Boundary-ReadOnly policy content (only renaming the file)
- Adding the `org-automation-broker-role` to this repo (it lives in the automation account)
- Sanitizing account IDs from the external reference doc

## Architecture

No architectural changes. All three fixes modify existing resources within the current baseline customization pattern.

## Features

### Feature 1: Rename Boundary Policy Files (Fix Double-Prefix)

**Problem:** `iam-permission-boundaries.tf` creates policy names as `${boundary_policy_prefix}-${filename}`. With `boundary_policy_prefix = "Boundary"` and filename `Boundary-Default`, the resulting IAM policy is named `Boundary-Boundary-Default`.

**Change:**
- Rename `boundary-policies/Boundary-Default.json` → `boundary-policies/Default.json`
- Rename `boundary-policies/Boundary-ReadOnly.json` → `boundary-policies/ReadOnly.json`

**Result:** Policy names become `Boundary-Default` and `Boundary-ReadOnly`.

**State impact:** Destroy/recreate is acceptable. The `for_each` key changes from `Boundary-Default` to `Default`, so Terraform will destroy the old policy and create a new one. Roles referencing the boundary will be updated in the same apply.

**Acceptance criteria:**
- `Boundary-Default.json` renamed to `Default.json`
- `Boundary-ReadOnly.json` renamed to `ReadOnly.json`
- `terraform fmt -check` passes
- `iam-deployment-roles.tf` boundary lookup key updated from `"Boundary-Default"` to `"Default"`
- Policy names in deployed accounts are `Boundary-Default` and `Boundary-ReadOnly` (no stutter)

### Feature 2: Add CodeBuild Direct Trust to Deployment Roles

**Problem:** The terraform-pipelines module uses `CodeBuild-<project>-ServiceRole` roles that assume deployment roles directly (first-hop). Current trust policies only allow the broker pattern (`org-automation-broker-role` → deployment role).

**Change:** Add a second trust statement to both `org-default-deployment-role` and `application-default-deployment-role`:

```json
{
  "Sid": "TrustCodeBuildServiceRoles",
  "Effect": "Allow",
  "Principal": {
    "AWS": "arn:aws:iam::<automation_account_id>:root"
  },
  "Action": "sts:AssumeRole",
  "Condition": {
    "StringEquals": {
      "aws:PrincipalOrgID": "<organization_id>"
    },
    "StringLike": {
      "aws:PrincipalArn": "arn:aws:iam::<automation_account_id>:role/CodeBuild-*-ServiceRole"
    }
  }
}
```

**Design decisions:**
- Hardcode `CodeBuild-*-ServiceRole` pattern (matches terraform-pipelines module convention)
- Both roles get the trust (org-default and application-default)
- `StringLike` for wildcard matching on the role name pattern
- Same org ID + automation account scoping as existing broker trust

**Acceptance criteria:**
- Both deployment roles have two trust statements: `TrustBrokerRole` + `TrustCodeBuildServiceRoles`
- Existing broker trust is unchanged
- `terraform fmt -check` passes
- Trust policy uses existing `local.automation_account_id` and `local.organization_id`

### Feature 3: Add AllowAllServices to Boundary-Default Policy

**Problem:** The Boundary-Default policy only has `AllowOrganizationVisibility` as its Allow statement. Since permission boundaries define the *maximum* permissions (intersection with identity policy), the effective permissions are limited to `organizations:Describe*/List*`. Deployment roles with `AdministratorAccess` can't actually do anything.

**Change:** Add `AllowAllServices` as the first statement in `Default.json` (after Feature 1 rename):

```json
{
  "Sid": "AllowAllServices",
  "Effect": "Allow",
  "Action": "*",
  "Resource": "*"
}
```

This converts the boundary from an allow-list to a deny-list pattern. The existing Deny statements continue to block privilege escalation.

**Acceptance criteria:**
- `AllowAllServices` statement is the first statement in the policy
- All existing Deny statements are preserved unchanged
- `AllowOrganizationVisibility` can be removed (it's now redundant under `Allow *:*`)
- `terraform fmt -check` passes
- Policy document stays under AWS 6,144 character limit

### Feature 4: Update Max Session Duration

**Change:** Update `max_session_duration` from 7200 (2 hours) to 43200 (12 hours) for both deployment roles.

**Acceptance criteria:**
- `local.deployment_role_config.max_session_duration` updated to `43200`
- Comment updated to reflect `# 12 hours`

## Input Variables

No new variables. All changes use existing variables and locals.

## Outputs

No output changes. `outputs.tf` references `aws_iam_policy.boundaries` which will have new keys but same structure.

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| Policy destroy/recreate leaves roles without boundary briefly | AFT applies atomically per account; brief window is acceptable |
| `Allow *:*` too permissive | Deny statements enforce the security envelope; this matches the manually-applied fix already in production |
| CodeBuild trust too broad | Scoped to `CodeBuild-*-ServiceRole` pattern + org ID + automation account only |
| Existing deployments break during transition | Roles are recreated in same apply; no manual intervention needed |

## Feature Ordering

Features 1 → 3 have a dependency: Feature 1 renames the file, Feature 3 modifies its content. These can be done together since we're editing the renamed file. Feature 2 and Feature 4 are independent.

Recommended order: Feature 1 + Feature 3 (same file), then Feature 2, then Feature 4.
