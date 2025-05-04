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
SSL_PEM_PATH="/etc/ssl/mongodb.pem"

# Function to restore backup with fallback to localhost
restore_backup() {
  local host="$1"
  local tls_args="$2"
  
  echo "Attempting to restore backup to MongoDB using host: $host"
  if mongorestore --host $host --port $MONGO_PORT $tls_args -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --archive=$TMP_PATH --gzip --drop 2>/dev/null; then
    echo "✅ Successfully restored backup to MongoDB using host: $host"
    return 0
  else
    echo "❌ Failed to restore backup to MongoDB using host: $host"
    return 1
  fi
}

if grep -q "tls:" /etc/mongod.conf && grep -q "mode: requireTLS" /etc/mongod.conf; then
  echo "MongoDB TLS is enabled. Using TLS connection..."
  TLS_ARGS="--tls"
  
  # Try with domain name first (if not localhost), then fallback to localhost
  if [ "$DOMAIN" != "localhost" ]; then
    if ! restore_backup "$DOMAIN" "$TLS_ARGS"; then
      echo "Trying with localhost instead..."
      if ! restore_backup "localhost" "$TLS_ARGS"; then
        echo "❌ ERROR: Failed to restore backup using both domain name and localhost."
        rm $TMP_PATH
        exit 1
      fi
    fi
  else
    # Just try localhost
    if ! restore_backup "localhost" "$TLS_ARGS"; then
      echo "❌ ERROR: Failed to restore backup using localhost."
      rm $TMP_PATH
      exit 1
    fi
  fi
elif grep -q "ssl:" /etc/mongod.conf && grep -q "mode: requireSSL" /etc/mongod.conf; then
  # For backward compatibility with older configurations
  echo "MongoDB SSL is enabled. Using SSL connection..."
  SSL_ARGS="--ssl"
  
  # Try with domain name first (if not localhost), then fallback to localhost
  if [ "$DOMAIN" != "localhost" ]; then
    if ! restore_backup "$DOMAIN" "$SSL_ARGS"; then
      echo "Trying with localhost instead..."
      if ! restore_backup "localhost" "$SSL_ARGS"; then
        echo "❌ ERROR: Failed to restore backup using both domain name and localhost."
        rm $TMP_PATH
        exit 1
      fi
    fi
  else
    # Just try localhost
    if ! restore_backup "localhost" "$SSL_ARGS"; then
      echo "❌ ERROR: Failed to restore backup using localhost."
      rm $TMP_PATH
      exit 1
    fi
  fi
else
  echo "MongoDB TLS is not enabled. Using standard connection..."
  
  # Try with domain name first (if not localhost), then fallback to localhost
  if [ "$DOMAIN" != "localhost" ]; then
    if ! restore_backup "$DOMAIN" ""; then
      echo "Trying with localhost instead..."
      if ! restore_backup "localhost" ""; then
        echo "❌ ERROR: Failed to restore backup using both domain name and localhost."
        rm $TMP_PATH
        exit 1
      fi
    fi
  else
    # Just try localhost
    if ! restore_backup "localhost" ""; then
      echo "❌ ERROR: Failed to restore backup using localhost."
      rm $TMP_PATH
      exit 1
    fi
  fi
fi

rm $TMP_PATH

echo "✅ Restore complete from $BACKUP_FILE"
