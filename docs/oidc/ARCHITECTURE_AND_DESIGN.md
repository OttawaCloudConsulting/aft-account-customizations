# Architecture and Design: OIDC Cluster Federation (Layer B, AFT-side)

## Overview

AFT's baseline customization provisions per-account IAM OIDC federation primitives that let pods in the OCC Kubernetes cluster (`oidc.k8s.occ.ottawacloudconsulting.com`) assume per-account workload roles via `sts:AssumeRoleWithWebIdentity`. The MVP creates one `aws_iam_openid_connect_provider` plus one workload role (`crossplane-aws-iam`) bound to the `crossplane-provider-aws:provider-aws-iam` ServiceAccount in every AFT-vended non-security-tier account, gated by an explicit feature flag (`var.oidc_federation_enabled`, default `false`).

This document is the single source-of-truth for the OIDC federation design. The PRD (`prd.md`) references this doc for diagrams, component inventory, and design decisions.

This is Layer B of the cluster-OIDC-issuer-pod-identity project. Layer A (the OIDC discovery host: S3 + CloudFront + ACM + Route53) is owned by the Application Team and out of scope here — see `DESCOPE.md` and `REQUIREMENTS-OIDC.md`.

## Component Diagram

```
                 baseline/terraform/
                 ┌──────────────────────────────────────────────────────┐
                 │ variables.tf                                          │
                 │   var.oidc_federation_enabled       (bool, default F) │
                 │   var.oidc_federation_security_tier_accounts (bool,F) │
                 │   var.oidc_issuer_url               (default pinned)  │
                 │   var.oidc_thumbprints              (list, default [])│
                 │   var.oidc_audience                 (default sts.*)   │
                 │   var.oidc_federation_role_prefix   (default "")      │
                 │   var.audit_account_id              (default "")      │
                 │   var.log_archive_account_id        (default "")      │
                 │                                                       │
                 │ iam-oidc-federation.tf                                │
                 │   aws_iam_openid_connect_provider.this  (count=0|1)   │
                 │     lifecycle { prevent_destroy = true }              │
                 │   local.oidc_federation_roles =                       │
                 │     { for f in fileset("oidc-federation-policies",    │
                 │                         "*.json") =>                  │
                 │         trimsuffix(f,".json") =>                      │
                 │           jsondecode(file(...)) }                     │
                 │   aws_iam_role.federation (for_each over roles)       │
                 │     ├── trust → this[0].arn / this[0].url             │
                 │     ├── permissions_boundary = boundaries[bk].arn     │
                 │     ├── policy = templatefile(...) of wrapper.policy  │
                 │     └── lifecycle { prevent_destroy = true }          │
                 │                                                       │
                 │ outputs.tf                                            │
                 │   oidc_provider_arn         (string|null)             │
                 │   oidc_federation_role_arns (map)                     │
                 │   oidc_module_version       (string)                  │
                 │                                                       │
                 │ oidc-federation-policies/                             │
                 │   README.md     (wrapper schema + immutability)       │
                 │   crossplane-aws-iam.json   (M03 supply)              │
                 │     { subject, audience?, boundary_key?,              │
                 │       role_name_override?, policy }                   │
                 │                                                       │
                 │ tests/oidc-federation.tftest.hcl  (Feature 7)         │
                 └──────────────────────────────────────────────────────┘
                                  │
                                  ▼  terraform apply (per account, when enabled)
       ┌─────────────────────────────────────────────────────────┐
       │ AWS account (every AFT-vended account when flag on,     │
       │   excluding Audit + Log Archive unless opted in)        │
       │                                                          │
       │  IAM OIDC Provider (.this[0])                            │
       │   url: oidc.k8s.occ.ottawacloudconsulting.com            │
       │   client_id_list: union(audience, per-role audiences)    │
       │   thumbprints: <var.oidc_thumbprints>                    │
       │   lifecycle: prevent_destroy                             │
       │                                                          │
       │  IAM Role: crossplane-aws-iam                            │
       │   trust → AssumeRoleWithWebIdentity                      │
       │     Federated: this[0].arn  ← resource attribute, NOT    │
       │                                string interpolation      │
       │     Condition: StringEquals                              │
       │       ${this[0].url}:aud = audience                      │
       │       ${this[0].url}:sub = subject                       │
       │   permissions_boundary: boundaries[boundary_key].arn     │
       │   policy: templatefile(wrapper.policy, vars)             │
       │   lifecycle: prevent_destroy                             │
       └─────────────────────────────────────────────────────────┘
                                  ▲
                                  │ AssumeRoleWithWebIdentity
                                  │ (projected SA token)
       ┌─────────────────────────────────────────────────────────┐
       │ K8s cluster pod                                          │
       │  ServiceAccount: crossplane-provider-aws/provider-aws-iam│
       │  Token: aud=sts.amazonaws.com,                           │
       │         sub=system:serviceaccount:<ns>:<sa>              │
       └─────────────────────────────────────────────────────────┘
```

## Data Flow

1. AFT CodeBuild triggers on account vend (or operator-driven replay) with `CUSTOMIZATION=baseline`.
2. Jinja-rendered `aft-providers.tf`, `backend.tf`, `locals-aft.tf` resolve provider config, backend, AFT management account ID.
3. `terraform init && terraform apply` runs in `baseline/terraform/`.
4. **Feature flag check**: if `var.oidc_federation_enabled = false`, no OIDC resources are created. Empty map outputs. Done.
5. **Account-type check**: if the account is a security-tier account (Audit, Log Archive) and `var.oidc_federation_security_tier_accounts = false`, no OIDC resources are created. Empty outputs.
6. Otherwise, `aws_iam_openid_connect_provider.this[0]` is created with the issuer URL, audience union, and CA thumbprints.
7. `fileset("oidc-federation-policies", "*.json")` discovers per-role JSON wrappers. For each:
   - `precondition` blocks validate the wrapper schema (`subject`, `policy` required; computed role name ≤ 64 chars; `boundary_key` exists in `aws_iam_policy.boundaries`).
   - `aws_iam_role.federation[<key>]` is created. Trust policy references `aws_iam_openid_connect_provider.this[0].arn` directly. Conditions use `aws_iam_openid_connect_provider.this[0].url` directly.
   - `aws_iam_role_policy` attaches the rendered permission policy (templated with `account_id`, `region`, `cluster_issuer_host`).
   - `permissions_boundary` resolves the boundary via `boundary_key` (default `"Default"`).
8. `outputs.tf` emits provider ARN, role-ARN map, and module version.
9. AFT operator on duty (named role) copies outputs to K8s Platform team's `docs/oidc/M01-verification.md` and posts to `#cluster-oidc` Slack (defined operational handoff).
10. At pod runtime, the K8s cluster issues a projected ServiceAccount token. STS validates the token against the per-account OIDC provider; the trust policy's `StringEquals` matches; the pod receives short-lived AWS credentials scoped by the role's policy ∩ boundary.

## Component Inventory

| # | Component | Terraform Type | Purpose |
|---|-----------|----------------|---------|
| 1 | Feature flag | `var.oidc_federation_enabled` (bool) | Master gate. Default `false` — zero state churn. |
| 2 | Account-type gate | `var.oidc_federation_security_tier_accounts` (bool) + `local.is_security_tier_account` | Excludes Audit/Log Archive by default. |
| 3 | OIDC provider | `aws_iam_openid_connect_provider.this` (`count = local.oidc_provider_count`) | Per-account trust anchor. `prevent_destroy`. |
| 4 | Federation roles | `aws_iam_role.federation` (`for_each` over discovered roles, gated by flag) | One IAM role per JSON wrapper. `prevent_destroy`. |
| 5 | Role permission policies | `aws_iam_role_policy` (inline; templated via `templatefile()`) | Attaches the wrapper's `policy` to the role with template vars resolved. |
| 6 | Permission-boundary attachment | `permissions_boundary` argument referencing `aws_iam_policy.boundaries[boundary_key]` | Per-role boundary via `boundary_key` field in wrapper. |
| 7 | Policy directory | `baseline/terraform/oidc-federation-policies/` | `fileset()` discovery target. Filenames (minus `.json`) become role keys. |
| 8 | JSON wrapper schema | `jsondecode(file(...))` returns `{subject, audience?, boundary_key?, role_name_override?, policy}` | All per-role config in one file. Schema enforced by `precondition`. |
| 9 | Input variables | 6 variables with `validation` blocks (see Configuration section) | Fail-fast at plan time on format drift. |
| 10 | Tag set | `local.oidc_federation_tags` | Merge of `local.common_tags` + OIDC-specific tags. Applied to provider and role. |
| 11 | Outputs | `oidc_provider_arn`, `oidc_federation_role_arns`, `oidc_module_version` | Surfaces ARNs + provenance in CodeBuild logs. |
| 12 | Validation (CI) | `terraform validate`, OPA/grep rule, `terraform test` snapshot | Automated controls — not "PR review enforces." See Validation Strategy below. |
| 13 | Failure modes runbook | `docs/oidc/failure-modes.md` | Documented operator actions for each failure mode. |

## Hand-off pinned specifications (snapshotted from K8s Platform team)

Snapshotted from `platform-team-handoff.md` (K8s Platform team repo) §R2.1, commit `<TBD-pin-on-merge>`, date 2026-05-15. Re-snapshot on every change.

| # | Item | Value |
|---|------|-------|
| 1 | OIDC provider URL | `https://oidc.k8s.occ.ottawacloudconsulting.com` |
| 2 | ClientIDList (audience) | `["sts.amazonaws.com"]` (default; per-role overrides allowed via wrapper) |
| 3 | ThumbprintList | SHA-1 of issuing CA leaf — supplied by K8s Platform team after Layer A is live |
| 4 | First role name | `crossplane-aws-iam` (preserved via `role_name_override` in wrapper) |
| 5 | Trust policy conditions | `StringEquals` on both `aud=sts.amazonaws.com` AND `sub=system:serviceaccount:crossplane-provider-aws:provider-aws-iam` — exact strings, no wildcards |
| 6 | Trust policy `Principal` | `arn:aws:iam::<accountId>:oidc-provider/oidc.k8s.occ.ottawacloudconsulting.com` (resolved via `aws_iam_openid_connect_provider.this[0].arn`, not string interpolation) |

## Security Model

### Trust Policy Conditions

The federation role's `AssumeRoleWithWebIdentity` trust statement uses `StringEquals` on two keys — `aud` and `sub` — with both keys derived from the OIDC provider resource attribute, not from `var.oidc_issuer_url`:

```hcl
assume_role_policy = jsonencode({
  Version = "2012-10-17"
  Statement = [{
    Effect    = "Allow"
    Action    = "sts:AssumeRoleWithWebIdentity"
    Principal = { Federated = aws_iam_openid_connect_provider.this[0].arn }
    Condition = {
      StringEquals = {
        "${aws_iam_openid_connect_provider.this[0].url}:aud" = coalesce(each.value.audience, var.oidc_audience)
        "${aws_iam_openid_connect_provider.this[0].url}:sub" = each.value.subject
      }
    }
  }]
})
```

No wildcards. No `StringLike`. Either condition mismatching produces `AccessDenied` — desired behavior. **Automated CI check** (Feature 7) fails the build if `StringLike` appears in `iam-oidc-federation.tf`. **Snapshot test** asserts trust-policy structure on every run.

### Why resource attributes, not string interpolation

`aws_iam_openid_connect_provider.this[0].arn` and `.url` are normalized by AWS post-creation. Using them eliminates three drift modes:

- **Trailing slash on `var.oidc_issuer_url`**: `replace()` strips only the scheme; AWS strips trailing slashes from the provider URL. Mismatch would be permanent if the trust policy parsed the variable.
- **`http://` scheme**: not stripped by naive `replace()`.
- **Case drift**: not normalized.

Defense-in-depth: `validation` block on `var.oidc_issuer_url` rejects these formats at variable-input time anyway.

### Permission Boundary

`crossplane-aws-iam` does not match the `org-*` protected prefix, so the org-level SCP (CLAUDE.md §Security Architecture — Layer 1) requires a `Boundary-*` permission boundary at role creation. The role resolves the boundary via the wrapper's `boundary_key` field (default `"Default"`):

```hcl
permissions_boundary = aws_iam_policy.boundaries[coalesce(each.value.boundary_key, "Default")].arn
```

A `precondition` block asserts the key exists in `aws_iam_policy.boundaries` — fails at plan time rather than apply if a wrapper references a non-existent boundary.

The K8s-team-supplied permission policy must be a subset of the chosen boundary. `docs/oidc/boundary-compatibility-analysis.md` (Feature 4 + Feature 7 acceptance criterion) records the intersection analysis before Feature 4 merges. If the supplied policy needs actions the default boundary denies, a new file is added under `boundary-policies/` and the wrapper's `boundary_key` is updated — not the boundary's deny envelope relaxed.

### Per-Account Principal Resolution

The federated principal in the trust policy is `aws_iam_openid_connect_provider.this[0].arn` — resolved by Terraform from the per-account provider created in the same apply. No `data.aws_caller_identity` substitution needed for the trust policy.

A `precondition` on the provider asserts `data.aws_caller_identity.current.account_id != local.aft_management_account_id` — defense against future provider-alias misconfiguration.

### Thumbprint Rotation Runbook

`var.oidc_thumbprints` is a `list(string)`. AWS allows up to 5 entries per provider.

1. **Phase 1 (add new)**: K8s Platform team announces upcoming rotation. AFT operator sets `oidc_thumbprints = [old, new]` and runs AFT customization re-run in batches of ≤ 10 accounts per day.
2. **Overlap window** (minimum 48h): both thumbprints active. K8s Platform team confirms readiness for cutover via `#cluster-oidc` Slack.
3. **Phase 2 (remove old)**: AFT operator sets `oidc_thumbprints = [new]` and re-runs.
4. **Fallback**: if both thumbprints fail, revert via `terraform state` rollback or re-set the previous value and re-apply. The K8s team supplies a known-good current value before the rollback.

Per-account apply latency × accounts must complete within the K8s rotation window — if not, K8s team pauses rotation. Maximum AFT lag bounded by the per-batch verification step.

### Audit and Logging

`assume-role-with-web-identity` events flow to the Control Tower organization trail by default. No additional logging configuration is required.

### Blast Radius Analysis

| Account type | Receive federation? | Rationale |
|--------------|---------------------|-----------|
| Workload accounts | Yes (default) | Primary use case — Crossplane providers run in workload accounts. |
| Future accounts (vended after merge) | Yes (default) | Universal baseline. |
| AFT management account | No | Already trusts cluster via existing pipeline; adding a workload-grade trust would expand blast radius unnecessarily. Implementation: `local.is_security_tier_account` returns `true` for this account ID. |
| Audit account | No (opt-in via `var.oidc_federation_security_tier_accounts = true`) | Control Tower security-tier account. Federation would introduce a non-audit IAM identity into an account that should be most isolated. Threat model: a compromised SA token could attempt `AssumeRoleWithWebIdentity` against the audit account; permission boundary mitigates but blast radius is still expanded. |
| Log Archive account | No (opt-in) | Same rationale as Audit. |

`local.is_security_tier_account` is derived from `local.security_tier_account_ids`, the union of:

- `local.aft_management_account_id` — extracted from the AFT-injected admin role ARN in the rendered `locals-aft.tf`.
- `var.audit_account_id` — operator-supplied via tfvars; default `""`.
- `var.log_archive_account_id` — operator-supplied via tfvars; default `""`.

`compact()` drops empty strings so default-empty variables don't expand the exclusion set. Cross-variable validation on both account-ID variables blocks `terraform plan` when `oidc_federation_enabled = true` and `oidc_federation_security_tier_accounts = false` but either ID is unset — so the default-deny guard cannot be silently bypassed by forgetting to set the variable. Future enhancement: switch to AWS Organizations tag lookup once org-tagging strategy is finalized.

## File Organization

```
baseline/terraform/
├── variables.tf                              # MODIFIED: + 6 OIDC variables with validation blocks
├── locals.tf                                 # MODIFIED: + oidc_federation_tags, oidc_provider_count, is_security_tier_account
├── iam-oidc-federation.tf                    # NEW: provider, roles, policy attachments
├── outputs.tf                                # MODIFIED: + oidc_provider_arn, oidc_federation_role_arns, oidc_module_version
├── oidc-federation-policies/                 # NEW: discovery directory
│   ├── README.md                             # NEW: wrapper schema docs + immutability constraint
│   └── crossplane-aws-iam.json               # NEW: K8s-team-supplied wrapper (M03)
├── tests/                                    # NEW: Feature 7
│   └── oidc-federation.tftest.hcl            # NEW: trust-policy snapshot test (no AWS creds)
├── iam-permission-boundaries.tf              # UNCHANGED — referenced for boundary attachment
├── iam-deployment-roles.tf                   # UNCHANGED
└── boundary-policies/
    ├── README.md                             # NEW (or extended): symmetric-rename constraint
    ├── Default.json
    └── ReadOnly.json

docs/oidc/                                    # NEW: operational artifacts
├── boundary-compatibility-analysis.md        # Feature 4 + Feature 7 acceptance
├── test-account.md                           # Feature 7: named test account ID
├── rollout-checklist.md                      # Feature 7: staged rollout procedure
├── failure-modes.md                          # Feature 7: failure modes & recovery
├── scp-verification.md                       # Feature 7: SCP allowance evidence
└── access.md                                 # K8s team's CodeBuild log access path

.github/policy/                               # NEW: CI policy rules
└── oidc-no-stringlike.rego                   # Feature 7: static check
```

## Configuration

### Required (when `oidc_federation_enabled = true`)

| Variable | Type | Validation | Description |
|----------|------|------------|-------------|
| `oidc_thumbprints` | `list(string)` | each entry matches `^[A-Fa-f0-9]{40}$`; non-empty when enabled | SHA-1 thumbprints of issuer's CA chain. AWS allows up to 5 entries (rotation overlap). |

### Optional

| Variable | Type | Default | Validation | Description |
|----------|------|---------|------------|-------------|
| `oidc_federation_enabled` | `bool` | `false` | — | Master feature flag. |
| `oidc_federation_security_tier_accounts` | `bool` | `false` | — | When `true`, allows federation in Audit/Log Archive. Requires documented threat-model review. |
| `oidc_issuer_url` | `string` | `https://oidc.k8s.occ.ottawacloudconsulting.com` | `^https://[a-z0-9.\-]+$` | Pinned by hand-off §R2.1. |
| `oidc_audience` | `string` | `sts.amazonaws.com` | non-empty | Default audience; per-role override via JSON wrapper. |
| `oidc_federation_role_prefix` | `string` | `""` | empty or kebab-case | Prepended to role names unless wrapper sets `role_name_override`. |

## Outputs

| Output | Type | Description |
|--------|------|-------------|
| `oidc_provider_arn` | `string` or `null` | Per-account provider ARN. `null` when flag is off. |
| `oidc_federation_role_arns` | `map(string)` | Map of role-key → role ARN. Empty when flag is off. |
| `oidc_module_version` | `string` | Module version (git tag/SHA) that produced these resources. Source: CI-set local or static literal. |

## Validation Strategy

The artifact relies on **automated controls**, not on "PR review enforces":

| Control | Type | Failure consequence |
|---------|------|---------------------|
| `terraform init -backend=false && terraform validate` | CI step; works without AWS creds | Fails the build on syntax errors or `validation {}` block violations. |
| `validation {}` blocks on all 6 OIDC variables | Plan-time fail-fast | Wrong format → fail at plan, before any state change. |
| OPA/grep rule `oidc-no-stringlike` | CI policy check | Fails the build if `StringLike` appears in `iam-oidc-federation.tf`. |
| `terraform test` snapshot in `tests/oidc-federation.tftest.hcl` | Synthesizes role + asserts trust-policy structure | Fails the build if trust policy deviates from spec. |
| `precondition` blocks on the role resource | Plan-time fail-fast | Wrapper missing required fields, boundary key non-existent, role name >64 chars, or account is security-tier without opt-in → fail at plan. |
| Boundary compatibility analysis (`docs/oidc/boundary-compatibility-analysis.md`) | Pre-merge gate | Feature 4 cannot land without committed analysis. |
| Rollout checklist (`docs/oidc/rollout-checklist.md`) | Operational gate | Per-account verification between batches. |

PR review is defense-in-depth on top of these — not the primary control for any security-critical guarantee.

## Failure Modes & Recovery

| # | Failure mode | Detection | Recovery | Rerun-safe? |
|---|--------------|-----------|----------|-------------|
| 1 | Provider create succeeds; role create denied by SCP | `terraform apply` error during role create | Investigate SCP per `docs/oidc/scp-verification.md`; fix SCP allowance; re-apply. Orphan provider stays — it is `prevent_destroy`, so cleanup is intentional after SCP is fixed. | Yes — Terraform retries role create idempotently. |
| 2 | Thumbprint list rejected at AWS API (malformed SHA-1) | `terraform apply` error during provider create | `validation {}` block on `var.oidc_thumbprints` catches this at plan time — should not reach apply. If somehow it does (e.g., template-rendered value), fix the input and re-apply. No resources created. | Yes — no state churn. |
| 3 | JSON wrapper malformed (missing required field) | `terraform plan` `precondition` block fails | Fix wrapper file; re-apply. Provider (if already created) remains untouched; role create deferred. | Yes — `precondition` blocks any state change. |
| 4 | Boundary-incompatibility (policy ∩ boundary = ∅ for required action) | Runtime `AccessDenied` at pod token-to-AWS-API call; no Terraform signal | K8s team detects in M01 verification or pod logs. AFT-side: review `docs/oidc/boundary-compatibility-analysis.md`; if policy needs new boundary, add file to `boundary-policies/` and update wrapper's `boundary_key`. | Yes — `boundary_key` change is idempotent. |
| 5 | Partial state from a Terraform crash mid-apply | Account ends with provider + no role, or provider + partial roles | Re-apply is idempotent: Terraform reconciles to declared state. `prevent_destroy` blocks accidental rollback. | Yes — idempotent. |
| 6 | JSON wrapper file renamed accidentally | `for_each` key changes → would destroy old role + create new | `lifecycle { prevent_destroy = true }` on role blocks the destroy. Terraform errors out with a clear message. Operator un-renames file or uses `terraform state mv` deliberately. | Yes — destroy is blocked. |
| 7 | Boundary file renamed (e.g., `Default.json` → `Foo.json`) | Federation role's `boundary_key` lookup returns nil → `precondition` fails at plan | Restore the boundary filename or update wrapper's `boundary_key`. No apply happens. | Yes — `precondition` blocks any state change. |
| 8 | Layer A not live → provider created but token validation fails | K8s team detects in M01 verification (post-merge handoff). No Terraform signal. | Wait for Layer A. AFT-side resources remain valid; no churn needed. | Yes — Terraform-side is correct; runtime gates on Layer A. |

## Design Decisions

| # | Decision | Alternatives considered | Rationale |
|---|----------|-------------------------|-----------|
| 1 | Gate all OIDC resources behind `var.oidc_federation_enabled` (default `false`) | (a) Required vars with no flag; (b) Empty-list default on thumbprints triggering `count = length > 0 ? 1 : 0` | (a) breaks AFT pipeline in every existing account until thumbprints supplied (P0 outage); (b) implicit flag is hard to discover. Explicit flag makes the cutover sequence reviewable and reversible. |
| 2 | Code lives in `baseline/terraform/` | `core/` only, `workload/` only, new top-level customization | Universal scope. Account-type filtering handled by `local.is_security_tier_account`, not by AFT customization stage. Existing IAM governance is here. |
| 3 | Per-role JSON **wrapper** with `{subject, audience?, boundary_key?, role_name_override?, policy}` (NOT bare policy) | (a) Bare policy + HCL `local.oidc_federation_subjects` map; (b) Single discovery file; (c) HCL local | Adding a federated workload becomes a true one-file change. Eliminates the bare-map-lookup foot-gun (cryptic "Invalid index" when JSON file and HCL map drift). Per-role overrides (audience, boundary) become local to the workload's own file. Rejected (a) and (c) because they require two-file changes, contradicting the "mirrors boundary discovery" claim. Rejected (b) because per-workload JSON files map to per-workload code review. |
| 4 | `fileset()` discovery keyed by filename-minus-`.json` | `count`-based array, manifest file enumeration | Same pattern as `boundary-policies/`. Adding a workload = drop a JSON file. No array indexing, no resource address churn. |
| 5 | `var.oidc_issuer_url` exposed as variable (default pinned) AND validated at variable-input time | Hardcoded literal in `.tf` | Variable enables test/staging clusters. Default matches hand-off so out-of-the-box use needs no override. **Validation block** rejects drift (trailing slash, mixed case, missing scheme) — the trust policy never parses the variable into the policy itself, so even if validation slipped, drift would not silently mismatch. |
| 6 | `var.oidc_thumbprints` is `list(string)`, default `[]`, validated as 40-char hex when enabled | `string`, `set(string)`, required no-default | List supports rotation overlap (Rotation Runbook). AWS max 5 entries. Empty default lets the code merge before Layer A is live; validation requires non-empty when feature flag is on. |
| 7 | Trust policy uses `StringEquals` (never `StringLike`); enforced by **automated CI rule** | `StringLike`, mixed conditions | Hand-off §R2.1 row 5. Cross-tenant token acceptance is the highest-impact security risk. Manual review alone is insufficient (Theme 1 in red-team review): static rule `oidc-no-stringlike.rego` fails the build if `StringLike` appears in this file. Snapshot test asserts structure on every run. |
| 8 | Trust policy `Federated` principal = `aws_iam_openid_connect_provider.this[0].arn`; conditions use `.url` | (a) String interpolation `arn:aws:iam::${account_id}:oidc-provider/${host}`; (b) `data.aws_caller_identity` + `replace(var.oidc_issuer_url, "https://", "")` | (a) and (b) both vulnerable to trailing-slash, scheme, case drift in `var.oidc_issuer_url` — produces silent `AccessDenied`. Resource attributes are AWS-normalized. This decision eliminates the highest-impact technical failure mode in the original draft. |
| 9 | Permission boundary attached at role creation; **per-role `boundary_key`** in JSON wrapper (default `"Default"`) | Hardcoded `boundaries["Default"]` reference | SCP denies role create for non-`org-*` roles without a boundary. Hardcoded `"Default"` would force every federated workload to use the same boundary; the Crossplane provider may need a different one (Q3). `boundary_key` field is one HCL line at cost; the design survives Q3 unmodified. |
| 10 | Role name = `role_name_override` (if set) else `${prefix}-${key}` (if prefix) else `${key}` | (a) Always `${key}`; (b) Always require prefix | Hand-off pins MVP name to `crossplane-aws-iam`; `role_name_override` preserves it. `var.oidc_federation_role_prefix` (default `""`) gives future workloads prefix discipline without forcing a K8s-side ServiceAccount rename today. Closes Q4. |
| 11 | `lifecycle { prevent_destroy = true }` on provider AND role | No lifecycle protection (original draft); only on provider; only on role | K8s ServiceAccounts bind to the role ARN. An accidental `git mv` of a JSON or boundary file would destroy the role/provider and break federation fleet-wide. `prevent_destroy` blocks the destroy; an operator who genuinely needs to destroy can remove the lifecycle block deliberately. Closes Q5. |
| 12 | Outputs via Terraform `output` blocks (CodeBuild logs) at MVP; SSM/DynamoDB writeback as future enhancement | SSM writeback at MVP; no outputs | Hand-off §R2.4 records outputs in K8s team's `M01-verification.md` manually. **Operational handoff** is formalized: named AFT operator on duty, `#cluster-oidc` Slack notification, K8s team read-only access to CodeBuild logs via documented role. SSM writeback would eliminate the manual handoff — promoted to Future Enhancement with clear trigger. |
| 13 | Net-new resources only — no `moved` blocks; no destroy/recreate | Use `moved` blocks defensively | Greenfield IAM. Already-vended accounts gain new resources on next AFT run **after the flag is flipped**. When the flag is `false`, zero state churn. |
| 14 | Filenames in `oidc-federation-policies/` AND `boundary-policies/` are immutable post-deploy; documented in both directories' READMEs; reinforced by `prevent_destroy` and `precondition` | Allow renames via `moved` blocks | Renaming changes the `for_each` key; even with `moved` blocks the operational risk is high. `prevent_destroy` + `precondition` make accidental rename a hard fail at plan, not silent destroy at apply. |
| 15 | Outputs not marked `sensitive`; tagged via `local.oidc_federation_tags` | Marked `sensitive`; ad-hoc tagging | ARNs are not credentials; masking them defeats the verification workflow. Tagging is consistent with the rest of `baseline/` (merge of `local.common_tags` + OIDC-specific fields). |
| 16 | Permission policy attached via `aws_iam_role_policy` with `templatefile()`-style rendering over the wrapper's `policy` field | Plain `file()` of a raw JSON policy | K8s-supplied policies almost certainly reference per-account values (account_id, region). `templatefile()` available variables documented in `oidc-federation-policies/README.md` so the K8s team has the author contract before M03. |
| 17 | Security-tier accounts (Audit, Log Archive, AFT mgmt) excluded by default; opt-in via `var.oidc_federation_security_tier_accounts` | Universal scope including all account types | Control Tower security-tier accounts have strict isolation requirements. A workload-grade trust policy in those accounts expands blast radius without business justification. Opt-in mechanism preserved for future use cases that have completed a threat-model review. |
| 18 | Pinned-specifications subsection of `platform-team-handoff.md` snapshotted into this doc | Reference-by-citation only | External-doc drift is a documented assumption risk. Snapshot includes commit SHA + date; re-snapshot on every change. |

## Deployment Workflow

Standard AFT pipeline; no new plumbing in `pre-api-helpers.sh` at MVP (deferred enhancement: optional Layer A health probe). Rollout sequence:

1. PR merged to `main`. `var.oidc_federation_enabled` is still `false` everywhere — zero impact on existing pipeline runs.
2. CI gate (Feature 7) confirms `terraform validate`, OPA rule, and snapshot test pass.
3. AFT operator on duty flips `oidc_federation_enabled = true` and supplies `oidc_thumbprints` (from K8s team) in the **named test account** (per `docs/oidc/test-account.md`).
4. AFT customization re-run against the test account. Verify outputs; transcribe to K8s team's `M01-verification.md`; K8s team runs end-to-end federation test.
5. If test passes, AFT operator flips the flag in workload accounts in batches of ≤ 10 per day. Verification between batches per `docs/oidc/rollout-checklist.md`.
6. Already-vended accounts pick up the new resources on the next AFT customization run after the flag flip — explicit operator-driven trigger, not automatic on merge. (CLAUDE.md §Execution Flow: AFT triggers on vend or operator replay.)
7. K8s Platform team runs end-to-end federation test per account batch (out of AFT scope per hand-off §R2.5 items 4–5).

## Dependency Graph

```
Feature 1: Architecture and Design (this doc)
    └── unblocks all subsequent features

Feature 2: variables.tf + validation blocks + locals
    └── Feature 3: OIDC provider (flag-gated) + fileset() discovery + JSON wrapper schema
        └── Feature 4: First federation role + boundary intersection analysis
            ├── Feature 5: Outputs (provider ARN, role ARNs, module version)
            └── Feature 6: Documentation (README, CLAUDE.md, variable-naming-convention reconciliation)

Feature 7: Validation & Test Plan
    ├── Required CI gate before Features 2–6 are mergeable
    └── Boundary compatibility analysis is a Feature 4 acceptance criterion
```

External dependency: Q1 (thumbprints) and Q2 (permission policy JSON) gate **flipping the flag to `true`**, not merging the code. Feature flag makes the dependency chain mergeable in segments.

## State Impact

- All new resources — `aws_iam_openid_connect_provider.this[0]`, `aws_iam_role.federation[*]`, `aws_iam_role_policy[*]`.
- No `moved` blocks. No renames. No deletions of existing resources.
- **Zero state churn when `var.oidc_federation_enabled = false`** — `count = 0` and `for_each = {}` produce no plan diff against accounts that have never had OIDC resources.
- Already-vended accounts gain new resources on the next AFT run **after the flag is flipped**.
- `prevent_destroy` blocks accidental destroy via filename rename — operator must remove the lifecycle block deliberately.

## Out of Scope

| Item | Rationale |
|------|-----------|
| Layer A — OIDC discovery host | Owned by Application Team per `DESCOPE.md`. Cross-team contract: K8s Platform team supplies thumbprints once Layer A is live. |
| Federation in Audit and Log Archive | Excluded by default per Blast Radius Analysis. Opt-in via `var.oidc_federation_security_tier_accounts` after threat-model review. |
| Persistent output capture (SSM, DynamoDB) | Manual transcription via operational handoff at MVP. Promoted to Future Enhancement with clear trigger ("when output volume > N or new consumer emerges"). |
| End-to-end federation test (pod → STS → AWS) | K8s Platform team responsibility per hand-off §R2.5 items 4–5. AFT scope ends at `terraform apply` success and `aws iam get-*` matching the spec. |
| Tampered-token rejection test | K8s Platform team responsibility per hand-off §R2.5 item 5. |
| Sharing one OIDC provider across accounts | AWS recommends per-account providers for per-account IAM trust. |
| Multiple cluster issuers | MVP supports one issuer. Multi-issuer = refactor to `for_each` over `local.oidc_issuers` map. Deferred until a real second cluster exists. |
| Pre-apply Layer A health probe in `pre-api-helpers.sh` | Deferred enhancement — adds operational coupling between AFT and Layer A. Decision: defer unless K8s team requests it. |

## References

- `REQUIREMENTS-OIDC.md` — Scope decision, pinned specifications, open questions.
- `DESCOPE.md` — Layer A out-of-scope details handed to Application Team.
- `CLAUDE.md` §Security Architecture — Boundary policy interaction; protected prefix constraint.
- `baseline/terraform/iam-permission-boundaries.tf` — `fileset()` discovery pattern.
- `baseline/terraform/iam-deployment-roles.tf` — Existing IAM role patterns in baseline.
- `baseline/docs/variable-naming-convention.md` — Prefix-vs-pattern rule (reconciled in Feature 6 to remove the stale `Boundary-Default.json` reference).
- K8s Platform team hand-off — `platform-team-handoff.md` (their repo); pinned-specifications subsection snapshotted above with commit SHA pinned on merge.
- AFT-OU SCP source-of-truth — link in `docs/oidc/scp-verification.md` (created in Feature 7).
- Red-team consolidated report — `docs/red-team/architecture-and-design-oidc-01/CONSOLIDATED-REPORT.md` (32 findings resolved by this design revision).
