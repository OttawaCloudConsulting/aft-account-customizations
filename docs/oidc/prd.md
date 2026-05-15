# PRD: OIDC Cluster Federation (Layer B, AFT-side)

## Summary

Provision per-account IAM OIDC federation primitives in every AFT-vended account so that pods in the OCC Kubernetes cluster (`oidc.k8s.occ.ottawacloudconsulting.com`) can assume per-account workload roles via `sts:AssumeRoleWithWebIdentity`. MVP delivers one provider plus one role (`crossplane-aws-iam`) bound to the `crossplane-provider-aws:provider-aws-iam` ServiceAccount. Source scope: `REQUIREMENTS-OIDC.md`; upstream hand-off: K8s Platform team, project `cluster-oidc-issuer-pod-identity`. The implementation is gated by an explicit feature flag (`var.oidc_federation_enabled`, default `false`) so the code may merge ahead of the K8s Platform team's external deliverables without affecting the AFT pipeline.

## Goals

- One `aws_iam_openid_connect_provider` per AFT-vended account trusting the cluster issuer URL with the K8s-team-supplied CA thumbprints (created only when `var.oidc_federation_enabled = true`).
- One IAM role per federated workload (MVP: `crossplane-aws-iam`) with a trust policy bound to a specific ServiceAccount subject and audience `sts.amazonaws.com`.
- Universal baseline scope when enabled — every AFT-vended account in the configured account-type set (default: workload + future, **excluding** Audit and Log Archive — see Blast Radius Analysis) receives federation primitives automatically on first AFT execution after the flag is flipped.
- Mirror existing baseline patterns: `fileset()` discovery, `${prefix}-${key}` naming, permission-boundary attachment for non-`org-*` roles. Per-role configuration (subject, audience, boundary, name override, permission policy) lives inside the discovered JSON wrapper so adding a workload is a true one-file change.
- Net-new resources only — zero state churn for already-vended accounts when the flag is `false`. When `true`, only net-new resources are added; no rename or move of existing IAM resources.

## Non-Goals

| Item | Rationale |
|------|-----------|
| Layer A — OIDC discovery host (S3 + CloudFront + ACM + Route53) | Out of scope per `DESCOPE.md`; owned by Application Team. |
| Federation in Audit and Log Archive accounts | Excluded by default — these are security-tier accounts with strict isolation requirements; see Blast Radius Analysis. Opt-in via `var.oidc_federation_security_tier_accounts = true` only after a documented threat-model review. |
| End-to-end token-to-credentials federation test | K8s Platform team responsibility (hand-off §R2.5 items 4–5). AFT scope ends at successful `terraform apply` and `aws iam get-role` matching the spec. |
| Cluster-wide OIDC provider sharing across accounts | Each account gets its own provider — required for per-account IAM trust and consistent with AWS recommended pattern. |
| Selective application by `core/`-only or `workload/`-only customization stage | Federation lives in `baseline/`, which is universal; account-type selection is handled by Blast Radius Analysis above, not by AFT customization stage. |
| Tampered-token rejection test | K8s Platform team responsibility (hand-off §R2.5 item 5). |

## Architecture

See `docs/ARCHITECTURE_AND_DESIGN-OIDC.md` for the single source-of-truth diagram and component inventory. In summary: when `var.oidc_federation_enabled = true`, AFT creates one `aws_iam_openid_connect_provider` per vended account and one `aws_iam_role` per JSON wrapper file discovered in `baseline/terraform/oidc-federation-policies/`. The federated principal in the trust policy references `aws_iam_openid_connect_provider.this[0].arn` directly; condition keys use `aws_iam_openid_connect_provider.this[0].url` — no string interpolation of `var.oidc_issuer_url` into the trust policy.

Code placement: `baseline/terraform/iam-oidc-federation.tf` alongside `iam-permission-boundaries.tf` and `iam-deployment-roles.tf`. Per-role JSON wrappers in `baseline/terraform/oidc-federation-policies/<role-key>.json`.

## JSON wrapper schema (per-role)

Every file in `baseline/terraform/oidc-federation-policies/` is a JSON object with this schema (validated at plan time via `precondition` blocks):

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `subject` | string | yes | — | Exact value for `<issuer-host>:sub` condition. Format: `system:serviceaccount:<namespace>:<sa-name>`. |
| `audience` | string | no | `var.oidc_audience` | Exact value for `<issuer-host>:aud` condition. Per-role override; provider `client_id_list` is the union of `var.oidc_audience` and all per-role audiences. |
| `boundary_key` | string | no | `"Default"` | Key into `aws_iam_policy.boundaries[<key>]`. Allows per-role boundary if the K8s-supplied policy does not fit `Boundary-Default`. |
| `role_name_override` | string | no | `null` | If set, used verbatim as the IAM role name (subject to AWS 64-char limit). If unset, name = `var.oidc_federation_role_prefix` (if non-empty) concatenated with `"-"` and the file's role-key; if both empty, name = role-key. |
| `policy` | object | yes | — | IAM policy document (Version + Statement). Processed by `templatefile()`; available template variables: `account_id`, `region`, `cluster_issuer_host`. |

MVP first role file (`crossplane-aws-iam.json`):

```json
{
  "subject": "system:serviceaccount:crossplane-provider-aws:provider-aws-iam",
  "role_name_override": "crossplane-aws-iam",
  "policy": { "...K8s-team-supplied at M03..." }
}
```

The `role_name_override` keeps the MVP role name `crossplane-aws-iam` to match the K8s Platform team's pinned spec (REQUIREMENTS-OIDC.md §R2.1 row 4) without forcing K8s-side ServiceAccount changes.

## Features

### Feature 1: Architecture and Design

Produce `docs/ARCHITECTURE_AND_DESIGN-OIDC.md` capturing component layout, design decisions, file organization, failure modes & recovery, blast-radius analysis, and the permission-boundary interaction. Note: this is a feature-scoped architecture doc — `docs/ARCHITECTURE_AND_DESIGN.md` remains the prior backport-feature doc and is left untouched.

**Acceptance Criteria:**

- `docs/ARCHITECTURE_AND_DESIGN-OIDC.md` exists with Overview, Component Inventory, Design Decisions (≥10, each with alternative-aware rationale), File Organization, Failure Modes & Recovery, Blast Radius Analysis, State Impact, and Out-of-Scope sections.
- Design decisions cover: feature flag, scope (account-type-aware), file split, JSON wrapper schema, `fileset()` discovery, permission boundary attachment, thumbprint rotation handling, role-name convention, trust-policy `.arn`/`.url` references (not string interpolation), `prevent_destroy` decision, validation strategy, output strategy, state-impact handling, auto-application.
- Cross-references to `REQUIREMENTS-OIDC.md`, `DESCOPE.md`, the K8s Platform team hand-off (snapshotted pinned-specifications subsection), and SCP source-of-truth are present.

### Feature 2: Input variables and locals

Add OIDC configuration variables to `baseline/terraform/variables.tf` with `validation` blocks, plus required locals.

**Acceptance Criteria:**

- `var.oidc_federation_enabled` declared as `bool`, default `false`. Description names this as the master gate for all OIDC resources.
- `var.oidc_federation_security_tier_accounts` declared as `bool`, default `false`. Description references the Blast Radius Analysis in `docs/ARCHITECTURE_AND_DESIGN-OIDC.md`.
- `var.oidc_issuer_url` declared as `string` with default `"https://oidc.k8s.occ.ottawacloudconsulting.com"`. Validation: `can(regex("^https://[a-z0-9.\\-]+$", var.oidc_issuer_url))` — rejects trailing slash, mixed case, missing scheme, `http://`.
- `var.oidc_thumbprints` declared as `list(string)`, default `[]`. Validation: `var.oidc_federation_enabled == false || length(var.oidc_thumbprints) > 0` AND `alltrue([for t in var.oidc_thumbprints : can(regex("^[A-Fa-f0-9]{40}$", t))])` — required only when enabled; each entry must be a 40-char hex SHA-1.
- `var.oidc_audience` declared as `string`, default `"sts.amazonaws.com"`. Validation: `length(var.oidc_audience) > 0`.
- `var.oidc_federation_role_prefix` declared as `string`, default `""` (empty for MVP/hand-off compat). Validation: `var.oidc_federation_role_prefix == "" || can(regex("^[a-z][a-z0-9-]*$", var.oidc_federation_role_prefix))` — kebab-case if non-empty.
- `local.oidc_federation_tags = merge(local.common_tags, { Purpose = "OIDCFederation", Protection = "PermissionBoundary", IssuerHost = trimprefix(var.oidc_issuer_url, "https://") })` defined in `locals.tf`.
- Variable descriptions follow `baseline/docs/variable-naming-convention.md`; types are explicit.
- `terraform fmt -check` and `terraform init -backend=false && terraform validate` pass.

### Feature 3: OIDC provider resource and policy discovery

Create `baseline/terraform/iam-oidc-federation.tf` with the `aws_iam_openid_connect_provider` resource (gated by the feature flag) and a `fileset()`-based discovery of per-role JSON wrapper files.

**Acceptance Criteria:**

- `aws_iam_openid_connect_provider.this` declared with `count = local.oidc_provider_count` where `local.oidc_provider_count = var.oidc_federation_enabled && (var.oidc_federation_security_tier_accounts || !local.is_security_tier_account) ? 1 : 0`. `local.is_security_tier_account` is derived from a known list of security-tier account IDs (or by tag lookup) — implementation in arch doc.
- Provider uses `var.oidc_issuer_url`, `var.oidc_thumbprints`, and `client_id_list = toset(concat([var.oidc_audience], [for r in local.oidc_federation_roles : r.audience]))` — union of default and per-role audiences.
- Provider declares `lifecycle { prevent_destroy = true }`.
- Provider tagged with `local.oidc_federation_tags`.
- `oidc-federation-policies/` directory exists with `README.md` documenting the JSON wrapper schema and the immutability constraint on filenames.
- `local.oidc_federation_roles` discovery: `{ for f in fileset("${path.module}/oidc-federation-policies", "*.json") : trimsuffix(f, ".json") => jsondecode(file("${path.module}/oidc-federation-policies/${f}")) }`. Schema enforced by `precondition` blocks on the role resource.
- `terraform init -backend=false && terraform validate` pass.

### Feature 4: First federation role — `crossplane-aws-iam`

Create the `crossplane-aws-iam` role with trust policy bound to `system:serviceaccount:crossplane-provider-aws:provider-aws-iam`, permission boundary attached, permission policy attached.

**Acceptance Criteria:**

- `aws_iam_role.federation` declared with `for_each = local.oidc_federation_enabled ? local.oidc_federation_roles : {}`.
- Role name computed as `each.value.role_name_override != null ? each.value.role_name_override : (var.oidc_federation_role_prefix != "" ? "${var.oidc_federation_role_prefix}-${each.key}" : each.key)`.
- Trust policy `Federated` principal references `aws_iam_openid_connect_provider.this[0].arn` directly (no string interpolation of `var.oidc_issuer_url` and no manual `arn:aws:iam::${account_id}:...` construction).
- Trust policy conditions use `${aws_iam_openid_connect_provider.this[0].url}:aud` and `:sub` as the condition keys. `StringEquals` only — never `StringLike`. Values: `aud = coalesce(each.value.audience, var.oidc_audience)`, `sub = each.value.subject`.
- `permissions_boundary = aws_iam_policy.boundaries[coalesce(each.value.boundary_key, "Default")].arn`.
- Role declares `lifecycle { prevent_destroy = true }`.
- Role tagged with `local.oidc_federation_tags`.
- `precondition` blocks on the role: (a) the boundary key exists in `aws_iam_policy.boundaries`; (b) JSON wrapper has required fields (`subject`, `policy`); (c) computed role name is ≤ 64 chars; (d) account is not a security-tier account unless `var.oidc_federation_security_tier_accounts = true`.
- `aws_iam_role_policy` attaches the rendered policy: `policy = templatefile_inline(jsonencode(each.value.policy), { account_id = data.aws_caller_identity.current.account_id, region = data.aws_region.current.name, cluster_issuer_host = trimprefix(var.oidc_issuer_url, "https://") })` (or equivalent; exact form documented in arch doc).
- First file `oidc-federation-policies/crossplane-aws-iam.json` exists with `role_name_override = "crossplane-aws-iam"` and the K8s-team-supplied policy from M03.
- **Boundary subset analysis committed**: `docs/oidc/boundary-compatibility-analysis.md` exists, intersects the supplied policy against `boundary-policies/Default.json`, lists every action the K8s team requires versus the boundary's deny envelope, and concludes with `BOUNDARY_FITS = yes|no`. If `no`, a new file is added to `boundary-policies/` (separate review) and the JSON wrapper's `boundary_key` is updated.

### Feature 5: Outputs

Expose per-account provider ARN, per-role role ARNs, and the module git ref so the K8s team's `M01-verification.md` can record provenance.

**Acceptance Criteria:**

- `output "oidc_provider_arn"` returns `try(aws_iam_openid_connect_provider.this[0].arn, null)` — `null` when the feature flag is off, so consumers can detect off-state without parsing.
- `output "oidc_federation_role_arns"` returns `{ for k, r in aws_iam_role.federation : k => r.arn }` — empty map when the flag is off.
- `output "oidc_module_version"` returns a `local.oidc_module_version` value sourced from a static literal updated per release (or from a `var.module_version` set by CI). Closes REQUIREMENTS-OIDC.md output #3.
- Outputs are **not** marked `sensitive = true` — ARNs are not credentials and must appear in CodeBuild logs.

### Feature 6: Documentation update

Update repository-level docs and reconcile pre-existing inconsistencies.

**Acceptance Criteria:**

- `README.md`: a new Terraform Input Variables section is added (not an extension of the AFT-environment-variable table, which is a different table). It documents `oidc_federation_enabled`, `oidc_federation_security_tier_accounts`, `oidc_issuer_url`, `oidc_thumbprints`, `oidc_audience`, `oidc_federation_role_prefix` with defaults, validation rules, and the cutover sequence.
- `README.md`: a new "OIDC Federation Pattern" subsection describes the JSON wrapper schema, the `oidc-federation-policies/` discovery directory, and how to add a federated workload (drop one JSON file — true one-file workflow).
- `CLAUDE.md` §Security Architecture (Baseline) table: append the row `crossplane-aws-iam | baseline/terraform/iam-oidc-federation.tf | OIDC-federated workload role; trust bound to system:serviceaccount:crossplane-provider-aws:provider-aws-iam; permission boundary = Boundary-Default`.
- `CLAUDE.md` §Key Patterns: append a paragraph describing the OIDC JSON-wrapper discovery pattern (parallel to the boundary discovery paragraph) and the symmetric coupling to `boundary-policies/Default.json` (renaming that file would break federation).
- `baseline/docs/variable-naming-convention.md:114` reconciled — replace stale `Boundary-Default.json` reference with the post-PR-#1 `Default.json` so future contributors do not restore the prefix and break the federation key lookup.
- `boundary-policies/README.md` (create if absent): notes that renaming files in this directory breaks the OIDC federation role's `boundary_key` lookup.

### Feature 7: Validation & Test Plan (NEW)

Establish the verification regime that prevents this artifact from relying on "PR review enforces" for security-critical controls.

**Acceptance Criteria:**

- **CI gate (new)**: a CI step runs `terraform -chdir=baseline/terraform init -backend=false && terraform -chdir=baseline/terraform validate` against this repo — succeeds without AWS credentials, fails on syntax or `validation {}` block failures.
- **Static security check (new)**: a CI step (Conftest/OPA rule OR grep equivalent) fails the build if `iam-oidc-federation.tf` contains the string `StringLike` in any condition clause. Rule file lives at `.github/policy/oidc-no-stringlike.rego` or equivalent.
- **Trust-policy snapshot test**: a `terraform test` block (Terraform 1.6+) or equivalent in `baseline/terraform/tests/oidc-federation.tftest.hcl` synthesizes the role with a stub permission policy and asserts the trust policy contains: exactly `StringEquals`, exactly one `aud` and one `sub` condition per role, federated principal references `aws_iam_openid_connect_provider.this[0].arn`. Runs in CI without AWS creds.
- **Named test account**: the AFT team identifies one already-vended non-security-tier test account by ID and records it in `docs/oidc/test-account.md`. Feature 4 must apply cleanly against this account before fleet rollout.
- **Pre-rollout checklist**: `docs/oidc/rollout-checklist.md` enumerates the steps from "flag flipped to `true` in test account" through "all accounts verified." Includes pause points and rollback triggers.
- **Failure-mode runbook**: `docs/oidc/failure-modes.md` enumerates the four failure modes from the arch doc's Failure Modes & Recovery section and the exact operator action for each.
- **Boundary compatibility analysis**: `docs/oidc/boundary-compatibility-analysis.md` (also referenced by Feature 4) is checked in before Feature 4 merges.

## Configuration

### Required (when `oidc_federation_enabled = true`)

| Parameter | Type | Validation | Description |
|-----------|------|------------|-------------|
| `oidc_thumbprints` | `list(string)` | each entry matches `^[A-Fa-f0-9]{40}$`; non-empty when enabled | SHA-1 thumbprints of the cluster issuer's CA chain. Supplied by K8s Platform team after Layer A is live. List form supports CA rotation overlap (up to 5 entries — AWS limit). |

### Optional

| Parameter | Type | Default | Validation | Description |
|-----------|------|---------|------------|-------------|
| `oidc_federation_enabled` | `bool` | `false` | — | Master feature flag. When `false`, no OIDC resources are created (zero state churn). Must be set to `true` per-account to roll out federation. |
| `oidc_federation_security_tier_accounts` | `bool` | `false` | — | When `false`, federation is skipped in Audit and Log Archive accounts (see Blast Radius Analysis in arch doc). Set to `true` only after a documented threat-model review. |
| `oidc_issuer_url` | `string` | `https://oidc.k8s.occ.ottawacloudconsulting.com` | matches `^https://[a-z0-9.\-]+$` | Cluster OIDC issuer URL. Pinned by hand-off §R2.1. Validation rejects trailing slash, mixed case, missing scheme. |
| `oidc_audience` | `string` | `sts.amazonaws.com` | non-empty | Default audience claim. Per-role override available via JSON wrapper. |
| `oidc_federation_role_prefix` | `string` | `""` | empty or kebab-case | Prefix prepended to discovered role names unless the JSON wrapper sets `role_name_override`. Empty default preserves the hand-off-pinned `crossplane-aws-iam` name at MVP. |

Per-role configuration (subject, audience override, boundary key, name override, permission policy) is encoded in each `oidc-federation-policies/<role-key>.json` wrapper — see "JSON wrapper schema" above.

## Outputs

| Output | Type | Description |
|--------|------|-------------|
| `oidc_provider_arn` | `string` or `null` | Per-account provider ARN. `null` when feature flag is off — consumers detect off-state without parsing. |
| `oidc_federation_role_arns` | `map(string)` | Map of role-key → role ARN. Empty map when flag is off. |
| `oidc_module_version` | `string` | Module version (git tag or short SHA) that produced these resources. Records provenance into K8s team's `M01-verification.md`. Closes REQUIREMENTS-OIDC.md output #3. |

Outputs are surfaced in CodeBuild logs at AFT customization time. The K8s Platform team transcribes them into their `docs/oidc/M01-verification.md` via the operational handoff defined below. Persistent capture (SSM, DynamoDB writeback) is a future enhancement.

## Operational handoff

The arch doc's Failure Modes & Recovery section formalizes this; summarized here:

- **AFT operator on duty** (named role, rotated weekly — owner: AFT team lead): after every AFT run that creates or modifies OIDC resources, copies the three outputs to the K8s team's `docs/oidc/M01-verification.md` and posts a notification to the `#cluster-oidc` Slack channel.
- **Cross-account log access**: K8s Platform team members have read-only access to the AFT management account's CodeBuild log group `/aws/codebuild/aft-account-customizations` via the existing read-only IAM role; documented in `docs/oidc/access.md`.
- **AFT re-trigger for already-vended accounts**: after merge, the AFT operator runs the AFT customization re-run mechanism (typically `aft-invoke-customizations` SSM doc or equivalent — exact command in `docs/oidc/rollout-checklist.md`) against the named test account first, then in batches of ≤ 10 accounts per day, verifying outputs between batches.

## Risk Assessment

| Risk | Mitigation |
|------|-----------|
| Thumbprint drift after CA rotation causes silent `AccessDenied` from STS. | `var.oidc_thumbprints` is `list(string)` with rotation overlap. Rotation Runbook (arch doc) names: K8s-team handshake required between phase 1 (add new) and phase 2 (remove old); minimum 48h overlap window; bounded per-account apply latency; fallback to last-known-good via state restore if both thumbprints fail. |
| K8s-supplied permission policy contains actions denied by `Boundary-Default`, causing silent runtime failures. | **Acceptance criterion**: pre-flight intersection analysis (`docs/oidc/boundary-compatibility-analysis.md`) committed before Feature 4 merges. If intersection is empty for any required action, a new boundary file is added under `boundary-policies/` and the JSON wrapper's `boundary_key` is updated. |
| Trust-policy wildcard regression (someone introduces `StringLike` in a refactor) opens cross-tenant token acceptance. | **Automated CI check** (Feature 7): static rule fails the build if `iam-oidc-federation.tf` contains `StringLike`. **Snapshot test** (Feature 7) asserts trust-policy structure. PR review is defense-in-depth, not the primary control. |
| Renaming a JSON file in `oidc-federation-policies/` after first deploy changes the `for_each` key and forces role destroy/recreate, breaking active K8s ServiceAccount bindings. | `lifecycle { prevent_destroy = true }` on the role resource. Documented constraint in `oidc-federation-policies/README.md`. Symmetric constraint on `boundary-policies/Default.json` rename (would break OIDC `boundary_key` lookup) documented in `boundary-policies/README.md`. |
| Issuer URL drift (trailing slash, case, scheme) causes silent provider/role mismatch. | `validation` block on `var.oidc_issuer_url` rejects drift at variable-input time. Trust policy references `aws_iam_openid_connect_provider.this[0].arn`/`.url` directly — AWS-normalized — so it does not parse the variable into the trust policy. |
| Permission boundary missing at role creation → SCP denies `iam:CreateRole` for non-`org-*` role. | Role declares `permissions_boundary` at creation (Feature 4 acceptance). **SCP verification** (Feature 7 pre-rollout checklist): confirm `iam:CreateOpenIDConnectProvider` and `iam:CreateRole` on `target_admin_role_arn` are not denied in the OU SCP; link SCP source-of-truth in `docs/oidc/scp-verification.md`. |
| Role name `crossplane-aws-iam` collides with a future federated workload. | `var.oidc_federation_role_prefix` (default `""`) allows future workloads to namespace via `${prefix}-${key}`. MVP keeps the pinned name via `role_name_override` in the JSON wrapper. |
| Layer A is not live when AFT runs → provider URL fails OIDC discovery on token validation. | Provider create-time does not validate. End-to-end federation test (K8s team) is the cutover gate. Optional pre-apply probe in `pre-api-helpers.sh` may be added in Feature 3 if K8s team requests it — documented as a deferred enhancement. |
| Partial apply leaves orphan provider + missing role. | Failure Modes & Recovery section in arch doc enumerates the four failure modes and rerun-safety of each. Both provider and role are net-new resources; rerun is idempotent. |
| Federation deployed into security-tier accounts (Audit, Log Archive) increases blast radius. | `var.oidc_federation_security_tier_accounts` defaults to `false`. Blast Radius Analysis (arch doc) enumerates account types and the explicit decision per type. Opt-in only after documented review. |
| External hand-off doc drift (specs in K8s team's repo change without notification). | Pinned-specifications subsection of `platform-team-handoff.md` is snapshotted into `REQUIREMENTS-OIDC.md` with commit SHA and date (Feature 1 acceptance). |

## External Dependencies

| Dependency | Owner | Status | Blocks |
|------------|-------|--------|--------|
| Layer A — singleton OIDC discovery host | Application Team (per `DESCOPE.md`) | Pending | Setting `oidc_federation_enabled = true` in any account. Code merge is **not** blocked. |
| CA thumbprint list | K8s Platform team | Pending Layer A | Flipping `oidc_federation_enabled = true`. Required input when enabled. |
| Permission policy JSON for `crossplane-aws-iam` | K8s Platform team (M03 closure window) | Pending | Boundary intersection analysis (Feature 4 / Feature 7). A stub policy may land first to unblock Features 2–3 under the flag. |
| Joint boundary-policy review (M03) | Joint (AFT side + K8s Platform team) | Pending | Feature 4 merge — gated by `docs/oidc/boundary-compatibility-analysis.md`. |
| AFT-OU SCP source-of-truth + verification | AFT team (link in `docs/oidc/scp-verification.md`) | Pending | Feature 7 pre-rollout checklist. |

## Success Criteria

Per-account, after flag is flipped:

- `aws iam get-open-id-connect-provider --open-id-connect-provider-arn <arn>` returns the configured URL, `ClientIDList` = union of `var.oidc_audience` and per-role audiences, and `ThumbprintList = var.oidc_thumbprints`.
- `aws iam get-role --role-name <computed-name>` returns a trust policy whose `Federated` principal ARN matches the per-account provider, conditions use only `StringEquals` on `aud` and `sub`, no wildcards, permission boundary attached.
- Role permission policy content matches the rendered template output for the JSON wrapper's `policy` field.
- `assume-role-with-web-identity` events appear in the Control Tower org-trail.
- `terraform apply` succeeds under the AFT execution role for the named test account, then for the staged rollout batches; outputs are recorded into K8s team's `M01-verification.md` for every account.
- The CI gate (Feature 7) passes on `main`.

Items 4 and 5 from hand-off §R2.5 (end-to-end federation test, tamper-token rejection) are validated by the K8s Platform team and are out of AFT scope.

## Future Enhancements

| Enhancement | Description |
|-------------|-------------|
| Persistent output capture | SSM Parameter Store writeback (`/oidc/federation/provider_arn`, `/oidc/federation/role_arns/<key>`) so downstream consumers don't scrape CodeBuild logs. Eliminates the operational handoff dependency. |
| Multi-issuer support | If a second cluster emerges, refactor `aws_iam_openid_connect_provider.this` from `count` to `for_each` over `local.oidc_issuers` map. State migration via `moved` blocks. |
| Pre-flight Layer A health probe | `pre-api-helpers.sh` curl probe against `${var.oidc_issuer_url}/.well-known/openid-configuration` before apply; fails fast on Layer A outage. |
| Per-account-type opt-out granularity | Today the security-tier toggle is binary. Replace with a map keyed by account-type tag if more granularity is needed. |
| Account-type discovery via tags | `local.is_security_tier_account` currently derived from a hardcoded ID list — switch to AWS Organizations tag lookup once the org tagging strategy is finalized. |

## Open Questions

All five questions from REQUIREMENTS-OIDC.md are closed (or have a clear resolution path) in this PRD:

| # | Question | Resolution |
|---|----------|------------|
| Q1 | Final thumbprint value(s) after Layer A goes live | **Decoupled from merge.** `var.oidc_thumbprints` defaults to `[]`; required only when `oidc_federation_enabled = true`. K8s team supplies values when Layer A is live; AFT operator flips the flag per-account. |
| Q2 | Permission policy JSON for `crossplane-aws-iam` | **Pending M03**, but does not block merge. Stub JSON wrapper lands with Feature 4; real policy replaces it at M03. Final apply blocked on real policy + intersection analysis (Feature 4 / Feature 7 acceptance). |
| Q3 | Does the supplied permission policy fit inside `Boundary-Default`? | **Acceptance-gated.** `docs/oidc/boundary-compatibility-analysis.md` required before Feature 4 merges. Per-role `boundary_key` in JSON wrapper supports a different boundary if needed. |
| Q4 | Owner prefix on role names | **Closed.** Hand-off pins MVP role name to `crossplane-aws-iam` (kept via `role_name_override`). `var.oidc_federation_role_prefix` exists for future workloads (default `""`). Decision: keep MVP unprefixed; future workloads decide per-merge. |
| Q5 | `prevent_destroy = true` on provider and role | **Closed: yes.** Applied at MVP. Rationale: K8s ServiceAccounts bind to role ARN; an accidental destroy via JSON-file rename or boundary-file rename would break federation fleet-wide. |
