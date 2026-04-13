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

#### IAM Identity Center — actual configuration

| Field | Value |
|---|---|
| Instance ARN | `arn:aws:sso:::instance/ssoins-668412822c756057` |
| Identity Store ID | `d-9a675626b0` |
| SSO region | `us-east-2` |
| Access portal URL | `https://d-9a675626b0.awsapps.com/start` |

**Permission sets provisioned:**

| Name | Policy | Accounts |
|---|---|---|
| `AdminAccess` | `AdministratorAccess` (AWS managed) | DEV · QA · PROD |
| `DevAccess` | Custom | DEV · QA · PROD |
| `ReadOnlyAccess` | `ReadOnlyAccess` (AWS managed) | DEV · QA · PROD |

Use **`AdminAccess`** for bootstrap — it has full `AdministratorAccess` and is pre-assigned to all three accounts.

#### 0a — Create your IAM Identity Center user (AWS Console, master account `810426675067`)

1. Open **IAM Identity Center** (region: `us-east-2`) → **Users → Add user**
2. Set username, email, first/last name → **Add user**
3. Check your email and complete account activation
4. **AWS accounts** (left sidebar) → select all three accounts (DEV · QA · PROD) → **Assign users or groups**
   - Select your user → **Next** → select `AdminAccess` → **Submit**

#### 0b — Add SSO profiles to `~/.aws/config`

Full file for reference (existing LocalStack profiles are kept for local dev; SSO profiles are appended):

```ini
# ── Default ───────────────────────────────────────────────────────────────────
[default]
region = us-east-1
output = json

# ── LocalStack (local development only) ───────────────────────────────────────
[profile dev]
region       = us-east-1
output       = json
endpoint_url = http://localhost:4566

[profile qa]
region       = us-east-1
output       = json
endpoint_url = http://localhost:4567

[profile prod]
region       = us-east-1
output       = json
endpoint_url = http://localhost:4568

# ── AWS IAM Identity Center — shared SSO session ──────────────────────────────
# Identity Center instance: ssoins-668412822c756057  (us-east-2)
# Identity store:           d-9a675626b0
# Portal URL:               https://d-9a675626b0.awsapps.com/start
#
# Login once to refresh token for all profiles:
#   aws sso login --sso-session nginx-pipeline
[sso-session nginx-pipeline]
sso_start_url            = https://d-9a675626b0.awsapps.com/start
sso_region               = us-east-2
sso_registration_scopes  = sso:account:access

# DEV workload account (648426766457)
[profile dev-admin]
sso_session     = nginx-pipeline
sso_account_id  = 648426766457
sso_role_name   = AdminAccess
region          = us-east-1
output          = json

# QA workload account (506250256146)
[profile qa-admin]
sso_session     = nginx-pipeline
sso_account_id  = 506250256146
sso_role_name   = AdminAccess
region          = us-east-1
output          = json

# PROD workload account (429429082896)
[profile prod-admin]
sso_session     = nginx-pipeline
sso_account_id  = 429429082896
sso_role_name   = AdminAccess
region          = us-east-1
output          = json
```

> `sso_region` (`us-east-2`) is where Identity Center is hosted. `region` (`us-east-1`) is where your AWS resources live — these are independent settings.

#### 0c — Log in and verify

```bash
# Log in once — opens browser, token lasts 8–12 hours
# One login covers all three profiles (dev-admin, qa-admin, prod-admin)
aws sso login --sso-session nginx-pipeline

# Verify you land in the DEV account
aws sts get-caller-identity --profile dev-admin
```

Expected output:
```json
{
    "UserId": "AROAZN6J7IB4T3NKZLYT7:sandeshlamsal",
    "Account": "648426766457",
    "Arn": "arn:aws:sts::648426766457:assumed-role/AWSReservedSSO_AdminAccess_18f22c5cfac8d136/sandeshlamsal"
}
```

> Run `aws sso login --sso-session nginx-pipeline` at the start of each working session. Token lasts 8–12 hours.

---

### Accessing the DEV account

#### CLI access

Every AWS CLI command for DEV resources uses `--profile dev-admin`:

```bash
# Check any resource in DEV
aws s3 ls --profile dev-admin
aws eks list-clusters --region us-east-1 --profile dev-admin
aws iam list-roles --profile dev-admin --query 'Roles[?contains(RoleName,`GitHubActions`)].RoleName'

# Verify S3 state bucket
aws s3api head-bucket \
  --bucket tfstate-nginx-release-dev-648426766457 \
  --profile dev-admin

# Check bucket versioning and encryption
aws s3api get-bucket-versioning \
  --bucket tfstate-nginx-release-dev-648426766457 \
  --profile dev-admin

aws s3api get-bucket-encryption \
  --bucket tfstate-nginx-release-dev-648426766457 \
  --profile dev-admin

# List state files in the bucket
aws s3 ls s3://tfstate-nginx-release-dev-648426766457 \
  --profile dev-admin --recursive
```

#### AWS Console access (browser)

Open the SSO access portal and select the DEV account:

```
https://d-9a675626b0.awsapps.com/start
```

1. Log in with your `sandeshlamsal` Identity Center credentials
2. Select **648426766457** (DEV account)
3. Click **AdminAccess → Management console**

You are now in the DEV account console. Common areas to check:

| What to verify | Console path |
|---|---|
| S3 state bucket | S3 → `tfstate-nginx-release-dev-648426766457` |
| IAM role | IAM → Roles → `GitHubActionsRole-dev` |
| OIDC provider | IAM → Identity providers → `token.actions.githubusercontent.com` |
| EKS cluster (after terraform-dev) | EKS → Clusters → `eks-dev` |
| NLB (after app deploy) | EC2 → Load balancers |
| CloudWatch logs | CloudWatch → Log groups → `/aws/eks/eks-dev` |

#### Switch between accounts

```bash
# DEV
aws sts get-caller-identity --profile dev-admin

# QA
aws sts get-caller-identity --profile qa-admin

# PROD
aws sts get-caller-identity --profile prod-admin
```

> All three profiles share the `nginx-pipeline` SSO session — no separate login needed per account.

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

### Pipeline SAST failures — all resolved

These failures appeared when the `terraform-github.yml` pipeline first ran end-to-end. Both scanners (Semgrep and Checkov) ran in the CI jobs but had not been exercised before.

#### Semgrep — 12 blocking findings (run [#24310192653](https://github.com/sandeshlamsal/Devops_AwsDevToProd_Deployment_ReleasePipeline_Tags/actions/runs/24310192653))

| Rule ID | File | Issue | Resolution |
|---|---|---|---|
| `yaml.github-actions.security.run-shell-injection` | `_reusable-build.yml` | `${{ github.repository }}` and `${{ inputs.image_tag }}` used directly in `run:` shell — attacker-controlled input could inject shell commands | **Fixed** — moved all context vars to `env:` block; shell reads `$REPO_RAW`, `$IMAGE_TAG`, etc. |
| `dockerfile.security.missing-user-entrypoint` | `nginx/Dockerfile` | No `USER` instruction before `ENTRYPOINT` — container runs as root | **`# nosemgrep`** — nginx master process requires root to bind port 80; worker processes already run as the built-in `nginx` (UID 101) user |
| `yaml.kubernetes.security.run-as-non-root` | `k8s/overlays/*/patch-replicas.yaml` (×3) | Pod spec missing `securityContext.runAsNonRoot: true` | **`# nosemgrep`** — same root requirement as above; would crash pod if enabled without switching to port 8080 |
| `terraform.lang.security.eks-public-endpoint-enabled` | `terraform/modules/eks/main.tf` | EKS public API endpoint not explicitly disabled | **`# nosemgrep`** — required for GitHub Actions OIDC runners to reach the API server |
| `terraform.lang.security.iam.no-iam-creds-exposure` | `terraform/modules/iam-oidc/main.tf` | `ec2:*` action in IAM policy | **`# nosemgrep`** — Terraform CI role needs broad EC2 rights to manage VPC/EKS; scoped to region via `Condition` |
| `terraform.lang.security.iam.no-iam-resource-exposure` (×2) | `terraform/modules/iam-oidc/main.tf` | `ec2:*` and IAM management actions | **`# nosemgrep`** — same as above; IAM rights scoped to this pipeline's resources |
| `terraform.lang.security.iam.no-iam-priv-esc-funcs` | `terraform/modules/iam-oidc/main.tf` | IAM role/policy management actions | **`# nosemgrep`** — Terraform must manage OIDC role, node group roles, and instance profiles |
| `terraform.lang.security.iam.no-iam-data-exfiltration` | `terraform/modules/iam-oidc/main.tf` | S3 `GetObject`/`PutObject` actions | **`# nosemgrep`** — scoped to the specific state bucket ARN for this environment |
| `terraform.aws.security.aws-subnet-has-public-ip-address` | `terraform/modules/vpc/main.tf` | `map_public_ip_on_launch = true` on public subnets | **`# nosemgrep`** — required for AWS NLB and NAT gateway placement |

#### Checkov — 8 blocking findings (run [#24310192653](https://github.com/sandeshlamsal/Devops_AwsDevToProd_Deployment_ReleasePipeline_Tags/actions/runs/24310192653))

| Check ID | Resource | Issue | Resolution |
|---|---|---|---|
| `CKV_AWS_37` | `aws_eks_cluster.main` | EKS control-plane logging not enabled for all 5 log types | **Fixed** — `enabled_cluster_log_types = ["api","audit","authenticator","controllerManager","scheduler"]` |
| `CKV_AWS_58` | `aws_eks_cluster.main` | EKS secrets not encrypted at rest | **Fixed** — added `aws_kms_key` with key rotation + `encryption_config { resources = ["secrets"] }` |
| `CKV_AWS_39` | `aws_eks_cluster.main` | EKS public API endpoint enabled | **`checkov:skip`** — GitHub Actions OIDC needs public endpoint access |
| `CKV_AWS_38` | `aws_eks_cluster.main` | EKS public endpoint accessible to `0.0.0.0/0` | **`checkov:skip`** — GitHub Actions runners use dynamic IPs; IP restriction not feasible |
| `CKV_AWS_130` | `aws_subnet.public` (×2) | VPC subnets assign public IPs by default | **`checkov:skip`** — public subnets require `map_public_ip_on_launch` for AWS NLB and NAT gateway |
| `CKV2_AWS_11` | `aws_vpc.main` | VPC flow logging not enabled | **Fixed** — added `aws_flow_log` → CloudWatch log group with 30-day retention + dedicated IAM role |
| `CKV2_AWS_12` | `aws_vpc.main` | Default security group not locked down | **Fixed** — added `aws_default_security_group` resource with no ingress/egress rules |

---

## Teardown — Destroying All Resources

> Everything created by this pipeline is reversible. Run teardown after end-to-end testing to avoid ongoing costs.

### What gets created and how it is destroyed

| Resource | Created by | Destroyed by |
|---|---|---|
| S3 state bucket | `bootstrap.sh` (local) | `teardown.sh` step 3 (local) |
| GitHub Actions OIDC provider | `bootstrap.sh` → `terraform apply` | `teardown.sh` step 2 → `terraform destroy` |
| IAM role `GitHubActionsRole-dev` + policies | `bootstrap.sh` → `terraform apply` | `teardown.sh` step 2 → `terraform destroy` |
| VPC, subnets, NAT gateway | `terraform-dev.yml` (GitHub Actions) | `teardown.sh` step 2 → `terraform destroy` |
| EKS cluster `eks-dev` | `terraform-dev.yml` (GitHub Actions) | `teardown.sh` step 2 → `terraform destroy` |
| EKS node group (SPOT instances) | `terraform-dev.yml` (GitHub Actions) | `teardown.sh` step 2 → `terraform destroy` |
| EKS access entry | `terraform-dev.yml` (GitHub Actions) | `teardown.sh` step 2 → `terraform destroy` |
| CloudWatch log groups | `terraform-dev.yml` (GitHub Actions) | `teardown.sh` step 2 → `terraform destroy` |
| Namespace `release-app` | `deploy-dev.yml` (GitHub Actions) | `teardown.sh` step 1 → `kubectl delete namespace` |
| Deployment, Service, ConfigMap, Secret | `deploy-dev.yml` (GitHub Actions) | `teardown.sh` step 1 (deleted with namespace) |
| AWS NLB (LoadBalancer service) | `deploy-dev.yml` → K8s Service | `teardown.sh` step 1 — **must delete before EKS or NLB orphans** |
| GitHub Environments | `terraform-github.yml` (GitHub Actions) | Manual (repo Settings) or set reviewer lists to `[]` |
| GHCR images | `_reusable-build.yml` (GitHub Actions) | Manual (GitHub → Packages) |

### Why teardown runs locally

The `terraform destroy` removes the IAM OIDC role that GitHub Actions uses to authenticate. Once that role is gone, no workflow can run. Teardown is therefore the **one permitted local operation** in this repo — every other change goes through CI.

### Teardown order — critical

```
1. kubectl delete namespace release-app    ← removes NLB cleanly before EKS is gone
        │
        ▼
2. terraform destroy                       ← destroys EKS, VPC, IAM roles, OIDC provider
        │                                    (~10 min)
        ▼
3. Delete S3 state bucket                  ← emptied (all versions) then deleted
        │
        ▼
4. Manual: delete GHCR images              ← GitHub → Packages → nginx-release
5. Manual: delete GitHub Environments      ← repo Settings → Environments (optional)
```

> **Do not skip step 1.** If EKS is destroyed before the LoadBalancer Service is deleted, the AWS NLB becomes an orphan — Terraform cannot delete it and it will keep billing.

### Run teardown

```bash
# DEV
AWS_PROFILE=dev-admin ./scripts/teardown.sh dev 648426766457

# QA (when ready)
AWS_PROFILE=qa-admin  ./scripts/teardown.sh qa  506250256146

# PROD (when ready)
AWS_PROFILE=prod-admin ./scripts/teardown.sh prod 429429082896
```

The script:
1. Confirms you typed the environment name before doing anything destructive
2. Verifies your AWS identity matches the target account
3. Updates kubeconfig → deletes namespace `release-app` (triggers NLB cleanup, waits 30s)
4. Runs `terraform init -reconfigure` + `terraform destroy -auto-approve`
5. Empties all object versions from the S3 bucket then deletes it

### Manual cleanup after teardown

**GHCR images** — GitHub Actions pushes one image per deploy. Delete them all at once:

```
https://github.com/sandeshlamsal?tab=packages
→ nginx-release → Package settings → Delete this package
```

Or delete individual tags via the GitHub UI under each package version.

**GitHub Environments** — these are lightweight and cost nothing; leave them for reuse. To remove:

```bash
# Set all reviewer lists to [] in terraform/github/terraform.tfvars, push to main
# terraform-github.yml will update the environments automatically.
# Or delete manually: repo → Settings → Environments → Delete environment
```

**CloudWatch log groups** — if `terraform destroy` does not remove them (can happen on EKS 1.29):

```bash
aws logs describe-log-groups \
  --log-group-name-prefix /aws/eks/eks-dev \
  --region us-east-1 \
  --query 'logGroups[].logGroupName' \
  --output text | tr '\t' '\n' | \
xargs -I{} aws logs delete-log-group --log-group-name {} --region us-east-1
```

### Cost while running

| Resource | Approx cost (us-east-1) |
|---|---|
| EKS cluster control plane | ~$0.10 / hr |
| 1× t3.small SPOT node | ~$0.005 / hr |
| NAT gateway | ~$0.045 / hr + data |
| NLB (LoadBalancer service) | ~$0.008 / hr + LCU |
| S3 state bucket | < $0.01 / month |
| **Total DEV (running)** | **~$0.16 / hr (~$3.84 / day)** |

Teardown brings the cost to **$0.00** — nothing runs outside the cluster.

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

---

## Pipeline Failure Log

A chronological record of every CI/CD failure encountered during initial pipeline bring-up, the root cause, and the exact fix applied. Useful for understanding why certain patterns exist in this codebase.

---

### F-01 — Semgrep rule-ID drift between CI and local

**Workflow:** `_reusable-ci.yml` — Semgrep SAST scan  
**Symptom:** Semgrep passed locally but failed in CI, or suppressed findings in CI that were never flagged locally.  
**Root cause:** CI used the old `semgrep/semgrep-action@v1` Docker image (pinned to Semgrep ~0.x). Local dev used `semgrep==1.159.0`. The two versions use different rule IDs for the same patterns — a `# nosemgrep: old.rule.id` comment suppresses nothing in the new CLI, and vice versa.  
**Fix:** Replaced `semgrep/semgrep-action@v1` with:
```yaml
- name: Install Semgrep
  run: pip install semgrep==1.159.0

- name: Semgrep — SAST scan
  run: semgrep scan --config "p/default" --config "p/dockerfile" --config "p/nginx" --error --no-autofix
```
CI and local now run the identical binary, eliminating rule-ID drift permanently.  
**File:** [.github/workflows/_reusable-ci.yml](.github/workflows/_reusable-ci.yml)

---

### F-02 — `nosemgrep` suppression on the wrong line

**Workflow:** `_reusable-ci.yml` — Semgrep SAST scan  
**Symptom:** `# nosemgrep: rule.id` comments present but findings still reported.  
**Root cause:** Semgrep suppresses a finding only when the comment is on the **exact line the finding is reported on**. Comments placed one line above (with a blank line between) or on the wrong resource block had no effect. Specifically, `dockerfile.security.missing-user` was flagged on the `HEALTHCHECK` line, not on a preceding comment line, and `yaml.kubernetes.security.run-as-non-root` was flagged on the inner `spec:` under `template:`, not the outer `spec:`.  
**Fix:** Moved every `# nosemgrep:` comment to land on the exact flagged line. Used `semgrep scan --json | python3 -c "import sys,json; [print(f['path'],f['start']['line'],f['check_id']) for f in json.load(sys.stdin)['results']]"` to identify exact line numbers before placing comments.  
**Files:** [nginx/Dockerfile](nginx/Dockerfile), [k8s/overlays/dev/patch-replicas.yaml](k8s/overlays/dev/patch-replicas.yaml)

---

### F-03 — Trivy blocking on `nginx:1.25-alpine` CVEs

**Workflow:** `_reusable-build.yml` — Trivy container scan  
**Symptom:** Trivy reported CRITICAL CVEs (libxml2, libssl3, libpng) with available fixes.  
**Root cause:** `nginx:1.25-alpine` is based on Alpine 3.19 which reached end-of-life. Packages in the base image snapshot had known CVEs with published fixes, but `ignore-unfixed: true` does not suppress patched CVEs — only CVEs with no available fix.  
**Fix (step 1):** Upgraded base image from `nginx:1.25-alpine` → `nginx:1.27-alpine` (Alpine 3.21, actively maintained).  
**Fix (step 2):** Even on 3.21, the pinned snapshot in the registry can lag behind published security patches. Added `apk upgrade --no-cache` as the first `RUN` instruction so every build pulls the latest patched packages at build time:
```dockerfile
RUN apk upgrade --no-cache && \
    apk add --no-cache gettext curl
```
**File:** [nginx/Dockerfile](nginx/Dockerfile)

---

### F-04 — Checkov `#checkov:skip` not suppressing findings

**Workflow:** `terraform-dev.yml` — Checkov IaC scan  
**Symptom:** `#checkov:skip=CKV2_AWS_11` and `#checkov:skip=CKV2_AWS_12` present on `aws_vpc` but Checkov still flagged them.  
**Root cause:** Checkov skip annotations must be placed **inside** the resource block (on any line between the opening `{` and closing `}`). Comments placed outside or above the block are ignored.  
**Fix:** Moved skip comments inside the `aws_vpc` resource block body.  
**File:** [terraform/modules/vpc/main.tf](terraform/modules/vpc/main.tf)

---

### F-05 — New Checkov findings after adding flow-log + KMS resources

**Workflow:** `terraform-dev.yml` — Checkov IaC scan  
**Symptom:** After adding VPC flow logs and KMS keys to fix F-04, three new Checkov checks fired.  

| Check | Resource | Requirement |
|---|---|---|
| `CKV_AWS_338` | `aws_cloudwatch_log_group` | Retention must be ≥ 365 days |
| `CKV_AWS_158` | `aws_cloudwatch_log_group` | Log group must be encrypted with a customer KMS key |
| `CKV2_AWS_64` | `aws_kms_key` | KMS key must have an explicit key policy (not rely on default) |

**Fix:**
- Set `retention_in_days = 365` on the log group
- Added a KMS key for flow log encryption with an explicit policy granting access to both the root account and the `logs.<region>.amazonaws.com` service principal with an `ArnLike` condition
- Added a separate KMS key for EKS secrets encryption with an explicit policy granting access to `eks.amazonaws.com`

**Files:** [terraform/modules/vpc/main.tf](terraform/modules/vpc/main.tf), [terraform/modules/eks/main.tf](terraform/modules/eks/main.tf)

---

### F-06 — `terraform-github.yml` plan output path mismatch

**Workflow:** `terraform-github.yml` — Terraform plan  
**Symptom:** `cat: terraform/github/plan-output.txt: No such file or directory`  
**Root cause:** The plan step piped output with `tee plan-output.txt` (relative path = repo root), but the summary step read from `${{ env.TF_DIR }}/plan-output.txt`. Using `-chdir=terraform/github` changes Terraform's working directory but does not change the shell's working directory — `tee` writes relative to the shell CWD (repo root).  
**Fix:** Changed `tee plan-output.txt` → `tee ${{ env.TF_DIR }}/plan-output.txt` so both write and read use the same absolute-equivalent path.  
**File:** [.github/workflows/terraform-github.yml](.github/workflows/terraform-github.yml)

---

### F-07 — Shell injection in `_reusable-build.yml`

**Workflow:** `_reusable-build.yml` — Docker build + push  
**Symptom:** Semgrep flagged `bash-injection` on lines using `${{ github.repository }}` and `${{ inputs.image_tag }}` directly inside `run:` scripts.  
**Root cause:** GitHub Actions expressions interpolated directly into `run:` shell scripts can be exploited via crafted branch names or input values. This is a real security risk, not just a lint issue.  
**Fix:** Moved all `${{ ... }}` expressions to an `env:` block and referenced them as shell environment variables:
```yaml
env:
  REPO_RAW:  ${{ github.repository }}
  IMAGE_TAG: ${{ inputs.image_tag }}
run: |
  REPO=$(echo "$REPO_RAW" | tr '[:upper:]' '[:lower:]')
  IMAGE_REF="ghcr.io/${REPO}/nginx-release:${IMAGE_TAG}"
```
**File:** [.github/workflows/_reusable-build.yml](.github/workflows/_reusable-build.yml)

---

### F-08 — `kms:TagResource` AccessDeniedException on first KMS key creation

**Workflow:** `terraform-dev.yml` — Terraform apply  
**Symptom:**
```
AccessDeniedException: User: .../GitHubActionsRole-dev/GitHubActions is not
authorized to perform: kms:TagResource
```
**Root cause:** The `terraform_infra` IAM policy had no KMS permissions at all. When Terraform created the `aws_kms_key` resources (which have `tags = var.tags`), the AWS provider internally calls `kms:TagResource` as part of the create operation.  
**Fix:** Added a `KMSManagement` statement to the `terraform_infra` IAM policy covering the full set of KMS operations needed to create, manage, alias, grant, and tag keys:
```hcl
{
  Sid    = "KMSManagement"
  Effect = "Allow"
  Action = [
    "kms:CreateKey", "kms:DescribeKey", "kms:EnableKeyRotation",
    "kms:GetKeyPolicy", "kms:GetKeyRotationStatus",
    "kms:ListResourceTags", "kms:PutKeyPolicy",
    "kms:ScheduleKeyDeletion", "kms:TagResource", "kms:UntagResource",
    "kms:CreateAlias", "kms:DeleteAlias", "kms:ListAliases", "kms:UpdateAlias",
    "kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant",
  ]
  Resource = "*"
}
```
**File:** [terraform/modules/iam-oidc/main.tf](terraform/modules/iam-oidc/main.tf)

---

### F-09 — Terraform modules applying in parallel, racing IAM policy update

**Workflow:** `terraform-dev.yml` — Terraform apply  
**Symptom:** Even after adding KMS permissions to the IAM policy (F-08), KMS key creation and EKS cluster creation still failed with `AccessDeniedException` on the *same run* that updated the policy.  
**Root cause:** Without explicit `depends_on`, Terraform applied `module.iam_oidc`, `module.vpc`, and `module.eks` **in parallel**. The IAM policy update and the KMS/EKS resource creation happened simultaneously — the new permissions were not yet in effect when the parallel modules made their first AWS API calls.  
**Fix:** Added `depends_on = [module.iam_oidc]` to both `module.vpc` and `module.eks` in all three environment root modules (`dev/main.tf`, `qa/main.tf`, `prod/main.tf`). Terraform now completes the IAM module before starting infrastructure modules.  
**Files:** [terraform/dev/main.tf](terraform/dev/main.tf), [terraform/qa/main.tf](terraform/qa/main.tf), [terraform/prod/main.tf](terraform/prod/main.tf)

---

### F-10 — `iam:CreateServiceLinkedRole` and `logs:ListTagsForResource` missing

**Workflow:** `terraform-dev.yml` — Terraform apply  
**Symptom:**
```
InvalidParameterException: EKS Cluster Service-Linked Role could not be created —
ensure caller has permission to perform iam:CreateServiceLinkedRole

AccessDeniedException: not authorized to perform: logs:ListTagsForResource
```
**Root cause:**
- EKS requires `iam:CreateServiceLinkedRole` to create `AWSServiceRoleForAmazonEKS` on first use in an account.
- Terraform AWS provider v5 replaced the deprecated `logs:ListTagsLogGroup` API with `logs:ListTagsForResource`. The IAM policy only had the old API.

**Fix:** Added both actions to the `IAMManagement` and `CloudWatchLogs` statements respectively.  
**File:** [terraform/modules/iam-oidc/main.tf](terraform/modules/iam-oidc/main.tf)

---

### F-11 — Bootstrap deadlock: plan fails because permissions are not yet live

**Workflow:** `terraform-dev.yml` — Terraform plan  
**Symptom:** `Cannot apply incomplete plan` — the apply job received a corrupt plan artifact.  
**Root cause (two-part):**

**Part A — silent plan failure:** The plan step used `terraform plan ... | tee plan-output.txt`. In bash, a pipe returns the exit code of the *last* command (`tee`), not terraform. When terraform plan failed with `AccessDeniedException`, `tee` still exited 0, the step was marked green, the corrupt `tfplan` artifact was uploaded, and the apply job ran `terraform apply tfplan` against it — producing the misleading "Cannot apply incomplete plan" error instead of a clear plan error.

**Part B — permission deadlock:** `terraform plan` refreshes all resources currently in the Terraform state. The CloudWatch log group (`/aws/vpc/dev-flow-logs`) existed in state from a previous partial apply. Refreshing it requires `logs:ListTagsForResource`. That permission existed in the Terraform code but had never been successfully applied to AWS (every previous apply failed before or during the IAM update). Result: plan always fails → apply never runs → permission never gets applied → plan always fails.

**Fix:**
1. Added `set -o pipefail` to the plan step so a failing `terraform` process causes the step to fail immediately.
2. Added a **"Pre-apply IAM permissions"** step *before* the plan step that runs `terraform apply -auto-approve -target=module.iam_oidc`. This pushes all pending IAM changes into AWS before the plan refresh reads existing resources.
3. Added a **30-second `sleep`** after the pre-apply step because IAM policy changes replicate globally within seconds but can take up to ~30 s to reach all regional service endpoints. Without the sleep, the plan step started 4 seconds after the IAM apply completed and still hit the old policy at the CloudWatch Logs endpoint.

```yaml
- name: Pre-apply IAM permissions (bootstrap gate)
  run: |
    terraform -chdir=${{ env.TF_DIR }} apply \
      -auto-approve -target=module.iam_oidc -no-color

- name: Wait for IAM propagation
  run: sleep 30

- name: Terraform plan
  run: |
    set -o pipefail
    terraform -chdir=${{ env.TF_DIR }} plan -no-color -out=tfplan \
      2>&1 | tee ${{ env.TF_DIR }}/plan-output.txt
```

**Files:** [.github/workflows/terraform-dev.yml](.github/workflows/terraform-dev.yml), [.github/workflows/terraform-qa.yml](.github/workflows/terraform-qa.yml), [.github/workflows/terraform-prod.yml](.github/workflows/terraform-prod.yml)
