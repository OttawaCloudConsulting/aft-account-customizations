# boundary-policies

Per-account IAM permission boundary policy documents. Each `.json` file in this directory becomes
one `Boundary-<filename>` IAM managed policy via `fileset()` discovery in `iam-permission-boundaries.tf`.

## Discovery mechanism

`iam-permission-boundaries.tf` uses `fileset()` to discover every `*.json` file here. The policy
name is `${var.boundary_policy_prefix}-${filename-without-.json}`:

```
boundary-policies/
  Default.json   →  Boundary-Default
  ReadOnly.json  →  Boundary-ReadOnly
```

## Template variables

Boundary policy JSON files are processed by `templatefile()` and may reference:

| Variable | Value |
|----------|-------|
| `account_id` | The vended account's AWS account ID. |
| `protected_role_prefix` | Value of `var.protected_role_prefix` (default: `"org"`). Used without wildcards in resource names; wildcards added explicitly in policy `Resource` strings. |
| `boundary_policy_prefix` | Value of `var.boundary_policy_prefix` (default: `"Boundary"`). |
| `boundary_name` | The full policy name for this file (`${prefix}-${key}`). Self-reference used in deny statements that protect the boundary policy itself. |

## Immutability constraint — CRITICAL

**Renaming or deleting a file in this directory changes the `for_each` key and forces
destroy/recreate of the IAM policy.**

### Symmetric coupling with OIDC federation

`Default.json` is specifically referenced by the OIDC federation module
(`baseline/terraform/iam-oidc-federation.tf`). Federation roles resolve their permission boundary
via the wrapper's `boundary_key` field, which defaults to `"Default"`. This lookup maps directly
to the filename:

```hcl
permissions_boundary = aws_iam_policy.boundaries[coalesce(each.value.boundary_key, "Default")].arn
```

**If `Default.json` is renamed**, every federation role whose JSON wrapper does not set an explicit
`boundary_key` will fail at plan time with a `precondition` error — no state change occurs, but
the `terraform plan` will be blocked until the filename is restored or all wrappers are updated
with an explicit `boundary_key`.

If a genuine rename is needed:
1. Update all `oidc-federation-policies/*.json` wrappers to set `boundary_key` to the new key.
2. Rename the file.
3. Apply. Terraform will destroy the old policy and create the new one (state impact — document in PR).

See also: `oidc-federation-policies/README.md` — renaming files there changes `for_each` keys on
the federation roles, which `lifecycle { prevent_destroy = true }` blocks at plan time.
