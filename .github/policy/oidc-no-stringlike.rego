# oidc-no-stringlike.rego
# Conftest/OPA policy: fails if iam-oidc-federation.tf contains StringLike.
#
# StringLike in an OIDC trust condition allows wildcard matching on sub or aud
# claims, which can enable cross-tenant token acceptance. Only StringEquals is
# permitted. This is Design Decision #7 in docs/ARCHITECTURE_AND_DESIGN-OIDC.md.
#
# Usage (conftest with raw text parser):
#   conftest test \
#     --parser text \
#     --policy .github/policy \
#     baseline/terraform/iam-oidc-federation.tf
#
# The CI workflow (oidc-validate.yml) enforces this check via grep, which does
# not require conftest to be installed. This file provides the equivalent OPA
# rule for teams that adopt conftest in their toolchain.

package oidc

import rego.v1

deny contains msg if {
    contains(input, "StringLike")
    msg := "iam-oidc-federation.tf must not use StringLike in any condition clause. Only StringEquals is permitted for OIDC trust policies. StringLike enables wildcard matching on sub or aud claims and can allow cross-tenant token acceptance."
}
