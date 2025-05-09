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

# Check for the replica set name file created by bootstrap.sh
if [ -f "/tmp/mongodb_replica_set" ]; then
  REPLICA_SET=$(cat /tmp/mongodb_replica_set)
  echo "Found replica set name: $REPLICA_SET"
else
  echo "⚠️ WARNING: Replica set name file not found. Using default name 'rs0'."
  REPLICA_SET="rs0"
fi

# Update MongoDB configuration to use TLS and add replication
echo "Updating MongoDB configuration to use TLS and add replication..."
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
      # Add TLS configuration under existing net section (requiring client certificates)
      echo "Adding TLS configuration to existing net section..."
      
      # Check if replica certificate exists
      REPLICA_CERT="/etc/ssl/mongodb/replicas.pem"
      if [ -f "$REPLICA_CERT" ]; then
        echo "Using replica certificate for x509 authentication..."
        sudo sed -i '/net:/a\  tls:\n    mode: requireTLS\n    certificateKeyFile: '"$CERT_FILE"'\n    CAFile: '"$CA_FILE"'\n    clusterFile: '"$REPLICA_CERT"'' "$MONGO_CONF"
      else
        echo "Replica certificate not found, using standard TLS configuration..."
        sudo sed -i '/net:/a\  tls:\n    mode: requireTLS\n    certificateKeyFile: '"$CERT_FILE"'\n    CAFile: '"$CA_FILE"'' "$MONGO_CONF"
      fi
      
      # Update bindIp to listen on all interfaces
      echo "Updating bindIp to listen on all interfaces..."
      sudo sed -i '/bindIp:/c\  bindIp: 0.0.0.0' "$MONGO_CONF"
    elif grep -q "net:" "$MONGO_CONF" && grep -q "  tls:" "$MONGO_CONF"; then
      # Update existing TLS configuration
      echo "Updating existing TLS configuration..."
      sudo sed -i '/tls:/,/[a-z]/ s|certificateKeyFile:.*|certificateKeyFile: '"$CERT_FILE"'|' "$MONGO_CONF"
      sudo sed -i '/tls:/,/[a-z]/ s|CAFile:.*|CAFile: '"$CA_FILE"'|' "$MONGO_CONF"
      
      # Check if replica certificate exists
      REPLICA_CERT="/etc/ssl/mongodb/replicas.pem"
      if [ -f "$REPLICA_CERT" ]; then
        echo "Using replica certificate for x509 authentication..."
        if grep -q "clusterFile:" "$MONGO_CONF"; then
          sudo sed -i '/clusterFile:/c\    clusterFile: '"$REPLICA_CERT"'' "$MONGO_CONF"
        else
          sudo sed -i '/CAFile:/a\    clusterFile: '"$REPLICA_CERT"'' "$MONGO_CONF"
        fi
      fi
      
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
      
      # Check if replica certificate exists
      REPLICA_CERT="/etc/ssl/mongodb/replicas.pem"
      if [ -f "$REPLICA_CERT" ]; then
        echo "Using replica certificate for x509 authentication..."
        echo -e "\nnet:\n  bindIp: 0.0.0.0\n  tls:\n    mode: requireTLS\n    certificateKeyFile: $CERT_FILE\n    CAFile: $CA_FILE\n    clusterFile: $REPLICA_CERT" | sudo tee -a "$MONGO_CONF"
      else
        echo "Replica certificate not found, using standard TLS configuration..."
        echo -e "\nnet:\n  bindIp: 0.0.0.0\n  tls:\n    mode: requireTLS\n    certificateKeyFile: $CERT_FILE\n    CAFile: $CA_FILE" | sudo tee -a "$MONGO_CONF"
      fi
    fi
    
    # Remove any old SSL configuration if it exists
    if grep -q "ssl:" "$MONGO_CONF"; then
      echo "Removing deprecated SSL configuration..."
      sudo sed -i '/ssl:/,/[a-z]/ d' "$MONGO_CONF"
    fi
  fi
  
  # Check for replica certificate
  REPLICA_CERT="/etc/ssl/mongodb/replicas.pem"
  if [ ! -f "$REPLICA_CERT" ]; then
    echo "⚠️ WARNING: Replica certificate not found at $REPLICA_CERT"
    echo "Please ensure the replica certificate is placed at $REPLICA_CERT before running this script."
    echo "This certificate is required for x509 authentication between replica set members."
  else
    echo "✅ Replica certificate found at $REPLICA_CERT"
    # Ensure proper permissions
    sudo chmod 600 "$REPLICA_CERT"
    sudo chown mongodb:mongodb "$REPLICA_CERT"
  fi
  
  # Configure x509 authentication for replica set members
  REPLICA_CERT="/etc/ssl/mongodb/replicas.pem"
  if [ -f "$REPLICA_CERT" ]; then
    echo "Configuring x509 authentication for replica set members..."
    
    # Check if security section exists
    if grep -q "security:" "$MONGO_CONF"; then
      # Add x509 authentication to existing security section
      if ! grep -q "clusterAuthMode:" "$MONGO_CONF"; then
        sudo sed -i '/security:/a\  clusterAuthMode: x509' "$MONGO_CONF"
      else
        sudo sed -i '/clusterAuthMode:/c\  clusterAuthMode: x509' "$MONGO_CONF"
      fi
    else
      # Add security section with x509 authentication
      echo -e "\nsecurity:\n  authorization: enabled\n  clusterAuthMode: x509" | sudo tee -a "$MONGO_CONF"
    fi
    
    echo "✅ x509 authentication configured for replica set members"
  else
    echo "⚠️ WARNING: Replica certificate not found at $REPLICA_CERT"
    echo "x509 authentication for replica set members will not be configured."
  fi
  
  # Add or update replication section
  if grep -q "replication:" "$MONGO_CONF"; then
    echo "Updating existing replication configuration..."
    sudo sed -i '/replication:/,/[a-z]/ s|replSetName:.*|replSetName: '"$REPLICA_SET"'|' "$MONGO_CONF"
  else
    echo "Adding replication configuration..."
    echo -e "\nreplication:\n  replSetName: $REPLICA_SET" | sudo tee -a "$MONGO_CONF"
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

sleep 10

if sudo systemctl is-active --quiet mongod; then
  echo "✅ MongoDB restarted successfully with TLS configuration"
  
  # Verify TLS is actually working
  echo "Verifying MongoDB TLS configuration..."
  
  # Load DB credentials from config.json
  if [ -f "$CONFIG_FILE" ]; then
    DB_USERNAME=$(jq -r '.db_username' "$CONFIG_FILE")
    DB_PASSWORD=$(jq -r '.db_password' "$CONFIG_FILE")
    MONGO_PORT=$(jq -r '.mongo_port' "$CONFIG_FILE")
    
    # Get domain name from config.json
    DOMAIN_CONFIG=$(jq -r '.domain_name' "$CONFIG_FILE")
    if [ -n "$DOMAIN_CONFIG" ] && [ "$DOMAIN_CONFIG" != "null" ] && [ "$DOMAIN_CONFIG" != "your.domain.com" ]; then
      DOMAIN="$DOMAIN_CONFIG"
      echo "Using domain name from config.json: $DOMAIN"
    else
      DOMAIN="localhost"
      echo "Domain name not set in config.json. Using localhost for connection."
    fi
    
    if command -v mongosh &> /dev/null; then
      # Try with domain name and client certificate
      echo "Attempting to verify TLS using domain name: $DOMAIN"
      echo "Running command: mongosh --host $DOMAIN --port $MONGO_PORT --tls --tlsCAFile $CA_FILE --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem -u $DB_USERNAME -p [PASSWORD] --authenticationDatabase admin --eval \"db.adminCommand({ getParameter: 1, tlsMode: 1 })\""
      
      # Create a temporary file to capture the output and errors
      TLS_CHECK_OUTPUT=$(mktemp)
      if mongosh --host $DOMAIN --port $MONGO_PORT --tls --tlsCAFile $CA_FILE --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --eval "db.adminCommand({ getParameter: 1, tlsMode: 1 })" > $TLS_CHECK_OUTPUT 2>&1; then
        if grep -q "requireTLS" $TLS_CHECK_OUTPUT; then
          echo "✅ MongoDB TLS mode verified using domain name: requireTLS is active"
        else
          echo "⚠️ WARNING: Command succeeded but TLS mode could not be verified."
          echo "Output from command:"
          cat $TLS_CHECK_OUTPUT
        fi
      else
        echo "⚠️ WARNING: MongoDB is running but TLS mode could not be verified."
        echo "Error output from command:"
        cat $TLS_CHECK_OUTPUT
        echo ""
        echo "IMPORTANT: To connect to MongoDB, you will need:"
        echo "1. A client certificate signed by your CA"
        echo "2. Connect using the domain name that matches your server certificate"
        echo ""
        echo "Example connection command:"
        echo "mongosh --host $DOMAIN --port $MONGO_PORT --tls --tlsCAFile $CA_FILE --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem -u $DB_USERNAME -p <password> --authenticationDatabase admin"
      fi
      rm -f $TLS_CHECK_OUTPUT
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

# Check if this is a primary or secondary node
echo "Checking if this is a primary or secondary node..."
IS_PRIMARY=false
IS_INITIALIZED=false

# Check for the replica set name file created by bootstrap.sh
if [ -f "/tmp/mongodb_replica_set" ]; then
  REPLICA_SET=$(cat /tmp/mongodb_replica_set)
  echo "Found replica set name: $REPLICA_SET"
else
  echo "⚠️ WARNING: Replica set name file not found. Using default name 'rs0'."
  REPLICA_SET="rs0"
fi

# Check for the primary role flag file created by bootstrap.sh
if [ -f "/tmp/mongodb_primary_role" ]; then
  IS_PRIMARY=true
  echo "This node was set up as a primary for replica set: $REPLICA_SET"
fi

if [ -f "$CONFIG_FILE" ]; then
  DB_USERNAME=$(jq -r '.db_username' "$CONFIG_FILE")
  DB_PASSWORD=$(jq -r '.db_password' "$CONFIG_FILE")
  MONGO_PORT=$(jq -r '.mongo_port' "$CONFIG_FILE")
  
  # Get domain name from config.json
  DOMAIN_CONFIG=$(jq -r '.domain_name' "$CONFIG_FILE")
  if [ -n "$DOMAIN_CONFIG" ] && [ "$DOMAIN_CONFIG" != "null" ] && [ "$DOMAIN_CONFIG" != "your.domain.com" ]; then
    DOMAIN="$DOMAIN_CONFIG"
    echo "Using domain name from config.json: $DOMAIN"
  else
    DOMAIN="localhost"
    echo "Domain name not set in config.json. Using localhost for connection."
  fi
  
  # Define TLS arguments for MongoDB connection
  TLS_ARGS=""
  if [ -f "$CERT_FILE" ] && grep -q "tls:" /etc/mongod.conf && grep -q "mode: requireTLS" /etc/mongod.conf; then
    TLS_ARGS="--tls"
  elif grep -q "ssl:" /etc/mongod.conf && grep -q "mode: requireSSL" /etc/mongod.conf; then
    TLS_ARGS="--ssl"
  fi
  
  # Check if the node is already initialized (part of a replica set)
  if mongosh --host $DOMAIN --port $MONGO_PORT --tls --tlsCAFile $CA_FILE --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --quiet --eval "JSON.stringify(rs.status())" 2>/dev/null | grep -q '"ok":1'; then
    IS_INITIALIZED=true
    echo "This node is already initialized as part of a replica set."
    
    # Now check if it's primary
    if mongosh --host $DOMAIN --port $MONGO_PORT --tls --tlsCAFile $CA_FILE --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --quiet --eval "JSON.stringify(rs.isMaster())" 2>/dev/null | grep -q '"ismaster":true'; then
      IS_PRIMARY=true
      echo "This node is the primary."
    else
      echo "This node is a secondary."
    fi
  else
    echo "This node is not yet initialized as part of a replica set."
  fi
  
  # Initialize or update replica set configuration
  if [ "$IS_PRIMARY" = true ]; then
    if [ "$IS_INITIALIZED" = false ]; then
      # This is a primary node that needs to be initialized
      echo "Initializing replica set with domain name..."
      
      # Initialize the replica set with the domain name instead of localhost
      if mongosh --host $DOMAIN --port $MONGO_PORT --tls --tlsCAFile $CA_FILE --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --eval "
        rs.initiate({
          _id: '$REPLICA_SET',
          members: [{ _id: 0, host: '$DOMAIN:$MONGO_PORT' }]
        })
      " 2>/dev/null; then
        echo "✅ Replica set initialized successfully with domain name: $DOMAIN:$MONGO_PORT"
        
        # Verify the initialization
        echo "Verifying replica set configuration..."
        mongosh --host $DOMAIN --port $MONGO_PORT --tls --tlsCAFile $CA_FILE --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --quiet --eval "rs.conf().members.forEach(function(m) { print(m.host); })"
      else
        echo "❌ ERROR: Failed to initialize replica set. You may need to initialize it manually."
        echo "Manual initialization command:"
        echo "mongosh --host $DOMAIN --port $MONGO_PORT --tls --tlsCAFile $CA_FILE --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --eval \"rs.initiate({ _id: '$REPLICA_SET', members: [{ _id: 0, host: '$DOMAIN:$MONGO_PORT' }] })\""
      fi
    elif [ "$IS_INITIALIZED" = true ]; then
      # This is an already initialized primary node, check if we need to update the configuration
      echo "Checking if replica set configuration needs to be updated..."
      
      # Get current replica set configuration
      TEMP_FILE=$(mktemp)
      if mongosh --host $DOMAIN --port $MONGO_PORT --tls --tlsCAFile $CA_FILE --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --quiet --eval "JSON.stringify(rs.conf())" > $TEMP_FILE 2>/dev/null; then
        # Check if any member is using localhost
        if grep -q "localhost" $TEMP_FILE; then
          echo "Found localhost in replica set configuration. Updating to use domain name..."
          
          # Update replica set configuration to use domain name
          if mongosh --host $DOMAIN --port $MONGO_PORT --tls --tlsCAFile $CA_FILE --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --eval "
            var config = rs.conf();
            for (var i = 0; i < config.members.length; i++) {
              if (config.members[i].host.includes('localhost')) {
                var port = config.members[i].host.split(':')[1];
                config.members[i].host = '$DOMAIN:' + port;
              }
            }
            rs.reconfig(config);
          " 2>/dev/null; then
            echo "✅ Replica set configuration updated to use domain name"
            
            # Verify the update
            echo "Verifying updated configuration..."
            mongosh --host $DOMAIN --port $MONGO_PORT --tls --tlsCAFile $CA_FILE --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --quiet --eval "rs.conf().members.forEach(function(m) { print(m.host); })"
          else
            echo "⚠️ WARNING: Failed to update replica set configuration. You may need to update it manually."
            echo "Manual update command:"
            echo "mongosh --host $DOMAIN --port $MONGO_PORT --tls --tlsCAFile $CA_FILE --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --eval \"var config = rs.conf(); config.members[0].host = '$DOMAIN:$MONGO_PORT'; rs.reconfig(config);\""
          fi
        else
          echo "Replica set configuration already using domain name. No update needed."
          echo "Current configuration:"
          cat $TEMP_FILE
        fi
      else
        echo "⚠️ WARNING: Failed to get replica set configuration. You may need to update it manually."
      fi
      rm -f $TEMP_FILE
    fi
  elif [ "$IS_INITIALIZED" = true ] && [ "$IS_PRIMARY" = false ]; then
    # This is a secondary node, provide instructions
    echo "This is a secondary node. Skipping replica set configuration update."
  elif [ "$IS_INITIALIZED" = false ] && [ "$IS_PRIMARY" = false ]; then
    # This node is not initialized and not a primary, provide instructions for adding it to a replica set
    echo ""
    echo "This node is not yet part of a replica set. To add it to an existing replica set:"
    echo ""
    echo "1. On the primary node, run:"
    echo "   ./utils/replica_sets.sh add $DOMAIN:$MONGO_PORT"
    echo ""
    echo "2. After adding this node to the replica set, authentication will be replicated from the primary."
    echo ""
  fi
  
  # Clean up the primary role flag file
  if [ -f "/tmp/mongodb_primary_role" ]; then
    rm -f /tmp/mongodb_primary_role
  fi
else
  echo "⚠️ WARNING: config.json not found. Unable to update replica set configuration."
fi

echo "✅ TLS configuration complete"
echo "MongoDB is now configured to use TLS with the certificate at $CERT_FILE"
echo ""
echo "IMPORTANT: Client certificates are required for connections"
echo "To connect to MongoDB, you will need:"
echo "1. A client certificate signed by your CA"
echo "2. Connect using the domain name that matches your server certificate"
echo ""
echo "Example connection command:"
echo "mongosh --host $DOMAIN --port $MONGO_PORT --tls --tlsCAFile $CA_FILE --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem -u $DB_USERNAME -p <password> --authenticationDatabase admin"
