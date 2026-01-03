# Variable Naming Convention: Prefixes vs Patterns

**Purpose**: Document the distinction between resource name prefixes and IAM policy matching patterns  
**Created**: January 3, 2026

---

## Overview

In our Terraform configuration, we distinguish between **prefixes** (literal strings used to construct resource names) and **patterns** (strings with wildcards used in IAM policies for matching).

## Problem Statement

**Original Issue**: Variables contained wildcards (e.g., `org-*`, `Boundary-*`) which caused failures when used to construct AWS resource names.

**Root Cause**: AWS resource names (IAM roles, policies) cannot contain wildcard characters. The regex pattern for IAM role names is `[\w+=,.@-]` which does **not** include asterisk (`*`).

## Solution

### Separate Concerns

1. **Prefix Variables** - Store only the literal prefix without wildcards
2. **Pattern Construction** - Add wildcards explicitly where needed for IAM policy matching

### Variable Definitions

#### `protected_role_prefix`

**Value**: `"org"`

**Usage**:
- **For Resource Names**: `"${var.protected_role_prefix}-default-deployment-role"` → `org-default-deployment-role` ✅
- **For Trust Policy ARNs**: `"arn:aws:iam::${account_id}:role/${var.protected_role_prefix}-automation-broker-role"` → `arn:aws:iam::ACCOUNT:role/org-automation-broker-role` ✅

#### `boundary_policy_prefix`

**Value**: `"Boundary"`

**Usage**:
- **For Policy Names**: `"${var.boundary_policy_prefix}-Default"` → `Boundary-Default` ✅
- **For Policy Names**: `"${var.boundary_policy_prefix}-ReadOnly"` → `Boundary-ReadOnly` ✅

### Pattern Construction in Boundary Policies

In permission boundary JSON templates, wildcards are added **explicitly** to create matching patterns:

```json
{
  "Resource": "arn:aws:iam::${account_id}:role/${protected_role_prefix}-*"
}
```

**Result**: `arn:aws:iam::ACCOUNT:role/org-*` ✅ (valid IAM policy pattern)

This matches:
- `org-default-deployment-role`
- `org-automation-broker-role`
- `org-application-broker-role`
- Any other roles with `org-` prefix

## Examples

### Creating Role Names (Terraform)

```hcl
# iam-deployment-roles.tf
resource "aws_iam_role" "org_default_deployment" {
  # Using prefix variable directly - NO wildcard
  name = "${var.protected_role_prefix}-default-deployment-role"
  # Results in: org-default-deployment-role ✅
}
```

### Referencing Role ARNs (Trust Policies)

```hcl
# iam-deployment-roles.tf
Principal = {
  # Using prefix variable to construct specific ARN - NO wildcard
  AWS = "arn:aws:iam::${local.automation_account_id}:role/${var.protected_role_prefix}-automation-broker-role"
  # Results in: arn:aws:iam::389068787156:role/org-automation-broker-role ✅
}
```

### Pattern Matching (Boundary Policies JSON)

```json
{
  "Sid": "DenyCreateProtectedRoles",
  "Effect": "Deny",
  "Action": ["iam:CreateRole"],
  "Resource": "arn:aws:iam::${account_id}:role/${protected_role_prefix}-*"
}
```

**Result after templating**: `arn:aws:iam::264675080489:role/org-*`  
**Matches**: All roles starting with `org-`

## Anatomy of the Pattern

For the pattern `org-*`:
- **Prefix**: `org` - The literal identifier
- **Delimiter**: `-` - Separates prefix from description
- **Wildcard**: `*` - Matches any characters (only valid in IAM policy resources)

## Implementation Notes

### Files Updated

1. **[baseline/terraform/variables.tf](../terraform/variables.tf)**:
   - `protected_role_prefix`: Changed from `"org-*"` to `"org"`
   - `boundary_policy_prefix`: Changed from `"Boundary-*"` to `"Boundary"`

2. **[baseline/terraform/boundary-policies/Boundary-Default.json](../terraform/boundary-policies/Boundary-Default.json)**:
   - Added `-*` suffix explicitly to resource patterns
   - `${protected_role_prefix}` → `${protected_role_prefix}-*`
   - `${boundary_policy_prefix}` → `${boundary_policy_prefix}-*`

3. **[baseline/terraform/iam-deployment-roles.tf](../terraform/iam-deployment-roles.tf)**:
   - No changes needed - already uses prefix variable correctly

## AWS Resource Naming Rules

### Valid Characters for IAM Role Names

Pattern: `[\w+=,.@-]`

- **Allowed**: `a-z A-Z 0-9 _ + = , . @ -`
- **NOT Allowed**: `* ? [ ] { } | \ / < > " ' ; : # $ % ^ & ( ) !`
- **Length**: 1-64 characters

### Wildcards in IAM Policies

Wildcards (`*`, `?`) are **only valid** in IAM policy statements for resource matching, not in actual resource names.

## Benefits of This Approach

1. **Single Source of Truth**: The prefix is defined once and reused everywhere
2. **Flexibility**: Easy to change the prefix (e.g., from `org` to `platform`) in one place
3. **Type Safety**: No risk of accidentally including wildcards in resource names
4. **Clear Intent**: Code explicitly shows where patterns (with wildcards) vs names (without) are used
5. **Maintainability**: Pattern construction logic is visible at point of use

## Related Documentation

- [IAM Deployment Roles](./iam-deployment-roles.md)
- [IAM Permission Boundaries](./iam-permission-boundaries.md)
- [AWS IAM Naming Rules](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html#reference_iam-quotas-names)
