# Enterprise AWS DevToProd — Release Pipeline with Tags

Multi-account AWS deployment pipeline using GitHub Actions, EKS, and tag-based promotion across DEV → QA → PROD.

> **All infrastructure and application changes flow exclusively through GitHub Actions.**
> No direct `kubectl` or `terraform apply` from a local machine. The OIDC IAM roles are
> scoped so they can only be assumed from GitHub Actions workflows — not from personal credentials.

---

## AWS Account Layout

| Role | Account ID |
|---|---|
| Control Tower Master | `810426675067` |
| DEV Workload | `648426766457` |
| QA Workload | `506250256146` |
| PROD Workload | `429429082896` |

---

## CI-Only Enforcement Model

```
Local machine                GitHub Actions
─────────────                ──────────────────────────────────────────
git push / git tag    ──►    Workflow triggered
                             │
                             ├── OIDC token issued (no long-lived keys)
                             │
                             └── IAM Role assumed
                                   DEV role   ← main branch only
                                   QA role    ← main branch + qa_* tags
                                   PROD role  ← main branch + prod_* tags
```

**Why local apply is impossible:**
- No long-lived AWS access keys exist — authentication is OIDC-only
- The IAM trust policy restricts `sts:AssumeRoleWithWebIdentity` to specific
  GitHub Actions subjects (`refs/heads/main`, `refs/tags/qa_*`, etc.)
- A personal developer token cannot match these subjects

---

## Architecture Overview

```
GitHub (main branch)
    │
    ├── push to main ──────────────► DEV  (auto)      tag: dev_<sha>_v<build>
    │   (terraform changes)  ──────► DEV infra (auto) plan + apply
    │
    ├── git tag qa_<sha>_<ver> ─────► QA   (auto)      tag: qa_<sha>_v<version>
    │   (terraform changes)  ──────► QA infra (approval gate)
    │
    └── git tag prod_<sha>_<ver> ───► PROD (approval)   tag: prod_<sha>_v<version>
        (terraform changes)  ──────► PROD infra (approval gate)
```

### Tag Naming Convention

| Environment | Tag Format | Example |
|---|---|---|
| DEV | `dev_<sha>_v<run>` | `dev_abc1234ef_v42` |
| QA | `qa_<sha>_v<version>` | `qa_abc1234ef_v1.2.0` |
| PROD | `prod_<sha>_v<version>` | `prod_abc1234ef_v1.2.0` |

---

## All GitHub Actions Workflows

| Workflow | Trigger | What it does |
|---|---|---|
| `_reusable-ci.yml` | Called | Gitleaks → Semgrep SAST → nginx lint → 7 unit tests |
| `_reusable-build.yml` | Called | Docker build → Trivy scan → push to GHCR (blocks on CRITICAL) |
| `deploy-dev.yml` | push to `main` | Full CI → Build → Deploy DEV → Smoke → OWASP ZAP |
| `deploy-qa.yml` | tag `qa_*` | Validate tag → re-tag dev image → Deploy QA → Smoke → DAST |
| `deploy-prod.yml` | tag `prod_*` | Validate → confirm QA image → approval gate → Deploy → Smoke → auto-rollback |
| `terraform-dev.yml` | push to `main` (tf files) | Fmt + validate + Checkov on PR; plan + apply on merge |
| `terraform-qa.yml` | push to `main` (tf files) | Fmt + validate + Checkov on PR; plan + apply (approval gate) |
| `terraform-prod.yml` | push to `main` (tf files) | Fmt + validate + Checkov on PR; plan (preview); apply (approval gate) |

---

## Application Pipeline Stages

### DEV — triggered on every push to `main`

```
CI checks
  ├── Gitleaks      (secret scanning — blocks on any secret)
  ├── Semgrep       (SAST — blocks on HIGH findings)
  ├── nginx -t      (config lint)
  └── Unit tests    (7 checks: health, /version JSON, HTML content, headers, 404)
        │
Build & scan
  ├── Docker build  (version injected via build-args at build time)
  ├── Trivy         (image + SCA — CRITICAL/HIGH blocks GHCR push)
  └── Push to GHCR  (tag: dev_<sha>_v<run>  +  dev_<sha> for easy promotion)
        │
Deploy DEV
  ├── OIDC assume IAM role → DEV account (648426766457)
  ├── kustomize set image + kubectl apply
  ├── RollingUpdate  (maxSurge: 1, maxUnavailable: 0 — zero downtime)
  ├── Smoke test     (6 endpoint checks via smoke-test.sh)
  └── OWASP ZAP      (DAST baseline — report only in DEV)
```

### QA — triggered by creating a `qa_*` git tag

```
Validate tag format  (qa_<sha>_<version>)
  │
Re-tag image         (dev_<sha> → qa_<sha>_<version> in GHCR)
  │                  No rebuild — same image bytes that passed DEV
Deploy QA
  ├── OIDC assume IAM role → QA account (506250256146)
  ├── kustomize set image + kubectl apply
  ├── Smoke test
  └── OWASP ZAP      (DAST — fails pipeline on active alerts)
```

### PROD — triggered by creating a `prod_*` git tag

```
Validate tag format  (prod_<sha>_<version>)
  │
Confirm QA image exists in GHCR  (ensures sha went through QA)
  │
Manual approval gate  (GitHub Environment: prod)
  │
Re-tag image          (qa_<sha>_<version> → prod_<sha>_<version>)
  │
Deploy PROD
  ├── OIDC assume IAM role → PROD account (429429082896)
  ├── Capture previous image tag  (for rollback)
  ├── kustomize set image + kubectl apply
  ├── RollingUpdate  (maxUnavailable: 0)
  ├── Smoke test
  └── Auto-rollback if rollout or smoke test fails
```

---

## Infrastructure Pipeline Stages (Terraform)

### On every PR touching `terraform/**`

```
No AWS access required:
  ├── terraform fmt -check    (formatting gate)
  ├── terraform validate      (syntax + schema)
  └── Checkov                 (IaC security scan — hard fail)
```

### On merge to `main` (DEV)

```
OIDC → DEV account
  ├── terraform plan    (output saved as artifact + job summary)
  └── terraform apply   (auto on merge — DEV is low risk)
```

### On merge to `main` (QA)

```
OIDC → QA account
  ├── terraform plan
  ├── ── Manual approval gate (GitHub Environment: qa-terraform) ──
  └── terraform apply
```

### On merge to `main` (PROD)

```
OIDC → PROD account
  ├── terraform plan    (runs immediately, output written to job summary)
  ├── ── Manual approval gate (GitHub Environment: prod-terraform) ──
  └── terraform apply   (uses the approved plan artifact — no drift)
```

---

## Security Controls

| Layer | Tool | Where | Action on Failure |
|---|---|---|---|
| Secrets in code | Gitleaks | App CI | Block push |
| Static code analysis | Semgrep | App CI | Block push |
| IaC security | Checkov | Terraform PR | Block merge |
| Container image CVEs | Trivy (CRITICAL/HIGH) | Build | Block GHCR push |
| Dependency/SCA | Trivy | Build | Block GHCR push |
| Runtime (DAST) | OWASP ZAP | Post-deploy | Report DEV / Block QA+PROD |
| IAM trust | OIDC (no long-lived keys) | AWS | Cannot assume role locally |
| Infra changes | PR required + Checkov | Terraform | No direct apply |
| QA infra | Manual approval | GitHub Env | Human sign-off |
| PROD infra | Manual approval | GitHub Env | Human sign-off |
| PROD app deploy | Manual approval | GitHub Env | Human sign-off |
| Image promotion | SHA-pinned re-tag | GHCR | Only QA-validated images reach PROD |
| PROD recovery | Auto rollback | deploy-prod.yml | Reverts to previous image |

---

## Infrastructure (Terraform)

### Module Structure

```
terraform/
├── modules/
│   ├── vpc/        — VPC, public/private subnets, single NAT (cost-optimised)
│   ├── eks/        — EKS cluster, SPOT node group, IRSA OIDC provider
│   └── iam-oidc/   — GitHub Actions OIDC trust, EKS deploy policy,
│                     Terraform infra management policy
├── dev/            — DEV account  (10.10.0.0/16, t3.small spot, 1 node)
├── qa/             — QA  account  (10.20.0.0/16, t3.small spot, 1 node)
└── prod/           — PROD account (10.30.0.0/16, t3.medium spot, 2 nodes)
```

### EKS Cost Optimisation

| Decision | Saving |
|---|---|
| SPOT instances (t3.small/medium) | ~65% vs on-demand |
| Single NAT gateway per env | Eliminates per-AZ NAT cost |
| DEV/QA: 1 replica, min 1 node | No idle capacity |
| PROD: 2 replicas, min 2 nodes | HA without over-provisioning |

### OIDC IAM Role Scoping

| Environment | Allowed OIDC Subjects | Used by |
|---|---|---|
| DEV | `refs/heads/main` | App deploy + Terraform apply |
| QA | `refs/heads/main` + `refs/tags/qa_*` | Terraform (main) + App deploy (tag) |
| PROD | `refs/heads/main` + `refs/tags/prod_*` | Terraform (main) + App deploy (tag) |

---

## Repository Structure

```
.
├── .github/workflows/
│   ├── _reusable-ci.yml         — Gitleaks, Semgrep, nginx lint, unit tests
│   ├── _reusable-build.yml      — Docker build, Trivy scan, GHCR push
│   ├── deploy-dev.yml           — App: DEV full pipeline (push to main)
│   ├── deploy-qa.yml            — App: QA promotion (qa_* tag)
│   ├── deploy-prod.yml          — App: PROD promotion (prod_* tag + approval)
│   ├── terraform-dev.yml        — Infra: DEV plan + apply (auto on merge)
│   ├── terraform-qa.yml         — Infra: QA plan + apply (approval gate)
│   └── terraform-prod.yml       — Infra: PROD plan + apply (approval gate)
│
├── nginx/
│   ├── Dockerfile
│   ├── nginx.conf
│   ├── entrypoint.sh
│   └── html/index.html.template
│
├── k8s/
│   ├── base/
│   └── overlays/{dev,qa,prod}/
│
├── scripts/
│   ├── smoke-test.sh            — 6-check endpoint validation
│   └── rollback.sh              — Reverts deployment to previous image
│
└── terraform/
    ├── modules/{vpc,eks,iam-oidc}/
    └── {dev,qa,prod}/
```

---

## One-Time Bootstrap (First-Time Setup Only)

This is the only time anything touches AWS outside of GitHub Actions.
After bootstrap, all changes flow through CI.

### Step 1 — Create S3 state buckets and DynamoDB lock tables

Run once in each account using temporary admin credentials:

```bash
# DEV account (648426766457)
aws s3 mb s3://tfstate-nginx-release-dev-648426766457 --region us-east-1
aws s3api put-bucket-versioning \
  --bucket tfstate-nginx-release-dev-648426766457 \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption \
  --bucket tfstate-nginx-release-dev-648426766457 \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws dynamodb create-table \
  --table-name tfstate-lock-dev \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1

# Repeat with qa / prod bucket names and lock table names
```

### Step 2 — Bootstrap the OIDC provider and IAM role

Run once per account to create the GitHub OIDC provider and the initial IAM role.
After this, GitHub Actions manages all subsequent infrastructure changes.

```bash
# From terraform/dev
terraform init
terraform apply -target=module.iam_oidc

# Repeat for qa and prod
```

### Step 3 — Add GitHub Actions secrets

After bootstrap, capture the role ARNs and store them as repository secrets:

```bash
terraform -chdir=terraform/dev  output github_actions_role_arn  # → DEV_IAM_ROLE_ARN
terraform -chdir=terraform/qa   output github_actions_role_arn  # → QA_IAM_ROLE_ARN
terraform -chdir=terraform/prod output github_actions_role_arn  # → PROD_IAM_ROLE_ARN
```

Add to **Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `DEV_IAM_ROLE_ARN` | ARN from DEV terraform output |
| `QA_IAM_ROLE_ARN` | ARN from QA terraform output |
| `PROD_IAM_ROLE_ARN` | ARN from PROD terraform output |

### Step 4 — Configure GitHub Environments

Go to **Settings → Environments** and create:

| Environment | Required reviewers | Purpose |
|---|---|---|
| `dev` | None | App auto-deploy |
| `qa` | None | App tag-gated deploy |
| `prod` | Named engineers | App deploy — manual approval |
| `dev-terraform` | None | Terraform DEV auto-apply |
| `qa-terraform` | Named engineers | Terraform QA apply gate |
| `prod-terraform` | Named engineers | Terraform PROD apply gate |

### Step 5 — Enable branch protection on `main`

Go to **Settings → Branches → Add rule** for `main`:

- [x] Require a pull request before merging
- [x] Require approvals (minimum 1)
- [x] Require status checks to pass: `lint-and-scan`, `CI checks`
- [x] Require branches to be up to date before merging
- [x] Do not allow bypassing the above settings

### Step 6 — Fix kustomize placeholder

```bash
sed -i 's/PLACEHOLDER/sandeshlamsal/g' k8s/overlays/*/kustomization.yaml
git add k8s/ && git commit -m "fix: set GHCR org in kustomize overlays"
git push
```

After this push, GitHub Actions takes over — the `terraform-dev.yml` workflow
applies the remaining DEV infrastructure, then `deploy-dev.yml` deploys the app.

---

## Day-to-Day Workflow

### Infrastructure changes

```bash
# Open a PR with terraform changes
git checkout -b infra/increase-prod-nodes
# edit terraform/prod/main.tf ...
git push origin infra/increase-prod-nodes
# → PR triggers: fmt check + validate + Checkov

# Merge PR to main
# → terraform-prod.yml runs: plan (visible in Actions summary)
#    → approval gate (prod-terraform environment)
#    → terraform apply with the approved plan
```

### Application changes

```bash
# DEV deploys automatically on every push to main

# Promote to QA (use a SHA from a DEV deploy that passed)
git tag qa_abc1234ef_v1.2.0
git push origin qa_abc1234ef_v1.2.0
# → deploy-qa.yml: validates tag → re-tags image → deploys → DAST

# Promote to PROD
git tag prod_abc1234ef_v1.2.0
git push origin prod_abc1234ef_v1.2.0
# → deploy-prod.yml: confirms QA image → approval gate → deploys → rollback if needed
```

---

## Future Improvements

| Gap | Recommendation |
|---|---|
| No Ingress / TLS | Add AWS Load Balancer Controller + ACM certificate |
| No centralized logging | Add CloudWatch Container Insights or Fluent Bit |
| No alerting | CloudWatch Alarms → SNS → Slack/PagerDuty |
| No drift detection | Add scheduled `terraform plan` workflow (cron) |
| No image signing | Add Cosign (Sigstore) to build workflow |
| No network policy | Add Calico or EKS native network policies |
| Spot interruption handling | Add AWS Node Termination Handler |
| Terraform plan in PR comments | Add `actions/github-script` to post plan diff on PR |
