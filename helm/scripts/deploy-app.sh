#!/usr/bin/env bash
# Applies this chart to whatever cluster kubectl is currently pointed at
# (see ./update-kubeconfig.sh). No SSM Parameter Store indirection - the ECR
# repository URL is derived directly from the current AWS account/region and
# microservice_2_terraform's fixed per-environment repo naming
# (microservice2-<env>/frontend).
#
# Requires: helm, aws cli, kubectl pointed at the target cluster.
#
# Usage: ./deploy-app.sh <env> [tag]
#   tag defaults to the current commit's short SHA.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$HELM_DIR/.." && pwd)"

ENV="${1:?Usage: $0 <develop|staging|production> [tag]}"
TAG="${2:-$(git -C "$REPO_ROOT" rev-parse --short HEAD)}"
REGION="${AWS_REGION:-ca-central-1}"

case "$ENV" in
  develop|staging|production) ;;
  *) echo "ENV must be one of: develop, staging, production" >&2; exit 1 ;;
esac

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
IMAGE_REPO="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/microservice2-$ENV/frontend"

echo "frontend -> $IMAGE_REPO:$TAG"

helm upgrade --install frontend "$HELM_DIR" \
  --namespace frontend --create-namespace \
  -f "$HELM_DIR/values-$ENV.yaml" \
  --set image.repository="$IMAGE_REPO" \
  --set image.tag="$TAG" \
  --wait --timeout 5m

echo ""
echo "Deployed. Once the AWS Load Balancer Controller provisions the ALB:"
echo "  kubectl get ingress -n frontend"
