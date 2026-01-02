output "boundary_default_policy_arn" {
  description = "ARN of the default permission boundary policy"
  value       = aws_iam_policy.boundary_default.arn
}

output "boundary_default_policy_name" {
  description = "Name of the default permission boundary policy"
  value       = aws_iam_policy.boundary_default.name
}

output "boundary_default_policy_id" {
  description = "ID of the default permission boundary policy"
  value       = aws_iam_policy.boundary_default.id
}

output "account_id" {
  description = "AWS Account ID where the boundary was created"
  value       = data.aws_caller_identity.current.account_id
}
