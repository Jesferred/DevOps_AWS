#!/usr/bin/env bash
# Deploys s3://<bucket>/releases/site.zip (current version) to the Amplify
# production branch and waits for the job to finish.
# usage: amplify-deploy.sh <bucket>
set -euo pipefail

bucket=$1
app=$(aws ssm get-parameter --name /kovalov-in/prod/site/amplify-app-id --query Parameter.Value --output text)

job=$(aws amplify start-deployment --app-id "$app" --branch-name main \
  --source-url "s3://$bucket/releases/site.zip" --query jobSummary.jobId --output text)
echo "Amplify job $job started"

for _ in $(seq 1 60); do
  status=$(aws amplify get-job --app-id "$app" --branch-name main --job-id "$job" --query job.summary.status --output text)
  case $status in
    SUCCEED)
      echo "Deployed to https://kovalov.in (Amplify job $job)" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
      exit 0 ;;
    FAILED | CANCELLED)
      aws amplify get-job --app-id "$app" --branch-name main --job-id "$job" --query 'job.steps[].[stepName,status,statusReason]' --output text
      echo "::error::Amplify job $job $status"
      exit 1 ;;
  esac
  sleep 5
done
echo "::error::Amplify job $job timed out"
exit 1
