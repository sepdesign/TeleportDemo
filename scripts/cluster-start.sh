#!/bin/bash
# Start the stopped project instances.
# Usage: bash scripts/cluster-start.sh [project]
# Set AWS_REGION if you did not use us-west-2.
set -euo pipefail
PROJECT="${1:-teleport}"
REGION="${AWS_REGION:-us-east-1}"

IDS=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" "Name=instance-state-name,Values=stopped" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text)

if [ -z "$IDS" ]; then
  echo "No stopped instances found for project $PROJECT"
  exit 0
fi

aws ec2 start-instances --region "$REGION" --instance-ids $IDS
echo "Starting: $IDS"
echo "Give the cluster about a minute to come back. Then run: kubectl get nodes"
