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

# NOTE: Setup health checks with state tracking
echo "Setting up MongoDB health check script..."
cat <<EOF | sudo tee /usr/local/bin/mongo_health_check.sh
#!/bin/bash

# State file to track MongoDB status
STATE_FILE="/tmp/mongodb_status"

# Check if MongoDB is running
if pgrep mongod > /dev/null; then
  CURRENT_STATE="up"
else
  CURRENT_STATE="down"
fi

# Check if state file exists, create it if not
if [ ! -f "\$STATE_FILE" ]; then
  echo "\$CURRENT_STATE" > "\$STATE_FILE"
  PREVIOUS_STATE="\$CURRENT_STATE"
else
  PREVIOUS_STATE=\$(cat "\$STATE_FILE")
fi

# Send alerts if state has changed
if [ "\$CURRENT_STATE" != "\$PREVIOUS_STATE" ]; then
  if [ "\$CURRENT_STATE" == "down" ]; then
    echo "MongoDB is DOWN on \$(hostname -f)" | mail -s "⚠️ ALERT: MongoDB DOWN" $ALERT_EMAIL
  else
    echo "MongoDB is back UP on \$(hostname -f)" | mail -s "✅ ALERT: MongoDB UP" $ALERT_EMAIL
  fi
  
  # Update state file
  echo "\$CURRENT_STATE" > "\$STATE_FILE"
fi
EOF

sudo chmod +x /usr/local/bin/mongo_health_check.sh

# Create a systemd service for the health check
echo "Creating systemd service for MongoDB health checks..."
cat <<EOF | sudo tee /etc/systemd/system/mongodb-health-check.service
[Unit]
Description=MongoDB Health Check Service
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c "while true; do /usr/local/bin/mongo_health_check.sh; sleep 30; done"
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the service
sudo systemctl daemon-reload
sudo systemctl enable mongodb-health-check.service
sudo systemctl start mongodb-health-check.service

# Remove old cron job if it exists
if [ -f /etc/cron.d/mongo-health-check ]; then
  sudo rm /etc/cron.d/mongo-health-check
fi

# NOTE: Define script for /monitor endpoint
echo "Creating monitoring endpoint script..."
cat <<EOF | sudo tee /usr/local/bin/mongo_monitor.sh
#!/bin/bash

# Set up logging
mkdir -p /tmp/monitor_logs
chmod 777 /tmp/monitor_logs
DEBUG_LOG="/tmp/monitor_logs/monitor_debug.log"
echo "=== Script executed at \$(date) ===" >> \$DEBUG_LOG

# Dump all environment variables for debugging
env > /tmp/monitor_logs/env.log

# Output headers
echo "Content-type: text/plain"
echo ""

# Log key environment variables
echo "QUERY_STRING=\${QUERY_STRING}" >> \$DEBUG_LOG
echo "REQUEST_URI=\${REQUEST_URI}" >> \$DEBUG_LOG
echo "REQUEST_METHOD=\${REQUEST_METHOD}" >> \$DEBUG_LOG
echo "REMOTE_ADDR=\${REMOTE_ADDR}" >> \$DEBUG_LOG

# Expected token
EXPECTED_TOKEN="$MONITOR_TOKEN"

# Simple token extraction - just use the raw QUERY_STRING
if [ -z "\$QUERY_STRING" ]; then
  echo "No query string provided" >> \$DEBUG_LOG
  echo "Forbidden: No query string"
  exit 0
fi

echo "Raw query string: \$QUERY_STRING" >> \$DEBUG_LOG

# Check if token is in the query string
if [[ "\$QUERY_STRING" == "token=\$EXPECTED_TOKEN" ]]; then
  echo "Token validation successful" >> \$DEBUG_LOG
  
  # Get system stats
  MEM=\$(free -m | awk '/Mem:/ {print \$3"/"\$2" MB"}')
  CPU=\$(top -bn1 | grep "Cpu(s)" | awk '{print \$2 + \$4 "%"}')
  DISK=\$(df -h / | awk 'NR==2 {print \$3"/"\$2}')
  MONGO_STATUS=\$(systemctl is-active mongod)

  # Output stats
  echo "Status: MongoDB \$MONGO_STATUS"
  echo "Memory: \$MEM"
  echo "CPU: \$CPU"
  echo "Disk: \$DISK"
else
  echo "Token validation failed. Got '\$QUERY_STRING', expected 'token=\$EXPECTED_TOKEN'" >> \$DEBUG_LOG
  echo "Forbidden: Invalid token"
fi
EOF

sudo chmod +x /usr/local/bin/mongo_monitor.sh

# NOTE: Configure nginx for the monitor endpoint
echo "Configuring nginx for the monitoring endpoint..."
cat <<EOF | sudo tee /etc/nginx/conf.d/monitor.conf
# This configuration adds the /monitor endpoint to both HTTP and HTTPS servers

# For HTTP
server {
  listen 80;
  server_name $DOMAIN;

  location = /monitor {
    fastcgi_pass unix:/var/run/fcgiwrap.socket;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME /usr/local/bin/mongo_monitor.sh;
  }
}

  # For HTTPS (if private CA certificates are set up)
  server {
    listen 443 ssl;
    server_name $DOMAIN;
    
    # These SSL settings will be ignored if the certificate files don't exist
    ssl_certificate /etc/ssl/mongodb/certificate_authority.pem;
    ssl_certificate_key /etc/ssl/mongodb/certificate.pem;
  
  location = /monitor {
    fastcgi_pass unix:/var/run/fcgiwrap.socket;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME /usr/local/bin/mongo_monitor.sh;
  }
}
EOF

# Fix the configuration if the include_if_exists directive is not supported
if ! nginx -t 2>/dev/null; then
  echo "Detected older nginx version without include_if_exists support. Adjusting configuration..."
  
  # Check if SSL certificates exist
  if [ -f "/etc/ssl/mongodb/certificate_authority.pem" ] && [ -f "/etc/ssl/mongodb/certificate.pem" ]; then
    # Create a configuration with both HTTP and HTTPS
    cat <<EOF | sudo tee /etc/nginx/conf.d/monitor.conf
# For HTTP
server {
  listen 80;
  server_name $DOMAIN;

  location = /monitor {
    fastcgi_pass unix:/var/run/fcgiwrap.socket;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME /usr/local/bin/mongo_monitor.sh;
  }
}

# For HTTPS
server {
  listen 443 ssl;
  server_name $DOMAIN;
  
  ssl_certificate /etc/ssl/mongodb/certificate_authority.pem;
  ssl_certificate_key /etc/ssl/mongodb/certificate.pem;
  
  location = /monitor {
    fastcgi_pass unix:/var/run/fcgiwrap.socket;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME /usr/local/bin/mongo_monitor.sh;
  }
}
EOF
  else
    # Create a configuration with only HTTP
    cat <<EOF | sudo tee /etc/nginx/conf.d/monitor.conf
server {
  listen 80;
  server_name $DOMAIN;

  location = /monitor {
    fastcgi_pass unix:/var/run/fcgiwrap.socket;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME /usr/local/bin/mongo_monitor.sh;
  }
}
EOF
  fi
fi

# NOTE: Test and reload nginx
if sudo nginx -t; then
  sudo systemctl reload nginx
else
  echo "❌ nginx config test failed; skipping nginx reload."
  exit 1
fi

# NOTE: Ensure fcgiwrap is running and has correct permissions
echo "Ensuring fcgiwrap is running and has correct permissions..."
sudo systemctl enable fcgiwrap
sudo systemctl restart fcgiwrap
sleep 2

# Always set socket permissions to world-readable/writable to ensure nginx can access it
FCGI_SOCKET="/var/run/fcgiwrap.socket"
if [ -S "$FCGI_SOCKET" ]; then
  echo "Setting fcgiwrap socket permissions to 666..."
  sudo chmod 666 "$FCGI_SOCKET"
else
  echo "Warning: fcgiwrap socket not found at $FCGI_SOCKET after restart."
  echo "Checking alternative locations..."
  
  # Check alternative socket locations
  ALT_SOCKETS=("/var/run/nginx/fcgiwrap.sock" "/var/lib/nginx/fcgiwrap.socket")
  for ALT_SOCKET in "${ALT_SOCKETS[@]}"; do
    if [ -S "$ALT_SOCKET" ]; then
      echo "Found fcgiwrap socket at $ALT_SOCKET"
      sudo chmod 666 "$ALT_SOCKET"
      
      # Update nginx configuration to use this socket
      sudo sed -i "s|unix:/var/run/fcgiwrap.socket|unix:$ALT_SOCKET|g" /etc/nginx/conf.d/monitor.conf
      echo "Updated nginx configuration to use socket at $ALT_SOCKET"
      break
    fi
  done
fi

# Restart nginx to apply changes
echo "Restarting nginx to apply changes..."
sudo systemctl restart nginx

echo "✅ MongoDB monitoring and alerts setup complete for $DOMAIN"
echo "Health checks will run every 30 seconds and send alerts to $ALERT_EMAIL"
echo "Alerts will be sent when MongoDB goes down AND when it comes back up"
echo "Monitoring endpoint available at: http://$DOMAIN/monitor?token=$MONITOR_TOKEN"
