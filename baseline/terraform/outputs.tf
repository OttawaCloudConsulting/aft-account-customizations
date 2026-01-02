output "boundary_policy_arns" {
  description = "Map of boundary policy names to their ARNs"
  value = {
    for name, policy in aws_iam_policy.boundaries :
    name => policy.arn
  }
}

output "boundary_policy_names" {
  description = "List of all boundary policy names created"
  value       = keys(aws_iam_policy.boundaries)
}

output "boundary_policy_ids" {
  description = "Map of boundary policy names to their IDs"
  value = {
    for name, policy in aws_iam_policy.boundaries :
    name => policy.id
  }
}

output "account_id" {
  description = "AWS Account ID where boundaries were created"
  value       = data.aws_caller_identity.current.account_id
}

# Deployment Roles Outputs

output "org_deployment_role_arn" {
  description = "ARN of the platform deployment role for org-automation-broker-role"
  value       = aws_iam_role.org_default_deployment.arn
}

output "org_deployment_role_name" {
  description = "Name of the platform deployment role"
  value       = aws_iam_role.org_default_deployment.name
}

output "application_deployment_role_arn" {
  description = "ARN of the application deployment role for application-automation-broker-role"
  value       = aws_iam_role.application_default_deployment.arn
}

output "application_deployment_role_name" {
  description = "Name of the application deployment role"
  value       = aws_iam_role.application_default_deployment.name
}

output "automation_account_id" {
  description = "AFT automation (management) account ID retrieved from SSM"
  value       = local.automation_account_id
}

output "organization_id" {
  description = "AWS Organization ID for trust policy validation"
  value       = local.organization_id
}
