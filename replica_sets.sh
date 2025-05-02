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

if [ "$ACTION" == "add" ]; then
  mongo -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --eval "rs.add('$NODE')"
  echo "Node $NODE added."
elif [ "$ACTION" == "remove" ]; then
  mongo -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --eval "rs.remove('$NODE')"
  echo "Node $NODE removed."
else
  echo "Usage: $0 add|remove hostname:port"
  exit 1
fi
