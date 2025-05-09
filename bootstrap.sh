#!/bin/bash

set -e

ROLE=$1
REPLICA_SET=$2
CONFIG_FILE="./config.json"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Missing config.json! Exiting."
  exit 1
fi

# Get domain name from config.json if available, otherwise use command line argument
DOMAIN_ARG=$3
DOMAIN_CONFIG=$(jq -r '.domain_name' "$CONFIG_FILE")

if [ -n "$DOMAIN_ARG" ]; then
  DOMAIN="$DOMAIN_ARG"
elif [ -n "$DOMAIN_CONFIG" ] && [ "$DOMAIN_CONFIG" != "null" ] && [ "$DOMAIN_CONFIG" != "your.domain.com" ]; then
  DOMAIN="$DOMAIN_CONFIG"
else
  echo "❌ ERROR: Domain name not provided as argument or in config.json."
  echo "Please provide a domain name as the third argument or add it to config.json."
  echo "Usage: $0 <role> <replica_set> [domain]"
  echo "Example: $0 primary rs0 mdb1.example.com"
  exit 1
fi

# NOTE: Install base dependencies required for MongoDB installation and configuration.
sudo apt update
sudo apt install -y curl gnupg2 ca-certificates lsb-release software-properties-common jq ufw unzip

DB_USERNAME=$(jq -r '.db_username' "$CONFIG_FILE")
DB_PASSWORD=$(jq -r '.db_password' "$CONFIG_FILE")
AWS_BUCKET=$(jq -r '.aws_bucket' "$CONFIG_FILE")
AWS_REGION=$(jq -r '.aws_region' "$CONFIG_FILE")
AWS_ACCESS_KEY=$(jq -r '.aws_access_key' "$CONFIG_FILE")
AWS_SECRET_KEY=$(jq -r '.aws_secret_key' "$CONFIG_FILE")
ALERT_EMAIL=$(jq -r '.alert_email' "$CONFIG_FILE")
SMTP_SERVER=$(jq -r '.smtp_server' "$CONFIG_FILE")
SMTP_PORT=$(jq -r '.smtp_port' "$CONFIG_FILE")
SMTP_USER=$(jq -r '.smtp_user' "$CONFIG_FILE")
SMTP_PASS=$(jq -r '.smtp_pass' "$CONFIG_FILE")
MONITOR_TOKEN=$(jq -r '.monitor_token' "$CONFIG_FILE")
REPLICA_SET_KEY=$(jq -r '.replica_set_key' "$CONFIG_FILE")
MONGO_PORT=$(jq -r '.mongo_port' "$CONFIG_FILE")

# Check if mongo_port is set
if [ -z "$MONGO_PORT" ] || [ "$MONGO_PORT" == "null" ]; then
  echo "❌ Missing required configuration value: mongo_port"
  echo "Please add mongo_port to your config.json file."
  exit 1
fi
MONGO_VERSION=8.0
MONGO_CONF="/etc/mongod.conf"
LOG_FILE="/var/log/mongodb/mongod.log"
BACKUP_SCRIPT="/usr/local/bin/mongo_backup.sh"
REPLICA_CERT="/etc/ssl/mongodb/replicas.pem"

# NOTE: Install MongoDB 8.0.
curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor

# Remove any existing MongoDB apt source list files
sudo rm -f /etc/apt/sources.list.d/mongodb*.list

# Always use noble (Ubuntu 24.04) repository for MongoDB
echo "Using noble repository for MongoDB..."
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list

sudo apt update
sudo apt install -y mongodb-org

# NOTE: We'll use x509 certificates for internal authentication instead of keyFile
echo "MongoDB will use x509 certificates for internal authentication"
echo "Make sure to place your replica certificate at $REPLICA_CERT"

# NOTE: First create a MongoDB config without authentication and without replication
cat <<EOF | sudo tee $MONGO_CONF
storage:
  dbPath: /var/lib/mongodb
systemLog:
  destination: file
  path: $LOG_FILE
  logAppend: true
net:
  port: $MONGO_PORT
  bindIp: 127.0.0.1
EOF

# Ensure MongoDB can resolve its own domain name
echo "Checking if domain is in /etc/hosts..."
if ! grep -q "$DOMAIN" /etc/hosts; then
  echo "Adding $DOMAIN to /etc/hosts..."
  echo "127.0.1.1 $DOMAIN" | sudo tee -a /etc/hosts
  echo "Added $DOMAIN to /etc/hosts"
else
  echo "Domain $DOMAIN already in /etc/hosts"
fi

# Store the replica set name for provision_ssl.sh to use later
echo "$REPLICA_SET" > /tmp/mongodb_replica_set

sudo systemctl enable mongod
sudo systemctl start mongod

# NOTE: Wait for MongoDB to start.
sleep 10

# NOTE: We'll initialize the replica set in provision_ssl.sh to use the domain name
# instead of localhost. This avoids having to update the replica set configuration later.
HOSTNAME=$(hostname -f)

# Create a flag file to indicate this is a primary node (for provision_ssl.sh)
if [ "$ROLE" == "primary" ]; then
  echo "$REPLICA_SET" > /tmp/mongodb_primary_role
fi

# NOTE: Create admin user.
echo "Creating admin user..."
if mongosh --port $MONGO_PORT --eval "db.getSiblingDB('admin').createUser({ user: '$DB_USERNAME', pwd: '$DB_PASSWORD', roles: [ { role: 'root', db: 'admin' } ] })"; then
  echo "✅ Admin user created successfully"
else
  echo "❌ Failed to create admin user"
  exit 1
fi

# NOTE: Now update the config to enable authentication (without replication)
echo "Enabling authentication in MongoDB configuration..."
cat <<EOF | sudo tee $MONGO_CONF
storage:
  dbPath: /var/lib/mongodb
systemLog:
  destination: file
  path: $LOG_FILE
  logAppend: true
net:
  port: $MONGO_PORT
  bindIp: 127.0.0.1
security:
  authorization: enabled
EOF

# Restart MongoDB with authentication enabled
echo "Restarting MongoDB with authentication enabled..."
sudo systemctl restart mongod
sleep 5

# Verify we can connect with authentication
echo "Verifying authentication..."
if mongosh --port $MONGO_PORT -u $DB_USERNAME -p $DB_PASSWORD --authenticationDatabase admin --eval "db.adminCommand('ping')"; then
  echo "✅ Authentication working correctly"
else
  echo "❌ Authentication verification failed"
  exit 1
fi

# NOTE: Setup log rotation.
cat <<EOF | sudo tee /etc/logrotate.d/mongod
$LOG_FILE {
  daily
  rotate 14
  compress
  missingok
  notifempty
  create 640 mongodb mongodb
  sharedscripts
  postrotate
    /bin/systemctl reload mongod >/dev/null 2>&1 || true
  endscript
}
EOF

# NOTE: Install AWS CLI for backup management.
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscli.zip"
unzip /tmp/awscli.zip -d /tmp
sudo /tmp/aws/install

# NOTE: Configure AWS CLI.
aws configure set aws_access_key_id $AWS_ACCESS_KEY
aws configure set aws_secret_access_key $AWS_SECRET_KEY
aws configure set region $AWS_REGION

# NOTE: Define backup script (primary only).
if [ "$ROLE" == "primary" ]; then
  cat <<EOF | sudo tee $BACKUP_SCRIPT
#!/bin/bash

# Set up logging
LOG_DIR="/var/log/mongodb-backup"
mkdir -p \$LOG_DIR
LOG_FILE="\$LOG_DIR/backup-\$(date +%F).log"

log() {
  echo "\$(date +"%Y-%m-%d %H:%M:%S") - \$1" | tee -a \$LOG_FILE
}

log "Starting MongoDB backup process"

# Load configuration values from config.json
CONFIG_FILE="/root/mongodb/config.json"
if [ ! -f "\$CONFIG_FILE" ]; then
  log "❌ ERROR: Missing config.json! Exiting."
  exit 1
fi

DB_USERNAME=\$(jq -r '.db_username' "\$CONFIG_FILE")
DB_PASSWORD=\$(jq -r '.db_password' "\$CONFIG_FILE")
AWS_BUCKET=\$(jq -r '.aws_bucket' "\$CONFIG_FILE")
AWS_REGION=\$(jq -r '.aws_region' "\$CONFIG_FILE")
MONGO_PORT=\$(jq -r '.mongo_port' "\$CONFIG_FILE")

TIMESTAMP=\$(date +%F-%H-%M)
BACKUP_PATH="/tmp/mongo-backup-\$TIMESTAMP.gz"

# Get domain name from config.json if available
DOMAIN_CONFIG=\$(jq -r '.domain_name' "\$CONFIG_FILE")
if [ -n "\$DOMAIN_CONFIG" ] && [ "\$DOMAIN_CONFIG" != "null" ] && [ "\$DOMAIN_CONFIG" != "your.domain.com" ]; then
  HOSTNAME="\$DOMAIN_CONFIG"
  log "Using domain name from config.json: \$HOSTNAME"
else
  HOSTNAME=\$(hostname -f)
  log "Domain name not set in config.json. Using hostname: \$HOSTNAME"
fi

# Check if MongoDB is running
if ! systemctl is-active --quiet mongod; then
  log "❌ ERROR: MongoDB is not running. Backup aborted."
  exit 1
fi

# Check if MongoDB TLS is configured
CERT_FILE="/etc/ssl/mongodb/certificate.pem"
CA_FILE="/etc/ssl/mongodb/certificate_authority.pem"
TLS_ENABLED=false
TLS_ARG=""
MONGOSH_TLS_ARG=""

if [ -f "\$CERT_FILE" ] && grep -q "tls:" /etc/mongod.conf && grep -q "mode: requireTLS" /etc/mongod.conf; then
  log "MongoDB TLS is enabled with private CA certificates. Using TLS connection for backup..."
  TLS_ENABLED=true
  # For mongodump, use --ssl flags
  TLS_ARG="--ssl --sslCAFile \$CA_FILE --sslPEMKeyFile /etc/ssl/mongodb/client.pem"
  # For mongosh, use --tls flags
  MONGOSH_TLS_ARG="--tls --tlsCAFile \$CA_FILE --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem"
  log "NOTE: Client certificates are required for connections."
  log "      Ensure the client certificate exists at /etc/ssl/mongodb/client.pem"
elif grep -q "ssl:" /etc/mongod.conf && grep -q "mode: requireSSL" /etc/mongod.conf; then
  log "MongoDB SSL is enabled (legacy configuration). Using SSL connection for backup..."
  TLS_ENABLED=true
  TLS_ARG="--ssl"
  MONGOSH_TLS_ARG="--tls"
else
  log "MongoDB TLS is not enabled. Using standard connection for backup..."
fi

# Check if MongoDB is responsive - use mongosh with --tls flags
log "Checking if MongoDB is responsive..."
log "Running command: mongosh --host \$HOSTNAME --port \$MONGO_PORT \$MONGOSH_TLS_ARG -u \$DB_USERNAME -p [PASSWORD] --authenticationDatabase admin --eval \"db.adminCommand('ping')\""

# Create a temporary file to capture the output and errors
MONGO_CHECK_OUTPUT=\$(mktemp)
if ! mongosh --host \$HOSTNAME --port \$MONGO_PORT \$MONGOSH_TLS_ARG -u \$DB_USERNAME -p \$DB_PASSWORD --authenticationDatabase admin --eval "db.adminCommand('ping')" > \$MONGO_CHECK_OUTPUT 2>&1; then
  log "❌ ERROR: MongoDB is not responsive. Backup aborted."
  log "Error output from command:"
  cat \$MONGO_CHECK_OUTPUT >> \$LOG_FILE
  rm -f \$MONGO_CHECK_OUTPUT
  exit 1
fi
log "✅ MongoDB is responsive."
rm -f \$MONGO_CHECK_OUTPUT

# Create backup - use mongodump with --ssl flags
log "Creating backup at \$BACKUP_PATH"
if mongodump --host \$HOSTNAME --port \$MONGO_PORT \$TLS_ARG -u \$DB_USERNAME -p \$DB_PASSWORD --authenticationDatabase admin --archive=\$BACKUP_PATH --gzip; then
  log "✅ Backup created successfully"
  
  # Check if backup file exists and has a size greater than 0
  if [ -f "\$BACKUP_PATH" ] && [ \$(stat -c%s "\$BACKUP_PATH") -gt 0 ]; then
    log "Backup file exists and has size: \$(stat -c%s "\$BACKUP_PATH") bytes"
    
    # Upload to S3
    log "Uploading backup to S3..."
    if aws s3 cp \$BACKUP_PATH s3://\$AWS_BUCKET/\$HOSTNAME/\$TIMESTAMP.gz --region \$AWS_REGION; then
      log "✅ Backup uploaded to S3 successfully"
      
      # Clean up local backup
      rm \$BACKUP_PATH
      log "Local backup file removed"
      
      # Manage retention (keep only the 12 most recent backups)
      log "Managing backup retention..."
      BACKUPS=\$(aws s3 ls s3://\$AWS_BUCKET/\$HOSTNAME/ --region \$AWS_REGION | awk '{print \$4}' | sort)
      BACKUP_COUNT=\$(echo "\$BACKUPS" | wc -l)
      
      if [ \$BACKUP_COUNT -gt 12 ]; then
        DELETE_COUNT=\$((BACKUP_COUNT - 12))
        OLD_BACKUPS=\$(echo "\$BACKUPS" | head -n \$DELETE_COUNT)
        
        log "Keeping 12 most recent backups, deleting \$DELETE_COUNT older backups"
        for FILE in \$OLD_BACKUPS; do
          if aws s3 rm s3://\$AWS_BUCKET/\$HOSTNAME/\$FILE --region \$AWS_REGION; then
            log "Deleted old backup: \$FILE"
          else
            log "Failed to delete old backup: \$FILE"
          fi
        done
      else
        log "Only \$BACKUP_COUNT backups exist, no cleanup needed"
      fi
    else
      log "❌ ERROR: Failed to upload backup to S3"
      exit 1
    fi
  else
    log "❌ ERROR: Backup file is missing or empty (\$(stat -c%s "\$BACKUP_PATH") bytes). Backup may be corrupted."
    exit 1
  fi
else
  log "❌ ERROR: Failed to create backup"
  exit 1
fi

log "Backup process completed successfully"
EOF
  chmod +x $BACKUP_SCRIPT
  echo "0 * * * * root $BACKUP_SCRIPT" | sudo tee /etc/cron.d/mongo-backup
  # Ensure the cron job file has a newline at the end and correct permissions
  echo "" | sudo tee -a /etc/cron.d/mongo-backup
  sudo chmod 644 /etc/cron.d/mongo-backup
fi

# NOTE: Setup UFW rules.

sudo ufw allow ssh                  # keep SSH open
sudo ufw allow 443/tcp              # keep HTTPS open
sudo ufw allow 80/tcp               # keep HTTP open

sudo ufw allow ${MONGO_PORT}/tcp    # allow MongoDB on custom port

sudo ufw deny 27017                 # deny default MongoDB port just in case

sudo ufw default deny incoming      # block all other inbound ports
sudo ufw default allow outgoing     # allow all outbound connections

sudo ufw --force enable             # enable/reload firewall

echo "✅ MongoDB $ROLE node bootstrap complete on $DOMAIN."
echo "Next steps:"
echo "1. Place your private CA certificates at:"
echo "   - /etc/ssl/mongodb/certificate.pem"
echo "   - /etc/ssl/mongodb/certificate_authority.pem"
echo "   - /etc/ssl/mongodb/replicas.pem (for x509 authentication between replica set members)"
echo "2. Run ./provision_ssl.sh to configure MongoDB to use the certificates."
echo "3. Run ./monitoring.sh $DOMAIN to set up monitoring and alerts."
