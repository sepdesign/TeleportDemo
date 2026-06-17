#!/bin/bash
# Show the project instances and their state.
# Usage: bash scripts/cluster-status.sh [project]
# Set AWS_REGION if you did not use us-west-2.
set -euo pipefail
PROJECT="${1:-teleport}"
REGION="${AWS_REGION:-us-east-1}"

aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT" \
  --query "Reservations[].Instances[].{Name:Tags[?Key=='Name']|[0].Value,State:State.Name,Public:PublicIpAddress,Private:PrivateIpAddress}" \
  --output table
