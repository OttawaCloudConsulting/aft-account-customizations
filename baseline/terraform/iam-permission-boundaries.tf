# IAM Permission Boundaries
# Dynamically creates permission boundary policies from templates in boundary-policies/
# Each .json file in the directory becomes a separate IAM policy

locals {
  # Discover all policy template files in the boundary-policies directory
  boundary_policy_files = fileset("${path.module}/boundary-policies", "*.json")
  
  # Create a map of policy name to file path
  boundary_policies = {
    for file in local.boundary_policy_files :
    # Use filename without extension as the policy name
    trimsuffix(file, ".json") => file
  }
  
  # Common template variables for all boundary policies
  template_vars = {
    account_id              = data.aws_caller_identity.current.account_id
    protected_role_prefix   = var.protected_role_prefix
    boundary_policy_prefix  = var.boundary_policy_prefix
  }
}

# Create IAM policies for each boundary template
resource "aws_iam_policy" "boundaries" {
  for_each = local.boundary_policies
  
  name        = each.key
  description = "Permission boundary preventing privilege escalation to ${var.protected_role_prefix} roles"
  
  policy = templatefile(
    "${path.module}/boundary-policies/${each.value}",
    merge(
      local.template_vars,
      {
        # Boundary-specific variable for self-reference in conditions
        boundary_name = each.key
      }
    )
  )
  
  tags = merge(
    local.common_tags,
    local.boundary_tags,
    {
      BoundaryName = each.key
    }
  )
}
