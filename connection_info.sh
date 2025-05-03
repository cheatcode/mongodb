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

# Check if SSL is provisioned
SSL_PEM_PATH="/etc/ssl/mongodb.pem"
SSL_ENABLED=false
if [ -f "$SSL_PEM_PATH" ] && grep -q "ssl:" /etc/mongod.conf && grep -q "mode: requireSSL" /etc/mongod.conf; then
  SSL_ENABLED=true
  SSL_ARGS="--ssl --sslCAFile $SSL_PEM_PATH"
else
  SSL_ARGS=""
fi

# Get replica set status and extract members
TEMP_FILE=$(mktemp)
mongosh --port $MONGO_PORT $SSL_ARGS --quiet --eval "JSON.stringify(rs.status())" > $TEMP_FILE

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
if [ "$SSL_ENABLED" = true ]; then
  CONNECTION_STRING="mongodb://$DB_USERNAME:$DB_PASSWORD@$(echo $HOSTS_JSON | jq -r 'map(.hostname + ":" + .port) | join(",")' || echo "localhost:$MONGO_PORT")/?ssl=true&authSource=admin&replicaSet=$REPLICA_SET"
else
  CONNECTION_STRING="mongodb://$DB_USERNAME:$DB_PASSWORD@$(echo $HOSTS_JSON | jq -r 'map(.hostname + ":" + .port) | join(",")' || echo "localhost:$MONGO_PORT")/?authSource=admin&replicaSet=$REPLICA_SET"
fi

# Output JSON
cat <<EOF
{
  "username": "$DB_USERNAME",
  "password": "$DB_PASSWORD",
  "hosts": $HOSTS_JSON,
  "ssl_enabled": $SSL_ENABLED,
  "replica_set": "$REPLICA_SET",
  "connection_string": "$CONNECTION_STRING"
}
EOF
