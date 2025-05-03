# MongoDB Replica Set Toolkit

Production-ready toolkit to provision, manage, backup, and restore MongoDB replica sets.

## Folder Structure

mongodb/
├── config.json
├── provision.sh
├── replica_sets.sh
├── list_backups.sh
├── restore_backup.sh
└── README.md

## Install Micro IDE

```
sudo apt install -y micro
```

This gives a mouse-friendly IDE on the instance for editing files quickly.

## DNS

1. Once the server is provisioned, point the domain at the instance so we can provision SSL during setup.

## Setup

1. Update `config.json` with your credentials.
2. Make scripts executable: chmod +x *.sh

## Provision Nodes

Run these on each DigitalOcean droplet:

# On primary node
./provision.sh primary rs0 <domain>

# On secondary node
./provision.sh secondary rs0 <domain>

# On arbiter node
./provision.sh arbiter rs0 <domain>

## Manage Replica Set

Add or remove members from the replica set:

# Add secondary or arbiter
./replica_sets.sh add <domain>:27017

# Remove secondary or arbiter
./replica_sets.sh remove <domain>:27017

## Backups

Backups only run from the primary node.

- List backups:
  ./list_backups.sh

- Restore backup:
  ./restore_backup.sh <backup_filename>

Example:
./restore_backup.sh 2025-05-02-02-00.gz

## Notes

- Make sure DNS records (<domain>, <domain>, etc.) point to the correct droplets.
- Backups are stored in S3 under s3://<bucket>/<hostname>/.
- Only the primary node runs automated backups and cleanup.
- Configure the AWS region in config.json to match your bucket.

## Example config.json

{
  "db_username": "admin",
  "db_password": "your_secure_password",
  "aws_bucket": "your-s3-bucket-name",
  "aws_region": "us-east-1",
  "aws_access_key": "YOUR_AWS_ACCESS_KEY",
  "aws_secret_key": "YOUR_AWS_SECRET_KEY",
  "alert_email": "alerts@yourdomain.com",
  "smtp_server": "smtp.postmarkapp.com",
  "smtp_port": "587",
  "smtp_user": "your-postmark-username",
  "smtp_pass": "your-postmark-password",
  "monitor_token": "your_secure_token"
}

## Using micro to edit files

This script installs [micro](https://micro-editor.github.io), a modern terminal-based editor with mouse support.

Basic commands:

- Edit a file:
  micro <filename>

- Example:
  micro /etc/mongod.conf

Mouse actions:

- Click to move the cursor
- Click and drag to select text
- Scroll to move up/down
- Right-click for menu (if enabled)

Other shortcuts:

- Ctrl+S → save
- Ctrl+Q → quit
- Ctrl+E → command menu

micro works great if you want an easier, mouse-driven alternative to nano, vim, or vi.
