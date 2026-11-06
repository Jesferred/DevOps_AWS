#!/usr/bin/env bash
# Records a production deployment for DORA metrics in the monitoring table.
# usage: record-deployment.sh <site|infra> <success|failure> <commit_unix_time>
set -euo pipefail

kind=$1 status=$2 commit_at=$3
now=$(date -u +%s)

item=$(jq -n \
  --arg sk "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)#$kind" \
  --arg kind "$kind" --arg status "$status" --arg sha "$GITHUB_SHA" \
  --arg run_url "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" \
  --arg deployed_at "$now" --arg commit_at "$commit_at" \
  --arg expires_at "$((now + 400 * 86400))" \
  '{pk: {S: "deploy"}, sk: {S: $sk}, kind: {S: $kind}, status: {S: $status}, sha: {S: $sha},
    run_url: {S: $run_url}, deployed_at: {N: $deployed_at}, commit_at: {N: $commit_at},
    expires_at: {N: $expires_at}}')

aws dynamodb put-item --region eu-central-1 --table-name kovalov-in-prod-monitoring --item "$item"
echo "recorded $kind deployment ($status), lead time $(( (now - commit_at) / 60 )) min"
