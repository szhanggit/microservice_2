#!/usr/bin/env bash
# Rolls back the frontend Helm release to a previous revision - the
# immediately preceding one if no revision is given, or a specific revision
# number if provided. See `helm history frontend -n frontend` for available
# revisions before choosing one.
#
# Doesn't protect against rolling back to a revision whose image tag has
# since been garbage-collected by ECR's lifecycle policy (keeps only the
# last 10 images per repo, see microservice_2_terraform/modules/ecr) - if
# that happens, this command will succeed but the resulting pods will fail
# to pull the image; check `aws ecr describe-images` for the tag first.
#
# Usage: ./rollback.sh <env> [revision]
set -euo pipefail

ENV="${1:?Usage: $0 <env> [revision]}"
REVISION="${2:-}"

echo "Release history before rollback:"
helm history frontend -n frontend

if [ -n "$REVISION" ]; then
  echo ""
  echo "Rolling back frontend ($ENV) to revision $REVISION..."
  helm rollback frontend "$REVISION" -n frontend --wait --timeout 5m
else
  echo ""
  echo "Rolling back frontend ($ENV) to the previous revision..."
  helm rollback frontend -n frontend --wait --timeout 5m
fi

echo ""
echo "Release history after rollback:"
helm history frontend -n frontend
