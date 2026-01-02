# Default Permission Boundary Policy
# Provides comprehensive privilege escalation prevention
# See: agents/boundary-default-design.md for full design documentation

resource "aws_iam_policy" "boundary_default" {
  name        = var.boundary_policy_name
  description = "Default permission boundary preventing privilege escalation to ${var.protected_role_prefix} roles"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # 1. Deny Creating Protected Roles
      {
        Sid    = "DenyCreateProtectedRoles"
        Effect = "Deny"
        Action = [
          "iam:CreateRole",
          "iam:PutRolePolicy",
          "iam:AttachRolePolicy"
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.protected_role_prefix}"
      },
      
      # 2. Deny Modifying Protected Roles
      {
        Sid    = "DenyModifyProtectedRoles"
        Effect = "Deny"
        Action = [
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
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.protected_role_prefix}"
      },
      
      # 3. Deny Creating Permission Boundary Policies
      {
        Sid    = "DenyCreatePermissionBoundaryPolicies"
        Effect = "Deny"
        Action = [
          "iam:CreatePolicy"
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.boundary_policy_prefix}"
      },
      
      # 4. Deny Modifying ANY Permission Boundary Policy
      {
        Sid    = "DenyModifyAnyBoundaryPolicy"
        Effect = "Deny"
        Action = [
          "iam:CreatePolicyVersion",
          "iam:DeletePolicy",
          "iam:DeletePolicyVersion",
          "iam:SetDefaultPolicyVersion"
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.boundary_policy_prefix}"
      },
      
      # 5. Deny Removing Permission Boundaries from Roles
      {
        Sid    = "DenyRemovingBoundaries"
        Effect = "Deny"
        Action = [
          "iam:DeleteRolePermissionsBoundary"
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*"
      },
      
      # 6. Require Boundary on New Role Creation
      {
        Sid    = "RequireBoundaryOnRoleCreation"
        Effect = "Deny"
        Action = [
          "iam:CreateRole",
          "iam:PutRolePermissionsBoundary"
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*"
        Condition = {
          StringNotEquals = {
            "iam:PermissionsBoundary" = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.boundary_policy_name}"
          }
        }
      }
    ]
  })

  tags = {
    ManagedBy   = "AFT"
    Purpose     = "PermissionBoundary"
    Protection  = "PrivilegeEscalationPrevention"
    Environment = "Baseline"
  }
}
