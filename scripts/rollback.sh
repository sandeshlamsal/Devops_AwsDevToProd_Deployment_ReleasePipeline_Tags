#!/bin/bash
# rollback.sh <namespace> <deployment> <previous_image>
# Rolls back a deployment to a known-good image.
# Called automatically by deploy-prod.yml on failure.

set -euo pipefail

NAMESPACE="${1:-}"
DEPLOYMENT="${2:-}"
PREV_IMAGE="${3:-}"

if [ -z "$NAMESPACE" ] || [ -z "$DEPLOYMENT" ] || [ -z "$PREV_IMAGE" ]; then
  echo "Usage: $0 <namespace> <deployment> <previous_image>"
  echo "  e.g. $0 release-app nginx-release ghcr.io/org/nginx-release:prod_abc123_v1.1.0"
  exit 1
fi

if [ "$PREV_IMAGE" = "none" ] || [ -z "$PREV_IMAGE" ]; then
  echo "No previous image recorded — attempting kubectl rollout undo instead."
  kubectl rollout undo deployment/"$DEPLOYMENT" -n "$NAMESPACE"
  kubectl rollout status deployment/"$DEPLOYMENT" -n "$NAMESPACE" --timeout=180s
  exit 0
fi

echo "Rolling back $DEPLOYMENT in $NAMESPACE to: $PREV_IMAGE"

# Patch the container image directly (fastest rollback path)
kubectl set image deployment/"$DEPLOYMENT" \
  nginx="$PREV_IMAGE" \
  -n "$NAMESPACE"

echo "Waiting for rollback rollout..."
kubectl rollout status deployment/"$DEPLOYMENT" \
  -n "$NAMESPACE" \
  --timeout=180s

echo ""
echo "Rollback complete. Current image:"
kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
echo ""
