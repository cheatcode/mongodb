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
MONGO_PORT=$(jq -r '.mongo_port' "$CONFIG_FILE")

# Get domain name from config.json if available
DOMAIN_CONFIG=$(jq -r '.domain_name' "$CONFIG_FILE")
if [ -n "$DOMAIN_CONFIG" ] && [ "$DOMAIN_CONFIG" != "null" ] && [ "$DOMAIN_CONFIG" != "your.domain.com" ]; then
  DOMAIN="$DOMAIN_CONFIG"
  echo "Using domain name from config.json: $DOMAIN"
else
  DOMAIN="localhost"
  echo "Domain name not set in config.json. Using localhost for connection."
fi

TMP_PATH="/tmp/$BACKUP_FILE"

echo "Downloading $BACKUP_FILE from S3..."
aws s3 cp s3://$AWS_BUCKET/$DOMAIN/$BACKUP_FILE $TMP_PATH --region $AWS_REGION

echo "Restoring backup..."
# Check if MongoDB TLS is configured
CERT_FILE="/etc/ssl/mongodb/certificate.pem"
CA_FILE="/etc/ssl/mongodb/certificate_authority.pem"

# Function to restore backup with fallback to localhost
restore_backup() {
  local host="$1"
  local tls_enabled="$2"
  
  echo "Attempting to restore backup to MongoDB using host: $host"
  # Save error output to a temporary file
  ERROR_LOG=$(mktemp)
  
  # Use the exact command that works
  if [ "$tls_enabled" = "true" ]; then
    TLS_ARG="--ssl --sslCAFile $CA_FILE --sslPEMKeyFile /etc/ssl/mongodb/client.pem"
    echo "NOTE: Client certificates are required for connections."
    echo "      Ensure the client certificate exists at /etc/ssl/mongodb/client.pem"
  else
    TLS_ARG=""
  fi
  
  echo "Running command: mongorestore --host $host --port $MONGO_PORT $TLS_ARG -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --archive=$TMP_PATH --gzip --drop"
  
  if mongorestore --host $host --port $MONGO_PORT $TLS_ARG -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --archive=$TMP_PATH --gzip --drop 2> $ERROR_LOG; then
    echo "✅ Successfully restored backup to MongoDB using host: $host"
    rm $ERROR_LOG
    return 0
  else
    echo "❌ Failed to restore backup to MongoDB using host: $host"
    echo "Error details:"
    cat $ERROR_LOG
    rm $ERROR_LOG
    return 1
  fi
}

# Check if MongoDB TLS/SSL is configured
TLS_ENABLED=false
if [ -f "$CERT_FILE" ] && grep -q "tls:" /etc/mongod.conf && grep -q "mode: requireTLS" /etc/mongod.conf; then
  echo "MongoDB TLS is enabled with private CA certificates."
  TLS_ENABLED=true
elif grep -q "ssl:" /etc/mongod.conf && grep -q "mode: requireSSL" /etc/mongod.conf; then
  echo "MongoDB SSL is enabled (legacy configuration)."
  TLS_ENABLED=true
else
  echo "MongoDB TLS/SSL is not enabled. Using standard connection..."
fi

# Try with domain name first (if not localhost), then fallback to localhost
if [ "$DOMAIN" != "localhost" ]; then
  if ! restore_backup "$DOMAIN" "$TLS_ENABLED"; then
    echo "Trying with localhost instead..."
    if ! restore_backup "localhost" "$TLS_ENABLED"; then
      echo "❌ ERROR: Failed to restore backup using both domain name and localhost."
      rm $TMP_PATH
      exit 1
    fi
  fi
else
  # Just try localhost
  if ! restore_backup "localhost" "$TLS_ENABLED"; then
    echo "❌ ERROR: Failed to restore backup using localhost."
    rm $TMP_PATH
    exit 1
  fi
fi

rm $TMP_PATH

echo "✅ Restore complete from $BACKUP_FILE"
