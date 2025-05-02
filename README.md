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

## Setup

1. Update `config.json` with your credentials.
2. Make scripts executable:
   chmod +x *.sh

## Provision Nodes

Run these on each DigitalOcean droplet:

# On primary node
./provision.sh primary rs0 mdb1.codewithparrot.com

# On secondary node
./provision.sh secondary rs0 mdb2.codewithparrot.com

# On arbiter node
./provision.sh arbiter rs0 mdb3.codewithparrot.com

## Manage Replica Set

Add or remove members from the replica set:

# Add secondary or arbiter
./replica_sets.sh add mdb2.codewithparrot.com:27017

# Remove secondary or arbiter
./replica_sets.sh remove mdb2.codewithparrot.com:27017

## Backups

Backups only run from the primary node.

- List backups:
  ./list_backups.sh

- Restore backup:
  ./restore_backup.sh <backup_filename>

Example:
./restore_backup.sh 2025-05-02-02-00.gz

## Notes

- Make sure DNS records (mdb1.codewithparrot.com, mdb2.codewithparrot.com, etc.) point to the correct droplets.
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
  "aws_secret_key": "YOUR_AWS_SECRET_KEY"
}

## License

MIT License
