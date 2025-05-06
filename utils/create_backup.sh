#!/bin/bash

# create_backup.sh - Manually create a MongoDB backup and upload to S3
# Usage: ./create_backup.sh [backup_name_prefix]

CONFIG_FILE="./config.json"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Missing config.json! Exiting."
  exit 1
fi

# Load configuration values
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
  DOMAIN=$(hostname -f)
  echo "Domain name not set in config.json. Using hostname: $DOMAIN"
fi

# Generate backup filename with timestamp
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
PREFIX=${1:-"manual"}
BACKUP_FILENAME="${PREFIX}-${TIMESTAMP}.gz"
TMP_PATH="/tmp/$BACKUP_FILENAME"

echo "🔄 Creating MongoDB backup: $BACKUP_FILENAME"

# Function to create backup with fallback to localhost
create_backup() {
  local host="$1"
  local tls_enabled="$2"
  
  echo "Attempting to create backup from MongoDB using host: $host"
  # Save error output to a temporary file
  ERROR_LOG=$(mktemp)
  
  # Use the exact command that works
  if [ "$tls_enabled" = "true" ]; then
    # For mongodump, use --ssl flags
    TLS_ARG="--ssl --sslCAFile $CA_FILE --sslPEMKeyFile /etc/ssl/mongodb/client.pem"
    # For mongosh, use --tls flags
    MONGOSH_TLS_ARG="--tls --tlsCAFile $CA_FILE --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem"
    echo "NOTE: Client certificates are required for connections."
    echo "      Ensure the client certificate exists at /etc/ssl/mongodb/client.pem"
    
    # Check if MongoDB is responsive first
    echo "Checking if MongoDB is responsive..."
    echo "Running command: mongosh --host $host --port $MONGO_PORT $MONGOSH_TLS_ARG -u $DB_USERNAME -p [PASSWORD] --authenticationDatabase admin --eval \"db.adminCommand('ping')\""
    
    MONGO_CHECK_OUTPUT=$(mktemp)
    if ! mongosh --host $host --port $MONGO_PORT $MONGOSH_TLS_ARG -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --eval "db.adminCommand('ping')" > $MONGO_CHECK_OUTPUT 2>&1; then
      echo "❌ ERROR: MongoDB is not responsive. Backup aborted."
      echo "Error output from command:"
      cat $MONGO_CHECK_OUTPUT
      rm -f $MONGO_CHECK_OUTPUT
      return 1
    fi
    echo "✅ MongoDB is responsive."
    rm -f $MONGO_CHECK_OUTPUT
  else
    TLS_ARG=""
  fi
  
  echo "Running command: mongodump --host $host --port $MONGO_PORT $TLS_ARG -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --archive=$TMP_PATH --gzip"
  
  if mongodump --host $host --port $MONGO_PORT $TLS_ARG -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --archive=$TMP_PATH --gzip 2> $ERROR_LOG; then
    echo "✅ Successfully created backup from MongoDB using host: $host"
    rm $ERROR_LOG
    return 0
  else
    echo "❌ Failed to create backup from MongoDB using host: $host"
    echo "Error details:"
    cat $ERROR_LOG
    rm $ERROR_LOG
    return 1
  fi
}

# Check if MongoDB TLS/SSL is configured
CERT_FILE="/etc/ssl/mongodb/certificate.pem"
CA_FILE="/etc/ssl/mongodb/certificate_authority.pem"
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
  if ! create_backup "$DOMAIN" "$TLS_ENABLED"; then
    echo "Trying with localhost instead..."
    if ! create_backup "localhost" "$TLS_ENABLED"; then
      echo "❌ ERROR: Failed to create backup using both domain name and localhost."
      exit 1
    fi
  fi
else
  # Just try localhost
  if ! create_backup "localhost" "$TLS_ENABLED"; then
    echo "❌ ERROR: Failed to create backup using localhost."
    exit 1
  fi
fi

# Upload to S3
echo "📤 Uploading backup to S3..."
aws s3 cp $TMP_PATH s3://$AWS_BUCKET/$DOMAIN/$BACKUP_FILENAME --region $AWS_REGION

# Clean up
rm $TMP_PATH

echo "✅ Backup complete: s3://$AWS_BUCKET/$DOMAIN/$BACKUP_FILENAME"
echo "Run ./utils/list_backups.sh to see all available backups."
