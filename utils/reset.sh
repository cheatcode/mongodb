#!/bin/bash

set -e

echo "⚠ WARNING: This will permanently delete MongoDB, nginx, certbot, AWS CLI, fcgiwrap, monitoring services, and configs."

read -p "Type 'RESET' to continue: " CONFIRM
if [ "$CONFIRM" != "RESET" ]; then
  echo "Aborted."
  exit 1
fi

echo "Stopping services..."
sudo systemctl stop mongod || true
sudo systemctl stop nginx || true
sudo systemctl stop fcgiwrap || true
sudo systemctl stop mongodb-health-check || true

echo "Disabling services..."
sudo systemctl disable mongod || true
sudo systemctl disable nginx || true
sudo systemctl disable fcgiwrap || true
sudo systemctl disable mongodb-health-check || true

echo "Removing MongoDB..."
sudo apt purge -y mongodb-org
sudo rm -rf /var/lib/mongodb /var/log/mongodb /etc/mongod.conf /etc/mongo-keyfile /etc/logrotate.d/mongod

echo "Removing nginx..."
sudo apt purge -y nginx nginx-common nginx-core
sudo rm -rf /etc/nginx

echo "Removing certbot..."
sudo apt purge -y certbot python3-certbot-nginx
sudo rm -rf /etc/letsencrypt

echo "Removing MongoDB SSL certificates..."
sudo rm -rf /etc/ssl/mongodb

echo "Removing fcgiwrap..."
sudo apt purge -y fcgiwrap

echo "Removing AWS CLI..."
sudo rm -rf /usr/local/aws-cli /usr/local/bin/aws /tmp/aws /tmp/awscli.zip

echo "Removing custom scripts..."
sudo rm -f /usr/local/bin/mongo_backup.sh
sudo rm -f /usr/local/bin/mongo_health_check.sh
sudo rm -f /usr/local/bin/mongo_monitor.sh

echo "Removing systemd service files..."
sudo rm -f /etc/systemd/system/mongodb-health-check.service
sudo systemctl daemon-reload

echo "Removing msmtp config..."
sudo rm -f /etc/msmtprc

echo "Cleaning up apt..."
sudo apt autoremove -y
sudo apt clean

echo "Reset complete. ✅"
