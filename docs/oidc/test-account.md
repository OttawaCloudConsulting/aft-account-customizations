# OIDC Federation — Named Test Account

This document records the test account used for Phase 1 of the OIDC federation rollout.
Feature 4 of the OIDC implementation must apply cleanly against this account before
fleet rollout proceeds. See `docs/oidc/rollout-checklist.md` §Phase 1.

---

## Test Account

| Field | Value |
|-------|-------|
| **Account ID** | `<FILL IN — AFT team lead nominates before rollout>` |
| **Account name** | `<FILL IN>` |
| **Account type** | Workload (non-security-tier) |
| **OU** | `<FILL IN>` |
| **Nominated by** | `<FILL IN — name, date>` |
| **Approved by** | `<FILL IN — AFT team lead>` |

**Criteria for selection:**
- Must be a non-security-tier account (not Audit, Log Archive, or AFT management account).
- Must already be vended (not a future account).
- Must not be serving live production workloads that cannot tolerate the addition of new
  IAM resources during Phase 1 verification (in practice, adding the OIDC provider and
  crossplane-aws-iam role causes zero production impact, but the account owner should be
  notified).
- Must be accessible by the AFT operator on duty for CodeBuild log inspection.

---

## Verification Procedure

After `var.oidc_federation_enabled = true` is set and AFT customization re-runs against
this account, verify the following before proceeding to fleet rollout:

### AFT operator checks

```bash
# Confirm provider created
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn <oidc_provider_arn output>

# Confirm role created
aws iam get-role --role-name crossplane-aws-iam

# Confirm trust policy structure
aws iam get-role --role-name crossplane-aws-iam \
  --query 'Role.AssumeRolePolicyDocument'
```

Expected trust policy fields:
- `Action`: `sts:AssumeRoleWithWebIdentity`
- `Effect`: `Allow`
- `Principal.Federated`: matches the `oidc_provider_arn` output
- `Condition.StringEquals`: contains exactly one `<issuer-url>:aud` and one `<issuer-url>:sub` key
- No `StringLike` condition operator anywhere in the trust policy

```bash
# Confirm boundary attached
aws iam get-role --role-name crossplane-aws-iam \
  --query 'Role.PermissionsBoundary'
# Expected: arn:aws:iam::<account_id>:policy/Boundary-Default
```

### K8s Platform team checks

The K8s Platform team runs the end-to-end federation test per their `M01-verification.md`
procedure. AFT scope ends at the Terraform outputs — end-to-end token exchange is the
K8s team's responsibility (REQUIREMENTS-OIDC.md §R2.5 items 4–5).

---

## Output Record (fill in after Phase 1 apply)

| Output | Value |
|--------|-------|
| `oidc_provider_arn` | `<record after apply>` |
| `oidc_federation_role_arns.crossplane-aws-iam` | `<record after apply>` |
| `oidc_module_version` | `<record after apply>` |
| Apply timestamp | `<record after apply>` |
| K8s verification status | `<pending / passed / failed>` |
