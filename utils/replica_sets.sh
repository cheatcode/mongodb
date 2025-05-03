#!/bin/bash

set -e

ACTION=$1
NODE=$2
CONFIG_FILE="./config.json"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Missing config.json! Exiting."
  exit 1
fi

DB_USERNAME=$(jq -r '.db_username' "$CONFIG_FILE")
DB_PASSWORD=$(jq -r '.db_password' "$CONFIG_FILE")

# Check if MongoDB SSL is configured
SSL_PEM_PATH="/etc/ssl/mongodb.pem"
SSL_ARGS=""
if grep -q "ssl:" /etc/mongod.conf && grep -q "mode: requireSSL" /etc/mongod.conf; then
  echo "MongoDB SSL is enabled. Using SSL connection..."
  SSL_ARGS="--port 2610 --ssl --sslCAFile $SSL_PEM_PATH"
else
  echo "MongoDB SSL is not enabled. Using standard connection..."
  SSL_ARGS="--port 2610"
fi

if [ "$ACTION" == "add" ]; then
  mongosh $SSL_ARGS -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --eval "rs.add('$NODE')"
  echo "Node $NODE added."
elif [ "$ACTION" == "remove" ]; then
  mongosh $SSL_ARGS -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --eval "rs.remove('$NODE')"
  echo "Node $NODE removed."
else
  echo "Usage: $0 add|remove hostname:port"
  exit 1
fi
