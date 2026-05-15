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

# ── OIDC Federation locals ───────────────────────────────────────────────────
# Design decisions: #1, #17 in docs/ARCHITECTURE_AND_DESIGN-OIDC.md

locals {
  # Account IDs that receive no OIDC federation by default (security-tier).
  # The AFT management account ID is derived from the injected admin role ARN.
  # Add Audit and Log Archive account IDs here once they are known.
  security_tier_account_ids = toset([
    local.aft_management_account_id,
    # "<AUDIT_ACCOUNT_ID>",
    # "<LOG_ARCHIVE_ACCOUNT_ID>",
  ])

  # True when the current vended account is a security-tier account.
  is_security_tier_account = contains(local.security_tier_account_ids, data.aws_caller_identity.current.account_id)

  # 1 when OIDC federation should be created; 0 when the feature flag is off or the
  # account is a security-tier account and the security-tier opt-in flag is false.
  oidc_provider_count = (var.oidc_federation_enabled && (var.oidc_federation_security_tier_accounts || !local.is_security_tier_account)) ? 1 : 0

  # Tags applied to all OIDC federation resources (provider and roles).
  oidc_federation_tags = merge(local.common_tags, {
    Purpose    = "OIDCFederation"
    Protection = "PermissionBoundary"
    IssuerHost = trimprefix(var.oidc_issuer_url, "https://")
  })

  # True when OIDC resources should be created — compound condition mirroring
  # oidc_provider_count > 0. Used to gate for_each on the federation role resource.
  oidc_federation_enabled = local.oidc_provider_count > 0
}
