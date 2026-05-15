# IAM OIDC Federation (Layer B)
# Provisions per-account OIDC provider and per-role IAM roles from JSON wrappers.
# All resources gated by local.oidc_federation_enabled (= local.oidc_provider_count > 0).
# Design decisions: #3, #4, #7, #8, #9, #10, #11, #14, #16 in docs/oidc/ARCHITECTURE_AND_DESIGN.md

locals {
  # Discover per-role JSON wrapper files and decode them.
  # Key = filename minus .json extension (role key); value = decoded wrapper object.
  # Pattern mirrors boundary-policies/ fileset() discovery (Design decisions #3, #4).
  oidc_federation_roles = {
    for f in fileset("${path.module}/oidc-federation-policies", "*.json") :
    trimsuffix(f, ".json") => jsondecode(file("${path.module}/oidc-federation-policies/${f}"))
  }

  # Pre-compute role names to avoid duplicating the name-resolution expression.
  # Precedence: role_name_override > ${prefix}-${key} > ${key} (Design Decision #10).
  oidc_role_names = {
    for k, v in local.oidc_federation_roles :
    k => (
      try(v.role_name_override, null) != null
      ? v.role_name_override
      : (var.oidc_federation_role_prefix != "" ? "${var.oidc_federation_role_prefix}-${k}" : k)
    )
  }

  # Pre-render each wrapper's policy to a JSON string. templatestring()'s first
  # argument must be a direct reference to a string value (var.X / local.X[key])
  # — it cannot accept an inline jsonencode(...) expression.
  oidc_role_policy_templates = {
    for k, v in local.oidc_federation_roles : k => jsonencode(v.policy)
  }
}

resource "aws_iam_openid_connect_provider" "this" {
  count = local.oidc_provider_count

  url = var.oidc_issuer_url

  # Union of the default audience and any per-role audience overrides from JSON wrappers.
  # Roles with no explicit audience field use var.oidc_audience at trust-policy time.
  client_id_list = toset(concat(
    [var.oidc_audience],
    [for r in values(local.oidc_federation_roles) : r.audience if can(r.audience)]
  ))

  thumbprint_list = var.oidc_thumbprints

  tags = local.oidc_federation_tags

  lifecycle {
    prevent_destroy = true

    # Defense against accidental provisioning in the AFT management account via
    # provider-alias misconfiguration. is_security_tier_account already gates count,
    # but a precondition produces a clear error message at plan time.
    precondition {
      condition     = data.aws_caller_identity.current.account_id != local.aft_management_account_id
      error_message = "OIDC federation must not be provisioned in the AFT management account. Verify oidc_federation_enabled and provider alias configuration."
    }
  }
}

resource "aws_iam_role" "federation" {
  for_each = local.oidc_federation_enabled ? local.oidc_federation_roles : {}

  name                 = local.oidc_role_names[each.key]
  permissions_boundary = aws_iam_policy.boundaries[try(each.value.boundary_key, "Default")].arn

  # Trust policy: Federated principal and conditions use resource attributes — never
  # string interpolation of var.oidc_issuer_url. Design Decisions #7, #8.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.this[0].arn }
      Condition = {
        StringEquals = {
          "${aws_iam_openid_connect_provider.this[0].url}:aud" = try(each.value.audience, var.oidc_audience)
          "${aws_iam_openid_connect_provider.this[0].url}:sub" = each.value.subject
        }
      }
    }]
  })

  tags = local.oidc_federation_tags

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = contains(keys(aws_iam_policy.boundaries), try(each.value.boundary_key, "Default"))
      error_message = "OIDC wrapper '${each.key}': boundary_key '${try(each.value.boundary_key, "Default")}' does not exist in aws_iam_policy.boundaries. Add the corresponding JSON file under boundary-policies/ or correct boundary_key in the wrapper."
    }

    precondition {
      condition     = can(each.value.subject) && length(try(each.value.subject, "")) > 0
      error_message = "OIDC wrapper '${each.key}': required field 'subject' is missing or empty. Format: system:serviceaccount:<namespace>:<serviceaccount-name>."
    }

    precondition {
      condition     = can(each.value.policy)
      error_message = "OIDC wrapper '${each.key}': required field 'policy' is missing. The JSON wrapper must contain a 'policy' object with Version and Statement."
    }

    precondition {
      condition     = length(local.oidc_role_names[each.key]) <= 64
      error_message = "OIDC wrapper '${each.key}': computed role name '${local.oidc_role_names[each.key]}' exceeds the 64-character IAM limit. Set role_name_override to a shorter name or shorten the role key."
    }

    precondition {
      condition     = !local.is_security_tier_account || var.oidc_federation_security_tier_accounts
      error_message = "OIDC federation is not allowed in security-tier accounts (Audit, Log Archive, AFT management) unless var.oidc_federation_security_tier_accounts = true. Complete a documented threat-model review before enabling federation in these accounts."
    }
  }
}

resource "aws_iam_role_policy" "federation" {
  for_each = local.oidc_federation_enabled ? local.oidc_federation_roles : {}

  name = "oidc-federation-policy"
  role = aws_iam_role.federation[each.key].id

  # templatestring() renders ${account_id}, ${region}, ${cluster_issuer_host} in the
  # policy JSON from the wrapper. The first argument must be a direct reference to
  # a string — we pre-render the wrapper policy to JSON in local.oidc_role_policy_templates
  # so templatestring() can resolve it. Template variables documented in
  # oidc-federation-policies/README.md. Requires Terraform >= 1.8. Design Decision #16.
  policy = templatestring(local.oidc_role_policy_templates[each.key], {
    account_id          = data.aws_caller_identity.current.account_id
    region              = data.aws_region.current.region
    cluster_issuer_host = trimprefix(var.oidc_issuer_url, "https://")
  })
}
