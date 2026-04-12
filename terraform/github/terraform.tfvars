github_org  = "sandeshlamsal"
github_repo = "Devops_AwsDevToProd_Deployment_ReleasePipeline_Tags"

# ── Reviewer GitHub usernames ─────────────────────────────────────────────────
# Add / remove usernames here to change who gets approval notifications.
# The user must have at least Read access to the repository.
# Set to [] to remove the gate (auto-deploy / auto-apply).

# DEV app deploy — gated like PROD for initial testing; set [] to remove later
dev_app_reviewers = ["sandeshlamsal"]

# PROD app deploy — who approves before deploy-prod.yml runs
prod_app_reviewers = ["sandeshlamsal"]

# Terraform DEV — gated like PROD for initial testing; set [] to remove later
dev_terraform_reviewers = ["sandeshlamsal"]

# Terraform QA
qa_terraform_reviewers = ["sandeshlamsal"]

# Terraform PROD
prod_terraform_reviewers = ["sandeshlamsal"]

# Optional: minutes to wait after a reviewer approves PROD before the job starts
prod_wait_minutes = 0
