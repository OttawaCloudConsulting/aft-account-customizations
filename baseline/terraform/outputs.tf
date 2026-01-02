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
