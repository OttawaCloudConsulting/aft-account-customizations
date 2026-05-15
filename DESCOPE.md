# DESCOPE — OIDC Cluster Federation (Layer A, Application Team)

> **Interpretation note (2026-05-15):** the source hand-off described "Layer A" and "Layer B" work. Layer B fits AFT and is captured in [REQUIREMENTS-OIDC.md](REQUIREMENTS-OIDC.md). This DESCOPE document captures **Layer A — the singleton OIDC discovery host** — as the work that does not fit AFT and is being handed to the Application Team. If a different scope was intended, raise it and this doc will be updated.

## Purpose

The Kubernetes Platform team's hand-off (`platform-team-handoff.md`) requested two pieces of work from the AWS Platform Team. One piece — Layer B, per-account IAM federation primitives — fits AFT and is captured in [REQUIREMENTS-OIDC.md](REQUIREMENTS-OIDC.md).

The other — Layer A, the singleton OIDC discovery host — **does not fit AFT** and is descoped from this repository. This document records what is being handed off to the **Application Team**.

## What Layer A is

A publicly-trusted, HTTPS-only static-content host serving:

- `GET /.well-known/openid-configuration` — OIDC discovery JSON
- `GET /openid/v1/jwks` — JSON Web Key Set

at the permanent URL `https://oidc.k8s.occ.ottawacloudconsulting.com`.

Components (from hand-off §R1.2):

| # | Component | Pinned value | Why fixed |
|---|---|---|---|
| 1 | Issuer hostname | `oidc.k8s.occ.ottawacloudconsulting.com` | Non-rotatable; embedded in every projected SA token's `iss` claim |
| 2 | ACM cert region | **`us-east-1`** | CloudFront alternate-domain-name requirement |
| 3 | ACM cert params | CN = issuer hostname; **no SANs**, **no wildcards**; DNS-01 validation; `RSA_2048` | Single-host issuer; wildcards bloat trust surface; RSA matches AWS SDK thumbprint expectations |
| 4 | S3 bucket | Suggested name `occ-k8s-oidc-<acctid>`; private; versioning on; **OAC the only reader** | CloudFront-only access pattern |
| 5 | CloudFront distribution | Single S3 origin via OAC; HTTPS-only; alternate domain = issuer hostname; `PriceClass_100`; cache TTL ≤ 300s on `/openid/v1/jwks` | Cache reduces S3 cost without hiding key rotation |
| 6 | Route53 record | **A-alias** (not CNAME) for `oidc.k8s.occ.ottawacloudconsulting.com` → CloudFront distribution | A-alias required for zone-apex / faster resolution |
| 7 | DNSSEC | Not required at MVP; follow parent zone posture | Out of scope unless parent zone already enables it |

## Why Layer A does not fit AFT

AFT is **per-account, triggered on account vending**. Every account that runs the `baseline` customization gets the resources defined there applied to it. Layer A is the opposite shape:

- **Singleton** — exactly one issuer URL exists for the cluster (hand-off PRD §A9 forbids issuer rotation); the stack runs **once**, against **one** chosen account.
- **One-shot lifecycle** — built, then left alone; reconciliation pressure is cert rotation and JWKS publication, not per-account vending.
- **Cross-cutting infrastructure** — serves a public endpoint used by AWS STS globally; not tied to the identity boundary of any single vended account.

Forcing Layer A into AFT would mean either:

- Putting it in `aft-account-customizations/baseline/` → runs on every account vend, attempting to create the same S3 bucket / CloudFront distribution / Route53 record in every account. Name and DNS conflicts.
- Putting it in `aft-global-customizations/` → runs every AFT cycle against every account. Same problem.
- Putting it in `aft-account-customizations/core/` → only runs when a core account is vended, against that account. Wrong shape — the resource is a singleton, not per-core-account.
- Targeting a single account via a tag check or conditional → fights the AFT model, hard to reason about, hard to migrate later.

None match the actual lifecycle. Layer A belongs in a **standalone platform-Terraform repository** (or equivalent IaC home) that runs out-of-band from AFT.

## What the Application Team is being asked to build

The full Layer A specification is in the source hand-off doc §R1. Summary:

1. **Choose the hosting account** (hand-off §R1.1 Q1 — three options: shared-services/network, dedicated `occ-platform` workload, current Crossplane workload).
2. **Stand up the stack** — S3 + CloudFront + ACM (`us-east-1`) + Route53 alias per the pinned specs above. Use IaC (Terraform recommended); do not hand-bootstrap.
3. **Provide a hand-off IAM principal** in the hosting account, scoped to the OIDC bucket and distribution only, permitting:
   - `s3:PutObject`, `s3:GetObject`, `s3:ListBucket` on the OIDC bucket
   - `cloudfront:CreateInvalidation` on the distribution
   - Used by the Kubernetes Platform team to publish the JWKS / discovery document and bust cache on rotation.
4. **Return the 13 output values** listed in hand-off §R1.4 to the Kubernetes Platform team (account ID, bucket name, cert ARN, cert subject/SANs, distribution ID/ARN, Route53 zone + record details, hand-off IAM principal ARN).
5. **Confirm success criteria** in hand-off §R1.5 — DNS resolves to CloudFront, public TLS chain validates, HTTP→HTTPS redirect works, sentinel object reachable via CloudFront, direct S3 access blocked, cache TTL ≤ 300s on JWKS, hand-off IAM principal can `PutObject`, CloudTrail captures changes.

## Hard dependency on the AFT-side Layer B work

The Layer B work captured in [REQUIREMENTS-OIDC.md](REQUIREMENTS-OIDC.md) **cannot complete a working federation without Layer A**:

- The `ThumbprintList` on `aws_iam_openid_connect_provider` is the SHA-1 of the issuing CA — the cert that ACM issues in Layer A. No Layer A cert → no thumbprint → provider applies but federation calls fail at STS validation time.
- The issuer URL must resolve over public DNS with a public-CA-trusted TLS chain when STS validates a token. Layer A must be live before end-to-end federation testing succeeds.

Practical implication: the AFT module can be authored and merged with a placeholder/empty thumbprint list and the provider creation can be feature-flagged off until Layer A acceptance lands. Once Layer A returns its outputs, the thumbprint variable is populated and the next AFT run on each account creates the working provider.

## Other items in the hand-off NOT owned by the Application Team

Listed for completeness — these are out of AFT scope but are also **not** the Application Team's deliverable:

- **JWKS / OIDC discovery document content** — Kubernetes Platform team (extracted from cluster signing-key material; uploaded via the hand-off IAM principal supplied by the Application Team).
- **kube-apiserver flags** (`--service-account-issuer`, `--api-audiences`) — Kubernetes Platform team, separate `occ-k8s-cluster-config` repo, M02 of their project.
- **Crossplane resources** (`ProviderConfig`, `DeploymentRuntimeConfig`, annotated ServiceAccount) — Kubernetes Platform team, GitOps repo, M05 of their project.
- **Pod-identity webhook** + cert-manager — Kubernetes Platform team, M04 of their project (optional, not on critical path).
- **SCP / boundary changes** — confirm-only request to AWS Platform Team; no authoring is being asked of any team.

## Open questions to surface back to the Kubernetes Platform team

These hand-off questions require a counterparty answer before Layer A work can proceed; listed here so the hand-back to the Application Team is unblocked:

| # | Hand-off ref | Question |
|---|---|---|
| Q1 | §R1.1 / §10 Q1 | Which Control Tower account hosts Layer A? (shared-services, dedicated `occ-platform`, or current Crossplane workload) |
| Q2 | §8 / §10 Q2 | Where is `ottawacloudconsulting.com.` hosted? Determines DNS delegation pattern (DNS-A subdomain delegation vs DNS-B cross-account record writes). |
| Q3 | §10 Q3 | Cache TTL on `/openid/v1/jwks` — accept the 300s suggestion, or pick a different value? |
| Q4 | §10 Q4 | Target repo for the Layer A stack (and AFT-side Layer B module home, if not this repo). |
| Q5 | §10 Q6 | SCP / permission-boundary constraints on `acm:RequestCertificate`, `route53:ChangeResourceRecordSets`, `iam:CreateOpenIDConnectProvider`, `sts:AssumeRoleWithWebIdentity` in the target accounts. |
| Q6 | §10 Q7 | Tag set required on Layer A resources for org cost-allocation. |

## References

- Source hand-off doc (K8s Platform team) — `platform-team-handoff.md` (their repo)
- [REQUIREMENTS-OIDC.md](REQUIREMENTS-OIDC.md) — Layer B work that AFT will deliver
- [CLAUDE.md](CLAUDE.md) — AFT execution flow and customization-type guidance
- Hand-off §R1 — Layer A full specification
- Hand-off §R1.5 — Layer A success criteria
- Hand-off §6 — cross-team operational requirements (IAM principals, notification channel)
