#!/usr/bin/env bash
# Local build/tag helper only - step4's GitHub Actions pipeline owns the real
# ECR push + kubectl deploy. Matches the per-environment ECR layout from
# microservice_2_terraform: one repo per environment (<cluster_name>/frontend),
# tagged with just the git SHA since the repo name already identifies the env.
#
# Usage: scripts/build-image.sh <develop|staging|production> [ecr-registry]
#   ecr-registry defaults to a placeholder; pass your real
#   <account-id>.dkr.ecr.ca-central-1.amazonaws.com when pushing.
set -euo pipefail

ENV="${1:?Usage: build-image.sh <develop|staging|production> [ecr-registry]}"
REGISTRY="${2:-<account-id>.dkr.ecr.ca-central-1.amazonaws.com}"

case "$ENV" in
  develop|staging|production) ;;
  *) echo "ENV must be one of: develop, staging, production" >&2; exit 1 ;;
esac

GIT_SHA=$(git rev-parse --short HEAD)
REPO="$REGISTRY/microservice2-$ENV/frontend"

docker build \
  --build-arg NG_APP_ENV="$ENV" \
  --build-arg GIT_SHA="$GIT_SHA" \
  -t "$REPO:$GIT_SHA" \
  .

echo "Built $REPO:$GIT_SHA"
