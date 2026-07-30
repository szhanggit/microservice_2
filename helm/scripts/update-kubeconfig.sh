#!/usr/bin/env bash
# Points local kubectl/helm at the EKS cluster for one environment. Cluster
# names are deterministic (microservice2-<env>, see microservice_2_terraform's
# environments/<env>/<env>.tfvars) so no SSM Parameter Store lookup is needed,
# unlike the microservice0 reference project.
#
# Usage: ./update-kubeconfig.sh <develop|staging|production>
set -euo pipefail

ENV="${1:?Usage: $0 <develop|staging|production>}"
REGION="${AWS_REGION:-ca-central-1}"

case "$ENV" in
  develop|staging|production) ;;
  *) echo "ENV must be one of: develop, staging, production" >&2; exit 1 ;;
esac

aws eks --region "$REGION" update-kubeconfig --name "microservice2-$ENV"
