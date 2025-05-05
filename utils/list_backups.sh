#!/bin/bash

CONFIG_FILE="./config.json"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Missing config.json! Exiting."
  exit 1
fi

AWS_BUCKET=$(jq -r '.aws_bucket' "$CONFIG_FILE")
AWS_REGION=$(jq -r '.aws_region' "$CONFIG_FILE")

# Get domain name from config.json if available
DOMAIN_CONFIG=$(jq -r '.domain_name' "$CONFIG_FILE")
if [ -n "$DOMAIN_CONFIG" ] && [ "$DOMAIN_CONFIG" != "null" ] && [ "$DOMAIN_CONFIG" != "your.domain.com" ]; then
  DOMAIN="$DOMAIN_CONFIG"
  echo "Using domain name from config.json: $DOMAIN"
else
  DOMAIN=$(hostname -f)
  echo "Domain name not set in config.json. Using hostname: $DOMAIN"
fi

echo "Backups in s3://$AWS_BUCKET/$DOMAIN (newest → oldest):"
aws s3 ls s3://$AWS_BUCKET/$DOMAIN/ --region $AWS_REGION | awk '{print $4}' | sort -r
