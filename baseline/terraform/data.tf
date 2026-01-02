# Data source for current AWS account information
data "aws_caller_identity" "current" {}

# Data source for current AWS region
data "aws_region" "current" {}
