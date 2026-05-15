variable "protected_role_prefix" {
  description = "IAM role prefix protected from creation/modification (e.g., org)"
  type        = string
  default     = "org"
}

variable "boundary_policy_prefix" {
  description = "Prefix for permission boundary policies (e.g., Boundary)"
  type        = string
  default     = "Boundary"
}

# ── OIDC Federation (Layer B) ────────────────────────────────────────────────
# Design decisions: #1, #5, #6, #10, #17 in docs/oidc/ARCHITECTURE_AND_DESIGN.md
# Feature flag is false by default — zero state churn until explicitly enabled.

variable "oidc_federation_enabled" {
  description = "Master feature flag for OIDC federation. When false, no OIDC resources are created (zero state churn on already-vended accounts). Set to true per-account to enable federation after Layer A is live and thumbprints are available."
  type        = bool
  default     = false
}

variable "oidc_federation_security_tier_accounts" {
  description = "Allow OIDC federation in security-tier accounts (Audit, Log Archive, AFT management). When false (default), these accounts are excluded. Set to true only after a documented threat-model review. See Blast Radius Analysis in docs/oidc/ARCHITECTURE_AND_DESIGN.md."
  type        = bool
  default     = false
}

variable "oidc_issuer_url" {
  description = "Cluster OIDC issuer URL. Pinned by K8s Platform team hand-off (REQUIREMENTS-OIDC.md §R2.1). Validation rejects trailing slash, mixed case, and missing https:// scheme."
  type        = string
  default     = "https://oidc.k8s.occ.ottawacloudconsulting.com"

  validation {
    condition     = can(regex("^https://[a-z0-9.\\-]+$", var.oidc_issuer_url))
    error_message = "oidc_issuer_url must begin with https://, contain only lowercase letters, digits, dots, and hyphens, and have no trailing slash."
  }
}

variable "oidc_thumbprints" {
  description = "SHA-1 thumbprints of the cluster OIDC issuer's CA chain. AWS allows up to 5 entries to support rotation overlap. Must be non-empty when oidc_federation_enabled is true. Each entry must be a 40-character hexadecimal string. Supplied by K8s Platform team after Layer A is live."
  type        = list(string)
  default     = []

  validation {
    condition     = var.oidc_federation_enabled == false || length(var.oidc_thumbprints) > 0
    error_message = "oidc_thumbprints must be non-empty when oidc_federation_enabled is true."
  }

  validation {
    condition     = alltrue([for t in var.oidc_thumbprints : can(regex("^[A-Fa-f0-9]{40}$", t))])
    error_message = "Each oidc_thumbprints entry must be a 40-character hexadecimal SHA-1 string."
  }
}

variable "oidc_audience" {
  description = "Default audience claim for OIDC federation trust policies. Per-role override available via the JSON wrapper audience field. Must not be empty."
  type        = string
  default     = "sts.amazonaws.com"

  validation {
    condition     = length(var.oidc_audience) > 0
    error_message = "oidc_audience must not be empty."
  }
}

variable "oidc_federation_role_prefix" {
  description = "Prefix prepended to federated IAM role names when the JSON wrapper does not set role_name_override. Empty string (default) preserves the hand-off-pinned crossplane-aws-iam name at MVP. When non-empty, must be kebab-case (starts with a lowercase letter, contains only lowercase letters, digits, and hyphens)."
  type        = string
  default     = ""

  validation {
    condition     = var.oidc_federation_role_prefix == "" || can(regex("^[a-z][a-z0-9-]*$", var.oidc_federation_role_prefix))
    error_message = "oidc_federation_role_prefix must be empty or kebab-case (starts with a lowercase letter, followed by lowercase letters, digits, or hyphens only)."
  }
}

variable "audit_account_id" {
  description = "AWS account ID of the Control Tower Audit account. Added to local.security_tier_account_ids so OIDC federation is excluded from this account by default. Must be a 12-digit AWS account ID when oidc_federation_enabled = true and oidc_federation_security_tier_accounts = false; otherwise the default-deny guard for security-tier accounts cannot identify it."
  type        = string
  default     = ""

  validation {
    condition     = var.audit_account_id == "" || can(regex("^[0-9]{12}$", var.audit_account_id))
    error_message = "audit_account_id must be empty or a 12-digit AWS account ID."
  }

  validation {
    condition     = !var.oidc_federation_enabled || var.oidc_federation_security_tier_accounts || can(regex("^[0-9]{12}$", var.audit_account_id))
    error_message = "audit_account_id must be a 12-digit AWS account ID when oidc_federation_enabled = true and oidc_federation_security_tier_accounts = false. The security-tier exclusion cannot identify the account without it."
  }
}

variable "log_archive_account_id" {
  description = "AWS account ID of the Control Tower Log Archive account. Added to local.security_tier_account_ids so OIDC federation is excluded from this account by default. Must be a 12-digit AWS account ID when oidc_federation_enabled = true and oidc_federation_security_tier_accounts = false; otherwise the default-deny guard for security-tier accounts cannot identify it."
  type        = string
  default     = ""

  validation {
    condition     = var.log_archive_account_id == "" || can(regex("^[0-9]{12}$", var.log_archive_account_id))
    error_message = "log_archive_account_id must be empty or a 12-digit AWS account ID."
  }

  validation {
    condition     = !var.oidc_federation_enabled || var.oidc_federation_security_tier_accounts || can(regex("^[0-9]{12}$", var.log_archive_account_id))
    error_message = "log_archive_account_id must be a 12-digit AWS account ID when oidc_federation_enabled = true and oidc_federation_security_tier_accounts = false. The security-tier exclusion cannot identify the account without it."
  }
}

