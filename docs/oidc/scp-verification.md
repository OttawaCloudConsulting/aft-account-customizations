# OIDC Federation — SCP Verification

OIDC federation requires two IAM actions that are not in the existing baseline:

| Action | Resource | Required for |
|--------|----------|-------------|
| `iam:CreateOpenIDConnectProvider` | `arn:aws:iam::<account_id>:oidc-provider/*` | Creating `aws_iam_openid_connect_provider.this` |
| `iam:CreateRole` with `iam:PermissionsBoundary = arn:aws:iam::*:policy/Boundary-*` | `arn:aws:iam::<account_id>:role/*` | Creating `aws_iam_role.federation` |

The SCP at the Organization level (Layer 1 in `CLAUDE.md` §Security Architecture) must not
deny these actions for the AFT execution role (`target_admin_role_arn`) in each vended account's OU.
This document records the verification evidence.

---

## SCP Source-of-Truth

| Field | Value |
|-------|-------|
| **SCP source** | `<FILL IN — link to SCP definition in IaC repo, AWS Organizations console, or version-controlled policy document>` |
| **Relevant SCP name(s)** | `<FILL IN — e.g., "OCC-Baseline-IAM-Controls">` |
| **Verified by** | `<FILL IN — name, date>` |
| **OU(s) in scope** | `<FILL IN — all workload OUs covered by the rollout>` |

---

## Verification Steps

Run the following against the test account (before Phase 1 rollout):

### Option A — IAM policy simulator

```bash
# Simulate CreateOpenIDConnectProvider
aws iam simulate-principal-policy \
  --policy-source-arn <target_admin_role_arn_for_test_account> \
  --action-names iam:CreateOpenIDConnectProvider \
  --resource-arns "arn:aws:iam::<test_account_id>:oidc-provider/*"

# Simulate CreateRole with boundary condition
aws iam simulate-principal-policy \
  --policy-source-arn <target_admin_role_arn_for_test_account> \
  --action-names iam:CreateRole \
  --resource-arns "arn:aws:iam::<test_account_id>:role/*" \
  --context-entries '[{"ContextKeyName":"iam:PermissionsBoundary","ContextKeyValues":["arn:aws:iam::<test_account_id>:policy/Boundary-Default"],"ContextKeyType":"arn"}]'
```

Both must return `EvaluationDecisionType: allowed`. If either returns `implicitDeny` or
`explicitDeny`, investigate the SCP attached to the account's OU.

### Option B — Test apply against the named test account

Run the AFT customization re-run against the test account with `oidc_federation_enabled = true`.
An SCP deny on `iam:CreateRole` produces an explicit error in the CodeBuild log:

```
Error: creating IAM Role (crossplane-aws-iam): AccessDeniedException: ...
```

If this error appears, see `docs/oidc/failure-modes.md` §Failure Mode 1.

---

## Verification Record

| Action | Account/OU | SCP result | Verified by | Date |
|--------|-----------|------------|-------------|------|
| `iam:CreateOpenIDConnectProvider` | `<test account ID>` | `<allowed / denied>` | `<name>` | `<date>` |
| `iam:CreateRole` (with Boundary-*) | `<test account ID>` | `<allowed / denied>` | `<name>` | `<date>` |

Extend this table with additional account/OU rows if rollout spans multiple OUs with different SCPs.

---

## If an SCP deny is found

1. Do not proceed with rollout.
2. Open `docs/oidc/failure-modes.md` §Failure Mode 1 for the full recovery procedure.
3. Work with the Control Tower admin team to update the SCP to allow the required actions
   for the AFT execution role.
4. Re-verify using Option A or Option B above before resuming rollout.
