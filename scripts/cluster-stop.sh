#!/bin/bash
# Stop the running project instances to save money.
# Usage: bash scripts/cluster-stop.sh [project]
# Set AWS_REGION if you did not use us-west-2.
set -euo pipefail
PROJECT="${1:-teleport}"
REGION="${AWS_REGION:-us-east-1}"

IDS=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text)

if [ -z "$IDS" ]; then
  echo "No running instances found for project $PROJECT"
  exit 0
fi

aws ec2 stop-instances --region "$REGION" --instance-ids $IDS
echo "Stopping: $IDS"
