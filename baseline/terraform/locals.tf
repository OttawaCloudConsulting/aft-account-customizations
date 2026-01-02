# Common tags and configuration for all baseline resources

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
  
  # Tags specific to IAM Deployment Roles
  deployment_role_tags = {
    Purpose    = "DeploymentAutomation"
    Protection = "PermissionBoundary"
  }
}
