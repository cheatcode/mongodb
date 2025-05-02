#!/bin/bash

CONFIG_FILE="./config.json"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Missing config.json! Exiting."
  exit 1
fi

AWS_BUCKET=$(jq -r '.aws_bucket' "$CONFIG_FILE")
AWS_REGION=$(jq -r '.aws_region' "$CONFIG_FILE")
HOSTNAME=$(hostname -f)

echo "Backups in s3://$AWS_BUCKET/$HOSTNAME (newest → oldest):"
aws s3 ls s3://$AWS_BUCKET/$HOSTNAME/ --region $AWS_REGION | awk '{print $4}' | sort -r
