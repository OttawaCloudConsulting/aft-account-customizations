#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#

echo "Executing Pre-API Helpers"

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Execute CDK bootstrap
bash "${SCRIPT_DIR}/shell_scripts/cdk-bootstrap.sh"
