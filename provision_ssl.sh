#!/bin/bash

# provision_ssl.sh - Configures MongoDB to use pre-generated private CA certificates
# Usage: ./provision_ssl.sh

set -e

CONFIG_FILE="./config.json"
MONGO_CONF="/etc/mongod.conf"
CERT_FILE="/etc/ssl/mongodb/certificate.pem"
CA_FILE="/etc/ssl/mongodb/certificate_authority.pem"

echo "🔐 Configuring MongoDB to use private CA certificates..."

# Check if certificate files exist
if [ ! -f "$CERT_FILE" ]; then
  echo "❌ ERROR: Certificate file not found at $CERT_FILE"
  echo "Please ensure the certificate is placed at $CERT_FILE before running this script."
  exit 1
fi

if [ ! -f "$CA_FILE" ]; then
  echo "❌ ERROR: Certificate Authority file not found at $CA_FILE"
  echo "Please ensure the CA certificate is placed at $CA_FILE before running this script."
  exit 1
fi

# Update MongoDB configuration to use TLS
echo "Updating MongoDB configuration to use TLS..."
if [ -f "$MONGO_CONF" ]; then
  # Backup the current MongoDB configuration
  BACKUP_FILE="${MONGO_CONF}.bak.$(date +%Y%m%d%H%M%S)"
  echo "Creating backup of MongoDB config at $BACKUP_FILE"
  sudo cp "$MONGO_CONF" "$BACKUP_FILE"
  
  # Check if TLS is already configured
  if grep -q "tls:" "$MONGO_CONF" && grep -q "certificateKeyFile: $CERT_FILE" "$MONGO_CONF"; then
    echo "MongoDB is already configured for TLS with the correct certificate path."
  else
    # Check if net section already exists
    if grep -q "net:" "$MONGO_CONF" && ! grep -q "  tls:" "$MONGO_CONF"; then
      # Add TLS configuration under existing net section
      echo "Adding TLS configuration to existing net section..."
      sudo sed -i '/net:/a\  tls:\n    mode: requireTLS\n    certificateKeyFile: '"$CERT_FILE"'\n    CAFile: '"$CA_FILE"'' "$MONGO_CONF"
      
      # Update bindIp to listen on all interfaces
      echo "Updating bindIp to listen on all interfaces..."
      sudo sed -i '/bindIp:/c\  bindIp: 0.0.0.0' "$MONGO_CONF"
    elif grep -q "net:" "$MONGO_CONF" && grep -q "  tls:" "$MONGO_CONF"; then
      # Update existing TLS configuration
      echo "Updating existing TLS configuration..."
      sudo sed -i '/tls:/,/[a-z]/ s|certificateKeyFile:.*|certificateKeyFile: '"$CERT_FILE"'|' "$MONGO_CONF"
      sudo sed -i '/tls:/,/[a-z]/ s|CAFile:.*|CAFile: '"$CA_FILE"'|' "$MONGO_CONF"
      
      # Remove any relaxed security settings if they exist
      sudo sed -i '/allowConnectionsWithoutCertificates:/d' "$MONGO_CONF"
      sudo sed -i '/allowInvalidHostnames:/d' "$MONGO_CONF"
      sudo sed -i '/allowInvalidCertificates:/d' "$MONGO_CONF"
      
      # Update bindIp to listen on all interfaces
      echo "Updating bindIp to listen on all interfaces..."
      sudo sed -i '/bindIp:/c\  bindIp: 0.0.0.0' "$MONGO_CONF"
    elif ! grep -q "net:" "$MONGO_CONF"; then
      # Add net section with TLS configuration
      echo "Adding new net section with TLS configuration..."
      echo -e "\nnet:\n  bindIp: 0.0.0.0\n  tls:\n    mode: requireTLS\n    certificateKeyFile: $CERT_FILE\n    CAFile: $CA_FILE" | sudo tee -a "$MONGO_CONF"
    fi
    
    # Remove any old SSL configuration if it exists
    if grep -q "ssl:" "$MONGO_CONF"; then
      echo "Removing deprecated SSL configuration..."
      sudo sed -i '/ssl:/,/[a-z]/ d' "$MONGO_CONF"
    fi
  fi
else
  echo "❌ ERROR: MongoDB configuration file not found at $MONGO_CONF"
  exit 1
fi

# Restart MongoDB to apply changes
echo "Restarting MongoDB to apply TLS configuration..."
if ! sudo systemctl restart mongod; then
  echo "❌ ERROR: MongoDB failed to restart with new TLS configuration."
  echo "Checking MongoDB logs for errors..."
  sudo journalctl -u mongod --no-pager -n 20
  
  echo "Attempting to restore previous configuration..."
  if [ -f "$BACKUP_FILE" ]; then
    sudo cp "$BACKUP_FILE" "$MONGO_CONF"
    echo "Restored previous MongoDB configuration from $BACKUP_FILE"
    sudo systemctl restart mongod
    
    if sudo systemctl is-active --quiet mongod; then
      echo "MongoDB restarted successfully with previous configuration."
      echo "Please check your TLS configuration and try again."
    else
      echo "❌ ERROR: MongoDB failed to restart even with previous configuration."
      echo "Manual intervention required."
    fi
  else
    echo "❌ ERROR: No backup file found to restore."
  fi
  
  exit 1
fi

# Verify MongoDB is running with TLS
echo "Waiting for MongoDB to start completely..."
sleep 5
if sudo systemctl is-active --quiet mongod; then
  echo "✅ MongoDB restarted successfully with TLS configuration"
  
  # Verify TLS is actually working
  echo "Verifying MongoDB TLS configuration..."
  
  # Load DB credentials from config.json
  if [ -f "$CONFIG_FILE" ]; then
    DB_USERNAME=$(jq -r '.db_username' "$CONFIG_FILE")
    DB_PASSWORD=$(jq -r '.db_password' "$CONFIG_FILE")
    MONGO_PORT=$(jq -r '.mongo_port' "$CONFIG_FILE")
    
    if command -v mongosh &> /dev/null; then
      # Try with localhost
      echo "Attempting to verify TLS using localhost"
      if sudo mongosh --host localhost --port $MONGO_PORT --tls -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --eval "db.adminCommand({ getParameter: 1, tlsMode: 1 })" 2>/dev/null | grep -q "requireTLS"; then
        echo "✅ MongoDB TLS mode verified using localhost: requireTLS is active"
      else
        echo "⚠️ WARNING: MongoDB is running but TLS mode could not be verified."
        echo "Please check manually with:"
        echo "mongosh --host localhost --port $MONGO_PORT --tls -u $DB_USERNAME -p <password> --authenticationDatabase admin --eval \"db.adminCommand({ getParameter: 1, tlsMode: 1 })\""
      fi
    else
      echo "⚠️ mongosh not available to verify TLS configuration."
      echo "MongoDB is running, but please verify TLS configuration manually."
    fi
  else
    echo "⚠️ WARNING: config.json not found. Unable to verify TLS configuration."
    echo "MongoDB is running, but please verify TLS configuration manually."
  fi
else
  echo "❌ ERROR: MongoDB failed to restart. Check logs with: sudo journalctl -u mongod"
  exit 1
fi

echo "✅ TLS configuration complete"
echo "MongoDB is now configured to use TLS with the certificate at $CERT_FILE"
echo "Clients will need to connect using TLS"
