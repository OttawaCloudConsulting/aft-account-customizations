# IAM Permission Boundaries

**Module Component**: Baseline Account Customizations  
**Purpose**: Prevent privilege escalation through comprehensive IAM permission boundaries  
**Last Updated**: February 13, 2026

---

## Table of Contents

- [IAM Permission Boundaries](#iam-permission-boundaries)
  - [Table of Contents](#table-of-contents)
  - [Design Overview](#design-overview)
    - [Architecture](#architecture)
    - [Two-Layer Defense Model](#two-layer-defense-model)
    - [How Permission Boundaries Work](#how-permission-boundaries-work)
    - [Design Patterns](#design-patterns)
      - [Boundary-Default: Deny-by-Exception Pattern](#boundary-default-deny-by-exception-pattern)
      - [Boundary-ReadOnly: Allow-Only Pattern](#boundary-readonly-allow-only-pattern)
    - [Protected Namespaces](#protected-namespaces)
  - [User Guide: Adding Permission Boundaries](#user-guide-adding-permission-boundaries)
    - [Prerequisites](#prerequisites)
    - [Creating a New Boundary](#creating-a-new-boundary)
    - [Boundary Policy Template Structure](#boundary-policy-template-structure)
    - [Available Template Variables](#available-template-variables)
    - [Testing Your Boundary](#testing-your-boundary)
    - [Deployment](#deployment)
  - [Developer Guide: Maintaining the Code](#developer-guide-maintaining-the-code)
    - [File Structure](#file-structure)
    - [How the Terraform Works](#how-the-terraform-works)
    - [Key Terraform Resources](#key-terraform-resources)
    - [Template Variable Injection](#template-variable-injection)
    - [Adding New Template Variables](#adding-new-template-variables)
    - [Modifying Existing Boundaries](#modifying-existing-boundaries)
    - [Troubleshooting](#troubleshooting)
  - [Reference](#reference)
    - [Current Boundaries](#current-boundaries)
    - [Outputs](#outputs)
    - [Variables](#variables)
  - [External References](#external-references)
    - [AWS Documentation](#aws-documentation)
    - [Terraform Documentation](#terraform-documentation)
    - [Related Tools](#related-tools)

---

## Design Overview

### Architecture

The IAM Permission Boundaries implementation provides a scalable, maintainable system for preventing privilege escalation in AWS accounts provisioned through AFT (Account Factory for Terraform).

**Key Design Principles:**

1. **DRY (Don't Repeat Yourself)**: Single Terraform resource with `for_each` pattern
2. **Declarative**: Policy logic externalized to JSON template files
3. **Scalable**: Add new boundaries by dropping files in a directory
4. **Type-Safe**: Template variable validation at Terraform plan time

### Two-Layer Defense Model

```
┌──────────────────────────────────────────────────────────┐
│ Layer 1: Service Control Policy (Organization-wide)      │
│ Requires: Boundary-* attachment on all IAM roles         │
│ Exception: org-* roles (privileged namespace)            │
└──────────────────────────────────────────────────────────┘
                            ↓
┌──────────────────────────────────────────────────────────┐
│ Layer 2: Permission Boundaries (Account-level)           │
│ All Boundary-* policies DENY:                            │
│  - Creating org-* roles                                  │
│  - Modifying org-* roles                                 │
│  - Creating/modifying Boundary-* policies                │
│  - Removing permission boundaries                        │
│  - Billing/payment modifications                         │
│  - Security service tampering (CloudTrail, Config, etc.) │
│  - Identity Center/SSO changes                           │
│  - Marketplace subscriptions                             │
└──────────────────────────────────────────────────────────┘
                            ↓
┌──────────────────────────────────────────────────────────┐
│ Result: Workload IAM Roles                               │
│ Can perform work, but cannot escalate privileges         │
│ Cannot tamper with security/audit infrastructure         │
└──────────────────────────────────────────────────────────┘
```

**Why Both Layers?**

- **SCP alone**: Could be bypassed by creating custom permissive boundaries
- **Boundaries alone**: Could be bypassed by creating roles without boundaries
- **Together**: Closes all privilege escalation paths

### Security Controls in Boundary-Default

The `Boundary-Default` policy implements comprehensive security controls beyond just IAM protection:

#### **IAM Protection (Privilege Escalation Prevention)**
- ✅ Deny creation of `org-*` protected roles
- ✅ Deny modification of `org-*` protected roles
- ✅ Deny creation/modification of `Boundary-*` policies
- ✅ Deny removal of permission boundaries from any role
- ✅ Require boundary on all new role creation

#### **Audit & Compliance Protection**
- ✅ **CloudTrail**: Prevent disabling, deletion, or modification of audit trails
- ✅ **Config**: Prevent deletion or stopping of configuration recorders
- ✅ **Infrastructure Logs**: Protect AFT and org-prefixed CloudWatch log groups from deletion

#### **Security Service Protection**
- ✅ **GuardDuty**: Prevent detector deletion or disassociation
- ✅ **Security Hub**: Prevent disabling or disassociation
- ✅ **Access Analyzer**: Prevent analyzer deletion

#### **Identity & Access Protection**
- ✅ **SSO/Identity Center**: Block all SSO, SSO-Directory, and IdentityStore modifications

#### **Cost Control**
- ✅ **Billing**: Prevent modifications to account, billing settings, and payment methods
- ✅ **Marketplace**: Block marketplace subscriptions/unsubscriptions

These controls create a **defense-in-depth** security posture where even roles with AdministratorAccess cannot tamper with core security, audit, or identity infrastructure.

### How Permission Boundaries Work

Permission boundaries set the **maximum permissions** an IAM entity can have. AWS evaluates permissions as:

```
Effective Permissions = (Identity-based Policy) AND (Permission Boundary) AND Session Policy
```

![Evaluation of a session policy, permissions boundary, and identity-based policy](https://docs.aws.amazon.com/images/IAM/latest/UserGuide/images/EffectivePermissions-session-boundary-id.png)

**Example:**

```
Identity Policy: Allow *:* (AdministratorAccess)
Boundary:        Allow s3:*, ec2:*, lambda:*
Result:          Can only use S3, EC2, Lambda
```

**Critical Rules:**

1. **Intersection Model**: Both policies must allow the action
2. **Explicit Deny Always Wins**: A Deny in either policy blocks the action
3. **Implicit Deny**: Actions not in the boundary's Allow list are implicitly denied

### Design Patterns

#### Boundary-Default: Deny-by-Exception Pattern

**Use Case**: Works with broad identity policies (e.g., AdministratorAccess)

**Structure**: Broad Allow (`*:*`) plus targeted Deny statements

```json
{
  "Statement": [
    {"Sid": "AllowAllServices", "Effect": "Allow", "Action": "*", "Resource": "*"},
    {"Effect": "Deny", "Action": "iam:CreateRole", "Resource": "org-*"},
    {"Effect": "Deny", "Action": "iam:DeleteRolePermissionsBoundary"}
  ]
}
```

**Logic**:

- Boundary allows all actions broadly
- Deny statements block specific dangerous actions
- Result: Administrator MINUS protected operations

**When to Use**:

- Automation roles needing broad permissions
- Platform engineering teams
- CI/CD pipelines
- Application teams with full service access

#### Boundary-ReadOnly: Allow-Only Pattern

**Use Case**: Restrictive read-only access

**Structure**: Primarily Allow statements with targeted Denies

```json
{
  "Statement": [
    {"Effect": "Allow", "Action": ["s3:List*", "s3:Get*"], "Resource": "*"},
    {"Effect": "Deny", "Action": "s3:GetObject*", "Resource": "arn:aws:s3:::*/*"}
  ]
}
```

**Logic**:

- Boundary explicitly lists allowed actions
- Everything else is implicitly denied
- Explicit Denies override resource-based policies

**When to Use**:

- Security audit roles
- Compliance reporting
- Read-only dashboards
- External consultants

### Protected Namespaces

**`/org/` Path**: Infrastructure and governance resources

- All boundary policies deployed to `/org/` path
- All deployment roles deployed to `/org/` path
- Makes it easy to identify and protect organizational infrastructure
- Clear separation between org-managed and workload resources

**`org-*` Roles**: Privileged roles exempt from boundary requirements

- Created only by core deployment mechanisms
- Have special SCP exceptions
- Cannot be created/modified by bounded roles
- ARN pattern: `arn:aws:iam::ACCOUNT:role/org/org-*`

**`Boundary-*` Policies**: Permission boundary policies

- Cannot be created by bounded roles
- Cannot be modified by bounded roles
- Self-protecting governance controls
- ARN pattern: `arn:aws:iam::ACCOUNT:policy/org/Boundary-*`

---

## User Guide: Adding Permission Boundaries

### Prerequisites

- Understanding of IAM policies and JSON
- Understanding of permission boundary intersection model
- Access to modify this repository
- Terraform 1.0+ installed locally for testing

### Creating a New Boundary

**Step 1: Create the Policy File**

Create a new JSON file in `baseline/terraform/boundary-policies/`:

```bash
cd baseline/terraform/boundary-policies/
touch DataScience.json
```

**File naming convention**: `<Name>.json`

- The filename (without `.json`) is combined with the `boundary_policy_prefix` variable to form the IAM policy name
- Example: `DataScience.json` → IAM policy `Boundary-DataScience`
- Do NOT include the `Boundary-` prefix in the filename (it's added automatically)
- Use PascalCase for readability

**Step 2: Define Your Policy**

Choose your pattern based on use case:

**For broad permissions with exceptions** (like Boundary-Default):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyDangerousActions",
      "Effect": "Deny",
      "Action": ["service:DangerousAction"],
      "Resource": "*"
    }
  ]
}
```

**For restrictive allow-list** (like Boundary-ReadOnly):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowSpecificActions",
      "Effect": "Allow",
      "Action": ["service:SafeAction*"],
      "Resource": "*"
    },
    {
      "Sid": "DenyResourceBasedPolicyBypass",
      "Effect": "Deny",
      "Action": ["service:SensitiveAction"],
      "Resource": "*"
    }
  ]
}
```

### Boundary Policy Template Structure

All boundary policies should include protection for governance controls. Add these statements to your policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "YourCustomStatements",
      "Effect": "Allow or Deny",
      "Action": ["your:actions"],
      "Resource": "*"
    },
    {
      "Sid": "DenyCreateProtectedRoles",
      "Effect": "Deny",
      "Action": [
        "iam:CreateRole",
        "iam:PutRolePolicy",
        "iam:AttachRolePolicy"
      ],
      "Resource": "arn:aws:iam::${account_id}:role/${protected_role_prefix}"
    },
    {
      "Sid": "DenyModifyProtectedRoles",
      "Effect": "Deny",
      "Action": [
        "iam:UpdateRole",
        "iam:UpdateRoleDescription",
        "iam:UpdateAssumeRolePolicy",
        "iam:DeleteRole",
        "iam:DeleteRolePolicy",
        "iam:DetachRolePolicy",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:PutRolePermissionsBoundary",
        "iam:DeleteRolePermissionsBoundary"
      ],
      "Resource": "arn:aws:iam::${account_id}:role/${protected_role_prefix}"
    },
    {
      "Sid": "DenyCreatePermissionBoundaryPolicies",
      "Effect": "Deny",
      "Action": ["iam:CreatePolicy"],
      "Resource": "arn:aws:iam::${account_id}:policy/${boundary_policy_prefix}"
    },
    {
      "Sid": "DenyModifyAnyBoundaryPolicy",
      "Effect": "Deny",
      "Action": [
        "iam:CreatePolicyVersion",
        "iam:DeletePolicy",
        "iam:DeletePolicyVersion",
        "iam:SetDefaultPolicyVersion"
      ],
      "Resource": "arn:aws:iam::${account_id}:policy/${boundary_policy_prefix}"
    },
    {
      "Sid": "DenyRemovingBoundaries",
      "Effect": "Deny",
      "Action": ["iam:DeleteRolePermissionsBoundary"],
      "Resource": "arn:aws:iam::${account_id}:role/*"
    }
  ]
}
```

**Note**: For deny-by-exception boundaries (like Boundary-Default), you may also want to include:

```json
{
  "Sid": "RequireBoundaryOnRoleCreation",
  "Effect": "Deny",
  "Action": [
    "iam:CreateRole",
    "iam:PutRolePermissionsBoundary"
  ],
  "Resource": "arn:aws:iam::${account_id}:role/*",
  "Condition": {
    "StringNotEquals": {
      "iam:PermissionsBoundary": "arn:aws:iam::${account_id}:policy/${boundary_name}"
    }
  }
}
```

### Available Template Variables

Your policy JSON can use these template variables:

| Variable | Description | Example Value |
|----------|-------------|---------------|
| `${account_id}` | AWS Account ID where boundary is deployed | `123456789012` |
| `${protected_role_prefix}` | Protected role prefix pattern | `org-*` |
| `${boundary_policy_prefix}` | Boundary policy prefix pattern | `Boundary-*` |
| `${boundary_name}` | Name of THIS specific boundary (filename without `.json`) | `DataScience` |

**Usage Example:**

```json
{
  "Resource": "arn:aws:iam::${account_id}:role/${protected_role_prefix}"
}
```

Becomes:

```json
{
  "Resource": "arn:aws:iam::123456789012:role/org-*"
}
```

### Testing Your Boundary

**Step 1: Validate Terraform**

```bash
cd baseline/terraform/
terraform init
terraform validate
```

**Step 2: Check Policy Discovery**

```bash
terraform plan
```

Look for your new boundary in the plan output:

```
# aws_iam_policy.boundaries["DataScience"] will be created
```

**Step 3: Test Policy Logic**

Use AWS IAM Policy Simulator or create a test account:

```bash
# After applying to a test account
aws iam simulate-custom-policy \
  --policy-input-list file://boundary-policies/DataScience.json \
  --action-names iam:CreateRole \
  --resource-arns "arn:aws:iam::123456789012:role/org-test-role"
```

### Deployment

**Automatic Deployment:**

Once your boundary policy file is committed to the repository:

1. AFT pipeline detects the change
2. Terraform applies the baseline module to affected accounts
3. New boundary policy is created in each account
4. Available immediately for use

**Manual Testing:**

```bash
cd baseline/terraform/
terraform plan
terraform apply
```

**Verification:**

```bash
# List all boundaries created
terraform output boundary_policy_names

# Get ARN of your new boundary
terraform output boundary_policy_arns
```

---

## Developer Guide: Maintaining the Code

### File Structure

```
baseline/terraform/
├── boundary-policies/              # Policy template directory
│   ├── Default.json                # Deny-by-exception pattern
│   └── ReadOnly.json               # Allow-only pattern
├── iam-permission-boundaries.tf    # Main Terraform resource
├── iam-deployment-roles.tf         # Deployment roles resource
├── locals.tf                       # Common tags and configuration
├── variables.tf                    # Configuration variables
├── outputs.tf                      # Output values
└── data.tf                         # Data sources
```

### How the Terraform Works

**High-Level Flow:**

```
1. fileset() discovers all .json files in boundary-policies/
2. for_each creates one aws_iam_policy per file
3. templatefile() injects variables into each JSON template
4. Policies are created with standardized tags
5. Outputs provide maps of all created resources
```

**Code Walkthrough:**

```hcl
# Step 1: Discover policy files
locals {
  boundary_policy_files = fileset("${path.module}/boundary-policies", "*.json")
  
  # Step 2: Create map of name -> filename
  boundary_policies = {
    for file in local.boundary_policy_files :
    trimsuffix(file, ".json") => file
  }
}

# Step 3: Create IAM policies
resource "aws_iam_policy" "boundaries" {
  for_each = local.boundary_policies  # Iterate over discovered files
  
  name = "${var.boundary_policy_prefix}-${each.key}"  # e.g., "Boundary-Default"
  
  # Step 4: Inject variables into template
  policy = templatefile(
    "${path.module}/boundary-policies/${each.value}",
    merge(
      local.template_vars,
      {
        boundary_name = each.key
      }
    )
  )
  
  # Step 5: Apply standardized tags
  tags = merge(
    local.common_tags,          # ManagedBy, AFTCustomization
    local.boundary_tags,        # Purpose, Protection
    {
      BoundaryName = each.key   # Boundary-specific identifier
    }
  )
}
```

### Tag Management

**Externalized Tags** (defined in `locals.tf`):

```hcl
locals {
  # Common tags applied to all resources in this baseline
  common_tags = {
    ManagedBy        = "AFT"
    AFTCustomization = "Baseline"
  }
  
  # Tags specific to IAM Permission Boundaries
  boundary_tags = {
    Purpose    = "PermissionBoundary"
    Protection = "PrivilegeEscalationPrevention"
  }
}
```

**Tag Merging Pattern:**

```hcl
tags = merge(
  local.common_tags,      # Standard across all baseline resources
  local.boundary_tags,    # Specific to permission boundaries
  {
    BoundaryName = each.key  # Resource-specific tags
  }
)
```

This pattern ensures:
- Consistent tagging across all baseline resources
- Easy updates to common tags in one place
- Clear separation between common, resource-type, and resource-specific tags

### Key Terraform Resources

**`locals.boundary_policy_files`**

- Type: Set of strings
- Purpose: List of all `.json` files in boundary-policies/
- Example: `["Default.json", "ReadOnly.json"]`

**`locals.boundary_policies`**

- Type: Map of string to string
- Purpose: Maps policy name to filename
- Example: `{ "Default" = "Default.json", "ReadOnly" = "ReadOnly.json" }`

**`aws_iam_policy.boundaries`**

- Type: Map of IAM policy resources
- Purpose: Creates one policy per discovered file
- Access: `aws_iam_policy.boundaries["Default"]`

### Template Variable Injection

**Template Processing:**

```hcl
policy = templatefile(
  "boundary-policies/Default.json",
  {
    account_id             = "123456789012",
    protected_role_prefix  = "org",
    boundary_policy_prefix = "Boundary",
    boundary_name          = "Default"
  }
)
```

**Before (Template):**

```json
{
  "Resource": "arn:aws:iam::${account_id}:role/${protected_role_prefix}"
}
```

**After (Rendered):**

```json
{
  "Resource": "arn:aws:iam::123456789012:role/org-*"
}
```

### Adding New Template Variables

**Step 1: Define Variable in variables.tf**

```hcl
variable "data_classification_tag" {
  description = "Required tag for data classification"
  type        = string
  default     = "DataClassification"
}
```

**Step 2: Add to local.template_vars**

```hcl
locals {
  template_vars = {
    account_id              = data.aws_caller_identity.current.account_id
    protected_role_prefix   = var.protected_role_prefix
    boundary_policy_prefix  = var.boundary_policy_prefix
    data_classification_tag = var.data_classification_tag  # NEW
  }
}
```

**Step 3: Update templatefile() call**

```hcl
policy = templatefile(
  "${path.module}/boundary-policies/${each.value}",
  merge(
    local.template_vars,
    {
      boundary_name = each.key
    }
  )
)
```

**Step 4: Use in Policy Templates**

```json
{
  "Condition": {
    "StringEquals": {
      "aws:RequestTag/${data_classification_tag}": "Confidential"
    }
  }
}
```

### Modifying Existing Boundaries

**⚠️ CAUTION**: Modifying existing boundaries affects all accounts using them.

**Safe Modification Process:**

1. **Test in non-production first**

   ```bash
   # Deploy to dev account manually
   terraform apply -target=aws_iam_policy.boundaries["Boundary-YourPolicy"]
   ```

2. **Check for breaking changes**
   - Are you removing Allow statements? (breaks existing roles)
   - Are you adding Deny statements? (may break existing workflows)
   - Use IAM Policy Simulator to test impact

3. **Version control**
   - Commit changes with clear description
   - Tag releases: `git tag -a v1.1.0 -m "Add S3 access to Boundary-Default"`

4. **Rollback plan**
   - Keep previous policy version in git history
   - Document how to revert: `git revert <commit-hash>`

**Policy Change Impact:**

| Change Type | Impact | Risk |
|-------------|--------|------|
| Add Allow statements | Expands permissions | Low |
| Add Deny statements | Restricts permissions | High - may break workflows |
| Remove Allow statements | Restricts permissions | High - breaks existing roles |
| Remove Deny statements | Expands permissions | Medium - security review needed |

### Troubleshooting

**Issue: Policy not discovered**

```bash
# Check file is in correct directory
ls -la baseline/terraform/boundary-policies/

# Verify filename pattern
# Must be: <Name>.json (without Boundary- prefix)
```

**Issue: Template variable not substituting**

```bash
# Check variable is defined in template_vars
grep "your_variable" baseline/terraform/iam-permission-boundaries.tf

# Validate JSON syntax
cat boundary-policies/Boundary-YourPolicy.json | jq .
```

**Issue: Policy too large (> 6144 characters)**

```bash
# Check policy size
wc -c boundary-policies/Boundary-YourPolicy.json

# Solution: Split into more specific boundaries or use wildcards
```

**Issue: Terraform plan shows unexpected changes**

```bash
# Compare current vs. planned state
terraform show -json | jq '.values.root_module.resources[] | select(.type=="aws_iam_policy")'

# Check for whitespace or formatting changes in JSON
```

**Debug Commands:**

```bash
# List discovered policies
terraform console
> local.boundary_policies

# Check template rendering
terraform console
> templatefile("boundary-policies/Boundary-Default.json", {
    account_id = "123456789012",
    protected_role_prefix = "org-*",
    boundary_policy_prefix = "Boundary-*",
    boundary_name = "Boundary-Default"
  })
```

---

## Reference

### Current Boundaries

| Boundary Name | Pattern | Use Case | Created |
|---------------|---------|----------|---------|
| Boundary-Default | Deny-by-exception | Broad permissions with governance controls | 2026-01-02 |
| Boundary-ReadOnly | Allow-only | Read-only audit/compliance access | 2026-01-02 |

### Outputs

**`boundary_policy_arns`**

- Type: Map of string to string
- Description: Map of boundary names to their ARNs
- Example:

  ```hcl
  {
    "Default"  = "arn:aws:iam::123456789012:policy/org/Boundary-Default"
    "ReadOnly" = "arn:aws:iam::123456789012:policy/org/Boundary-ReadOnly"
  }
  ```

**`boundary_policy_names`**

- Type: List of strings
- Description: List of all boundary policy names
- Example: `["Default", "ReadOnly"]`

**`boundary_policy_ids`**

- Type: Map of string to string
- Description: Map of boundary names to their policy IDs
- Example: `{"Default" = "ANPAI23HZ27SI6FQMGNQ2"}`

**`account_id`**

- Type: String
- Description: AWS Account ID where boundaries were created
- Example: `"123456789012"`

### Variables

**`protected_role_prefix`**

- Type: `string`
- Default: `"org"`
- Description: IAM role prefix protected from creation/modification
- Used in: Policy templates to define protected namespace (appended with `-*` in policy patterns)

**`boundary_policy_prefix`**

- Type: `string`
- Default: `"Boundary"`
- Description: Prefix for permission boundary policies
- Used in: IAM policy naming (`${prefix}-${filename}`) and policy templates to protect boundary policies themselves

---

## External References

### AWS Documentation

- **[Permissions boundaries for IAM entities](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html)** - Official AWS documentation on permission boundaries
- **[When and where to use IAM permissions boundaries](https://aws.amazon.com/blogs/security/when-and-where-to-use-iam-permissions-boundaries/)** - AWS Security Blog post on best practices
- **[Policy evaluation logic](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html)** - How AWS evaluates policies including boundaries
- **[Creating a permissions boundary](https://docs.aws.amazon.com/prescriptive-guidance/latest/transitioning-to-multiple-aws-accounts/creating-a-permissions-boundary.html)** - AWS Prescriptive Guidance on implementation patterns

### Terraform Documentation

- **[AWS Provider: aws_iam_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy)** - Terraform resource documentation
- **[templatefile function](https://developer.hashicorp.com/terraform/language/functions/templatefile)** - Template variable injection
- **[fileset function](https://developer.hashicorp.com/terraform/language/functions/fileset)** - File discovery pattern

### Related Tools

- **[IAM Policy Simulator](https://policysim.aws.amazon.com/)** - Test policy logic before deployment
- **[IAM Access Analyzer](https://docs.aws.amazon.com/IAM/latest/UserGuide/what-is-access-analyzer.html)** - Analyze resource policies and permissions

---

**For questions or issues**: Refer to the [main AFT documentation](../../README.md) or contact the platform team.
