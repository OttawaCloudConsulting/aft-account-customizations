# Baseline IAM - TL;DR

**Quick reference guide for IAM Permission Boundaries and Deployment Roles**

- [Baseline IAM - TL;DR](#baseline-iam---tldr)
  - [Permission Boundaries](#permission-boundaries)
  - [Deployment Roles](#deployment-roles)
  - [Quick Decision Matrix](#quick-decision-matrix)
  - [Architecture Overview](#architecture-overview)


---

## Permission Boundaries

**What**: IAM policies that set maximum permissions for roles, preventing privilege escalation

**Why**: Prevents users/roles with admin access from creating unlimited privileged roles

**Key Files**:

- `baseline/terraform/iam-permission-boundaries.tf` - Main Terraform resource
- `baseline/terraform/boundary-policies/*.json` - Policy templates

**Current Boundaries**:

| Name | Type | Use Case |
|------|------|----------|
| **Boundary-Default** | Deny-by-exception | Works with AdministratorAccess - denies specific dangerous actions |
| **Boundary-ReadOnly** | Allow-only | Read-only audit access - explicitly allows Get/List/Describe actions |

**Protection Model**:

```
SCP (Organization) → Requires Boundary-* on all roles (except org-*)
         +
Boundary Policies  → Deny creating org-* roles, modifying Boundary-* policies
         =
No privilege escalation possible
```

**What You CANNOT Do** (with Boundary-Default):

- ❌ Create roles with `org-*` prefix
- ❌ Create roles without permission boundaries
- ❌ Modify or delete `org-*` roles
- ❌ Create or modify `Boundary-*` policies
- ❌ Remove permission boundaries from roles

**Adding a New Boundary**:

1. Drop `YourName.json` file in `boundary-policies/` directory (prefix added automatically)
2. Include governance protection statements (see full docs)
3. Terraform automatically discovers and creates it
4. No code changes needed

**Template Variables Available**:

- `${account_id}` - AWS Account ID
- `${protected_role_prefix}` - Usually `org-*`
- `${boundary_policy_prefix}` - Usually `Boundary-*`
- `${boundary_name}` - Name of this specific boundary

**Tags** (from `locals.tf`):

```hcl
common_tags          # ManagedBy, AFTCustomization
boundary_tags        # Purpose, Protection
```

**Full Documentation**: [iam-permission-boundaries.md](iam-permission-boundaries.md)

---

## Deployment Roles

**What**: Cross-account IAM roles allowing AFT automation account to deploy infrastructure

**Why**: Secure, auditable automation without hardcoded credentials

**Key Files**:

- `baseline/terraform/iam-deployment-roles.tf` - Role definitions
- `baseline/terraform/locals.tf` - Common tags

**Current Roles**:

| Role Name | Trusted By | Boundary | Purpose |
|-----------|-----------|----------|---------|
| **org-default-deployment-role** | `org-automation-broker-role`, `CodeBuild-*-ServiceRole` | Boundary-Default | Platform infrastructure |
| **application-default-deployment-role** | `application-automation-broker-role-{account-id}`, `CodeBuild-*-ServiceRole` | Boundary-Default | Application workloads |

**Trust Model** (two patterns):

```
Broker Pattern:    Broker Role → Deployment Role → Deploy infrastructure
Direct Pattern:    CodeBuild-*-ServiceRole → Deployment Role → Deploy infrastructure
Both require:      PrincipalOrgID + PrincipalArn match
Permissions:       AdministratorAccess + Boundary-Default
```

**Key Features**:

- ✅ **Native AFT Integration** - Retrieves automation account ID from SSM: `/aft/account/aft-management/account-id`
- ✅ **Organization Boundary** - Trust policies require `aws:PrincipalOrgID` match
- ✅ **Permission Boundaries** - Both roles use `Boundary-Default` to prevent escalation
- ✅ **Session Limits** - 12-hour maximum session duration

**Assuming a Role** (from automation account):

```bash
# Platform deployments
aws sts assume-role \
  --role-arn "arn:aws:iam::TARGET_ACCOUNT:role/org-default-deployment-role" \
  --role-session-name "platform-deploy"

# Application deployments
aws sts assume-role \
  --role-arn "arn:aws:iam::TARGET_ACCOUNT:role/application-default-deployment-role" \
  --role-session-name "app-deploy"
```

**What You CAN Do**:

- ✅ Deploy AWS services (EC2, Lambda, S3, RDS, etc.)
- ✅ Create IAM roles with `Boundary-Default` attached
- ✅ Create IAM policies (except `Boundary-*` prefix)
- ✅ Manage infrastructure as code

**What You CANNOT Do**:

- ❌ Create `org-*` roles (protected namespace)
- ❌ Remove permission boundaries
- ❌ Modify `Boundary-*` policies
- ❌ Sessions longer than 12 hours

**Adding a New Deployment Role**:

1. Add `aws_iam_role` resource in `iam-deployment-roles.tf`
2. Define trust policy with automation account principal
3. Include `aws:PrincipalOrgID` condition
4. Attach appropriate boundary (`Boundary-Default` or `Boundary-ReadOnly`)
5. Add outputs to `outputs.tf`

**Tags** (from `locals.tf`):

```hcl
common_tags              # ManagedBy, AFTCustomization
deployment_role_tags     # Purpose, Protection
```

**Full Documentation**: [iam-deployment-roles.md](iam-deployment-roles.md)

---

## Quick Decision Matrix

**Need to add a new role?**

- Read-only access → Use `Boundary-ReadOnly`
- Admin access (controlled) → Use `Boundary-Default`
- Security scanning → Use `Boundary-ReadOnly`
- Platform deployment → Extend existing `org-default-deployment-role` or create new with `org-*` prefix

**Need to add a new boundary?**

- Broad permissions with exceptions → Deny-by-exception pattern (like `Boundary-Default`)
- Restrictive allow-list → Allow-only pattern (like `Boundary-ReadOnly`)
- Always include governance protection statements

**Troubleshooting**:

- Access denied → Check organization ID matches and broker role name
- Boundary not found → Verify `.json` file in `boundary-policies/` directory
- SSM parameter error → Running in wrong account or AFT not deployed
- Session expired → Max 12 hours, re-authenticate

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                 AFT Automation Account                       │
│  ┌────────────────────┐    ┌──────────────────────────┐   │
│  │ org-automation-    │    │ application-automation-  │   │
│  │ broker-role        │    │ broker-role-{account}    │   │
│  └─────────┬──────────┘    └────────────┬─────────────┘   │
│            │    ┌──────────────────────┐ │                  │
│            │    │ CodeBuild-*-         │ │                  │
│            │    │ ServiceRole          │ │                  │
│            │    └──────────┬───────────┘ │                  │
└────────────┼───────────────┼─────────────┼─────────────────┘
             │               │             │
             │ Broker        │ Direct      │ Broker
             ▼               ▼             ▼
┌─────────────────────────────────────────────────────────────┐
│              Target Account (This Baseline)                  │
│  ┌────────────────────┐    ┌──────────────────────────┐   │
│  │ org-default-       │    │ application-default-     │   │
│  │ deployment-role    │    │ deployment-role          │   │
│  │ + Boundary-Default │    │ + Boundary-Default       │   │
│  └─────────┬──────────┘    └────────────┬─────────────┘   │
│            │                             │                  │
│            └─────────────┬───────────────┘                  │
│                          ▼                                  │
│            Deploy Infrastructure                            │
│            (within boundary limits)                         │
│                                                             │
│  Permission Boundaries:                                     │
│  ├─ Boundary-Default (deny-by-exception)                   │
│  └─ Boundary-ReadOnly (allow-only)                         │
└─────────────────────────────────────────────────────────────┘
```

---

**For detailed information**, see the full documentation:

- [Permission Boundaries](iam-permission-boundaries.md) - Complete design, user guide, developer guide
- [Deployment Roles](iam-deployment-roles.md) - Architecture, usage examples, maintenance
