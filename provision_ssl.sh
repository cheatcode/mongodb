#!/bin/bash

# provision_ssl.sh - Provisions SSL certificate and configures MongoDB to use it
# Usage: ./provision_ssl.sh example.com

set -e

if [ $# -ne 1 ]; then
  echo "Usage: $0 <domain>"
  echo "Example: $0 mdb1.example.com"
  exit 1
fi

DOMAIN=$1
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

if [[ ! -f "\$FULLCHAIN" || ! -f "\$PRIVKEY" ]]; then
  echo "Certificate files not found for \$DOMAIN" >&2
  exit 1
fi

cat "\$FULLCHAIN" "\$PRIVKEY" > "\$OUTPUT"
chmod 600 "\$OUTPUT"
chown mongodb:mongodb "\$OUTPUT"

echo "MongoDB SSL PEM file updated at \$OUTPUT"

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
  
  # Check if SSL is already configured
  if grep -q "ssl:" "$MONGO_CONF" && grep -q "PEMKeyFile: $SSL_PEM_PATH" "$MONGO_CONF"; then
    echo "MongoDB is already configured for SSL with the correct certificate path."
  else
    # Check if net.ssl section already exists
    if grep -q "net:" "$MONGO_CONF" && ! grep -q "  ssl:" "$MONGO_CONF"; then
      # Add SSL configuration under existing net section
      echo "Adding SSL configuration to existing net section..."
      sudo sed -i '/net:/a\  ssl:\n    mode: requireSSL\n    PEMKeyFile: '"$SSL_PEM_PATH"'\n    disabledProtocols: TLS1_0,TLS1_1' "$MONGO_CONF"
    elif grep -q "net:" "$MONGO_CONF" && grep -q "  ssl:" "$MONGO_CONF"; then
      # Update existing SSL configuration
      echo "Updating existing SSL configuration..."
      sudo sed -i '/ssl:/,/[a-z]/ s|PEMKeyFile:.*|PEMKeyFile: '"$SSL_PEM_PATH"'|' "$MONGO_CONF"
    elif ! grep -q "net:" "$MONGO_CONF"; then
      # Add net section with SSL configuration
      echo "Adding new net section with SSL configuration..."
      echo -e "\nnet:\n  ssl:\n    mode: requireSSL\n    PEMKeyFile: $SSL_PEM_PATH\n    disabledProtocols: TLS1_0,TLS1_1" | sudo tee -a "$MONGO_CONF"
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
  
  # Verify SSL is actually working
  echo "Verifying MongoDB SSL configuration..."
  if command -v mongosh &> /dev/null; then
    # Use mongosh to check SSL status if available
    if sudo mongosh --eval "db.adminCommand({ getParameter: 1, sslMode: 1 })" | grep -q "requireSSL"; then
      echo "✅ MongoDB SSL mode verified: requireSSL is active"
    else
      echo "⚠️ WARNING: MongoDB is running but SSL mode could not be verified."
      echo "Please check manually with: mongosh --eval \"db.adminCommand({ getParameter: 1, sslMode: 1 })\""
    fi
  else
    echo "⚠️ mongosh not available to verify SSL configuration."
    echo "MongoDB is running, but please verify SSL configuration manually."
  fi
else
  echo "❌ ERROR: MongoDB failed to restart. Check logs with: sudo journalctl -u mongod"
  exit 1
fi

echo "✅ SSL provisioning and MongoDB configuration complete for $DOMAIN"
echo "MongoDB is now configured to use SSL with the certificate at $SSL_PEM_PATH"
echo "Clients will need to connect using SSL/TLS"
