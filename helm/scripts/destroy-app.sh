#!/usr/bin/env bash
# Tears down the frontend Helm release for one environment - run this BEFORE
# `just destroy <env>` in microservice_2_terraform, or the ALB's security
# groups/ENIs can block Terraform from deleting the VPC.
#
# Captures the Ingress's ExternalDNS hostname *before* deleting anything,
# since it's needed by cleanup-dns.sh afterward.
#
# Usage: ./destroy-app.sh <env>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV="${1:?Usage: $0 <env>}"

HOSTNAME="$(kubectl get ingress -n frontend frontend -o jsonpath='{.metadata.annotations.external-dns\.alpha\.kubernetes\.io/hostname}' 2>/dev/null || true)"

# --wait matters: without it, the ALB controller may not have finished
# deleting the real AWS ALB (via the Ingress's finalizer) before this
# returns, which can leave the namespace stuck in Terminating.
helm uninstall frontend -n frontend --wait --timeout 5m || true

if [ -n "$HOSTNAME" ]; then
  "$SCRIPT_DIR/cleanup-dns.sh" "$ENV" "$HOSTNAME"
else
  echo "No Ingress hostname found (already deleted?) - skipping DNS cleanup."
fi
