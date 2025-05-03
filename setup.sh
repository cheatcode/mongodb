#!/bin/bash

# setup.sh - Makes all shell scripts in the project executable
# Run this script after cloning the repository

set -e

echo "🔧 Setting up MongoDB deployment scripts..."

# Make all shell scripts executable
echo "Making all shell scripts executable..."
chmod +x *.sh
chmod +x utils/*.sh

echo "✅ Setup complete. You can now run the following scripts in sequence:"
echo "1. ./bootstrap.sh primary rs0 your-domain.com"
echo "2. ./provision_ssl.sh your-domain.com"
echo "3. ./monitoring.sh your-domain.com"
echo ""
echo "Additional utility scripts are available in the utils/ directory:"
echo "- utils/replica_sets.sh: Manage replica set members"
echo "- utils/list_backups.sh: List available backups in S3"
echo "- utils/restore_backup.sh: Restore a backup from S3"
echo "- utils/reset.sh: Reset the server (WARNING: destructive operation)"
