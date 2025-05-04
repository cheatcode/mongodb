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

# Check if MongoDB TLS is configured
SSL_PEM_PATH="/etc/ssl/mongodb.pem"
MONGO_PORT=$(jq -r '.mongo_port' "$CONFIG_FILE")
TLS_ARGS=""

if grep -q "tls:" /etc/mongod.conf && grep -q "mode: requireTLS" /etc/mongod.conf; then
  echo "MongoDB TLS is enabled. Using TLS connection..."
  TLS_ARGS="--tls"
elif grep -q "ssl:" /etc/mongod.conf && grep -q "mode: requireSSL" /etc/mongod.conf; then
  # For backward compatibility with older configurations
  echo "MongoDB SSL is enabled. Using SSL connection..."
  TLS_ARGS="--ssl"
else
  echo "MongoDB TLS is not enabled. Using standard connection..."
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

# Function to execute MongoDB command with fallback to localhost
execute_mongo_command() {
  local command="$1"
  
  # Try to connect using the domain name first (if not localhost)
  if [ "$DOMAIN" != "localhost" ]; then
    echo "Attempting to connect to MongoDB using domain name: $DOMAIN"
    if mongosh --host $DOMAIN --port $MONGO_PORT $TLS_ARGS -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --eval "$command" 2>/dev/null; then
      echo "✅ Successfully connected to MongoDB using domain name: $DOMAIN"
      return 0
    else
      echo "Connection using domain name failed. Trying localhost..."
      if mongosh --host localhost --port $MONGO_PORT $TLS_ARGS -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --eval "$command" 2>/dev/null; then
        echo "✅ Successfully connected to MongoDB using localhost."
        return 0
      else
        echo "❌ ERROR: Failed to connect to MongoDB using both domain name and localhost."
        return 1
      fi
    fi
  else
    # Just try localhost
    echo "Attempting to connect to MongoDB using localhost"
    if mongosh --host localhost --port $MONGO_PORT $TLS_ARGS -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --eval "$command" 2>/dev/null; then
      echo "✅ Successfully connected to MongoDB using localhost."
      return 0
    else
      echo "❌ ERROR: Failed to connect to MongoDB using localhost."
      return 1
    fi
  fi
}

if [ "$ACTION" == "add" ]; then
  if execute_mongo_command "rs.add('$NODE')"; then
    echo "Node $NODE added."
  else
    echo "Failed to add node $NODE."
    exit 1
  fi
elif [ "$ACTION" == "remove" ]; then
  if execute_mongo_command "rs.remove('$NODE')"; then
    echo "Node $NODE removed."
  else
    echo "Failed to remove node $NODE."
    exit 1
  fi
else
  echo "Usage: $0 add|remove hostname:port"
  exit 1
fi
