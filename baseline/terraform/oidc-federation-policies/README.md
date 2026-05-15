# oidc-federation-policies

Per-role JSON wrappers for OIDC federation. Each file in this directory becomes one IAM role
in every AFT-vended account when `var.oidc_federation_enabled = true`.

## Discovery mechanism

`iam-oidc-federation.tf` uses `fileset()` to discover every `*.json` file here.
The filename **minus the `.json` extension** is the role's key in the `for_each` map:

```
oidc-federation-policies/
  crossplane-aws-iam.json   →  aws_iam_role.federation["crossplane-aws-iam"]
  my-workload.json          →  aws_iam_role.federation["my-workload"]
```

Adding a federated workload = **drop one JSON file**. No Terraform locals, no variable
changes, no HCL edits required.

## JSON wrapper schema

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `subject` | string | **yes** | — | Exact `<issuer>:sub` condition value. Format: `system:serviceaccount:<namespace>:<sa-name>`. |
| `audience` | string | no | `var.oidc_audience` | Exact `<issuer>:aud` condition value. When set, this audience is also added to the provider's `client_id_list`. |
| `boundary_key` | string | no | `"Default"` | Key into `aws_iam_policy.boundaries`. Allows a per-role permission boundary. The key must exist in `boundary-policies/` — missing keys are caught by a `precondition` block at plan time. |
| `role_name_override` | string | no | `null` | If set, used verbatim as the IAM role name (must be ≤ 64 characters). If unset, the role name is `${var.oidc_federation_role_prefix}-${key}` (when prefix is non-empty) or `${key}`. |
| `policy` | object | **yes** | — | IAM policy document with `Version` and `Statement` fields. Processed by `templatefile()` — see template variables below. |

### Template variables available inside `policy`

| Variable | Value |
|----------|-------|
| `account_id` | The vended account's AWS account ID. |
| `region` | The AWS region of the current apply. |
| `cluster_issuer_host` | Issuer hostname without `https://` scheme (e.g., `oidc.k8s.occ.ottawacloudconsulting.com`). |

Use `${account_id}`, `${region}`, `${cluster_issuer_host}` as placeholders inside string values
in the `policy` object.

### Minimal example

```json
{
  "subject": "system:serviceaccount:my-ns:my-sa",
  "policy": {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": ["s3:GetObject"],
        "Resource": ["arn:aws:s3:::my-bucket-${account_id}/*"]
      }
    ]
  }
}
```

## Immutability constraint — CRITICAL

**Renaming or deleting a file in this directory changes the `for_each` key and will attempt to
destroy the IAM role.** `lifecycle { prevent_destroy = true }` blocks the destroy, but the
`terraform plan` will fail until the filename is restored or the lifecycle block is intentionally
removed.

Consequences of an accidental rename:
- Kubernetes ServiceAccounts bound to the role ARN lose AWS access immediately.
- Recovery: restore the original filename (no state change needed) or use `terraform state mv`
  deliberately.

If a role genuinely needs to be renamed:
1. Remove `lifecycle { prevent_destroy = true }` from `aws_iam_role.federation` for that key.
2. Apply the destroy/recreate.
3. Update K8s-side ServiceAccount annotations to the new role ARN.
4. Re-add `lifecycle { prevent_destroy = true }`.

See also: `boundary-policies/README.md` — renaming `Default.json` breaks the `boundary_key`
lookup for any wrapper that relies on the `"Default"` boundary.

## Trust policy conditions

Every federation role trust policy uses **`StringEquals`** on both `aud` and `sub` condition
keys, derived from the OIDC provider resource attributes (not from `var.oidc_issuer_url`):

```
StringEquals:
  "${provider.url}:aud" = <audience>   # per-role or var.oidc_audience
  "${provider.url}:sub" = <subject>    # required field in this file
```

No wildcards. No `StringLike`. A CI rule fails the build if `StringLike` appears in
`iam-oidc-federation.tf`.
