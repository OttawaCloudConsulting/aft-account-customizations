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
  # AFT management ID is derived from the injected admin role ARN; Audit and
  # Log Archive IDs come from operator-supplied input variables. compact()
  # drops empty strings so default-empty variables preserve current behavior
  # when the feature flag is off; cross-variable validation on the variables
  # blocks plan when they are empty AND the federation flag is on.
  security_tier_account_ids = toset(compact([
    local.aft_management_account_id,
    var.audit_account_id,
    var.log_archive_account_id,
  ]))

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
