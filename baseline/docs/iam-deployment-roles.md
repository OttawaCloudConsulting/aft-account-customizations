# IAM Deployment Roles

**Module Component**: Baseline Account Customizations  
**Purpose**: Platform and application deployment roles for AFT automation account  
**Last Updated**: January 2, 2026

---

## Table of Contents

- [IAM Deployment Roles](#iam-deployment-roles)
  - [Table of Contents](#table-of-contents)
  - [Design Overview](#design-overview)
    - [Architecture](#architecture)
    - [Role Separation Strategy](#role-separation-strategy)
    - [Trust Policy Design](#trust-policy-design)
    - [Integration with AFT](#integration-with-aft)
  - [User Guide: Using Deployment Roles](#user-guide-using-deployment-roles)
    - [Prerequisites](#prerequisites)
    - [Assuming the Platform Deployment Role](#assuming-the-platform-deployment-role)
    - [Assuming the Application Deployment Role](#assuming-the-application-deployment-role)
    - [Understanding Session Limits](#understanding-session-limits)
    - [Understanding Permission Boundaries](#understanding-permission-boundaries)
    - [Troubleshooting Access Issues](#troubleshooting-access-issues)
  - [Developer Guide: Maintaining the Code](#developer-guide-maintaining-the-code)
    - [File Structure](#file-structure)
    - [How the Terraform Works](#how-the-terraform-works)
    - [Key Terraform Resources](#key-terraform-resources)
    - [Data Sources](#data-sources)
    - [Adding New Deployment Roles](#adding-new-deployment-roles)
    - [Modifying Existing Roles](#modifying-existing-roles)
    - [Tag Management](#tag-management)
    - [Troubleshooting](#troubleshooting)
  - [Reference](#reference)
    - [Current Deployment Roles](#current-deployment-roles)
    - [Outputs](#outputs)
    - [Variables](#variables)
  - [External References](#external-references)
    - [AWS Documentation](#aws-documentation)
    - [AFT Documentation](#aft-documentation)
    - [Related Documentation](#related-documentation)

---

## Design Overview

### Architecture

The IAM Deployment Roles implementation provides secure cross-account access from the AFT automation account to target accounts for infrastructure and application deployments.

**Key Design Principles:**

1. **Native AFT Integration**: Uses SSM Parameter Store for automation account ID discovery
2. **Organization Boundary**: Trust policies enforce organization membership
3. **Privilege Escalation Prevention**: All roles protected by permission boundaries
4. **Role Separation**: Platform vs. application deployment concerns
5. **Session Time Limits**: 2-hour maximum to limit exposure

### Role Separation Strategy

```
AFT Automation Account
│
├─ org-automation-broker-role
│  └─> Assumes: org-default-deployment-role (Platform)
│     ├─ Infrastructure deployments
│     ├─ Governance configurations
│     └─ Privileged operations
│
└─ application-automation-broker-role-{account-id}
   └─> Assumes: application-default-deployment-role (Application)
      ├─ Application workload deployments
      ├─ Service configurations
      └─ Application-scoped operations
```

**Why Separate Roles?**

- **Blast radius control**: Platform changes isolated from application changes
- **Audit clarity**: Separate CloudTrail logs by deployment type
- **Permission refinement**: Future ability to restrict application roles
- **Broker identity**: Different automation workflows use different brokers

### Trust Policy Design

**Dual-Condition Validation Pattern:**

The trust policies use a combination of organization validation and specific role ARN matching to ensure secure, flexible cross-account access:

```hcl
Principal = {
  AWS = "arn:aws:iam::${automation_account_id}:root"
}
Condition = {
  StringEquals = {
    "aws:PrincipalOrgID" = organization_id
    "aws:PrincipalArn"   = "arn:aws:iam::${automation_account_id}:role/org-automation-broker-role"
  }
}
```

**Why Use Root Principal with PrincipalArn Condition?**

1. **Decoupled Creation Order**: Roles can be created even if broker roles don't exist yet
2. **Runtime Validation**: AWS validates the specific role ARN at assume-role time, not at role creation
3. **Organization Boundary**: Still enforces organization membership via `PrincipalOrgID`
4. **Specific Role Restriction**: Only the exact broker role can assume, not any role in the account

**Benefits:**

- Prevents cross-organization role assumption
- Works with AWS Organizations moving accounts
- No hardcoded account ID lists to maintain
- Allows flexible deployment ordering (target account roles before automation broker roles)
- Combines account-level trust with role-specific restrictions
- Leverages AWS Organizations as authority

**Role Naming Convention:**

- Platform roles: `org-*` prefix (protected namespace)
- Application roles: `application-*` prefix (workload namespace)

### Integration with AFT

**Native SSM Parameter Discovery:**

```hcl
data "aws_ssm_parameter" "aft_management_account_id" {
  name = "/aft/account/aft-management/account-id"
}
```

**AFT automatically populates:**

- `/aft/account/aft-management/account-id` - Automation account ID
- `/aft/account/ct-management/account-id` - Control Tower management
- `/aft/account/audit/account-id` - Audit account
- `/aft/account/log-archive/account-id` - Log Archive account

**No manual configuration required** - AFT maintains these parameters during deployment.

---

## User Guide: Using Deployment Roles

### Prerequisites

- Access to AFT automation account
- Appropriate broker role in automation account:
  - `org-automation-broker-role` for platform deployments
  - `application-automation-broker-role-{account-id}` for application deployments
- AWS CLI or SDK configured
- Valid session in automation account

### Assuming the Platform Deployment Role

**From AWS CLI:**

```bash
# Set target account ID
TARGET_ACCOUNT_ID="123456789012"

# Assume the platform deployment role
aws sts assume-role \
  --role-arn "arn:aws:iam::${TARGET_ACCOUNT_ID}:role/org-default-deployment-role" \
  --role-session-name "platform-deployment-$(date +%s)" \
  --duration-seconds 7200
```

**From Terraform:**

```hcl
provider "aws" {
  alias  = "target_account"
  region = "us-east-1"
  
  assume_role {
    role_arn     = "arn:aws:iam::${var.target_account_id}:role/org-default-deployment-role"
    session_name = "terraform-platform-deployment"
  }
}
```

**Use Cases:**

- VPC and networking infrastructure
- IAM roles and policies (within boundary limits)
- AWS Config and compliance resources
- Security Hub configurations
- Organization-level integrations

### Assuming the Application Deployment Role

**From AWS CLI:**

```bash
# Set target account ID
TARGET_ACCOUNT_ID="123456789012"

# Assume the application deployment role
aws sts assume-role \
  --role-arn "arn:aws:iam::${TARGET_ACCOUNT_ID}:role/application-default-deployment-role" \
  --role-session-name "app-deployment-$(date +%s)" \
  --duration-seconds 7200
```

**From GitHub Actions:**

```yaml
- name: Configure AWS Credentials
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::${{ vars.TARGET_ACCOUNT_ID }}:role/application-default-deployment-role
    role-session-name: github-actions-deployment
    aws-region: us-east-1
```

**Use Cases:**

- Lambda functions, containers, compute resources
- Application databases (RDS, DynamoDB)
- API Gateway, load balancers
- S3 buckets, CloudFront distributions
- Application-specific configurations

### Understanding Session Limits

**Maximum Session Duration: 2 hours (7200 seconds)**

**Implications:**

- Long-running deployments must handle session refresh
- CI/CD pipelines should complete within 2 hours
- Use pagination for large Terraform applies
- Consider splitting very large deployments

**Best Practices:**

```bash
# Set explicit duration (max 7200 seconds)
aws sts assume-role \
  --duration-seconds 3600 \  # 1 hour for quick deployments
  --role-arn "..."
  
# For Terraform, use shorter refresh intervals
provider "aws" {
  assume_role {
    duration = "1h"  # Terraform refreshes automatically
  }
}
```

### Understanding Permission Boundaries

Both deployment roles have the `Boundary-Default` permission boundary attached.

**What You CAN Do:**

- ✅ Create and manage AWS services (EC2, Lambda, S3, etc.)
- ✅ Create IAM roles with `Boundary-Default` attached
- ✅ Create IAM policies (except `Boundary-*` prefix)
- ✅ Deploy infrastructure as code
- ✅ Configure service integrations

**What You CANNOT Do:**

- ❌ Create roles with `org-*` prefix
- ❌ Create roles without permission boundaries
- ❌ Modify or delete `org-*` roles
- ❌ Create or modify `Boundary-*` policies
- ❌ Remove permission boundaries from roles

**Example - Creating a Role:**

```hcl
# ✅ ALLOWED - Role with boundary attached
resource "aws_iam_role" "app_role" {
  name                 = "my-application-role"
  permissions_boundary = data.aws_iam_policy.boundary_default.arn
  
  assume_role_policy = jsonencode({...})
}

# ❌ DENIED - Role without boundary
resource "aws_iam_role" "bad_role" {
  name = "my-application-role"
  # Missing permissions_boundary - will fail
}

# ❌ DENIED - Role with org-* prefix
resource "aws_iam_role" "protected_role" {
  name                 = "org-special-role"
  permissions_boundary = data.aws_iam_policy.boundary_default.arn
  # Will fail due to org-* prefix protection
}
```

**For complete boundary documentation, see:** [IAM Permission Boundaries](iam-permission-boundaries.md)

### Troubleshooting Access Issues

**Issue: "Access Denied" when assuming role**

```bash
# Check organization ID matches
aws organizations describe-organization

# Verify you're in the automation account
aws sts get-caller-identity

# Confirm broker role name matches
aws iam get-role --role-name org-automation-broker-role
```

**Issue: "Session duration exceeds maximum"**

```bash
# Check role's maximum session duration
aws iam get-role --role-name org-default-deployment-role \
  --query 'Role.MaxSessionDuration'

# Use duration <= 7200 seconds
aws sts assume-role --duration-seconds 7200 ...
```

**Issue: Permission denied for specific actions**

```bash
# Check if action is denied by permission boundary
# See: baseline/terraform/boundary-policies/Boundary-Default.json

# Verify you're not trying to modify org-* resources
# Verify you're attaching boundaries to new roles
```

**Issue: "Cannot find SSM parameter"**

This indicates the code is running in wrong account:

```bash
# Verify running in target account, not automation account
aws sts get-caller-identity

# SSM parameter only exists in AFT management account
# Roles don't read it - Terraform reads it during apply
```

---

## Developer Guide: Maintaining the Code

### File Structure

```
baseline/terraform/
├── iam-deployment-roles.tf         # THIS FILE - Deployment roles
├── iam-permission-boundaries.tf    # Permission boundaries
├── locals.tf                       # Common tags and configuration
├── variables.tf                    # Configuration variables
├── outputs.tf                      # Output values
├── data.tf                         # Data sources
└── boundary-policies/              # Boundary policy templates
    ├── Boundary-Default.json
    └── Boundary-ReadOnly.json
```

**Related Documentation:**

- [IAM Permission Boundaries](iam-permission-boundaries.md) - Boundary design and maintenance
- [IAM Roles Strategy](../../agents/iam-roles-strategy.md) - Role planning decisions

### How the Terraform Works

**High-Level Flow:**

```
1. Retrieve AFT management account ID from SSM
2. Retrieve organization ID from Organizations API
3. Create platform deployment role (org-default-deployment-role)
   ├─ Trust policy: org-automation-broker-role
   ├─ Attach: AdministratorAccess
   ├─ Boundary: Boundary-Default
   └─ Tags: Merged from locals.tf
4. Create application deployment role (application-default-deployment-role)
   ├─ Trust policy: application-automation-broker-role-{account-id}
   ├─ Attach: AdministratorAccess
   ├─ Boundary: Boundary-Default
   └─ Tags: Merged from locals.tf
```

**Code Walkthrough:**

```hcl
# Step 1: Retrieve AFT automation account ID
data "aws_ssm_parameter" "aft_management_account_id" {
  name = "/aft/account/aft-management/account-id"
}

# Step 2: Get organization ID for trust policy
data "aws_organizations_organization" "current" {}

# Step 3: Define locals for reuse
locals {
  automation_account_id = data.aws_ssm_parameter.aft_management_account_id.value
  organization_id       = data.aws_organizations_organization.current.id
  
  deployment_role_config = {
    max_session_duration = 7200
    managed_policy_arn   = "arn:aws:iam::aws:policy/AdministratorAccess"
    boundary_policy_name = "Boundary-Default"
  }
}

# Step 4: Create platform deployment role
resource "aws_iam_role" "org_default_deployment" {
  name                 = "${var.protected_role_prefix}-default-deployment-role"
  max_session_duration = local.deployment_role_config.max_session_duration
  permissions_boundary = aws_iam_policy.boundaries["Boundary-Default"].arn
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = "arn:aws:iam::${local.automation_account_id}:role/org-automation-broker-role"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:PrincipalOrgID" = local.organization_id
        }
      }
    }]
  })
  
  tags = merge(
    local.common_tags,          # ManagedBy, AFTCustomization
    local.deployment_role_tags, # Purpose, Protection
    {
      RoleType = "PlatformDeployment"  # Role-specific
    }
  )
}
```

### Key Terraform Resources

**`data.aws_ssm_parameter.aft_management_account_id`**

- **Purpose**: Retrieve AFT automation account ID from SSM
- **Parameter Path**: `/aft/account/aft-management/account-id`
- **Populated By**: AFT during initial deployment
- **Access**: `data.aws_ssm_parameter.aft_management_account_id.value`

**`data.aws_organizations_organization.current`**

- **Purpose**: Retrieve current organization ID for trust policy
- **API Call**: `organizations:DescribeOrganization`
- **Access**: `data.aws_organizations_organization.current.id`
- **Why**: Enforces organization boundary in trust policies

**`aws_iam_role.org_default_deployment`**

- **Name**: `org-default-deployment-role` (with variable prefix)
- **Purpose**: Platform/infrastructure deployment role
- **Trust**: `org-automation-broker-role` in automation account
- **Permissions**: AdministratorAccess with Boundary-Default
- **Access**: `aws_iam_role.org_default_deployment.arn`

**`aws_iam_role.application_default_deployment`**

- **Name**: `application-default-deployment-role`
- **Purpose**: Application workload deployment role
- **Trust**: `application-automation-broker-role-{account-id}` in automation account
- **Permissions**: AdministratorAccess with Boundary-Default
- **Access**: `aws_iam_role.application_default_deployment.arn`

### Data Sources

**SSM Parameter Retrieval:**

```hcl
data "aws_ssm_parameter" "aft_management_account_id" {
  name = "/aft/account/aft-management/account-id"
}
```

**Requirements:**

- Runs in target account (not automation account)
- Requires `ssm:GetParameter` permission
- Parameter exists in AFT management account
- Populated by AFT, no manual configuration

**Organizations API:**

```hcl
data "aws_organizations_organization" "current" {}
```

**Requirements:**

- Requires `organizations:DescribeOrganization` permission
- Works from any account in the organization
- Returns organization ID for trust policy conditions

### Adding New Deployment Roles

**Step 1: Define the Role Resource**

```hcl
# Add to iam-deployment-roles.tf
resource "aws_iam_role" "security_scanner" {
  name                 = "security-scanner-role"
  description          = "Read-only security scanning role"
  max_session_duration = 3600  # 1 hour for scanners
  
  # Use Boundary-ReadOnly for read-only access
  permissions_boundary = aws_iam_policy.boundaries["Boundary-ReadOnly"].arn
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = "arn:aws:iam::${local.automation_account_id}:role/security-automation-role"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:PrincipalOrgID" = local.organization_id
        }
      }
    }]
  })
  
  tags = merge(
    local.common_tags,
    {
      Purpose    = "SecurityScanning"
      Protection = "ReadOnly"
      RoleType   = "SecurityScanner"
    }
  )
}
```

**Step 2: Attach Appropriate Policies**

```hcl
# Read-only policy for security scanning
resource "aws_iam_role_policy_attachment" "security_scanner_readonly" {
  role       = aws_iam_role.security_scanner.name
  policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}
```

**Step 3: Add Outputs**

```hcl
# Add to outputs.tf
output "security_scanner_role_arn" {
  description = "ARN of the security scanner role"
  value       = aws_iam_role.security_scanner.arn
}
```

**Step 4: Validate**

```bash
cd baseline/terraform
terraform validate
terraform plan
```

### Modifying Existing Roles

**⚠️ CAUTION**: Changes affect all accounts using this baseline.

**Safe Modifications:**

```hcl
# ✅ Adding tags - low risk
tags = merge(
  local.common_tags,
  local.deployment_role_tags,
  {
    Environment = "Production"  # New tag
  }
)

# ✅ Adjusting session duration - document reason
max_session_duration = 3600  # Reduced from 7200

# ✅ Adding conditions to trust policy
Condition = {
  StringEquals = {
    "aws:PrincipalOrgID" = local.organization_id
  }
  IpAddress = {
    "aws:SourceIp" = var.allowed_cidr_blocks  # Add IP restriction
  }
}
```

**High-Risk Modifications:**

```hcl
# ⚠️ Changing boundary - test thoroughly
permissions_boundary = aws_iam_policy.boundaries["Boundary-ReadOnly"].arn
# Impact: Restricts permissions dramatically, may break deployments

# ⚠️ Changing trust policy principal
Principal = {
  AWS = "arn:aws:iam::${local.automation_account_id}:role/new-broker-role"
}
# Impact: Existing automation will fail until updated

# ⚠️ Removing organization condition
# Don't do this - removes security control
```

**Modification Checklist:**

1. ✅ Test in non-production account first
2. ✅ Document change reason in commit message
3. ✅ Check for breaking changes with `terraform plan`
4. ✅ Update this documentation if behavior changes
5. ✅ Communicate changes to automation teams
6. ✅ Have rollback plan ready

### Tag Management

**Externalized Tags** (defined in `locals.tf`):

```hcl
locals {
  # Common tags applied to all resources in this baseline
  common_tags = {
    ManagedBy        = "AFT"
    AFTCustomization = "Baseline"
  }
  
  # Tags specific to IAM Deployment Roles
  deployment_role_tags = {
    Purpose    = "DeploymentAutomation"
    Protection = "PermissionBoundary"
  }
}
```

**Tag Merging Pattern:**

```hcl
tags = merge(
  local.common_tags,           # Standard across all baseline resources
  local.deployment_role_tags,  # Specific to deployment roles
  {
    RoleType        = "PlatformDeployment"  # Role-specific tags
    TrustedBroker   = "org-automation-broker-role"
    DeploymentScope = "Platform"
  }
)
```

**Benefits:**

- ✅ Single source of truth for common tags
- ✅ Easy to update tags globally
- ✅ Clear separation between common, type-specific, and resource-specific tags
- ✅ Consistent with permission boundary tagging

**Modifying Common Tags:**

```hcl
# Edit baseline/terraform/locals.tf
locals {
  common_tags = {
    ManagedBy        = "AFT"
    AFTCustomization = "Baseline"
    CostCenter       = "Platform"  # NEW - applies to all resources
  }
}
```

### Troubleshooting

**Issue: SSM parameter not found**

```
Error: reading SSM Parameter (/aft/account/aft-management/account-id): ParameterNotFound
```

**Causes:**

- Running in non-AFT environment
- AFT not fully deployed yet
- Wrong AWS region

**Solution:**

```bash
# Verify AFT is deployed
aws ssm get-parameter \
  --name /aft/account/aft-management/account-id \
  --region <aft-region>

# Check if running in correct account
aws sts get-caller-identity
```

**Issue: Organization ID access denied**

```
Error: describing Organization: AccessDenied
```

**Causes:**

- Missing `organizations:DescribeOrganization` permission
- Running from non-member account

**Solution:**

```bash
# Verify organizations permission
aws organizations describe-organization

# Add permission to execution role if needed
```

**Issue: Boundary policy not found**

```
Error: aws_iam_policy.boundaries["Boundary-Default"] is empty map
```

**Causes:**

- Permission boundaries not deployed yet
- Dependency ordering issue

**Solution:**

```hcl
# Verify dependency exists
depends_on = [
  aws_iam_policy.boundaries
]

# Or ensure boundaries are deployed first
terraform apply -target=aws_iam_policy.boundaries
```

**Issue: Trust policy validation failed**

```
Error: MalformedPolicyDocument: Invalid principal
```

**Causes:**

- Automation account ID not retrieved correctly
- SSM parameter contains invalid value

**Solution:**

```bash
# Debug the SSM parameter value
terraform console
> data.aws_ssm_parameter.aft_management_account_id.value

# Verify it's a valid 12-digit account ID
```

**Debug Commands:**

```bash
# List all outputs
terraform output

# Check specific data source values
terraform console
> data.aws_ssm_parameter.aft_management_account_id.value
> data.aws_organizations_organization.current.id
> local.automation_account_id

# Validate without applying
terraform validate
terraform plan

# Test role assumption from automation account
aws sts assume-role \
  --role-arn "arn:aws:iam::123456789012:role/org-default-deployment-role" \
  --role-session-name test
```

---

## Reference

### Current Deployment Roles

| Role Name | Trust Principal | Boundary | Session Duration | Purpose |
|-----------|----------------|----------|------------------|---------|
| `org-default-deployment-role` | `org-automation-broker-role` | Boundary-Default | 2 hours | Platform infrastructure |
| `application-default-deployment-role` | `application-automation-broker-role-{account-id}` | Boundary-Default | 2 hours | Application workloads |

### Outputs

**`org_deployment_role_arn`**

- **Type**: String
- **Description**: ARN of the platform deployment role
- **Example**: `arn:aws:iam::123456789012:role/org-default-deployment-role`
- **Usage**: Reference in automation scripts and Terraform

**`org_deployment_role_name`**

- **Type**: String
- **Description**: Name of the platform deployment role
- **Example**: `org-default-deployment-role`

**`application_deployment_role_arn`**

- **Type**: String
- **Description**: ARN of the application deployment role
- **Example**: `arn:aws:iam::123456789012:role/application-default-deployment-role`

**`application_deployment_role_name`**

- **Type**: String
- **Description**: Name of the application deployment role
- **Example**: `application-default-deployment-role`

**`automation_account_id`**

- **Type**: String
- **Description**: AFT automation account ID retrieved from SSM
- **Example**: `987654321098`
- **Source**: `/aft/account/aft-management/account-id`

**`organization_id`**

- **Type**: String
- **Description**: AWS Organization ID for trust policy validation
- **Example**: `o-abc1234567`
- **Source**: `organizations:DescribeOrganization` API

### Variables

**`protected_role_prefix`**

- **Type**: `string`
- **Default**: `"org-*"`
- **Description**: Prefix for protected roles (used in role name)
- **Usage**: Platform deployment role name uses this prefix

---

## External References

### AWS Documentation

- **[IAM Roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html)** - IAM role concepts and usage
- **[AssumeRole API](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html)** - STS AssumeRole reference
- **[Trust Policies](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_terms-and-concepts.html)** - Role trust policy design
- **[AWS Organizations Conditions](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_condition-keys.html#condition-keys-principalorgid)** - PrincipalOrgID documentation

### AFT Documentation

- **[AFT Account Customizations](https://docs.aws.amazon.com/controltower/latest/userguide/aft-account-customization-options.html)** - AFT customization guide
- **[AFT GitHub Repository](https://github.com/aws-ia/terraform-aws-control_tower_account_factory)** - AFT source code and examples

### Related Documentation

- **[IAM Permission Boundaries](iam-permission-boundaries.md)** - Complete boundary documentation
- **[IAM Roles Strategy](../../agents/iam-roles-strategy.md)** - Role planning decisions

---

**For questions or issues**: Refer to the [main AFT documentation](../../README.md) or contact the platform team.
