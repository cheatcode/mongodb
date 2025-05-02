#!/bin/bash

BACKUP_FILE=$1
CONFIG_FILE="./config.json"

if [ -z "$BACKUP_FILE" ]; then
  echo "Usage: $0 <backup_filename>"
  echo "Run ./list_backups.sh to see available backups."
  exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Missing config.json! Exiting."
  exit 1
fi

DB_USERNAME=$(jq -r '.db_username' "$CONFIG_FILE")
DB_PASSWORD=$(jq -r '.db_password' "$CONFIG_FILE")
AWS_BUCKET=$(jq -r '.aws_bucket' "$CONFIG_FILE")
AWS_REGION=$(jq -r '.aws_region' "$CONFIG_FILE")
HOSTNAME=$(hostname -f)

TMP_PATH="/tmp/$BACKUP_FILE"

echo "Downloading $BACKUP_FILE from S3..."
aws s3 cp s3://$AWS_BUCKET/$HOSTNAME/$BACKUP_FILE $TMP_PATH --region $AWS_REGION

echo "Restoring backup..."
mongorestore --username $DB_USERNAME --password $DB_PASSWORD --authenticationDatabase admin --archive=$TMP_PATH --gzip --drop

rm $TMP_PATH

echo "✅ Restore complete from $BACKUP_FILE"
