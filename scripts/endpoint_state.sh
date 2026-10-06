#!/usr/bin/env bash
# Print the blue/green state of an online endpoint as key=value lines
# (append to $GITHUB_OUTPUT). The endpoint is the source of truth for
# "production": whatever deployment takes the most traffic is live.
#
#   exists=true|false      endpoint exists
#   live=blue|green|       deployment with the most traffic ('' if none)
#   idle=blue|green        slot the next rollout goes to
#   live_version=N|        model version served by the live slot
#                          ('' if none, or if it serves a different model)
#
# Usage: scripts/endpoint_state.sh <endpoint-name> <model-name>
set -euo pipefail

endpoint="$1"
model_name="$2"

if ! traffic=$(az ml online-endpoint show --name "$endpoint" --query traffic -o json 2>/dev/null); then
  echo "exists=false"; echo "live="; echo "idle=blue"; echo "live_version="
  exit 0
fi
echo "exists=true"

live=$(jq -r '(. // {}) | to_entries | map(select(.value > 0)) | max_by(.value) | .key // ""' <<<"$traffic")
case "$live" in
  blue)  idle=green ;;
  green) idle=blue ;;
  "")    idle=blue ;;
  *)     echo "Unexpected deployment '$live' on $endpoint (expected blue/green)" >&2; exit 1 ;;
esac
echo "live=$live"
echo "idle=$idle"

live_version=""
if [ -n "$live" ]; then
  # Model reference is either an ARM id (.../models/<name>/versions/<v>) or azureml:<name>:<v>.
  ref=$(az ml online-deployment show --name "$live" --endpoint-name "$endpoint" --query model -o tsv)
  if [[ "$ref" =~ models/([^/]+)/versions/([^/]+)$ ]] || [[ "$ref" =~ ^azureml:([^:]+):([^:]+)$ ]]; then
    [ "${BASH_REMATCH[1]}" = "$model_name" ] && live_version="${BASH_REMATCH[2]}"
  fi
fi
echo "live_version=$live_version"
