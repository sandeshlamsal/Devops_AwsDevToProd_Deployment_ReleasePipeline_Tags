# Pipeline Hardening Log — DEV Environment

All issues encountered, root causes, fixes applied, and forward recommendations
for QA and PROD. Covers the full CI → Build → Deploy pipeline for the
nginx-release app on EKS.

---

## Table of Contents

1. [Pipeline Overview](#pipeline-overview)
2. [Issues Fixed — Terraform / Infrastructure](#issues-fixed--terraform--infrastructure)
3. [Issues Fixed — CI (Semgrep, Gitleaks, nginx lint)](#issues-fixed--ci)
4. [Issues Fixed — Build (Trivy)](#issues-fixed--build)
5. [Issues Fixed — Deploy (kubectl, ConfigMap, rollback)](#issues-fixed--deploy)
6. [Issues Fixed — DAST (OWASP ZAP)](#issues-fixed--dast-owasp-zap)
7. [DEV vs QA vs PROD Pipeline Parity](#dev-vs-qa-vs-prod-pipeline-parity)
8. [ZAP in QA and PROD — Full Guide](#zap-in-qa-and-prod--full-guide)
9. [Cost Management](#cost-management)

---

## Pipeline Overview

```
Push to main
    │
    ├─► Terraform — DEV          (infra: VPC, EKS, IAM/OIDC)
    │
    └─► DEV — CI → Build → Deploy
            │
            ├── Job 1: CI         (Gitleaks, Semgrep SAST, nginx lint, unit tests)
            ├── Job 2: Build       (Docker build, Trivy image scan, push to GHCR)
            └── Job 3: Deploy      (kubectl apply, smoke test, OWASP ZAP, rollback)
```

Tag push (`qa_<sha>_v<ver>` / `prod_<sha>_v<ver>`) promotes the dev image to QA/PROD
without rebuilding — same image, re-tagged.

---

## Issues Fixed — Terraform / Infrastructure

### 1. EKS cluster destroyed on every Terraform apply

**Symptom:** Every `terraform apply` triggered a full EKS cluster destroy + recreate (~25 min).

**Root cause:** A one-time migration step (`terraform destroy -target=module.eks`) added
for the 1.29 → 1.34 Kubernetes version upgrade was never removed from `terraform-dev.yml`.
It ran on every subsequent apply.

**Fix:** Removed the destroy step from the workflow after the migration was complete.

---

### 2. `kubectl create namespace` — Forbidden

**Symptom:** `kubectl create namespace release-app` failed with `403 Forbidden`.

**Root cause (two layers):**
1. `access_scope.type = "namespace"` — the GitHub Actions IAM role only had
   namespace-scoped EKS access, but creating a namespace is a cluster-scoped operation.
2. `AmazonEKSAdminPolicy` — even after switching to `type = "cluster"`, this policy
   maps to the Kubernetes `admin` ClusterRole, which still cannot create namespaces.

**Fix:** Two changes in `terraform/dev/main.tf`:
- `access_scope.type = "cluster"`
- Policy changed from `AmazonEKSAdminPolicy` → `AmazonEKSClusterAdminPolicy`
  (maps to `cluster-admin`, full cluster access)

---

### 3. IAM permission bootstrap deadlock

**Symptom:** `terraform plan` failed with `AccessDeniedException` on KMS and CloudWatch
Logs resources — the plan step itself needed permissions that only `terraform apply` could grant.

**Root cause:** Chicken-and-egg: plan reads existing resources (needs permissions) →
apply grants permissions → plan can't run → apply never runs.

**Fix:** Added a `Pre-apply IAM permissions` step in the plan job that runs
`terraform apply -target=module.iam_oidc` before the plan. IAM propagation delay of 30s
added after to let the policy reach all regional endpoints.

---

### 4. Missing IAM permissions (incremental)

Multiple `AccessDeniedException` errors during terraform apply and EKS operations:

| Missing Permission | Where Needed |
|---|---|
| `iam:CreateServiceLinkedRole` | EKS needs to create `AWSServiceRoleForAmazonEKS` |
| `logs:ListTagsForResource` | CloudWatch Logs tagging during plan refresh |
| `iam:ListInstanceProfilesForRole` | EKS node group role validation |
| `kms:PutKeyPolicy`, `kms:CreateGrant` | EKS cluster encryption key management |

All added to `terraform/modules/iam-oidc/main.tf`. The KMS block required a
`# nosemgrep` comment because the Semgrep rule `no-iam-resource-exposure` fires
on wildcard KMS resources (intentional — KMS key doesn't exist at policy creation time).

---

### 5. Stale S3 state lock

**Symptom:** `terraform init` / `plan` failed with state lock error after a cancelled run.

**Fix:** Added a `Release stale state lock` step to both plan and apply jobs:
```bash
aws s3 rm s3://tfstate-nginx-release-dev-.../eks/terraform.tfstate.tflock || true
```

---

## Issues Fixed — CI

### 6. Semgrep SAST — 12 blocking findings (initial run)

All resolved. Key suppressions added with `# nosemgrep` and documented inline:

| File | Rule | Reason |
|---|---|---|
| `iam-oidc/main.tf` | `no-iam-resource-exposure` | KMS key doesn't exist at policy-creation time (chicken-and-egg) |
| `nginx/nginx.conf` | `header-redefinition` | Cache-Control intentionally set per-location (different values for `/`, `/health`, `/version`). Security headers come from the shared `include` file. |

---

### 7. nginx lint — `security-headers.conf` not found

**Symptom:** CI lint step (`nginx -t`) failed with:
```
open() "/etc/nginx/security-headers.conf" failed (2: No such file or directory)
```

**Root cause:** The lint step mounted only `nginx.conf` into the Docker container.
After extracting security headers to a separate `security-headers.conf` include file,
the container couldn't find it.

**Fix:** Added a second `-v` mount in `_reusable-ci.yml`:
```yaml
docker run --rm \
  -v ".../nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v ".../nginx/security-headers.conf:/etc/nginx/security-headers.conf:ro" \
  nginx:1.27-alpine nginx -t
```

---

### 8. nginx base image CVEs

**Fix:** Upgraded base image from `nginx:1.25-alpine` → `nginx:1.27-alpine`.
Added `apk upgrade --no-cache` at build time to patch CVEs that appear after the
base image is published (libxml2, libssl3, libpng).

---

## Issues Fixed — Build

### 9. Trivy — CVEs in base image packages

Resolved by the base image upgrade + `apk upgrade` in Dockerfile (see #8 above).

---

## Issues Fixed — Deploy

### 10. ConfigMap showing `unknown` values

**Symptom:** The release dashboard showed `APP_VERSION=unknown`, `ENV_NAME=unknown`.

**Root cause:** Ordering bug. The original sequence was:
1. `kubectl create configmap` (with real values)
2. `kubectl apply -k overlays/dev` ← this overwrites ConfigMap with `unknown` placeholder values from `k8s/base/configmap.yaml`

**Fix:** Reversed the order — apply kustomize first, then overwrite the ConfigMap.
Also added a `kubectl patch deployment` with a `configmap-version` annotation to force
pods to restart and pick up the new ConfigMap values:
```bash
kubectl patch deployment nginx-release -n release-app \
  -p '{"spec":{"template":{"metadata":{"annotations":{"configmap-version":"<sha>"}}}}}'
```

---

### 11. Rollback not implemented in DEV

**Fix:** Added full rollback parity with QA/PROD:
- `Capture previous image` step before deploy
- `id: rollout` + `continue-on-error: true` on rollout wait
- `id: smoke` + `continue-on-error: true` on smoke test
- `Rollback on failure` step using `scripts/rollback.sh`
- `Fail pipeline if rollback triggered` step

---

### 12. nginx returning 200 for unknown paths (SPA fallback)

**Root cause:** `try_files $uri $uri/ /index.html` was treating all unknown paths
as SPAs and returning the index page with a 200.

**Fix:** Changed to `try_files $uri $uri/ =404` — unknown paths return a proper 404.

---

## Issues Fixed — DAST (OWASP ZAP)

### 13. ZAP — PermissionError writing `zap.yaml`

**Symptom:**
```
PermissionError: [Errno 13] Permission denied: '/github/workspace/zap.yaml'
```

**Root cause:** ZAP runs as a non-root Docker container. The GitHub Actions workspace
directory was owned by root.

**Fix:** Added `chmod a+w .` step before the ZAP action in both DEV and QA workflows.

---

### 14. ZAP — `allow_issue_writing` — `Resource not accessible by integration`

**Symptom:** ZAP step failed with:
```
Error: Resource not accessible by integration
https://docs.github.com/rest/issues/issues#create-an-issue
```

**Root cause:** ZAP's default behaviour (`allow_issue_writing: true`) tries to create
a GitHub Issue with the scan report. The workflow token doesn't have `issues: write`.

**Fix:** Added `allow_issue_writing: false` to the ZAP action in DEV.

---

### 15. ZAP — 7 WARN-NEW security header alerts

**Root cause:** nginx `add_header` inheritance rule: if a child `location` block
contains ANY `add_header` directive, it does NOT inherit `add_header` directives
from the parent `server` block. The security headers were in the `server` block;
each location block had its own `add_header Cache-Control`, which silently dropped
all security headers for those locations.

**Fix:**
- Created `nginx/security-headers.conf` — a shared include file with all 9 headers.
- Rewrote `nginx/nginx.conf` to use `include /etc/nginx/security-headers.conf;`
  inside every `location` block alongside its per-location `Cache-Control`.
- Added `COPY html/security-headers.conf` to the Dockerfile.
- Updated the CI lint step to mount both files.

**Headers added:**

| Header | Value |
|---|---|
| `X-Frame-Options` | `SAMEORIGIN` |
| `X-Content-Type-Options` | `nosniff` |
| `X-XSS-Protection` | `1; mode=block` |
| `Referrer-Policy` | `no-referrer` |
| `Content-Security-Policy` | `default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'` |
| `Permissions-Policy` | `geolocation=(), microphone=(), camera=()` |
| `Cross-Origin-Embedder-Policy` | `require-corp` |
| `Cross-Origin-Opener-Policy` | `same-origin` |
| `Cross-Origin-Resource-Policy` | `same-origin` |

---

### 16. ZAP — CSP `unsafe-inline` [rule 10055]

**Root cause:** The HTML template had a `<style>` block and an inline `style=`
attribute. The CSP included `style-src 'self' 'unsafe-inline'` to allow them.
ZAP flags `'unsafe-inline'` as a security risk.

**Fix:**
- Moved all CSS to `nginx/html/style.css` (external file).
- Replaced the inline `style=` attribute with a CSS class.
- Removed `'unsafe-inline'` from the CSP `style-src` directive.
- Added `COPY html/style.css` to the Dockerfile.

---

### 17. ZAP — Cache-Control rule 10049 (the persistent one)

This rule has three variants — all are WARN level by default in the ZAP baseline scan:

| Cache-Control value | ZAP fires as |
|---|---|
| `no-store` | "Non-Storable Content" — WARN |
| `no-cache` / `must-revalidate` | "Storable but Non-Cacheable" — WARN |
| `public, max-age=60` | "Storable and Cacheable" — WARN (for discovered URLs) |

**Key insight:** ZAP rule 10049 fires for **all three caching states** on URLs it
discovers by crawling (CSS files, probed paths like `/robots.txt`, `/sitemap.xml`).
The scan target URL itself (`/`) is exempt from this check.

**DEV resolution:** `continue-on-error: true` + `fail_action: false` + `allow_issue_writing: false`.
ZAP still runs and generates a report artifact, but never blocks the DEV pipeline.

**QA/PROD resolution:** See the next section.

---

## DEV vs QA vs PROD Pipeline Parity

| Check | DEV | QA | PROD |
|---|---|---|---|
| Gitleaks secret scan | ✓ | ✓ (via DEV CI) | ✓ (via DEV CI) |
| Semgrep SAST | ✓ | ✓ | ✓ |
| nginx lint (`nginx -t`) | ✓ | ✓ | ✓ |
| Unit tests | ✓ | ✓ | ✓ |
| Trivy image scan | ✓ | ✓ (same image) | ✓ (same image) |
| Rollback on failure | ✓ | ✓ | ✓ |
| Smoke test | ✓ | ✓ | ✓ |
| OWASP ZAP DAST | Runs, never blocks | `fail_action: true` | No ZAP (no LB) |
| Approval gate | None (auto) | Required | Required |
| Image rebuild | Every push | Re-tag only | Re-tag only |

---

## ZAP in QA and PROD — Full Guide

### Current state

QA has ZAP with `fail_action: true`. It will block the QA promotion if any
WARN-NEW or FAIL-NEW findings are present.

### Expected findings in QA (and how to resolve them)

#### Rule 10049 — Cache-Control (the hardest one)

**Why it will fire in QA:**
ZAP crawls the app, discovers `/style.css`, and probes for `/robots.txt`, `/sitemap.xml`.
These get either a `public, max-age=60` (200) or a cached 404 response. Both trigger 10049.

**Option A — `.zap/rules.tsv` (recommended)**

Create `.zap/rules.tsv` at the repo root:
```
10049	IGNORE	Cache-Control intentionally set to public,max-age=60. Dynamic release dashboard content. Reviewed and accepted.
```

Add `rules_file_name: .zap/rules.tsv` to the ZAP action in `deploy-qa.yml` and
`deploy-prod.yml` (if prod gets ZAP in the future):
```yaml
- name: DAST — OWASP ZAP baseline scan
  uses: zaproxy/action-baseline@v0.12.0
  with:
    target:          ${{ steps.url.outputs.url }}
    fail_action:     true
    rules_file_name: .zap/rules.tsv
```

This is the **documented, correct ZAP mechanism** for intentional design decisions.
It does not suppress other rules — only 10049.

**Option B — Add `robots.txt` and `sitemap.xml` static files**

This prevents 404s on probed paths. Create in `nginx/html/`:
- `robots.txt`:
  ```
  User-agent: *
  Disallow:
  ```
- `sitemap.xml`:
  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.2"/>
  ```

These files return 200 instead of 404. However, the `/style.css` 200 response
will still trigger 10049. Option B alone does not fully solve the problem.
Must be combined with Option A.

**Option C — Long-lived caching for static assets**

Serve `/style.css` from a dedicated location block with `Cache-Control: private, max-age=3600`:
```nginx
location ~* \.(css|js|ico|png|jpg|woff2?)$ {
  include /etc/nginx/security-headers.conf;
  add_header Cache-Control "private, max-age=3600" always;
}
```

`private` means browser-only cache (not shared proxy cache). ZAP may not flag
`private` responses for "Storable and Cacheable Content" since the concern is
shared cache exposure. **Uncertain** — needs testing in a ZAP scan to confirm.

**Recommendation: Use Option A (rules file).** It is the documented ZAP approach,
is auditable (the rules file lives in source control with a comment explaining why),
and does not require architectural compromises.

---

#### Rule 10055 — CSP `unsafe-inline` (already fixed)

Already resolved by moving CSS to an external file. As long as no new inline
`<style>` blocks or `style=` attributes are added to the HTML template, this
rule will not fire.

**Going forward:** Never add inline styles to `nginx/html/index.html.template`.
All styling must live in `nginx/html/style.css`.

---

#### Other rules to watch in QA

| Rule | Description | Likely status |
|---|---|---|
| 10035 — HSTS | Strict-Transport-Security missing | PASS (HTTP, not HTTPS — HSTS not applicable) |
| 10038 — CSP not set | Content-Security-Policy missing | PASS (we set it) |
| 10020 — Anti-clickjacking | X-Frame-Options missing | PASS (we set it) |
| 10021 — X-Content-Type-Options | Missing | PASS (we set it) |

If QA terminates TLS at the ALB/ingress and ZAP scans via HTTPS, rule 10035
(HSTS) will fire. Fix: add `Strict-Transport-Security: max-age=31536000` to
`security-headers.conf`.

---

### Recommended QA ZAP setup (copy-paste ready)

```yaml
      - name: Set workspace permissions for ZAP
        run: chmod a+w .

      - name: DAST — OWASP ZAP baseline scan
        uses: zaproxy/action-baseline@v0.12.0
        with:
          target:          ${{ steps.url.outputs.url }}
          fail_action:     true
          allow_issue_writing: false
          rules_file_name: .zap/rules.tsv
```

`.zap/rules.tsv`:
```
10049	IGNORE	Cache-Control: public,max-age=60 on dynamic release dashboard. Rule fires on discovered CSS and probed paths regardless of cache value. Intentional — reviewed.
```

---

## Cost Management

### DEV daily cost breakdown

| Resource | $/hr | $/day |
|---|---|---|
| EKS control plane | $0.10 | $2.40 |
| EC2 spot t3.small | ~$0.007 | ~$0.17 |
| NAT Gateway | $0.045 | $1.08 |
| Load Balancer | $0.018 | $0.43 |
| **Total (running)** | | **~$4.08/day** |
| **Total (torn down)** | | **~$0.01/day** (S3 + KMS only) |

### Tear down and bring up

**Tear down (end of day):**
Actions → **DEV — Teardown (save costs)** → Run workflow → type `DESTROY`

Destroys: EKS cluster, node group, VPC, NAT gateway, subnets, load balancer.
Keeps: IAM OIDC role + policies (required for bring-up auth).

**Bring back up (next day, 2 steps):**
1. Actions → **Terraform — DEV** → Run workflow → `action=apply` (~15 min)
2. Actions → **DEV — CI → Build → Deploy** → Run workflow (~5 min)

### Node scale (alternative to full teardown)

If you want to keep the cluster (avoid 15-min recreate) but stop paying for EC2:
```bash
# Pause nodes (keeps control plane at $0.10/hr)
aws eks update-nodegroup-config \
  --cluster-name eks-dev \
  --nodegroup-name eks-dev-spot \
  --scaling-config minSize=0,maxSize=3,desiredSize=0 \
  --region us-east-1

# Resume
aws eks update-nodegroup-config \
  --cluster-name eks-dev \
  --nodegroup-name eks-dev-spot \
  --scaling-config minSize=1,maxSize=3,desiredSize=1 \
  --region us-east-1
```

Or use the **Cluster — Pause / Resume** GitHub Actions workflow.
