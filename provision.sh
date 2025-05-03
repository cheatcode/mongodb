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

# NOTE: Install base dependencies required for install/config.
sudo apt update
sudo apt install -y curl gnupg2 ca-certificates lsb-release software-properties-common jq ufw msmtp msmtp-mta bsd-mailx fcgiwrap unzip

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

# NOTE: Install AWS CLI for backup management.
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscli.zip"
unzip /tmp/awscli.zip -d /tmp
sudo /tmp/aws/install

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

# NOTE: Install official nginx.org build with --with-stream (required for proxying to MongoDB).
curl https://nginx.org/keys/nginx_signing.key | sudo gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" | sudo tee /etc/apt/sources.list.d/nginx.list
sudo apt update
sudo apt remove -y nginx nginx-common nginx-core || true
sudo apt install -y nginx

sudo apt install -y certbot python3-certbot-nginx

# NOTE: Update mongod.conf.
cat <<EOF | sudo tee $MONGO_CONF
storage:
  dbPath: /var/lib/mongodb
systemLog:
  destination: file
  path: $LOG_FILE
  logAppend: true
net:
  port: 27017
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

# NOTE: Create admin user.
mongo --eval "db.getSiblingDB('admin').createUser({ user: '$DB_USERNAME', pwd: '$DB_PASSWORD', roles: [ { role: 'root', db: 'admin' } ] })" || echo "Admin user may already exist."

# NOTE: Get Let's Encrypt cert.
sudo certbot certonly --nginx --non-interactive --agree-tos --email admin@$DOMAIN -d $DOMAIN

# NOTE: Setup SSL renew cron
echo "0 3 * * * root certbot renew --nginx --quiet" | sudo tee /etc/cron.d/certbot-renew

# NOTE: Stop Nginx to avoid weird restart errors.
sudo systemctl stop nginx

# NOTE: Modify Nginx config to include stream directive for routing to Mongo.
sudo sed -i '/^http {/i stream {\n  upstream mongo_backend {\n    server 127.0.0.1:27017;\n  }\n  server {\n    listen 443 ssl;\n    ssl_certificate /etc/letsencrypt/live/'$DOMAIN'/fullchain.pem;\n    ssl_certificate_key /etc/letsencrypt/live/'$DOMAIN'/privkey.pem;\n    proxy_pass mongo_backend;\n  }\n}\n' /etc/nginx/nginx.conf

if sudo nginx -t; then
  sudo systemctl start nginx
else
  echo "❌ nginx config test failed; skipping nginx start."
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

# NOTE: Configure msmtp (SMTP email alerts).
cat <<EOF | sudo tee /etc/msmtprc
defaults
auth on
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
account default
host $SMTP_SERVER
port $SMTP_PORT
user $SMTP_USER
password $SMTP_PASS
from $ALERT_EMAIL
logfile ~/.msmtp.log
EOF

chmod 600 /etc/msmtprc

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
mongodump --username $DB_USERNAME --password $DB_PASSWORD --authenticationDatabase admin --archive=\$BACKUP_PATH --gzip
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

# NOTE: Setup health checks.
cat <<EOF | sudo tee /usr/local/bin/mongo_health_check.sh
#!/bin/bash
if ! pgrep mongod > /dev/null; then
  echo "MongoDB is DOWN on \$(hostname -f)" | mail -s "MongoDB DOWN ALERT" $ALERT_EMAIL
fi
EOF

chmod +x /usr/local/bin/mongo_health_check.sh
echo "*/5 * * * * root /usr/local/bin/mongo_health_check.sh" | sudo tee /etc/cron.d/mongo-health-check

# NOTE: Define script for /monitor endpoint.
cat <<EOF | sudo tee /usr/local/bin/mongo_monitor.sh
#!/bin/bash
read QUERY_STRING
TOKEN_VALUE=\$(echo \$QUERY_STRING | sed -n 's/.*token=\\([^&]*\\).*/\\1/p')
if [ "\$TOKEN_VALUE" != "$MONITOR_TOKEN" ]; then
  echo -e "HTTP/1.1 403 Forbidden\\n"
  echo "Forbidden"
  exit 0
fi
MEM=\$(free -m | awk '/Mem:/ {print \$3"/"\$2" MB"}')
CPU=\$(top -bn1 | grep "Cpu(s)" | awk '{print \$2 + \$4 "%"}')
DISK=\$(df -h / | awk 'NR==2 {print \$3"/"\$2}')
echo -e "HTTP/1.1 200 OK\\n"
echo "Memory: \$MEM"
echo "CPU: \$CPU"
echo "Disk: \$DISK"
EOF

chmod +x /usr/local/bin/mongo_monitor.sh

# NOTE: Update nginx config for /monitor.
sudo systemctl stop nginx

cat <<EOF | sudo tee /etc/nginx/conf.d/monitor.conf
server {
  listen 80;
  server_name $DOMAIN;

  location /monitor {
    fastcgi_pass unix:/var/run/fcgiwrap.socket;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME /usr/local/bin/mongo_monitor.sh;
  }
}
EOF

if sudo nginx -t; then
  sudo systemctl start nginx
else
  echo "❌ nginx config test failed; skipping nginx start."
fi

sudo systemctl enable fcgiwrap
sudo systemctl start fcgiwrap

# NOTE: Setup UFW rules.
sudo ufw allow ssh
sudo ufw allow 443/tcp
sudo ufw allow 80/tcp
sudo ufw deny 27017
sudo ufw --force enable

echo "✅ MongoDB $ROLE node setup complete on $DOMAIN"