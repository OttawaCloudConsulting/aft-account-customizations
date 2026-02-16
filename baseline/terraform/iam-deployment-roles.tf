# IAM Deployment Roles
# Platform and application deployment roles for automation account
# Trusted by AFT automation account via broker roles with Organization validation

# Get current organization ID for trust policy validation
data "aws_organizations_organization" "current" {}

locals {
  # Automation account ID is extracted from aft_admin_role_arn in locals-aft.tf (generated from Jinja template)
  automation_account_id = local.aft_management_account_id

  # Current organization ID for aws:PrincipalOrgID condition
  organization_id = data.aws_organizations_organization.current.id

  # Common deployment role configuration
  deployment_role_config = {
    max_session_duration = 43200 # 12 hours
    managed_policy_arn   = "arn:aws:iam::aws:policy/AdministratorAccess"
    boundary_policy_name = "Default"
  }
}

# Platform Deployment Role
# Assumed by org-automation-broker-role from automation account
# Used for privileged infrastructure and governance deployments
resource "aws_iam_role" "org_default_deployment" {
  name                 = "${var.protected_role_prefix}-default-deployment-role"
  path                 = "/org/"
  description          = "Platform deployment role for AFT automation account via org-automation-broker-role"
  max_session_duration = local.deployment_role_config.max_session_duration
  permissions_boundary = aws_iam_policy.boundaries[local.deployment_role_config.boundary_policy_name].arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TrustBrokerRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.automation_account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:PrincipalOrgID" = local.organization_id
            "aws:PrincipalArn"   = "arn:aws:iam::${local.automation_account_id}:role/org/${var.protected_role_prefix}-automation-broker-role"
          }
        }
      },
      {
        Sid    = "TrustCodeBuildServiceRoles"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.automation_account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:PrincipalOrgID" = local.organization_id
          }
          StringLike = {
            "aws:PrincipalArn" = "arn:aws:iam::${local.automation_account_id}:role/CodeBuild-*-ServiceRole"
          }
        }
      }
    ]
  })

  tags = merge(
    local.common_tags,
    local.deployment_role_tags,
    {
      RoleType        = "PlatformDeployment"
      TrustedBroker   = "${var.protected_role_prefix}-automation-broker-role"
      DeploymentScope = "Platform"
    }
  )
}

# Attach AdministratorAccess to platform deployment role
resource "aws_iam_role_policy_attachment" "org_default_deployment_admin" {
  role       = aws_iam_role.org_default_deployment.name
  policy_arn = local.deployment_role_config.managed_policy_arn
}

# Application Deployment Role
# Assumed by application-automation-broker-role-${accountid} from automation account
# Used for application workload deployments
resource "aws_iam_role" "application_default_deployment" {
  name                 = "application-default-deployment-role"
  path                 = "/org/"
  description          = "Application deployment role for AFT automation account via application-automation-broker-role"
  max_session_duration = local.deployment_role_config.max_session_duration
  permissions_boundary = aws_iam_policy.boundaries[local.deployment_role_config.boundary_policy_name].arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TrustBrokerRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.automation_account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:PrincipalOrgID" = local.organization_id
            "aws:PrincipalArn"   = "arn:aws:iam::${local.automation_account_id}:role/org/application-automation-broker-role-${data.aws_caller_identity.current.account_id}"
          }
        }
      },
      {
        Sid    = "TrustCodeBuildServiceRoles"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.automation_account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:PrincipalOrgID" = local.organization_id
          }
          StringLike = {
            "aws:PrincipalArn" = "arn:aws:iam::${local.automation_account_id}:role/CodeBuild-*-ServiceRole"
          }
        }
      }
    ]
  })

  tags = merge(
    local.common_tags,
    local.deployment_role_tags,
    {
      RoleType        = "ApplicationDeployment"
      TrustedBroker   = "application-automation-broker-role-${data.aws_caller_identity.current.account_id}"
      DeploymentScope = "Application"
    }
  )
}

# Attach AdministratorAccess to application deployment role
resource "aws_iam_role_policy_attachment" "application_default_deployment_admin" {
  role       = aws_iam_role.application_default_deployment.name
  policy_arn = local.deployment_role_config.managed_policy_arn
}
