# aft-account-customizations

For account-specific customizations

## Customization Types

1. **baseline** - Baseline configuration applied to every vended account
2. **core** - Configuration applied to 'core' environment accounts only
3. **workload** - Configuration applied to Workoad/Application accounts

## CodeBuild Runtime Environment Variables

These environment variables are available during the AFT customization execution in CodeBuild.

### AFT-Specific Variables

| Variable | Description | Example Value |
|----------|-------------|---------------|
| `AFT_MGMT_ACCOUNT` | AFT Management/Automation Account ID | `389068787156` |
| `AFT_ADMIN_ROLE_ARN` | ARN of the AFT Admin role | `arn:aws:iam::389068787156:role/AWSAFTAdmin` |
| `AFT_ADMIN_ROLE_NAME` | Name of the AFT Admin role | `AWSAFTAdmin` |
| `AFT_EXEC_ROLE_ARN` | ARN of the AFT Execution role in management account | `arn:aws:iam::389068787156:role/AWSAFTExecution` |
| `VENDED_ACCOUNT_ID` | Target account ID being customized | `264675080489` |
| `VENDED_EXEC_ROLE_ARN` | ARN of the AFT Execution role in vended account | `arn:aws:iam::264675080489:role/AWSAFTExecution` |
| `CUSTOMIZATION` | Customization type being executed | `baseline`, `core`, or `workload` |
| `CT_MGMT_REGION` | Control Tower management region | `ca-central-1` |

### AWS Variables

| Variable | Description | Example Value |
|----------|-------------|---------------|
| `AWS_REGION` | Current AWS region | `ca-central-1` |
| `AWS_DEFAULT_REGION` | Default AWS region | `ca-central-1` |
| `AWS_PROFILE` | AWS CLI profile in use | `aft-target` |
| `AWS_PARTITION` | AWS partition | `aws` |
| `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` | ECS container credentials URI | `/v2/credentials/...` |

### CodeBuild Variables

| Variable | Description | Example Value |
|----------|-------------|---------------|
| `CODEBUILD_SRC_DIR` | Source directory path | `/codebuild/output/src494611630/src` |
| `CODEBUILD_BUILD_ID` | Unique build identifier | `aft-account-customizations-terraform:4d70827e...` |
| `CODEBUILD_BUILD_ARN` | Full ARN of the build | `arn:aws:codebuild:ca-central-1:...` |
| `CODEBUILD_PROJECT_ARN` | ARN of the CodeBuild project | `arn:aws:codebuild:ca-central-1:...` |
| `CODEBUILD_RESOLVED_SOURCE_VERSION` | Git commit SHA | `0ef7646811e08b835dca3d1d39ba64f6f46b9155` |
| `CODEBUILD_BUILD_NUMBER` | Sequential build number | `12` |
| `CODEBUILD_INITIATOR` | What triggered the build | `codepipeline/...` |
| `CODEBUILD_KMS_KEY_ID` | KMS key for encryption | `arn:aws:kms:ca-central-1:...:alias/aft` |

### Tool Versions

| Variable | Description | Example Value |
|----------|-------------|---------------|
| `TF_VERSION` | Terraform version | `1.14.3` |
| `NODE_*_VERSION` | Node.js versions available | `NODE_20_VERSION=20.19.5` |
| `PYTHON_*_VERSION` | Python versions available | `PYTHON_312_VERSION=3.12.12` |
| `JAVA_*_HOME` | Java installation paths | `JAVA_17_HOME=/usr/lib/jvm/...` |
| `DOCKER_VERSION` | Docker version | `27.5.1` |
| `DOCKER_COMPOSE_VERSION` | Docker Compose version | `2.37.1` |

### Path Variables

| Variable | Description | Example Value |
|----------|-------------|---------------|
| `DEFAULT_PATH` | Default working directory | `/codebuild/output/src494611630/src` |
| `HOME` | Home directory | `/root` |
| `MAVEN_HOME` | Maven installation path | `/opt/maven` |
| `GRADLE_PATH` | Gradle installation path | `/gradle` |

### Usage Examples

#### Access AFT Management Account ID in Shell Scripts

```bash
echo "AFT Management Account: ${AFT_MGMT_ACCOUNT}"
echo "Target Account: ${VENDED_ACCOUNT_ID}"
echo "Customization Type: ${CUSTOMIZATION}"
```

#### Use in Terraform

These variables are also available when Terraform executes:

```hcl
# Access via environment variable
data "external" "env_vars" {
  program = ["bash", "-c", "echo {\\\"aft_mgmt_account\\\":\\\"$AFT_MGMT_ACCOUNT\\\"}"]
}
```

#### Retrieve from SSM Parameter Store

Instead of using environment variables, you can also retrieve account IDs from SSM:

```bash
aws ssm get-parameter \
  --name "/aft/account/aft-management/account-id" \
  --query "Parameter.Value" \
  --output text
```

## Terraform Input Variables

These variables are set in the AFT customization framework per-account (distinct from the
CodeBuild environment variables above). All are declared in `baseline/terraform/variables.tf`.

### OIDC Federation Variables

| Variable | Type | Default | Validation | Description |
|----------|------|---------|------------|-------------|
| `oidc_federation_enabled` | `bool` | `false` | — | Master feature flag. When `false`, no OIDC resources are created (zero state churn for all existing accounts). Set to `true` per-account to roll out federation. |
| `oidc_federation_security_tier_accounts` | `bool` | `false` | — | When `false`, federation is skipped in Audit and Log Archive accounts. Set to `true` only after a documented threat-model review — see Blast Radius Analysis in `docs/ARCHITECTURE_AND_DESIGN-OIDC.md`. |
| `oidc_issuer_url` | `string` | `https://oidc.k8s.occ.ottawacloudconsulting.com` | must match `^https://[a-z0-9.\-]+$` | Cluster OIDC issuer URL. Pinned by K8s Platform team hand-off. Validation rejects trailing slashes, mixed case, and non-`https` schemes. |
| `oidc_thumbprints` | `list(string)` | `[]` | each entry must be a 40-character hex SHA-1; non-empty when `oidc_federation_enabled = true` | SHA-1 thumbprints of the cluster issuer's CA chain. Supplied by the K8s Platform team after the OIDC discovery host (Layer A) is live. List supports CA rotation overlap (AWS allows up to 5 entries). |
| `oidc_audience` | `string` | `sts.amazonaws.com` | non-empty | Default audience claim (`aud`) in federation tokens. Per-role override available via the `audience` field in each JSON wrapper. |
| `oidc_federation_role_prefix` | `string` | `""` | empty string or kebab-case (`^[a-z][a-z0-9-]*$`) | Prefix prepended to discovered role names when the JSON wrapper does not set `role_name_override`. Empty default preserves the hand-off-pinned `crossplane-aws-iam` name at MVP. |
| `audit_account_id` | `string` | `""` | empty or 12-digit; **required** when `oidc_federation_enabled = true` and `oidc_federation_security_tier_accounts = false` | AWS account ID of the Control Tower Audit account. Added to `local.security_tier_account_ids` so federation is skipped by default. Cross-variable validation blocks `terraform plan` if the federation flag is on but this value is missing — the default-deny guard cannot identify the account without it. |
| `log_archive_account_id` | `string` | `""` | empty or 12-digit; **required** when `oidc_federation_enabled = true` and `oidc_federation_security_tier_accounts = false` | AWS account ID of the Control Tower Log Archive account. Same role and constraint as `audit_account_id`. |

### Cutover Sequence

When rolling out OIDC federation to already-vended accounts:

1. Merge this repo with `oidc_federation_enabled = false` (default) — zero impact on the AFT pipeline.
2. Confirm CI gates pass on `main` (terraform validate, OPA rule, snapshot test — see Feature 7).
3. Obtain CA thumbprints from the K8s Platform team (available once Layer A is live).
4. Set `oidc_federation_enabled = true`, supply `oidc_thumbprints`, and set `audit_account_id` + `log_archive_account_id` in the **named test account** (`docs/oidc/test-account.md`). Trigger AFT customization re-run; verify outputs.
5. K8s Platform team confirms end-to-end federation in the test account.
6. Roll out to workload accounts in batches of ≤ 10 per day, verifying outputs between batches per `docs/oidc/rollout-checklist.md`.

## OIDC Federation Pattern

### Overview

When `var.oidc_federation_enabled = true`, AFT provisions per-account OIDC federation
primitives: one `aws_iam_openid_connect_provider` and one IAM role per file discovered in
`baseline/terraform/oidc-federation-policies/`.

Adding a new federated workload is a **one-file change**: drop a JSON wrapper into
`baseline/terraform/oidc-federation-policies/` and open a PR. No Terraform locals, no variable
changes, no HCL edits are required.

### JSON Wrapper Schema

Each file in `baseline/terraform/oidc-federation-policies/` is a JSON object:

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `subject` | string | **yes** | — | Exact `<issuer>:sub` claim value. Format: `system:serviceaccount:<namespace>:<sa-name>`. |
| `policy` | object | **yes** | — | IAM policy document (`Version` + `Statement`). Processed by `templatefile()`; see template variables below. |
| `audience` | string | no | `var.oidc_audience` | Per-role `<issuer>:aud` claim override. |
| `boundary_key` | string | no | `"Default"` | Key into `aws_iam_policy.boundaries` (i.e., filename minus `.json` in `boundary-policies/`). Defaults to `Boundary-Default`. |
| `role_name_override` | string | no | `null` | Verbatim IAM role name (≤ 64 chars). When unset, name = `${var.oidc_federation_role_prefix}-${key}` or `${key}`. |

Template variables available inside `policy`:

| Variable | Value |
|----------|-------|
| `account_id` | The vended account's AWS account ID. |
| `region` | The AWS region of the current apply. |
| `cluster_issuer_host` | Issuer hostname without `https://` (e.g., `oidc.k8s.occ.ottawacloudconsulting.com`). |

### Minimal Example

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

### Filename Immutability

Filenames in `oidc-federation-policies/` are immutable after first deployment. Renaming a file
changes the `for_each` key and would attempt to destroy the IAM role — `lifecycle { prevent_destroy = true }` blocks this at plan time. A `precondition` on the role also fails the plan if the `boundary_key` field references a boundary file that does not exist.

For full design details, failure modes, and the thumbprint rotation runbook, see
`docs/ARCHITECTURE_AND_DESIGN-OIDC.md`.