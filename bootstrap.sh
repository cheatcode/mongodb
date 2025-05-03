#!/bin/bash

set -e

ROLE=$1
REPLICA_SET=$2
DOMAIN=$3
CONFIG_FILE="./config.json"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Missing config.json! Exiting."
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
MONGO_VERSION=8.0
MONGO_CONF="/etc/mongod.conf"
MONGO_KEYFILE="/etc/mongo-keyfile"
LOG_FILE="/var/log/mongodb/mongod.log"
BACKUP_SCRIPT="/usr/local/bin/mongo_backup.sh"

# NOTE: Install MongoDB 8.0.
curl -fsSL https://pgp.mongodb.com/server-8.0.asc | sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-8.0.gpg
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/8.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list
sudo apt update
sudo apt install -y mongodb-org

# NOTE: Create Mongo keyfile if missing.
if [ ! -f "$MONGO_KEYFILE" ]; then
  echo "$REPLICA_SET_KEY" > "$MONGO_KEYFILE"
  chmod 400 "$MONGO_KEYFILE"
  chown mongodb:mongodb "$MONGO_KEYFILE"
fi

# NOTE: Update mongod.conf.
cat <<EOF | sudo tee $MONGO_CONF
storage:
  dbPath: /var/lib/mongodb
systemLog:
  destination: file
  path: $LOG_FILE
  logAppend: true
net:
  port: 2610
  bindIp: 127.0.0.1
security:
  authorization: enabled
  keyFile: $MONGO_KEYFILE
replication:
  replSetName: $REPLICA_SET
EOF

sudo systemctl enable mongod
sudo systemctl start mongod

# NOTE: Wait for MongoDB to start.
sleep 10

# NOTE: Init the replica set.

if [ "$ROLE" == "primary" ]; then
  mongosh --eval "rs.initiate({ _id: 'rs0', members: [{ _id: 0, host: 'localhost:27017' }]})"
fi

# NOTE: Create admin user.
mongosh --eval "db.getSiblingDB('admin').createUser({ user: '$DB_USERNAME', pwd: '$DB_PASSWORD', roles: [ { role: 'root', db: 'admin' } ] })" || echo "Admin user may already exist."

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
  HOSTNAME=$(hostname -f)
  cat <<EOF | sudo tee $BACKUP_SCRIPT
#!/bin/bash
TIMESTAMP=\$(date +%F-%H-%M)
BACKUP_PATH="/tmp/mongo-backup-\$TIMESTAMP.gz"

# Check if MongoDB SSL is configured
SSL_PEM_PATH="/etc/ssl/mongodb.pem"
if grep -q "ssl:" /etc/mongod.conf && grep -q "mode: requireSSL" /etc/mongod.conf; then
  echo "MongoDB SSL is enabled. Using SSL connection for backup..."
  mongodump --port 2610 --ssl --sslCAFile \$SSL_PEM_PATH --username $DB_USERNAME --password $DB_PASSWORD --authenticationDatabase admin --archive=\$BACKUP_PATH --gzip
else
  echo "MongoDB SSL is not enabled. Using standard connection for backup..."
  mongodump --port 2610 --username $DB_USERNAME --password $DB_PASSWORD --authenticationDatabase admin --archive=\$BACKUP_PATH --gzip
fi

aws s3 cp \$BACKUP_PATH s3://$AWS_BUCKET/\$HOSTNAME/\$TIMESTAMP.gz --region $AWS_REGION
rm \$BACKUP_PATH
BACKUPS=\$(aws s3 ls s3://$AWS_BUCKET/\$HOSTNAME/ --region $AWS_REGION | awk '{print \$4}' | sort)
BACKUP_COUNT=\$(echo "\$BACKUPS" | wc -l)
if [ \$BACKUP_COUNT -gt 10 ]; then
  DELETE_COUNT=\$((BACKUP_COUNT - 10))
  OLD_BACKUPS=\$(echo "\$BACKUPS" | head -n \$DELETE_COUNT)
  for FILE in \$OLD_BACKUPS; do
    aws s3 rm s3://$AWS_BUCKET/\$HOSTNAME/\$FILE --region $AWS_REGION
  done
fi
EOF
  chmod +x $BACKUP_SCRIPT
  echo "0 2 * * * root $BACKUP_SCRIPT" | sudo tee /etc/cron.d/mongo-backup
fi

# NOTE: Setup UFW rules.

sudo ufw allow ssh                  # keep SSH open
sudo ufw allow 443/tcp              # keep HTTPS open
sudo ufw allow 80/tcp               # keep HTTP open

sudo ufw allow 2610/tcp             # allow MongoDB on custom port

sudo ufw deny 27017                 # deny default MongoDB port just in case

sudo ufw default deny incoming      # block all other inbound ports
sudo ufw default allow outgoing     # allow all outbound connections

sudo ufw --force enable             # enable/reload firewall

echo "✅ MongoDB $ROLE node bootstrap complete on $DOMAIN."
echo "Next steps:"
echo "1. Run ./provision_ssl.sh $DOMAIN to provision SSL and update MongoDB config."
echo "2. Run ./monitoring.sh $DOMAIN to set up monitoring and alerts."
