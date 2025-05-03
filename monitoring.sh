#!/bin/bash

# monitoring.sh - Sets up email alerts and monitoring endpoint for MongoDB
# Usage: ./monitoring.sh <domain>
# Run this after bootstrap.sh and provision_ssl.sh

set -e

if [ $# -ne 1 ]; then
  echo "Usage: $0 <domain>"
  echo "Example: $0 mdb1.example.com"
  exit 1
fi

DOMAIN=$1
CONFIG_FILE="./config.json"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Missing config.json! Exiting."
  exit 1
fi

# Load configuration values
ALERT_EMAIL=$(jq -r '.alert_email' "$CONFIG_FILE")
SMTP_SERVER=$(jq -r '.smtp_server' "$CONFIG_FILE")
SMTP_PORT=$(jq -r '.smtp_port' "$CONFIG_FILE")
SMTP_USER=$(jq -r '.smtp_user' "$CONFIG_FILE")
SMTP_PASS=$(jq -r '.smtp_pass' "$CONFIG_FILE")
MONITOR_TOKEN=$(jq -r '.monitor_token' "$CONFIG_FILE")

echo "🔔 Setting up MongoDB monitoring and alerts for $DOMAIN..."

# NOTE: Install required dependencies if not already installed
if ! command -v msmtp &> /dev/null || ! command -v fcgiwrap &> /dev/null || ! command -v nginx &> /dev/null; then
  echo "Installing required dependencies..."
  sudo apt update
  sudo apt install -y msmtp msmtp-mta bsd-mailx fcgiwrap nginx
  
  # Enable nginx if newly installed
  if systemctl list-unit-files | grep -q nginx; then
    sudo systemctl enable nginx
    sudo systemctl start nginx
  fi
fi

# NOTE: Configure msmtp (SMTP email alerts)
echo "Configuring email alerts via SMTP..."
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

sudo chmod 600 /etc/msmtprc

# NOTE: Setup health checks
echo "Setting up MongoDB health check script..."
cat <<EOF | sudo tee /usr/local/bin/mongo_health_check.sh
#!/bin/bash
if ! pgrep mongod > /dev/null; then
  echo "MongoDB is DOWN on \$(hostname -f)" | mail -s "MongoDB DOWN ALERT" $ALERT_EMAIL
fi
EOF

sudo chmod +x /usr/local/bin/mongo_health_check.sh
echo "*/5 * * * * root /usr/local/bin/mongo_health_check.sh" | sudo tee /etc/cron.d/mongo-health-check

# NOTE: Define script for /monitor endpoint
echo "Creating monitoring endpoint script..."
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
MONGO_STATUS=\$(systemctl is-active mongod)
echo -e "HTTP/1.1 200 OK\\n"
echo "Status: MongoDB $MONGO_STATUS"
echo "Memory: \$MEM"
echo "CPU: \$CPU"
echo "Disk: \$DISK"
EOF

sudo chmod +x /usr/local/bin/mongo_monitor.sh

# NOTE: Configure nginx for the monitor endpoint
echo "Configuring nginx for the monitoring endpoint..."
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

# NOTE: Test and reload nginx
if sudo nginx -t; then
  sudo systemctl reload nginx
else
  echo "❌ nginx config test failed; skipping nginx reload."
  exit 1
fi

# NOTE: Ensure fcgiwrap is running
sudo systemctl enable fcgiwrap
sudo systemctl start fcgiwrap

echo "✅ MongoDB monitoring and alerts setup complete for $DOMAIN"
echo "Health checks will run every 5 minutes and send alerts to $ALERT_EMAIL"
echo "Monitoring endpoint available at: http://$DOMAIN/monitor?token=$MONITOR_TOKEN"
