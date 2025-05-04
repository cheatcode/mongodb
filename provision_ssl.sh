#!/bin/bash

# provision_ssl.sh - Provisions SSL certificate and configures MongoDB to use it
# Usage: ./provision_ssl.sh example.com

set -e

CONFIG_FILE="./config.json"

# Get domain name from command line argument or config.json
if [ $# -eq 1 ]; then
  DOMAIN=$1
elif [ -f "$CONFIG_FILE" ]; then
  DOMAIN_CONFIG=$(jq -r '.domain_name' "$CONFIG_FILE")
  if [ -n "$DOMAIN_CONFIG" ] && [ "$DOMAIN_CONFIG" != "null" ] && [ "$DOMAIN_CONFIG" != "your.domain.com" ]; then
    DOMAIN="$DOMAIN_CONFIG"
  else
    echo "❌ ERROR: Domain name not provided as argument or in config.json."
    echo "Please provide a domain name as an argument or add it to config.json."
    echo "Usage: $0 <domain>"
    echo "Example: $0 mdb1.example.com"
    exit 1
  fi
else
  echo "❌ ERROR: Domain name not provided and config.json not found."
  echo "Please provide a domain name as an argument."
  echo "Usage: $0 <domain>"
  echo "Example: $0 mdb1.example.com"
  exit 1
fi
MONGO_CONF="/etc/mongod.conf"
SSL_PEM_PATH="/etc/ssl/mongodb.pem"

echo "🔐 Provisioning SSL certificate for $DOMAIN..."

# NOTE: Install certbot if not already installed
if ! command -v certbot &> /dev/null; then
  echo "Installing certbot..."
  sudo apt update
  sudo apt install -y certbot
fi

# NOTE: Check if certificate already exists to avoid hitting rate limits
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
if [ -d "$CERT_DIR" ]; then
  echo "Certificate directory already exists at $CERT_DIR"
  echo "Checking certificate expiration..."
  
  # Check if certificate expires in less than 30 days
  EXPIRY=$(sudo openssl x509 -enddate -noout -in "$CERT_DIR/cert.pem" | cut -d= -f2)
  EXPIRY_EPOCH=$(sudo date -d "$EXPIRY" +%s)
  NOW_EPOCH=$(date +%s)
  DAYS_LEFT=$(( ($EXPIRY_EPOCH - $NOW_EPOCH) / 86400 ))
  
  if [ $DAYS_LEFT -gt 30 ]; then
    echo "Certificate is still valid for $DAYS_LEFT days. Using existing certificate."
  else
    echo "Certificate expires in $DAYS_LEFT days. Attempting renewal..."
    sudo certbot renew --cert-name $DOMAIN
  fi
else
  echo "Obtaining new Let's Encrypt certificate..."
  # First try with --dry-run to validate without consuming rate limits
  echo "Performing dry run first to validate domain and configuration..."
  if sudo certbot certonly --standalone --dry-run --non-interactive --agree-tos --email admin@$DOMAIN -d $DOMAIN; then
    echo "Dry run successful. Obtaining actual certificate..."
    sudo certbot certonly --standalone --non-interactive --agree-tos --email admin@$DOMAIN -d $DOMAIN
  else
    echo "❌ ERROR: Certbot dry run failed. Please check domain configuration and try again."
    echo "Note: Let's Encrypt has rate limits of 5 failed validations per hour and 50 certificates per domain per week."
    exit 1
  fi
fi

# NOTE: Create a renewal hook script to concatenate certificates after renewal
# Certbot automatically executes all scripts in /etc/letsencrypt/renewal-hooks/deploy/
# after each successful certificate renewal (via cron or manual renewal)
echo "Creating certbot renewal hook for certificate concatenation..."
RENEWAL_HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
RENEWAL_HOOK_SCRIPT="$RENEWAL_HOOK_DIR/mongodb-concat-certificates.sh"

sudo mkdir -p "$RENEWAL_HOOK_DIR"

sudo tee "$RENEWAL_HOOK_SCRIPT" > /dev/null << EOF
#!/bin/bash

# This script runs after successful certificate renewal
# It concatenates the renewed certificates for MongoDB

DOMAIN="$DOMAIN"
FULLCHAIN="/etc/letsencrypt/live/\${DOMAIN}/fullchain.pem"
PRIVKEY="/etc/letsencrypt/live/\${DOMAIN}/privkey.pem"
OUTPUT="$SSL_PEM_PATH"
MONGO_CA_FILE="/etc/ssl/mongodb-ca.pem"

if [[ ! -f "\$FULLCHAIN" || ! -f "\$PRIVKEY" ]]; then
  echo "Certificate files not found for \$DOMAIN" >&2
  exit 1
fi

# Update the concatenated certificate file
cat "\$FULLCHAIN" "\$PRIVKEY" > "\$OUTPUT"
chmod 600 "\$OUTPUT"
chown mongodb:mongodb "\$OUTPUT"

echo "MongoDB TLS PEM file updated at \$OUTPUT"

# Create a copy of fullchain.pem accessible by MongoDB
echo "Copying fullchain.pem to \$MONGO_CA_FILE for MongoDB access..."
cp "\$FULLCHAIN" "\$MONGO_CA_FILE"
chmod 644 "\$MONGO_CA_FILE"
chown mongodb:mongodb "\$MONGO_CA_FILE"

echo "MongoDB CA file updated at \$MONGO_CA_FILE"

# Check if MongoDB config needs updating
MONGO_CONF="/etc/mongod.conf"
if grep -q "ssl:" "\$MONGO_CONF" && ! grep -q "tls:" "\$MONGO_CONF"; then
  echo "Updating MongoDB config to use TLS instead of deprecated SSL..."
  # Backup the current MongoDB configuration
  BACKUP_FILE="\${MONGO_CONF}.bak.\$(date +%Y%m%d%H%M%S)"
  cp "\$MONGO_CONF" "\$BACKUP_FILE"
  
  # Replace SSL with TLS configuration
  sed -i 's/ssl:/tls:/g' "\$MONGO_CONF"
  sed -i 's/mode: requireSSL/mode: requireTLS/g' "\$MONGO_CONF"
  sed -i 's/PEMKeyFile:/certificateKeyFile:/g' "\$MONGO_CONF"
  
  # Add CAFile if it doesn't exist
  if ! grep -q "CAFile:" "\$MONGO_CONF"; then
    sed -i '/certificateKeyFile:/a\\    CAFile: \$MONGO_CA_FILE' "\$MONGO_CONF"
  else
    # Update CAFile to use the accessible copy
    sed -i '/CAFile:/c\\    CAFile: \$MONGO_CA_FILE' "\$MONGO_CONF"
  fi
  
  # Add allowConnectionsWithoutCertificates if it doesn't exist
  if ! grep -q "allowConnectionsWithoutCertificates:" "\$MONGO_CONF"; then
    sed -i '/CAFile:/a\\    allowConnectionsWithoutCertificates: true' "\$MONGO_CONF"
  fi
fi

# Restart MongoDB to use the new certificate
systemctl restart mongod

exit 0
EOF

sudo chmod +x "$RENEWAL_HOOK_SCRIPT"

# NOTE: Setup SSL renew cron if not already set
if [ ! -f /etc/cron.d/certbot-renew ]; then
  echo "Setting up certificate renewal cron job..."
  echo "0 3 * * * root certbot renew --standalone --quiet" | sudo tee /etc/cron.d/certbot-renew
fi

# NOTE: Concatenate fullchain.pem and privkey.pem for MongoDB
echo "Concatenating certificate files for MongoDB..."
concat_ssl_for_mongodb() {
  local domain=$1
  local fullchain="/etc/letsencrypt/live/${domain}/fullchain.pem"
  local privkey="/etc/letsencrypt/live/${domain}/privkey.pem"
  local output="$SSL_PEM_PATH"

  if [[ ! -f "$fullchain" ]]; then
    echo "❌ ERROR: fullchain.pem not found at $fullchain"
    return 1
  fi

  if [[ ! -f "$privkey" ]]; then
    echo "❌ ERROR: privkey.pem not found at $privkey"
    return 1
  fi

  sudo cat "$fullchain" "$privkey" > "$output"
  sudo chmod 600 "$output"
  sudo chown mongodb:mongodb "$output"

  echo "✅ MongoDB SSL PEM file created at $output"
}

concat_ssl_for_mongodb "$DOMAIN"

# NOTE: Update MongoDB configuration to use SSL
echo "Updating MongoDB configuration to use SSL..."
if [ -f "$MONGO_CONF" ]; then
  # Backup the current MongoDB configuration
  BACKUP_FILE="${MONGO_CONF}.bak.$(date +%Y%m%d%H%M%S)"
  echo "Creating backup of MongoDB config at $BACKUP_FILE"
  sudo cp "$MONGO_CONF" "$BACKUP_FILE"
  
  # Check if TLS is already configured
  if grep -q "tls:" "$MONGO_CONF" && grep -q "certificateKeyFile: $SSL_PEM_PATH" "$MONGO_CONF"; then
    echo "MongoDB is already configured for TLS with the correct certificate path."
  else
    # Check if net section already exists
    if grep -q "net:" "$MONGO_CONF" && ! grep -q "  tls:" "$MONGO_CONF"; then
      # Get the fullchain.pem path and create a copy accessible by MongoDB
      FULLCHAIN_PEM="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
      MONGO_CA_FILE="/etc/ssl/mongodb-ca.pem"
      
      # Copy fullchain.pem to a location accessible by MongoDB
      echo "Copying fullchain.pem to $MONGO_CA_FILE for MongoDB access..."
      sudo cp "$FULLCHAIN_PEM" "$MONGO_CA_FILE"
      sudo chmod 644 "$MONGO_CA_FILE"
      sudo chown mongodb:mongodb "$MONGO_CA_FILE"
      
      # Add TLS configuration under existing net section
      echo "Adding TLS configuration to existing net section..."
      sudo sed -i '/net:/a\  tls:\n    mode: requireTLS\n    certificateKeyFile: '"$SSL_PEM_PATH"'\n    CAFile: '"$MONGO_CA_FILE"'\n    allowConnectionsWithoutCertificates: true' "$MONGO_CONF"
      
      # Update bindIp to listen on all interfaces
      echo "Updating bindIp to listen on all interfaces..."
      sudo sed -i '/bindIp:/c\  bindIp: 0.0.0.0' "$MONGO_CONF"
    elif grep -q "net:" "$MONGO_CONF" && grep -q "  tls:" "$MONGO_CONF"; then
      # Get the fullchain.pem path and create a copy accessible by MongoDB
      FULLCHAIN_PEM="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
      MONGO_CA_FILE="/etc/ssl/mongodb-ca.pem"
      
      # Copy fullchain.pem to a location accessible by MongoDB
      echo "Copying fullchain.pem to $MONGO_CA_FILE for MongoDB access..."
      sudo cp "$FULLCHAIN_PEM" "$MONGO_CA_FILE"
      sudo chmod 644 "$MONGO_CA_FILE"
      sudo chown mongodb:mongodb "$MONGO_CA_FILE"
      
      # Update existing TLS configuration
      echo "Updating existing TLS configuration..."
      sudo sed -i '/tls:/,/[a-z]/ s|certificateKeyFile:.*|certificateKeyFile: '"$SSL_PEM_PATH"'|' "$MONGO_CONF"
      sudo sed -i '/tls:/,/[a-z]/ s|CAFile:.*|CAFile: '"$MONGO_CA_FILE"'|' "$MONGO_CONF"
      
      # Add allowConnectionsWithoutCertificates if it doesn't exist
      if ! grep -q "allowConnectionsWithoutCertificates:" "$MONGO_CONF"; then
        sudo sed -i '/CAFile:/a\    allowConnectionsWithoutCertificates: true' "$MONGO_CONF"
      fi
      
      # Update bindIp to listen on all interfaces
      echo "Updating bindIp to listen on all interfaces..."
      sudo sed -i '/bindIp:/c\  bindIp: 0.0.0.0' "$MONGO_CONF"
    elif ! grep -q "net:" "$MONGO_CONF"; then
      # Get the fullchain.pem path and create a copy accessible by MongoDB
      FULLCHAIN_PEM="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
      MONGO_CA_FILE="/etc/ssl/mongodb-ca.pem"
      
      # Copy fullchain.pem to a location accessible by MongoDB
      echo "Copying fullchain.pem to $MONGO_CA_FILE for MongoDB access..."
      sudo cp "$FULLCHAIN_PEM" "$MONGO_CA_FILE"
      sudo chmod 644 "$MONGO_CA_FILE"
      sudo chown mongodb:mongodb "$MONGO_CA_FILE"
      
      # Add net section with TLS configuration
      echo "Adding new net section with TLS configuration..."
      echo -e "\nnet:\n  bindIp: 0.0.0.0\n  tls:\n    mode: requireTLS\n    certificateKeyFile: $SSL_PEM_PATH\n    CAFile: $MONGO_CA_FILE\n    allowConnectionsWithoutCertificates: true" | sudo tee -a "$MONGO_CONF"
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

# NOTE: Restart MongoDB to apply changes
echo "Restarting MongoDB to apply SSL configuration..."
if ! sudo systemctl restart mongod; then
  echo "❌ ERROR: MongoDB failed to restart with new SSL configuration."
  echo "Checking MongoDB logs for errors..."
  sudo journalctl -u mongod --no-pager -n 20
  
  echo "Attempting to restore previous configuration..."
  if [ -f "$BACKUP_FILE" ]; then
    sudo cp "$BACKUP_FILE" "$MONGO_CONF"
    echo "Restored previous MongoDB configuration from $BACKUP_FILE"
    sudo systemctl restart mongod
    
    if sudo systemctl is-active --quiet mongod; then
      echo "MongoDB restarted successfully with previous configuration."
      echo "Please check your SSL configuration and try again."
    else
      echo "❌ ERROR: MongoDB failed to restart even with previous configuration."
      echo "Manual intervention required."
    fi
  else
    echo "❌ ERROR: No backup file found to restore."
  fi
  
  exit 1
fi

# NOTE: Verify MongoDB is running with SSL
echo "Waiting for MongoDB to start completely..."
sleep 5
if sudo systemctl is-active --quiet mongod; then
  echo "✅ MongoDB restarted successfully with SSL configuration"
  
  # Verify TLS is actually working
  echo "Verifying MongoDB TLS configuration..."
  # Get domain name from config.json if available
  DOMAIN_CONFIG=$(jq -r '.domain_name' "$CONFIG_FILE")
  if [ -n "$DOMAIN_CONFIG" ] && [ "$DOMAIN_CONFIG" != "null" ] && [ "$DOMAIN_CONFIG" != "your.domain.com" ]; then
    DOMAIN="$DOMAIN_CONFIG"
    echo "Using domain name from config.json: $DOMAIN"
  else
    DOMAIN="localhost"
    echo "Domain name not set in config.json. Using localhost for verification."
  fi
  
  # Load DB credentials from config.json
  DB_USERNAME=$(jq -r '.db_username' "$CONFIG_FILE")
  DB_PASSWORD=$(jq -r '.db_password' "$CONFIG_FILE")
  MONGO_PORT=$(jq -r '.mongo_port' "$CONFIG_FILE")
  
  if command -v mongosh &> /dev/null; then
    # Try with domain name first (if not localhost)
    if [ "$DOMAIN" != "localhost" ]; then
      echo "Attempting to verify TLS using domain name: $DOMAIN"
      if sudo mongosh --host $DOMAIN --port $MONGO_PORT --tls -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --eval "db.adminCommand({ getParameter: 1, tlsMode: 1 })" 2>/dev/null | grep -q "requireTLS"; then
        echo "✅ MongoDB TLS mode verified using domain name: requireTLS is active"
      else
        echo "Verification using domain name failed. Trying localhost..."
        # If that fails, try with localhost
        if sudo mongosh --host localhost --port $MONGO_PORT --tls -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --eval "db.adminCommand({ getParameter: 1, tlsMode: 1 })" 2>/dev/null | grep -q "requireTLS"; then
          echo "✅ MongoDB TLS mode verified using localhost: requireTLS is active"
        else
          echo "⚠️ WARNING: MongoDB is running but TLS mode could not be verified."
          echo "Please check manually with:"
          echo "mongosh --host $DOMAIN --port $MONGO_PORT --tls -u $DB_USERNAME -p <password> --authenticationDatabase admin --eval \"db.adminCommand({ getParameter: 1, tlsMode: 1 })\""
          echo "or"
          echo "mongosh --host localhost --port $MONGO_PORT --tls -u $DB_USERNAME -p <password> --authenticationDatabase admin --eval \"db.adminCommand({ getParameter: 1, tlsMode: 1 })\""
        fi
      fi
    else
      # Just try localhost
      echo "Attempting to verify TLS using localhost"
      if sudo mongosh --host localhost --port $MONGO_PORT --tls -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --eval "db.adminCommand({ getParameter: 1, tlsMode: 1 })" 2>/dev/null | grep -q "requireTLS"; then
        echo "✅ MongoDB TLS mode verified using localhost: requireTLS is active"
      else
        echo "⚠️ WARNING: MongoDB is running but TLS mode could not be verified."
        echo "Please check manually with:"
        echo "mongosh --host localhost --port $MONGO_PORT --tls -u $DB_USERNAME -p <password> --authenticationDatabase admin --eval \"db.adminCommand({ getParameter: 1, tlsMode: 1 })\""
      fi
    fi
  else
    echo "⚠️ mongosh not available to verify TLS configuration."
    echo "MongoDB is running, but please verify TLS configuration manually."
  fi
else
  echo "❌ ERROR: MongoDB failed to restart. Check logs with: sudo journalctl -u mongod"
  exit 1
fi

# Update replica set configuration to use domain name instead of localhost
echo "Updating replica set configuration to use domain name..."
if [ -f "$CONFIG_FILE" ]; then
  DB_USERNAME=$(jq -r '.db_username' "$CONFIG_FILE")
  DB_PASSWORD=$(jq -r '.db_password' "$CONFIG_FILE")
  MONGO_PORT=$(jq -r '.mongo_port' "$CONFIG_FILE")
  
  # Define TLS arguments for MongoDB connection
  TLS_ARGS=""
  if [ -f "$SSL_PEM_PATH" ] && grep -q "tls:" /etc/mongod.conf && grep -q "mode: requireTLS" /etc/mongod.conf; then
    TLS_ARGS="--tls"
  elif [ -f "$SSL_PEM_PATH" ] && grep -q "ssl:" /etc/mongod.conf && grep -q "mode: requireSSL" /etc/mongod.conf; then
    TLS_ARGS="--ssl"
  fi
  
  # Get current replica set configuration
  TEMP_FILE=$(mktemp)
  if mongosh --host localhost --port $MONGO_PORT $TLS_ARGS -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --quiet --eval "JSON.stringify(rs.conf())" > $TEMP_FILE 2>/dev/null; then
    # Check if any member is using localhost
    if grep -q "localhost" $TEMP_FILE; then
      echo "Found localhost in replica set configuration. Updating to use domain name..."
      
      # Update replica set configuration to use domain name
      if mongosh --host localhost --port $MONGO_PORT $TLS_ARGS -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --eval "
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
      else
        echo "⚠️ WARNING: Failed to update replica set configuration. You may need to update it manually."
      fi
    else
      echo "Replica set configuration already using domain name. No update needed."
    fi
  else
    echo "⚠️ WARNING: Failed to get replica set configuration. You may need to update it manually."
  fi
  rm -f $TEMP_FILE
else
  echo "⚠️ WARNING: config.json not found. Unable to update replica set configuration."
fi

echo "✅ TLS provisioning and MongoDB configuration complete for $DOMAIN"
echo "MongoDB is now configured to use TLS with the certificate at $SSL_PEM_PATH"
echo "Clients will need to connect using TLS"
