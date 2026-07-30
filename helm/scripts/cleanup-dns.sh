#!/usr/bin/env bash
# Deletes the Route53 records ExternalDNS created for one Ingress hostname.
#
# ExternalDNS runs with policy=upsert-only (ekslab.xyz is a shared personal
# domain also used by other, unrelated projects, so it's deliberately never
# allowed to auto-delete anything there) - meaning it will NEVER clean these
# records up on its own after the Ingress is deleted. This script does that
# cleanup directly via the Route53 API instead.
#
# Scoped to only the records this cluster's ExternalDNS instance owns
# (verified via its TXT ownership records' txtOwnerId, which matches
# microservice2-<env>), so it never touches another project's records
# sharing the same hosted zone.
#
# Usage: ./cleanup-dns.sh <env> <hostname>
#   hostname is the exact value of the Ingress's
#   external-dns.alpha.kubernetes.io/hostname annotation, e.g.
#   dev_microservice_2.ekslab.xyz
set -euo pipefail

ENV="${1:?Usage: $0 <env> <hostname>}"
HOSTNAME="${2:?Usage: $0 <env> <hostname>}"
# Fixed, not derived from $HOSTNAME by stripping one label - that breaks for
# any hostname with more than one label before the zone (e.g. a hostname like
# "a.b.ekslab.xyz" would wrongly derive "b.ekslab.xyz" as the zone instead of
# the real zone "ekslab.xyz"). Matches microservice_2_terraform's
# var.route53_domain default.
DOMAIN="${ROUTE53_DOMAIN:-ekslab.xyz}"
REGION="${AWS_REGION:-ca-central-1}"
CLUSTER_NAME="microservice2-$ENV"

ZONE_ID="$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" \
  --query "HostedZones[?Name=='${DOMAIN}.'].Id | [0]" --output text)"
ZONE_ID="${ZONE_ID#/hostedzone/}"

if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "None" ]; then
  echo "No hosted zone found for $DOMAIN - skipping DNS cleanup."
  exit 0
fi

echo "Looking for Route53 records under $HOSTNAME in zone $ZONE_ID..."

# Matches the tracked record (A/AAAA, named exactly $HOSTNAME) plus
# ExternalDNS's TXT ownership records (named "<type-prefix>-$HOSTNAME").
RECORDS_JSON="$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${HOSTNAME}.' || ends_with(Name, '-${HOSTNAME}.')]" \
  --output json)"

OWNED_COUNT="$(echo "$RECORDS_JSON" | jq --arg owner "$CLUSTER_NAME" '
  [.[] | select(.Type == "TXT" and (.ResourceRecords[0].Value | contains("external-dns/owner=\($owner)")))] | length
')"

if [ "$OWNED_COUNT" = "0" ]; then
  echo "No records under $HOSTNAME are owned by $CLUSTER_NAME - nothing to clean up (already gone, or never created)."
  exit 0
fi

RECORD_COUNT="$(echo "$RECORDS_JSON" | jq 'length')"
echo "Deleting $RECORD_COUNT Route53 record(s) under $HOSTNAME owned by $CLUSTER_NAME..."

TMP_FILE="$(mktemp)"
echo "$RECORDS_JSON" | jq '{Changes: map({Action: "DELETE", ResourceRecordSet: .})}' > "$TMP_FILE"
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "file://$TMP_FILE" > /dev/null
rm -f "$TMP_FILE"

echo "Route53 cleanup complete."
