#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Bootstrap AWS CDK for newly vended accounts
# Configures CDK with trust to AFT automation account

set -x

echo "Bootstrapping AWS CDK..."

# Check if CDK CLI is installed
if ! command -v cdk &> /dev/null; then
  echo "CDK CLI not found. Installing AWS CDK..."
  npm install -g aws-cdk
fi

# Verify CDK version
cdk --version

# Debug
node --version

# Get current account ID and region
echo "Automation Account: ${AFT_MGMT_ACCOUNT}"
echo "Target Account: ${VENDED_ACCOUNT_ID}"
echo "Region: ${AWS_DEFAULT_REGION}"

# Bootstrap CDK with trust to AFT automation account
cdk bootstrap \
  --trust "${AFT_MGMT_ACCOUNT}" \
  --cloudformation-execution-policies arn:aws:iam::aws:policy/AdministratorAccess \
  "aws://${VENDED_ACCOUNT_ID}/${AWS_DEFAULT_REGION}"

echo "CDK bootstrap completed successfully"
