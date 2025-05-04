#!/bin/bash

# setup.sh - Makes all shell scripts in the project executable
# Run this script after cloning the repository

set -e

echo "🔧 Setting up MongoDB deployment scripts..."

# Check if micro is installed, install if not
if ! command -v micro &> /dev/null; then
  echo "Installing micro text editor for easier file editing..."
  sudo apt update
  sudo apt install -y micro
fi

# Ensure that config.json is only readable by root user.
chmod 600 /root/mongodb/config.json

# Make all shell scripts executable
echo "Making all shell scripts executable..."
chmod +x *.sh
chmod +x utils/*.sh

echo "✅ Setup complete. You can now run the following scripts in sequence:"
echo "1. ./bootstrap.sh primary rs0 your-domain.com"
echo "2. ./provision_ssl.sh your-domain.com"
echo "3. ./monitoring.sh your-domain.com"
echo ""
echo "After setup, you can get connection information with:"
echo "- ./connection_info.sh: Get MongoDB connection information in JSON format"
echo ""
echo "Additional utility scripts are available in the utils/ directory:"
echo "- utils/replica_sets.sh: Manage replica set members"
echo "- utils/list_backups.sh: List available backups in S3"
echo "- utils/restore_backup.sh: Restore a backup from S3"
echo "- utils/reset.sh: Reset the server (WARNING: destructive operation)"
