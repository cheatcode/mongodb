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

MONGO_VERSION=8.0
MONGO_CONF="/etc/mongod.conf"
MONGO_KEYFILE="/etc/mongo-keyfile"
LOG_FILE="/var/log/mongodb/mongod.log"
NGINX_CONF="/etc/nginx/sites-available/mongo_ssl"
BACKUP_SCRIPT="/usr/local/bin/mongo_backup.sh"

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

# Install required packages
wget -qO - https://www.mongodb.org/static/pgp/server-$MONGO_VERSION.asc | sudo apt-key add -
echo "deb [ arch=amd64 ] https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/$MONGO_VERSION multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-$MONGO_VERSION.list
sudo apt update
sudo apt install -y mongodb-org nginx certbot python3-certbot-nginx logrotate awscli jq ufw micro msmtp msmtp-mta bsd-mailx fcgiwrap

# Configure msmtp (SMTP email)
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

# Create Mongo keyfile if missing
if [ ! -f "$MONGO_KEYFILE" ]; then
  openssl rand -base64 756 > "$MONGO_KEYFILE"
  chmod 400 "$MONGO_KEYFILE"
  chown mongodb:mongodb "$MONGO_KEYFILE"
fi

# Configure mongod.conf
cat <<EOF | sudo tee $MONGO_CONF
storage:
  dbPath: /var/lib/mongodb
  journal:
    enabled: true
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
processManagement:
  fork: false
EOF

sudo systemctl enable mongod
sudo systemctl restart mongod

# Wait for MongoDB to start
sleep 10

# Create admin user
mongo --eval "db.getSiblingDB('admin').createUser({ user: '$DB_USERNAME', pwd: '$DB_PASSWORD', roles: [ { role: 'root', db: 'admin' } ] })" || echo "Admin user may already exist, skipping creation."

# Get SSL cert
sudo certbot certonly --nginx --non-interactive --agree-tos --email admin@$DOMAIN -d $DOMAIN

# Configure Nginx SSL proxy
cat <<EOF | sudo tee $NGINX_CONF
stream {
  upstream mongo_backend {
    server 127.0.0.1:27017;
  }
  server {
    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    proxy_pass mongo_backend;
  }
}
EOF

sudo ln -sf $NGINX_CONF /etc/nginx/sites-enabled/mongo_ssl
sudo systemctl reload nginx

# Set up SSL renew cron
echo "0 3 * * * root certbot renew --nginx --quiet" | sudo tee /etc/cron.d/certbot-renew

# Setup logrotate
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

# Configure AWS CLI
aws configure set aws_access_key_id $AWS_ACCESS_KEY
aws configure set aws_secret_access_key $AWS_SECRET_KEY
aws configure set region $AWS_REGION

# Backups only on primary
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

# Setup health check cron
cat <<EOF | sudo tee /usr/local/bin/mongo_health_check.sh
#!/bin/bash
if ! pgrep mongod > /dev/null; then
  echo "MongoDB is DOWN on \$(hostname -f)" | mail -s "MongoDB DOWN ALERT" $ALERT_EMAIL
fi
EOF
chmod +x /usr/local/bin/mongo_health_check.sh
echo "*/5 * * * * root /usr/local/bin/mongo_health_check.sh" | sudo tee /etc/cron.d/mongo-health-check

# Setup /monitor endpoint
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

# Nginx config for monitor
cat <<EOF | sudo tee /etc/nginx/sites-available/mongo_monitor
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

sudo ln -sf /etc/nginx/sites-available/mongo_monitor /etc/nginx/sites-enabled/mongo_monitor
sudo systemctl reload nginx
sudo systemctl enable fcgiwrap
sudo systemctl start fcgiwrap

# Setup UFW
sudo ufw allow ssh
sudo ufw allow 443/tcp
sudo ufw allow 80/tcp
sudo ufw deny 27017
sudo ufw --force enable

echo "✅ MongoDB $ROLE node setup complete on $DOMAIN"
echo "✅ micro editor installed — run 'micro <file>' to edit configs easily"
