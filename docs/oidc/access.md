# OIDC Federation — CodeBuild Log Access

The three Terraform outputs from each AFT customization run appear in the CodeBuild log:

```
oidc_provider_arn           = "arn:aws:iam::<account_id>:oidc-provider/..."
oidc_federation_role_arns   = { "crossplane-aws-iam" = "arn:aws:iam::<account_id>:role/..." }
oidc_module_version         = "<git-tag-or-sha>"
```

The K8s Platform team must transcribe these into their `docs/oidc/M01-verification.md`
after each account's apply. This document describes how to access those logs.

---

## Log Location

| Field | Value |
|-------|-------|
| **AWS account** | AFT management account |
| **Service** | AWS CodeBuild |
| **Log group** | `/aws/codebuild/aft-account-customizations` |
| **Log stream pattern** | `<build-id>` — one stream per customization run |

---

## Access Path for K8s Platform Team Members

K8s Platform team members have read-only access to the AFT management account's CodeBuild
log group via an existing read-only IAM role. Access is cross-account via `sts:AssumeRole`.

| Field | Value |
|-------|-------|
| **Cross-account role ARN** | `<FILL IN — read-only role ARN in the AFT management account>` |
| **Role name** | `<FILL IN>` |
| **Trusted principals** | K8s Platform team members (IAM users or SSO-federated identities in their own account) |
| **Policy** | Read-only access to CloudWatch Logs (`logs:GetLogEvents`, `logs:FilterLogEvents`, `logs:DescribeLogStreams`) scoped to `/aws/codebuild/aft-account-customizations` |

### Assume the role

```bash
aws sts assume-role \
  --role-arn <cross-account-role-arn> \
  --role-session-name oidc-verification \
  --profile <your-profile>
```

Export the returned credentials, then:

```bash
# List recent CodeBuild log streams
aws logs describe-log-streams \
  --log-group-name /aws/codebuild/aft-account-customizations \
  --order-by LastEventTime \
  --descending \
  --limit 20

# Read a specific stream (replace <stream-name> with the build ID)
aws logs get-log-events \
  --log-group-name /aws/codebuild/aft-account-customizations \
  --log-stream-name <stream-name> \
  --query 'events[*].message' \
  --output text | grep -A5 "oidc_"
```

### Console access

If the K8s team has console access to the AFT management account via SSO:
1. Navigate to **CodeBuild** → **Build history**.
2. Filter by project `aft-account-customizations`.
3. Open the build for the account of interest.
4. Scroll to the `TERRAFORM_APPLY` phase in the build log.
5. Search for `oidc_provider_arn` to find the outputs section.

---

## Operational Handoff

After each AFT customization run that creates or modifies OIDC resources, the
**AFT operator on duty** (not the K8s team) is responsible for:

1. Locating the outputs in the CodeBuild log.
2. Copying them to the K8s team's `docs/oidc/M01-verification.md`.
3. Posting a notification to the `#cluster-oidc` Slack channel with:
   - Account ID
   - `oidc_provider_arn`
   - `oidc_federation_role_arns.crossplane-aws-iam`
   - `oidc_module_version`
   - Build log stream URL

K8s team members may access logs directly (using the access path above) but the operator
handoff is the primary mechanism at MVP. Persistent output capture (SSM Parameter Store
writeback) is a future enhancement — see `prd.md` §Future Enhancements.
