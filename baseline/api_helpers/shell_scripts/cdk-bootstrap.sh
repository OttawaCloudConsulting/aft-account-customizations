#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Bootstrap AWS CDK for newly vended accounts
# Configures CDK with trust to AFT automation account

echo "Bootstrapping AWS CDK..."

# Check if CDK CLI is installed
if ! command -v cdk &> /dev/null; then
  echo "CDK CLI not found. Installing AWS CDK..."
  npm install -g aws-cdk
fi

# Verify CDK version
cdk --version

# Get AFT automation account ID from SSM Parameter Store
AUTOMATION_ACCOUNT_ID=$(aws ssm get-parameter \
  --name "/aft/account/aft-management/account-id" \
  --query "Parameter.Value" \
  --output text)

# Get current account ID and region
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
REGION=$(aws ec2 describe-availability-zones --query "AvailabilityZones[0].RegionName" --output text)

echo "Automation Account: ${AUTOMATION_ACCOUNT_ID}"
echo "Target Account: ${ACCOUNT_ID}"
echo "Region: ${REGION}"

# Bootstrap CDK with trust to AFT automation account
cdk bootstrap \
  --trust "${AUTOMATION_ACCOUNT_ID}" \
  --cloudformation-execution-policies arn:aws:iam::aws:policy/AdministratorAccess \
  "aws://${ACCOUNT_ID}/${REGION}"

echo "CDK bootstrap completed successfully"
