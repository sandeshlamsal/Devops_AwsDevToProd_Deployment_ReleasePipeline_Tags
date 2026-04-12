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

GitHub Actions jobs that declare `environment:` receive a different OIDC subject than branch/tag jobs — both must be listed in the role's trust policy.

| Environment | Allowed OIDC Subjects |
|---|---|
| DEV | `ref:refs/heads/main` · `environment:dev` · `environment:dev-terraform` |
| QA | `ref:refs/heads/main` · `ref:refs/tags/qa_*` · `environment:qa` · `environment:qa-terraform` |
| PROD | `ref:refs/heads/main` · `ref:refs/tags/prod_*` · `environment:prod` · `environment:prod-terraform` |

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

## Environment Setup

> **The bootstrap script is the only step that runs locally.**
> Everything after that — cluster creation, app deployment, config changes — flows exclusively through GitHub Actions.
> State locking uses S3 native conditional writes (Terraform ≥ 1.10). No DynamoDB table is needed.

---

## DEV Environment Setup

### Prerequisites

| Tool | Minimum version | Check |
|---|---|---|
| Terraform | 1.10.0 | `terraform version` |
| AWS CLI | v2 | `aws --version` |
| AWS credentials | Admin in account `648426766457` via SSO | `aws sts get-caller-identity --profile dev-admin` |

---

### Step 0 — Configure AWS SSO access (one-time per machine)

This pipeline uses **AWS IAM Identity Center (SSO)** — no long-lived access keys. Sessions are time-limited, centrally audited, and revokable from the Control Tower master account.

#### 0a — Set up IAM Identity Center (in the AWS Console, master account `810426675067`)

1. Open **IAM Identity Center → Users** — confirm your user exists or create one
2. Open **Permission sets → Create permission set** → choose `AdministratorAccess` (AWS managed) → name it `AdministratorAccess`
3. Open **AWS accounts** → select `648426766457` (DEV) → **Assign users or groups** → assign your user with the `AdministratorAccess` permission set
4. Note your **SSO start URL** from IAM Identity Center → **Dashboard** (format: `https://d-xxxxxxxxxx.awsapps.com/start`)

#### 0b — Add SSO profiles to `~/.aws/config`

Add the following (replace the `sso_start_url` with yours):

```ini
[sso-session nginx-pipeline]
sso_start_url            = https://d-xxxxxxxxxx.awsapps.com/start
sso_region               = us-east-1
sso_registration_scopes  = sso:account:access

[profile dev-admin]
sso_session     = nginx-pipeline
sso_account_id  = 648426766457
sso_role_name   = AdministratorAccess
region          = us-east-1
output          = json
```

> QA and PROD profiles (`qa-admin`, `prod-admin`) follow the same pattern with their account IDs — add them when you reach those environments.

#### 0c — Log in and verify

```bash
# Log in (opens browser, token lasts 8–12 hours)
aws sso login --sso-session nginx-pipeline

# Verify you are in the DEV account
aws sts get-caller-identity --profile dev-admin
```

Expected output:
```json
{
    "Account": "648426766457",
    "Arn": "arn:aws:sts::648426766457:assumed-role/AWSReservedSSO_AdministratorAccess_.../..."
}
```

> Run `aws sso login --sso-session nginx-pipeline` at the start of each working session. The SSO token is shared across all profiles that reference the same `sso-session`.

---

### Step 1 — Run bootstrap (local, one-time)

```bash
AWS_PROFILE=dev-admin ./scripts/bootstrap.sh dev 648426766457
```

The script:
1. Verifies your AWS identity matches account `648426766457`
2. Creates S3 bucket `tfstate-nginx-release-dev-648426766457` (versioned · AES-256 encrypted · public access blocked)
3. Runs `terraform init` + `terraform apply -target=module.iam_oidc`
4. Creates the GitHub Actions OIDC provider and IAM role `GitHubActionsRole-dev`

At the end it prints the role ARN — **copy it**:

```
github_actions_role_arn = "arn:aws:iam::648426766457:role/GitHubActionsRole-dev"
```

---

### Step 2 — Add GitHub Secrets

Go to: **Settings → Secrets and variables → Actions → New repository secret**

| Secret | Value | Used by |
|---|---|---|
| `DEV_IAM_ROLE_ARN` | Role ARN from Step 1 | All DEV workflows (OIDC) |
| `GH_PAT` | Personal Access Token (see scopes below) | GitHub Environments Terraform + GHCR pull secret |

**`GH_PAT` required scopes:**

| Scope | Why |
|---|---|
| `repo` | Read/write repository content and settings |
| `workflow` | Update workflow files |
| `write:packages` + `read:packages` | Push and pull GHCR images |
| `admin:repo_hook` | Create/update GitHub Environments via Terraform |

> `GITHUB_TOKEN` is injected automatically — do **not** add it as a secret.

---

### Step 3 — Create GitHub Environments

Run the Terraform GitHub workflow **once manually** before anything else. It creates the approval gates that terraform-dev and deploy-dev depend on.

```
Actions → "Terraform — GitHub Environments" → Run workflow
  Branch: main
  Action: apply
```

Verify in **Settings → Environments** that all six exist:

| Environment | Reviewer | Purpose |
|---|---|---|
| `dev` | sandeshlamsal | App deploy approval gate |
| `qa` | _(none)_ | Tag-triggered — no manual gate |
| `prod` | sandeshlamsal | App deploy approval gate |
| `dev-terraform` | sandeshlamsal | Terraform DEV apply gate |
| `qa-terraform` | sandeshlamsal | Terraform QA apply gate |
| `prod-terraform` | sandeshlamsal | Terraform PROD apply gate |

> To remove the DEV gate later, set `dev_app_reviewers = []` and `dev_terraform_reviewers = []` in [terraform/github/terraform.tfvars](terraform/github/terraform.tfvars) and push.

---

### Step 4 — Create DEV cluster

```
Actions → "Terraform — DEV" → Run workflow
  Branch: main
  Action: apply
```

**Job flow:**

```
lint-and-scan   — terraform fmt · validate · Checkov (no AWS needed)
    │
    ▼
plan            — OIDC → GitHubActionsRole-dev · terraform plan
                  Plan output saved to job summary + artifact
    │
    ▼  [PAUSE — approval email sent to sandeshlamsal]
       Open the run → read the plan in job summary → click Approve
    │
    ▼
apply           — downloads the saved plan artifact · terraform apply
                  (no re-plan — zero drift between what was reviewed and what runs)
```

**Resources created (~15 min):**

| Resource | Detail |
|---|---|
| VPC | `10.10.0.0/16` across `us-east-1a` / `us-east-1b` |
| Subnets | Public + private per AZ, single NAT gateway |
| EKS cluster | `eks-dev` · Kubernetes 1.29 · `API_AND_CONFIG_MAP` auth mode |
| Node group | SPOT · `t3.small/medium/t3a.small/t3a.medium` · desired: 1 · max: 3 |
| OIDC provider | EKS cluster OIDC (for IRSA) |
| EKS access entry | `GitHubActionsRole-dev` → `AmazonEKSAdminPolicy` scoped to `release-app` namespace |

---

### Step 5 — Deploy the app to DEV

Every push to `main` triggers `deploy-dev.yml` automatically. The commit from Step 4 will already have triggered it. To force a fresh one:

```bash
git commit --allow-empty -m "trigger: first DEV app deploy"
git push origin main
```

**Job flow:**

```
ci      — Gitleaks (secret scan) · Semgrep SAST · nginx -t lint · 4 unit tests
    │
    ▼
build   — Docker build (version injected via build-args)
          Trivy scan — blocks on CRITICAL/HIGH unfixed CVEs
          Push to GHCR:
            ghcr.io/sandeshlamsal/<repo>/nginx-release:dev_<sha>_v<N>   ← versioned
            ghcr.io/sandeshlamsal/<repo>/nginx-release:dev_<sha>        ← promotion alias
    │
    ▼  [PAUSE — approval gate: GitHub Environment "dev"]
       Open the run → click Approve
    │
    ▼
deploy  — OIDC → GitHubActionsRole-dev (subject: environment:dev)
          aws eks update-kubeconfig  (cluster: eks-dev)
          Install kustomize v5.3.0
          kubectl create namespace release-app
          kubectl create secret docker-registry ghcr-pull-secret (using GH_PAT — long-lived)
          kustomize edit set image → patches overlay with exact tag
          kubectl create configmap nginx-release-config
          kubectl apply -k k8s/overlays/dev
          kubectl rollout status --timeout=300s
          Poll for LoadBalancer hostname (30 × 10 s)
          scripts/smoke-test.sh — 6 endpoint checks
          OWASP ZAP baseline scan — report only (no failure in DEV)
```

---

### Step 6 — Verify DEV is live

The deploy job summary shows the URL. Check it manually:

```bash
# Health endpoint
curl http://<nlb-hostname>/health
# → HTTP 200

# Version info
curl http://<nlb-hostname>/version
# → {"version":"dev_<sha>_v1","sha":"<sha>","env":"dev","buildDate":"..."}

# Index page
curl http://<nlb-hostname>/
# → HTML with "Release Dashboard" heading and the version tag

# Security headers
curl -I http://<nlb-hostname>/
# → X-Frame-Options, X-Content-Type-Options present
```

---

### DEV audit — all issues resolved

| # | File | Issue | Status |
|---|---|---|---|
| 1 | `terraform/{dev,qa,prod}/terraform.tfvars` | Placeholder `YOUR_GITHUB_ORG` / `YOUR_REPO_NAME` | Fixed |
| 2 | `k8s/overlays/*/kustomization.yaml` | `bases:` deprecated in kustomize v5 | Fixed → `resources:` |
| 3 | `deploy-dev.yml` | `kustomize` not installed on runner | Fixed → `imranismail/setup-kustomize@v2` |
| 4 | `deploy-dev.yml` | Namespace not created before apply | Fixed → `kubectl create namespace` |
| 5 | `deploy-dev.yml` | No GHCR pull secret before `kubectl apply` | Fixed |
| 6 | `k8s/base/deployment.yaml` | No `imagePullSecrets` on pod spec | Fixed |
| 7 | `deploy-*.yml` | Pull secret used `GITHUB_TOKEN` (expires ~1 hr) → `ImagePullBackOff` on pod restart | Fixed → `GH_PAT` |
| 8 | `terraform/dev/main.tf` | OIDC `allowed_subjects` missing `environment:dev` + `environment:dev-terraform` → apply/deploy jobs fail to assume role | Fixed |
| 9 | `terraform/modules/eks/main.tf` | Missing `authentication_mode = API_AND_CONFIG_MAP` → access entries API unavailable | Fixed |
| 10 | `terraform/dev/main.tf` | No EKS access entry → `kubectl` returns Unauthorized despite valid IAM credentials | Fixed |
| 11 | `.github/workflows/terraform-dev.yml` | Plan output written to repo root, read from `$TF_DIR` → empty plan summary for reviewers | Fixed |
| 12 | All backends + IAM policy | DynamoDB used for state locking | Removed → S3 native locking (`use_lockfile = true`, Terraform ≥ 1.10) |

---

## QA Environment Setup

> _Coming soon. QA setup follows the same pattern but is triggered by `qa_*` git tags._

---

## PROD Environment Setup

> _Coming soon. PROD setup follows the same pattern with stricter approval gates and auto-rollback._

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
