# Boundary Compatibility Analysis: crossplane-aws-iam

**Date**: 2026-05-15
**Analyst**: AFT team
**Status**: STUB POLICY — Re-analysis required when M03 supplies the real policy (see note below)

## Summary

```
BOUNDARY_FITS = yes
```

The stub permission policy attached to the `crossplane-aws-iam` federated role is a subset of
`Boundary-Default`. No deny statement in `Boundary-Default` applies to the actions in the stub
policy.

---

## Policy under analysis

Source: `baseline/terraform/oidc-federation-policies/crossplane-aws-iam.json` (`policy` field)

The stub policy (pending real policy from K8s Platform team at M03):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StubPolicyPendingM03Supply",
      "Effect": "Allow",
      "Action": [
        "iam:GetRole",
        "iam:ListRoles",
        "iam:ListRoleTags"
      ],
      "Resource": "arn:aws:iam::<account_id>:role/*"
    }
  ]
}
```

Actions required: `iam:GetRole`, `iam:ListRoles`, `iam:ListRoleTags` (read-only IAM lookups).

---

## Boundary under analysis

Source: `baseline/terraform/boundary-policies/Default.json`

Boundary name after `${var.boundary_policy_prefix}-${key}` expansion: `Boundary-Default`

`Boundary-Default` structure (deny statements only; the `AllowAllServices` Allow-`*` is the base):

| Sid | Denied actions | Resource scope |
|-----|---------------|----------------|
| `DenyCreateProtectedRoles` | `iam:CreateRole`, `iam:PutRolePolicy`, `iam:AttachRolePolicy` | `arn:aws:iam::<acct>:role/org/org-*` |
| `DenyModifyProtectedRoles` | `iam:UpdateRole`, `iam:UpdateRoleDescription`, `iam:UpdateAssumeRolePolicy`, `iam:DeleteRole`, `iam:DeleteRolePolicy`, `iam:DetachRolePolicy`, `iam:TagRole`, `iam:UntagRole`, `iam:PutRolePermissionsBoundary`, `iam:DeleteRolePermissionsBoundary` | `arn:aws:iam::<acct>:role/org/org-*` |
| `DenyCreatePermissionBoundaryPolicies` | `iam:CreatePolicy` | `arn:aws:iam::<acct>:policy/org/Boundary-*` |
| `DenyModifyAnyBoundaryPolicy` | `iam:CreatePolicyVersion`, `iam:DeletePolicy`, `iam:DeletePolicyVersion`, `iam:SetDefaultPolicyVersion` | `arn:aws:iam::<acct>:policy/org/Boundary-*` |
| `DenyRemovingBoundaries` | `iam:DeleteRolePermissionsBoundary` | `arn:aws:iam::<acct>:role/*` (all roles) |
| `RequireBoundaryOnRoleCreation` | `iam:CreateRole`, `iam:PutRolePermissionsBoundary` (when no boundary attached) | `arn:aws:iam::<acct>:role/*` (all roles) |
| `DenyBillingChanges` | `aws-portal:ModifyAccount`, `aws-portal:ModifyBilling`, `aws-portal:ModifyPaymentMethods` | `*` |
| `DenyMarketplaceSubscriptions` | `aws-marketplace:Subscribe`, `aws-marketplace:Unsubscribe`, `aws-marketplace:CreatePrivateMarketplace` | `*` |
| `DenyIdentityCenterChanges` | `sso:*`, `sso-directory:*`, `identitystore:*` | `*` |
| `DenyCloudTrailChanges` | `cloudtrail:DeleteTrail`, `cloudtrail:StopLogging`, `cloudtrail:UpdateTrail`, `cloudtrail:PutEventSelectors` | `*` |
| `DenyConfigChanges` | `config:DeleteConfigurationRecorder`, `config:DeleteDeliveryChannel`, `config:StopConfigurationRecorder`, `config:PutConfigurationRecorder`, `config:PutDeliveryChannel` | `*` |
| `DenySecurityServiceChanges` | `guardduty:DeleteDetector`, `guardduty:DisassociateFromMasterAccount`, `guardduty:StopMonitoringMembers`, `securityhub:DisableSecurityHub`, `securityhub:DisassociateFromMasterAccount`, `access-analyzer:DeleteAnalyzer` | `*` |
| `ProtectInfrastructureLogs` | `logs:DeleteLogGroup`, `logs:DeleteLogStream`, `logs:PutRetentionPolicy` | AFT/org log group ARNs only |

---

## Intersection analysis

| Required action | Denied by any boundary statement? | Conclusion |
|-----------------|-----------------------------------|------------|
| `iam:GetRole` | No — no deny statement covers read-only IAM listing actions | ALLOWED |
| `iam:ListRoles` | No — no deny statement covers read-only IAM listing actions | ALLOWED |
| `iam:ListRoleTags` | No — no deny statement covers read-only IAM listing actions | ALLOWED |

All three required actions are read-only IAM lookups. No deny statement in `Boundary-Default`
targets read operations on IAM roles. The `AllowAllServices` Allow-`*` base permits them, and
no deny overrides apply.

---

## Verdict

```
BOUNDARY_FITS = yes
```

The stub policy is a strict subset of `Boundary-Default`. The `crossplane-aws-iam` JSON wrapper's
`boundary_key` field is correctly omitted (defaults to `"Default"`); no new boundary file is
required for the stub policy.

---

## ⚠ Re-analysis required at M03

This analysis covers the **stub policy only**. The K8s Platform team will supply the real
permission policy for `crossplane-aws-iam` at milestone M03. The real policy (which will likely
include IAM write actions for Crossplane to manage roles) **must be re-analyzed against
`Boundary-Default` before Feature 4 is marked complete**.

Steps for M03 re-analysis:
1. Replace the `policy` field in `crossplane-aws-iam.json` with the K8s-team-supplied policy.
2. List every `Action` in the real policy.
3. Check each action against the deny statements in `boundary-policies/Default.json`.
4. If any required action is denied on the target resource scope:
   - Add a new boundary file under `boundary-policies/` (separate review required).
   - Update `crossplane-aws-iam.json` to set `"boundary_key": "<new-boundary-key>"`.
   - Re-analyze until `BOUNDARY_FITS = yes`.
5. Update this document with the final verdict and replace the ⚠ warning.
