#!/bin/bash

# connection_info.sh - Outputs MongoDB connection information in JSON format
# Usage: ./connection_info.sh

set -e

CONFIG_FILE="./config.json"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Missing config.json! Exiting."
  exit 1
fi

# Load configuration values
DB_USERNAME=$(jq -r '.db_username' "$CONFIG_FILE")
DB_PASSWORD=$(jq -r '.db_password' "$CONFIG_FILE")
MONGO_PORT=$(jq -r '.mongo_port' "$CONFIG_FILE")
REPLICA_SET=$(grep -oP 'replSetName: \K\S+' /etc/mongod.conf || echo "rs0")

# Check if MongoDB is running
if ! systemctl is-active --quiet mongod; then
  echo "❌ ERROR: MongoDB is not running. Please start MongoDB first."
  exit 1
fi

# Check if TLS is provisioned
CERT_FILE="/etc/ssl/mongodb/certificate.pem"
CA_FILE="/etc/ssl/mongodb/certificate_authority.pem"
TLS_ENABLED=false
if [ -f "$CERT_FILE" ] && grep -q "tls:" /etc/mongod.conf && grep -q "mode: requireTLS" /etc/mongod.conf; then
  TLS_ENABLED=true
  TLS_ARGS="--tls"
elif grep -q "ssl:" /etc/mongod.conf && grep -q "mode: requireSSL" /etc/mongod.conf; then
  # For backward compatibility with older configurations
  TLS_ENABLED=true
  TLS_ARGS="--ssl"
else
  TLS_ARGS=""
fi

# Get domain name from config.json if available
DOMAIN_CONFIG=$(jq -r '.domain_name' "$CONFIG_FILE")
if [ -n "$DOMAIN_CONFIG" ] && [ "$DOMAIN_CONFIG" != "null" ] && [ "$DOMAIN_CONFIG" != "your.domain.com" ]; then
  DOMAIN="$DOMAIN_CONFIG"
  echo "Using domain name from config.json: $DOMAIN"
else
  DOMAIN="localhost"
  echo "Domain name not set in config.json. Using localhost for connection."
fi

# Get replica set status and extract members
TEMP_FILE=$(mktemp)

# Store the original domain name for the connection string
CONNECTION_DOMAIN="$DOMAIN"

  # Try to connect using the domain name first (if not localhost)
  if [ "$DOMAIN" != "localhost" ]; then
    echo "Attempting to connect to MongoDB using domain name: $DOMAIN"
    if mongosh --host $DOMAIN --port $MONGO_PORT --tls --tlsCAFile $CA_FILE --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --quiet --eval "JSON.stringify(rs.status())" > $TEMP_FILE 2>/dev/null; then
      echo "✅ Successfully connected to MongoDB using domain name: $DOMAIN"
    else
      echo "Connection using domain name failed. Trying localhost..."
      # If that fails, try connecting using localhost
      if mongosh --host localhost --port $MONGO_PORT --tls --tlsCAFile $CA_FILE --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --quiet --eval "JSON.stringify(rs.status())" > $TEMP_FILE 2>/dev/null; then
      echo "✅ Successfully connected to MongoDB using localhost."
      # Note: We're not changing CONNECTION_DOMAIN, only the DOMAIN for the current connection
      DOMAIN="localhost"
    else
      echo "❌ ERROR: Failed to connect to MongoDB using both domain name and localhost."
      rm $TEMP_FILE
      exit 1
    fi
  fi
else
  # Just try localhost
  echo "Attempting to connect to MongoDB using localhost"
  if mongosh --host localhost --port $MONGO_PORT --tls --tlsCAFile $CA_FILE --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --quiet --eval "JSON.stringify(rs.status())" > $TEMP_FILE 2>/dev/null; then
    echo "✅ Successfully connected to MongoDB using localhost."
  else
    echo "❌ ERROR: Failed to connect to MongoDB using localhost."
    rm $TEMP_FILE
    exit 1
  fi
fi

# Check if the command was successful
if [ $? -ne 0 ] || [ ! -s $TEMP_FILE ]; then
  echo "❌ ERROR: Failed to get replica set status."
  rm $TEMP_FILE
  exit 1
fi

# Extract hosts array using jq
HOSTS_JSON=$(cat $TEMP_FILE | jq -c '[.members[] | {hostname: (.name | split(":")[0]), port: (.name | split(":")[1]), state: (if .stateStr == "PRIMARY" then "primary" elif .stateStr == "SECONDARY" then "secondary" else "other" end)}]')
rm $TEMP_FILE

# Build connection string
if [ "$TLS_ENABLED" = true ]; then
  CONNECTION_STRING="mongodb://$DB_USERNAME:$DB_PASSWORD@$(echo $HOSTS_JSON | jq -r 'map(.hostname + ":" + .port) | join(",")' || echo "$CONNECTION_DOMAIN:$MONGO_PORT")/?tls=true&tlsCAFile=$CA_FILE&tlsCertificateKeyFile=/etc/ssl/mongodb/client.pem&authSource=admin&replicaSet=$REPLICA_SET"
  echo "NOTE: The connection string includes client certificate path."
  echo "      Ensure the client certificate exists at /etc/ssl/mongodb/client.pem"
else
  CONNECTION_STRING="mongodb://$DB_USERNAME:$DB_PASSWORD@$(echo $HOSTS_JSON | jq -r 'map(.hostname + ":" + .port) | join(",")' || echo "$CONNECTION_DOMAIN:$MONGO_PORT")/?authSource=admin&replicaSet=$REPLICA_SET"
fi

# Output JSON
cat <<EOF
{
  "username": "$DB_USERNAME",
  "password": "$DB_PASSWORD",
  "hosts": $HOSTS_JSON,
  "tls_enabled": $TLS_ENABLED,
  "replica_set": "$REPLICA_SET",
  "connection_string": "$CONNECTION_STRING"
}
EOF
