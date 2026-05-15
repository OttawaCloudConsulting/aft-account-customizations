# OIDC Federation — Failure Modes & Recovery

Source of truth: `docs/oidc/ARCHITECTURE_AND_DESIGN.md` §Failure Modes & Recovery.
This runbook enumerates all eight failure modes and the exact operator action for each.

---

## Failure Mode 1: Provider created; role create denied by SCP

**Detection:** `terraform apply` error during `aws_iam_role.federation` create.
Error message will reference `iam:CreateRole` being denied.

**Root cause:** The OU SCP does not permit `iam:CreateRole` with a `Boundary-*` permission
boundary for the AFT execution role in this account's OU.

**Recovery:**
1. Do not re-apply until the SCP is fixed — repeated applies will keep failing.
2. Open `docs/oidc/scp-verification.md` and follow the SCP verification steps.
3. Confirm the SCP allows `iam:CreateRole` with condition `iam:PermissionsBoundary`
   matching `Boundary-*`.
4. Engage the Control Tower admin team to update the SCP if blocked.
5. Re-trigger the AFT customization against the affected account once the SCP is updated.
6. The orphan OIDC provider (created before role failed) remains — it is `prevent_destroy` and
   will be reconciled correctly on the next successful apply.

**Rerun-safe:** Yes — Terraform retries role create idempotently; existing provider is unchanged.

---

## Failure Mode 2: Thumbprint list rejected at AWS API (malformed SHA-1)

**Detection:** `terraform apply` error during `aws_iam_openid_connect_provider` create.
AWS returns a validation error for an entry in `ThumbprintList`.

**Root cause:** An entry in `var.oidc_thumbprints` failed the AWS-side SHA-1 format check.

**Prevention:** The `validation {}` block on `var.oidc_thumbprints` validates each entry as a
40-character hex string at plan time. If this failure reaches apply, a template-rendered value
bypassed the validation block.

**Recovery:**
1. Identify the malformed thumbprint in the apply error.
2. Obtain the correct thumbprint from the K8s Platform team (see `#cluster-oidc` Slack).
3. Update the variable value for the affected account.
4. Re-apply. No state was changed — no resources were created.

**Rerun-safe:** Yes — no state churn; re-apply starts fresh.

---

## Failure Mode 3: JSON wrapper malformed (missing required field)

**Detection:** `terraform plan` fails with a `precondition` block error on
`aws_iam_role.federation`. Error message names the wrapper file and the missing field.

**Root cause:** A JSON wrapper file in `oidc-federation-policies/` is missing `subject`
or `policy`, or contains a `boundary_key` that does not exist in `aws_iam_policy.boundaries`.

**Recovery:**
1. Open the named wrapper file and add the missing field.
2. For a `boundary_key` error: either correct the key to an existing boundary file
   (e.g., `"Default"`) or create the missing boundary JSON under `boundary-policies/`
   (requires separate review — see `docs/oidc/boundary-compatibility-analysis.md` process).
3. Re-plan. The OIDC provider (if already created in a prior apply) remains untouched.
4. Re-apply once plan succeeds.

**Rerun-safe:** Yes — `precondition` blocks block state changes; re-plan is safe.

---

## Failure Mode 4: Boundary incompatibility (policy ∩ boundary = ∅ for a required action)

**Detection:** Runtime `AccessDenied` at pod → AWS API call, after a successful `terraform apply`.
There is no Terraform signal — the role is created and the policy is attached; the deny comes
from the permission boundary at token exchange time.

**Root cause:** The K8s-team-supplied permission policy includes an action that is denied by
the `Boundary-*` policy attached to the role. The permission boundary deny wins at token
exchange even though the role policy allows the action.

**Prevention:** `docs/oidc/boundary-compatibility-analysis.md` is a required pre-merge gate.
It must enumerate all actions in the permission policy and verify each is not denied by the
attached boundary.

**Recovery:**
1. Identify the denied action from the K8s team's pod logs or CloudTrail (`aws cloudtrail lookup-events`).
2. Review `docs/oidc/boundary-compatibility-analysis.md` — verify whether the action was
   missed in the intersection analysis.
3. If the action must be permitted:
   a. Create a new boundary JSON file under `boundary-policies/` that permits the action.
   b. Update the wrapper's `boundary_key` field to reference the new boundary.
   c. Update `docs/oidc/boundary-compatibility-analysis.md` with the revised analysis.
   d. Create a PR with the boundary file + wrapper change (separate review required per PRD).
   e. Trigger AFT customization re-run to apply the new boundary.
4. Do NOT relax the deny envelope of `Boundary-Default` — add a new, more permissive boundary
   and use `boundary_key` in the wrapper.

**Rerun-safe:** Yes — `boundary_key` change is idempotent; re-apply updates `permissions_boundary`.

---

## Failure Mode 5: Partial state from a Terraform crash mid-apply

**Detection:** AFT customization CodeBuild log shows a Terraform process crash or timeout.
The account may have an OIDC provider but no role, or a provider and partial roles.

**Root cause:** Terraform process killed (timeout, OOM, network interruption) during apply.

**Recovery:**
1. Re-trigger the AFT customization for the affected account.
2. Terraform reconciles to the declared state — it creates the missing resources without
   touching the already-created ones.
3. `prevent_destroy` on provider and role prevents accidental rollback.
4. Verify outputs after re-apply; transcribe to K8s team's `M01-verification.md`.

**Rerun-safe:** Yes — idempotent; apply is the source of truth.

---

## Failure Mode 6: JSON wrapper file renamed accidentally

**Detection:** `terraform plan` fails with an error from `lifecycle { prevent_destroy = true }`.
Error message: Terraform cannot destroy `aws_iam_role.federation["<old-key>"]` because of the
lifecycle constraint.

**Root cause:** A JSON file in `oidc-federation-policies/` was renamed after first deploy.
The `for_each` key changed from `<old-key>` to `<new-key>`, so Terraform plans to destroy the
old role and create a new one.

**Why this is blocked:** `lifecycle { prevent_destroy = true }` on the role resource. An accidental
rename would destroy and recreate the role, changing the ARN and breaking K8s ServiceAccount
bindings fleet-wide.

**Recovery:**
1. Revert the rename — restore the original filename. The `for_each` key is the filename
   minus `.json`; it is immutable post-deploy (see `oidc-federation-policies/README.md`).
2. If a genuine role rename is required:
   a. Confirm with the K8s Platform team — the role ARN is bound into ServiceAccount
      annotations; a rename requires a coordinated K8s-side update.
   b. Temporarily remove `prevent_destroy` from the role resource in a dedicated PR.
   c. Run `terraform state mv` to rename the state key before applying, or accept
      the destroy/recreate with the K8s team's acknowledgment.
   d. Restore `prevent_destroy` immediately after the rename is complete.

**Rerun-safe:** Yes — `prevent_destroy` blocks the destroy; no state change occurs until resolved.

---

## Failure Mode 7: Boundary file renamed (e.g., `Default.json` → `Foo.json`)

**Detection:** `terraform plan` fails with a `precondition` block error on
`aws_iam_role.federation`. Error: `boundary_key 'Default' does not exist in aws_iam_policy.boundaries`.

**Root cause:** `boundary-policies/Default.json` was renamed. The OIDC federation role's wrapper
omits `boundary_key` (defaults to `"Default"`), so the lookup fails when `"Default"` is no
longer a valid key.

**Why this matters:** This is the symmetric coupling documented in `CLAUDE.md` §Key Patterns
and `boundary-policies/README.md`. Renaming a boundary file changes the `for_each` key in
`aws_iam_policy.boundaries` and breaks any federation wrapper that references the old key.

**Recovery:**
1. Restore the original filename (`Default.json`) — the boundary policy filename is immutable
   post-deploy (see `boundary-policies/README.md`).
2. If a genuine rename is required:
   a. Update every JSON wrapper in `oidc-federation-policies/` that references the old key
      (via `boundary_key` field, or implicitly via the `"Default"` fallback).
   b. Create the new boundary file and deprecate the old one in the same PR.
   c. Run `terraform state mv aws_iam_policy.boundaries["<old>"] aws_iam_policy.boundaries["<new>"]`
      before applying to avoid destroy/recreate of the IAM policy.

**Rerun-safe:** Yes — `precondition` blocks any state change until resolved.

---

## Failure Mode 8: Layer A not live — provider created but token validation fails

**Detection:** K8s Platform team reports that `sts:AssumeRoleWithWebIdentity` calls fail
with `InvalidIdentityToken` or similar errors. No Terraform signal — apply succeeded.

**Root cause:** The OIDC discovery host (Layer A: S3 + CloudFront + ACM + Route53, owned by the
Application Team per `DESCOPE.md`) is not yet live, or the OIDC well-known configuration
endpoint is unreachable. AWS STS cannot retrieve the provider's public keys to validate tokens.

**Recovery:**
1. This is an AFT-out-of-scope item — the AFT-side Terraform resources are correct.
2. Escalate to the Application Team (Layer A) and K8s Platform team.
3. AFT-side resources (OIDC provider and role) remain valid; no Terraform churn is needed.
4. Once Layer A is live, the K8s team retests end-to-end federation per `docs/oidc/rollout-checklist.md`.
5. If Layer A is permanently not coming (project cancelled), remove the OIDC resources by:
   a. Removing `lifecycle { prevent_destroy = true }` in a dedicated PR.
   b. Setting `var.oidc_federation_enabled = false` and applying.

**Rerun-safe:** Yes — Terraform-side is correct; no AFT action required.
