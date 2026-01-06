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

# Check for existing of CDK Assets Bucket
BUCKET_NAME="cdk-hnb659fds-assets-${VENDED_ACCOUNT_ID}-${AWS_DEFAULT_REGION}" && \
echo "Checking for bucket: ${BUCKET_NAME}" && \
BUCKET_EXISTS=$(aws s3api list-buckets | jq -r '.Buckets[] | select(.Name == "'${BUCKET_NAME}'") | .Name') && \
if [ -n "$BUCKET_EXISTS" ]; then
  echo "Bucket exists: ${BUCKET_EXISTS}"
  echo "Counting objects..."
  OBJECT_COUNT=$(aws s3 ls s3://${BUCKET_NAME} --recursive | wc -l | xargs)
  echo "Total objects in bucket: ${OBJECT_COUNT}"
#   if [ "$OBJECT_COUNT" -eq 0 ]; then
#     echo "Bucket is empty. Deleting left over bucket from previous deployment..."
#     aws s3api delete-bucket --bucket ${BUCKET_NAME} | jq
#   fi
else
  echo "Bucket does not exist"
fi

# Bootstrap CDK with trust to AFT automation account
cdk bootstrap \
  --trust "${AFT_MGMT_ACCOUNT}" \
  --cloudformation-execution-policies arn:aws:iam::aws:policy/AdministratorAccess \
  "aws://${VENDED_ACCOUNT_ID}/${AWS_DEFAULT_REGION}"

echo "CDK bootstrap completed successfully"
