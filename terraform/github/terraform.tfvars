github_org  = "sandeshlamsal"
github_repo = "Devops_AwsDevToProd_Deployment_ReleasePipeline_Tags"

# ── Reviewer GitHub usernames ─────────────────────────────────────────────────
# Add / remove usernames here to change who gets approval notifications.
# The user must have at least Read access to the repository.

# PROD app deploy — who approves before deploy-prod.yml runs
prod_app_reviewers = ["sandeshlamsal"]

# Terraform DEV — leave empty [] for auto-apply, add names to gate
dev_terraform_reviewers = []

# Terraform QA
qa_terraform_reviewers = ["sandeshlamsal"]

# Terraform PROD
prod_terraform_reviewers = ["sandeshlamsal"]

# Optional: minutes to wait after a reviewer approves PROD before the job starts
prod_wait_minutes = 0
