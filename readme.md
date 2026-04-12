# Enterprise AWS DevToProd — Release Pipeline with Tags

Multi-account AWS deployment pipeline using GitHub Actions, EKS, and tag-based promotion across DEV → QA → PROD.

---

## AWS Account Layout

| Role | Account ID |
|---|---|
| Control Tower Master | `810426675067` |
| DEV Workload | `648426766457` |
| QA Workload | `506250256146` |
| PROD Workload | `429429082896` |

---

## Architecture Overview

```
GitHub (main branch)
    │
    ├── push to main ──────────────► DEV  (auto)     tag: dev_<sha>_v<build>
    │
    ├── git tag qa_<sha>_<ver> ─────► QA   (auto)     tag: qa_<sha>_v<version>
    │
    └── git tag prod_<sha>_<ver> ───► PROD (approval)  tag: prod_<sha>_v<version>
```

### Tag Naming Convention

| Environment | Tag Format | Example |
|---|---|---|
| DEV | `dev_<sha>_v<run>` | `dev_abc1234ef_v42` |
| QA | `qa_<sha>_v<version>` | `qa_abc1234ef_v1.2.0` |
| PROD | `prod_<sha>_v<version>` | `prod_abc1234ef_v1.2.0` |

The SHA embedded in the tag ties every deployment back to an exact commit and ensures a QA-validated image is what reaches PROD.

---

## Pipeline Stages

### DEV — triggered on every push to `main`

```
CI checks
  ├── Gitleaks      (secret scanning)
  ├── Semgrep       (SAST)
  ├── nginx -t      (config lint)
  └── Unit tests    (7 checks: health, version JSON, HTML, headers, 404)
        │
Build & scan
  ├── Docker build  (version injected via build-args)
  ├── Trivy         (image + SCA — CRITICAL/HIGH blocks push)
  └── Push to GHCR  (tag: dev_<sha>_v<run>)
        │
Deploy DEV
  ├── OIDC assume IAM role → DEV account (648426766457)
  ├── kustomize set image + kubectl apply
  ├── RollingUpdate (zero downtime)
  ├── Smoke test    (6 endpoint checks)
  └── OWASP ZAP     (DAST baseline — report only)
```

### QA — triggered by creating a `qa_*` git tag

```
Validate tag format  (qa_<sha>_<version>)
  │
Re-tag image         (dev_<sha> → qa_<sha>_<version> in GHCR)
  │
Deploy QA
  ├── OIDC assume IAM role → QA account (506250256146)
  ├── kustomize set image + kubectl apply
  ├── Smoke test
  └── OWASP ZAP     (DAST — fails pipeline on active alerts)
```

### PROD — triggered by creating a `prod_*` git tag

```
Validate tag format  (prod_<sha>_<version>)
  │
Confirm QA image exists in GHCR
  │
Manual approval gate (GitHub Environment: prod)
  │
Re-tag image         (qa_<sha>_<version> → prod_<sha>_<version> in GHCR)
  │
Deploy PROD
  ├── OIDC assume IAM role → PROD account (429429082896)
  ├── Capture previous image tag (for rollback)
  ├── kustomize set image + kubectl apply
  ├── RollingUpdate (maxUnavailable: 0)
  ├── Smoke test
  └── Auto-rollback if rollout or smoke test fails
```

---

## Security Controls

| Layer | Tool | Action on Failure |
|---|---|---|
| Source code | Gitleaks | Block push |
| Static analysis | Semgrep | Block push |
| Container image | Trivy (CRITICAL/HIGH) | Block image push |
| Dependency/SCA | Trivy | Block image push |
| Runtime (DAST) | OWASP ZAP | Report in DEV / Block in QA+PROD |
| IAM trust | OIDC (no long-lived keys) | Scoped per env tag prefix |
| Image promotion | SHA-pinned re-tag | Only QA-validated images reach PROD |
| PROD gate | Manual approval | Human sign-off required |
| PROD recovery | Auto rollback | Reverts to previous image on failure |

---

## Infrastructure (Terraform)

### Module Structure

```
terraform/
├── modules/
│   ├── vpc/        — VPC, public/private subnets, single NAT (cost-optimised)
│   ├── eks/        — EKS cluster, SPOT node group, IRSA OIDC provider
│   └── iam-oidc/   — GitHub Actions OIDC trust + scoped IAM role per env
├── dev/            — DEV account config  (10.10.0.0/16, t3.small spot, 1 node)
├── qa/             — QA account config   (10.20.0.0/16, t3.small spot, 1 node)
└── prod/           — PROD account config (10.30.0.0/16, t3.medium spot, 2 nodes)
```

### EKS Cost Optimisation

| Decision | Saving |
|---|---|
| SPOT instances (t3.small/medium) | ~65% vs on-demand |
| Single NAT gateway per env | Eliminates per-AZ NAT cost |
| DEV/QA: 1 replica, min 1 node | No idle capacity |
| PROD: 2 replicas, min 2 nodes | HA without over-provisioning |

### OIDC IAM Role Scoping

Each environment's IAM role only accepts tokens from its own tag prefix:

| Environment | Allowed OIDC Subject |
|---|---|
| DEV | `repo:org/repo:ref:refs/heads/main` |
| QA | `repo:org/repo:ref:refs/tags/qa_*` |
| PROD | `repo:org/repo:ref:refs/tags/prod_*` |

---

## Application — Nginx Release Dashboard

### Version Injection Flow

```
Docker build (--build-arg APP_VERSION, BUILD_SHA, ENV_NAME, BUILD_DATE)
    │
    └── entrypoint.sh (runtime envsubst)
          ├── Renders index.html from template
          └── Writes /version.json
```

### Endpoints

| Path | Returns |
|---|---|
| `/` | Release dashboard HTML — env badge, active version, build info |
| `/health` | `200 healthy` — used for liveness/readiness probes |
| `/version` | JSON: `{ version, sha, env, buildDate }` |

### Container Registry

Images are stored in **GHCR** (`ghcr.io/<org>/nginx-release`) and tagged per the naming convention above.

---

## Kubernetes (Kustomize)

```
k8s/
├── base/              — Namespace, ConfigMap, Deployment, Service
└── overlays/
    ├── dev/           — 1 replica, 128Mi/100m limits
    ├── qa/            — 1 replica, 128Mi/100m limits
    └── prod/          — 2 replicas, 256Mi/250m limits, larger requests
```

Deployment strategy: `RollingUpdate` with `maxSurge: 1` and `maxUnavailable: 0` (zero-downtime across all environments).

---

## Repository Structure

```
.
├── .github/workflows/
│   ├── _reusable-ci.yml        — Gitleaks, Semgrep, nginx lint, unit tests
│   ├── _reusable-build.yml     — Docker build, Trivy scan, GHCR push
│   ├── deploy-dev.yml          — DEV full pipeline (push to main)
│   ├── deploy-qa.yml           — QA promotion (qa_* tag)
│   └── deploy-prod.yml         — PROD promotion (prod_* tag + approval)
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
│   ├── smoke-test.sh           — 6-check endpoint validation
│   └── rollback.sh             — Reverts deployment to previous image
│
└── terraform/
    ├── modules/{vpc,eks,iam-oidc}/
    └── {dev,qa,prod}/
```

---

## One-Time Setup

### 1. Terraform state buckets (run once per account)

```bash
# In each account, create the S3 bucket and DynamoDB lock table
aws s3 mb s3://tfstate-nginx-release-dev-648426766457  --region us-east-1
aws s3 mb s3://tfstate-nginx-release-qa-506250256146   --region us-east-1
aws s3 mb s3://tfstate-nginx-release-prod-429429082896 --region us-east-1

aws dynamodb create-table --table-name tfstate-lock-dev \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region us-east-1
# repeat for qa and prod
```

### 2. Update tfvars

Edit `terraform/{dev,qa,prod}/terraform.tfvars` and set:
```
github_org  = "sandeshlamsal"
github_repo = "Devops_AwsDevToProd_Deployment_ReleasePipeline_Tags"
```

### 3. Apply Terraform (per account)

```bash
cd terraform/dev  && terraform init && terraform apply
cd terraform/qa   && terraform init && terraform apply
cd terraform/prod && terraform init && terraform apply
```

### 4. Add GitHub Actions secrets

After `terraform apply`, add these secrets to the repository:

| Secret | Value (from terraform output) |
|---|---|
| `DEV_IAM_ROLE_ARN` | `terraform -chdir=terraform/dev output github_actions_role_arn` |
| `QA_IAM_ROLE_ARN` | `terraform -chdir=terraform/qa output github_actions_role_arn` |
| `PROD_IAM_ROLE_ARN` | `terraform -chdir=terraform/prod output github_actions_role_arn` |

### 5. GitHub Environments

Create three environments in **Settings → Environments**:

| Environment | Protection |
|---|---|
| `dev` | None (auto-deploy) |
| `qa` | None (tag-gated) |
| `prod` | Required reviewers (manual approval) |

### 6. Update kustomize placeholder

Replace `PLACEHOLDER` in all three overlay `kustomization.yaml` files with your GitHub org name:

```bash
sed -i 's/PLACEHOLDER/sandeshlamsal/g' k8s/overlays/*/kustomization.yaml
```

---

## Promotion Workflow (Day-to-day)

```bash
# DEV deploys automatically on every push to main

# Promote to QA (pick a commit SHA that passed DEV)
git tag qa_abc1234ef_v1.2.0
git push origin qa_abc1234ef_v1.2.0

# Promote to PROD (must use a SHA that was deployed to QA)
git tag prod_abc1234ef_v1.2.0
git push origin prod_abc1234ef_v1.2.0
# → triggers manual approval gate in GitHub
```

---

## Gaps Identified (Future Improvements)

| Gap | Recommendation |
|---|---|
| No Ingress / TLS | Add AWS Load Balancer Controller + ACM certificate |
| No centralized logging | Add CloudWatch Container Insights or Fluent Bit |
| No alerting | Add CloudWatch Alarms → SNS → Slack/PagerDuty |
| No drift detection | Add `terraform plan` scheduled workflow |
| No image signing | Add Cosign (Sigstore) to build workflow |
| No network policy | Add Calico or EKS native network policies |
| Spot interruption handling | Add node termination handler (AWS Node Termination Handler) |
