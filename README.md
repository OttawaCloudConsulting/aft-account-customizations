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