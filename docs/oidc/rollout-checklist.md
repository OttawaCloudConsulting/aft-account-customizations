# OIDC Federation — Rollout Checklist

Staged rollout from "PR merged to main" through "all workload accounts verified."
Pause at every checkpoint before proceeding to the next batch.

**AFT operator on duty** (named role, rotated weekly — owner: AFT team lead) is responsible
for executing this checklist. The K8s Platform team owns steps marked [K8s].

---

## Pre-rollout gates (must be green before flipping any flag)

- [ ] CI gate passes on `main`: `terraform validate`, StringLike check, and snapshot test
      all green in `.github/workflows/oidc-validate.yml`.
- [ ] `docs/oidc/boundary-compatibility-analysis.md` committed with `BOUNDARY_FITS = yes`
      for the real M03-supplied policy (not the stub).
- [ ] Named test account recorded in `docs/oidc/test-account.md`.
- [ ] K8s Platform team has confirmed Layer A (OIDC discovery host) is live and has supplied
      the CA thumbprint(s) for `var.oidc_thumbprints`.
- [ ] SCP verification complete: `docs/oidc/scp-verification.md` has evidence that
      `iam:CreateOpenIDConnectProvider` and `iam:CreateRole` (with boundary) are not denied
      in the test account's OU SCP.
- [ ] K8s Platform team has read-only access to CodeBuild logs (see `docs/oidc/access.md`).

---

## Phase 1: Test account

### Step 1 — Set variables for the test account

In the AFT account vending configuration for the test account, set:

```hcl
oidc_federation_enabled = true
oidc_thumbprints        = ["<thumbprint-from-k8s-team>"]
```

Leave `oidc_federation_security_tier_accounts = false` (default).
Leave `oidc_issuer_url` and `oidc_audience` at their pinned defaults unless the K8s team
explicitly requests changes.

### Step 2 — Trigger AFT customization re-run

Run the AFT customization re-run mechanism against the test account (typically the
`aft-invoke-customizations` SSM document or equivalent — exact command recorded in the
AFT management account's runbook):

```bash
# Example (replace with actual mechanism):
aws ssm start-automation-execution \
  --document-name "aft-invoke-customizations" \
  --parameters "AccountId=<test-account-id>"
```

### Step 3 — Verify apply succeeded

In the AFT management account CodeBuild log group `/aws/codebuild/aft-account-customizations`:

- [ ] `terraform apply` exit code 0.
- [ ] No SCP deny errors in the log.
- [ ] Output `oidc_provider_arn` is present and non-null.
- [ ] Output `oidc_federation_role_arns` contains `crossplane-aws-iam` with a valid ARN.
- [ ] Output `oidc_module_version` matches the git tag/SHA of the merged PR.

### Step 4 — Transcribe outputs

Copy the three outputs from the CodeBuild log into the K8s Platform team's
`docs/oidc/M01-verification.md` (their repo):

```
oidc_provider_arn:           <value>
oidc_federation_role_arns:   { "crossplane-aws-iam": "<value>" }
oidc_module_version:         <value>
```

Post a notification to the `#cluster-oidc` Slack channel with the account ID,
the provider ARN, and the role ARN.

### Step 5 — K8s Platform team verification [K8s]

- [ ] [K8s] `aws iam get-open-id-connect-provider --open-id-connect-provider-arn <arn>`
      returns the correct URL, ClientIDList, and ThumbprintList.
- [ ] [K8s] `aws iam get-role --role-name crossplane-aws-iam` returns trust policy with
      `StringEquals` on `aud=sts.amazonaws.com` and `sub=system:serviceaccount:crossplane-provider-aws:provider-aws-iam`.
- [ ] [K8s] End-to-end federation test passes (pod → STS → AWS API call) in the test account.

### Checkpoint: Proceed only if all Phase 1 steps are green.

**Rollback trigger:** If apply fails or K8s verification fails, stop rollout.
Open `docs/oidc/failure-modes.md` for the relevant failure mode and recovery steps.
Do not proceed to Phase 2 until Phase 1 is fully verified.

---

## Phase 2: Workload account batches

Process workload accounts in batches of **≤ 10 accounts per day**.

### For each batch:

**Step B1 — Select batch**
Identify the next ≤ 10 non-security-tier workload accounts. Exclude any accounts where
a flag flip would cause unexpected side effects (e.g., accounts pending decommission).

**Step B2 — Set variables**
For each account in the batch, set `oidc_federation_enabled = true` and supply
`oidc_thumbprints` in the AFT account vending configuration.

**Step B3 — Trigger AFT customization re-runs**
Re-run AFT customization for each account in the batch. These may run in parallel.

**Step B4 — Verify apply for each account**
For each account in the batch:
- [ ] `terraform apply` exit code 0 in the CodeBuild log.
- [ ] `oidc_provider_arn` and `oidc_federation_role_arns` outputs present and non-null.

**Step B5 — Transcribe outputs**
Copy outputs for each account to the K8s team's `M01-verification.md`.
Post batch summary to `#cluster-oidc` Slack (account IDs + provider ARNs).

**Step B6 — K8s spot-check [K8s]**
K8s Platform team verifies at least one account per batch via `aws iam get-role`
and a live token exchange test.

**Batch pause point:** After each batch, wait for K8s team confirmation before
starting the next batch. Do not rush — a systematic failure is caught after batch 1,
not batch 10.

---

## Pause triggers (stop rollout immediately if any of these occur)

- Apply error in any account (`iam:CreateRole` denied, precondition failure, etc.)
- K8s Platform team reports `AccessDenied` from any pod in a just-enabled account
- `oidc_provider_arn` output is null in any account where `oidc_federation_enabled = true`
- Trust policy structure deviates from spec (e.g., wrong sub value)
- Any unresolved failure mode without a documented recovery path

**On pause:** Stop all pending re-runs. Open `docs/oidc/failure-modes.md`, identify the
failure mode, execute recovery, re-verify, and only then resume.

---

## Rollback procedure

Rolling back OIDC federation for a specific account:

1. Set `oidc_federation_enabled = false` in that account's AFT configuration.
2. **Remove `lifecycle { prevent_destroy = true }` from `aws_iam_openid_connect_provider.this`
   and `aws_iam_role.federation` in `iam-oidc-federation.tf`** — these blocks block Terraform
   from destroying the resources. This must be done in a dedicated PR.
3. Re-trigger AFT customization for the account. Terraform will destroy the OIDC provider
   and role.
4. Notify the K8s Platform team — the role ARN is no longer valid; ServiceAccount bindings
   will start failing immediately.
5. Restore `lifecycle { prevent_destroy = true }` in a follow-up PR.

**Warning:** Rollback is disruptive. Coordinate with the K8s Platform team before proceeding.
The intent of `prevent_destroy` is to make rollback a deliberate, visible decision, not an
accident.

---

## Post-rollout

- [ ] All workload accounts show `oidc_provider_arn` and `oidc_federation_role_arns` in CodeBuild logs.
- [ ] K8s Platform team confirms end-to-end federation is functional in a representative account sample.
- [ ] `docs/oidc/M01-verification.md` in the K8s team's repo is up to date.
- [ ] AFT operator on duty posts final rollout summary to `#cluster-oidc` Slack.
- [ ] Update this checklist with any lessons learned.
