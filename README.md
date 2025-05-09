# MongoDB Deployment with TLS and Monitoring

> **⚠️ Security Notice**: This deployment uses private CA certificates for enhanced security in MongoDB configuration. The deployment is secured through strong authentication, custom port usage, and firewall rules. Always use strong passwords and restrict network access for production deployments.

This repository contains a comprehensive set of scripts for deploying, securing, and monitoring MongoDB instances. The scripts are designed to be modular, allowing you to set up MongoDB with proper security, TLS encryption, and monitoring capabilities.

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Initial Setup](#initial-setup)
4. [Step 1: Bootstrap MongoDB](#step-1-bootstrap-mongodb)
5. [Step 2: Provision TLS Certificates](#step-2-provision-tls-certificates)
6. [Step 3: Set Up Monitoring](#step-3-set-up-monitoring)
7. [Managing Replica Sets](#managing-replica-sets)
8. [Connection Information](#connection-information)
9. [Password Rotation](#password-rotation)
10. [Backup and Restore](#backup-and-restore)
11. [Troubleshooting](#troubleshooting)
12. [Scaling](#scaling)
13. [Reset and Cleanup](#reset-and-cleanup)

## Overview

This deployment solution consists of several scripts that handle different aspects of MongoDB deployment:

- **bootstrap.sh**: Sets up MongoDB with proper configuration, security, and backup capabilities
- **provision_ssl.sh**: Provisions SSL certificates and configures MongoDB to use TLS
- **monitoring.sh**: Sets up email alerts and a monitoring endpoint
- **Utility scripts**: Additional scripts for managing replica sets, backups, and more

## Prerequisites

Before you begin, ensure you have:

1. **A Ubuntu server** (preferably Ubuntu 20.04 LTS or newer)
2. **Root or sudo access** to the server
3. **A domain name** pointing to your server's IP address (for SSL certificates)
4. **Open ports**:
   - 22 (SSH)
   - 80 (HTTP)
   - 443 (HTTPS)
   - The port you specify for MongoDB in config.json (e.g., 27017, 2610, etc.)
5. **AWS account** (if you plan to use S3 for backups)

## Initial Setup

1. **Clone this repository** to your server:

   ```bash
   git clone https://github.com/cheatcode/mongodb.git
   cd mongodb
   ```

2. **Make the setup script executable**:

   ```bash
   chmod +x setup.sh
   ```

3. **Run the setup script** to make all scripts executable:

   ```bash
   ./setup.sh
   ```

   Note: The setup script will also install the Micro text editor, which provides a user-friendly interface for editing files via the command line. After installation, you can edit files using:
   ```bash
   micro filename
   ```

4. **Create and configure the config.json file**:

   Create a file named `config.json` in the repository root with the following content:

   ```json
   {
     "db_username": "admin",
     "db_password": "your_secure_password",
     "aws_bucket": "your-s3-bucket-name",
     "aws_region": "us-east-1",
     "aws_access_key": "YOUR_AWS_ACCESS_KEY",
     "aws_secret_key": "YOUR_AWS_SECRET_KEY",
     "alert_email": "alerts@yourdomain.com",
     "smtp_server": "smtp.example.com",
     "smtp_port": "587",
     "smtp_user": "your-smtp-username",
     "smtp_pass": "your-smtp-password",
     "monitor_token": "your_secure_monitor_token",
     "replica_set_key": "your_replica_set_key",
     "mongo_port": "27017",
     "domain_name": "your.domain.com"
   }
   ```

   Replace the placeholder values with your actual configuration:
   
   - `db_username` and `db_password`: Credentials for the MongoDB admin user
   - `aws_*` parameters: Your AWS credentials and S3 bucket information for backups
   - `alert_email`: Email address to receive monitoring alerts
   - `smtp_*` parameters: SMTP server details for sending alert emails
   - `monitor_token`: A secure token for accessing the monitoring endpoint
   - `replica_set_key`: A secure key for MongoDB replica set authentication
   - `mongo_port`: The port MongoDB will listen on (e.g., 27017, 2610, etc.)

   To generate a secure `replica_set_key`, you can use:
   ```bash
   openssl rand -base64 32
   ```

   For `monitor_token`, you can use:
   ```bash
   openssl rand -hex 16
   ```

## Step 1: Bootstrap MongoDB

The bootstrap script installs MongoDB, configures it with proper security settings, and sets up backup capabilities.

1. **Run the bootstrap script**:

   ```bash
   ./bootstrap.sh primary rs0 your-domain.com
   ```

   Parameters:
   - `primary`: The role of this node (can be `primary`, `secondary`, or `arbiter`)
   - `rs0`: The name of the replica set
   - `your-domain.com`: Your server's domain name

2. **What the bootstrap script does**:
   - Installs MongoDB 8.0
   - Creates a keyfile for replica set authentication
   - Configures MongoDB to use the port specified in config.json
   - Sets up user authentication
   - Configures log rotation
   - Sets up AWS CLI and S3 backup script (if you're the primary)
   - Configures firewall rules with UFW

3. **Verify MongoDB is running**:

   ```bash
   sudo systemctl status mongod
   ```

   You should see that MongoDB is active and running.

## Step 2: Provision TLS Certificates

The provision_ssl script configures MongoDB to use pre-generated private CA certificates for enhanced security instead of Let's Encrypt certificates. This approach provides better security and easier maintenance for MongoDB deployments.

1. **Place your private CA certificates in the required locations**:

   ```bash
   sudo mkdir -p /etc/ssl/mongodb
   sudo cp /path/to/your/certificate.pem /etc/ssl/mongodb/certificate.pem
   sudo cp /path/to/your/ca_certificate.pem /etc/ssl/mongodb/certificate_authority.pem
   sudo chmod 600 /etc/ssl/mongodb/certificate.pem
   sudo chmod 600 /etc/ssl/mongodb/certificate_authority.pem
   sudo chown mongodb:mongodb /etc/ssl/mongodb/certificate.pem
   sudo chown mongodb:mongodb /etc/ssl/mongodb/certificate_authority.pem
   ```

   Replace `/path/to/your/certificate.pem` and `/path/to/your/ca_certificate.pem` with the actual paths to your certificate files.

2. **Generate a client certificate** (required for connecting to MongoDB):

   You'll need to create a client certificate signed by the same CA that signed your server certificate. If you're using the certificate generation script from the repository, you can add a function to generate client certificates:

   ```javascript
   const generate_client_certificate = (client_name) => {
     const ca_key = 'ca.key';
     const ca_crt = 'ca.crt';
     const client_key = `${client_name}.key`;
     const client_csr = `${client_name}.csr`;
     const client_crt = `${client_name}.crt`;
     const client_pem = `${client_name}.pem`;
     
     // Generate client key
     execSync(`openssl genrsa -out ${client_key} 2048`);
     
     // Generate CSR
     execSync(`openssl req -new -key ${client_key} -out ${client_csr} -subj "/CN=${client_name}"`);
     
     // Sign with CA
     execSync(`openssl x509 -req -in ${client_csr} -CA ${ca_crt} -CAkey ${ca_key} -CAcreateserial -out ${client_crt} -days 7300 -sha256`);
     
     // Create combined PEM file
     const crtContent = fs.readFileSync(client_crt);
     const keyContent = fs.readFileSync(client_key);
     fs.writeFileSync(client_pem, Buffer.concat([crtContent, keyContent]));
     
     return client_pem;
   };
   ```

3. **Run the TLS provisioning script**:

   ```bash
   ./provision_ssl.sh
   ```

4. **What the provision_ssl script does**:
   - Checks for the existence of the certificate files
   - Updates the MongoDB configuration to use TLS with proper settings
   - Configures MongoDB to allow connections from outside the server (bindIp: 0.0.0.0)
   - Adds the replica set configuration
   - Initializes the replica set using the domain name from config.json
   - Restarts MongoDB with the new TLS configuration

5. **Connecting to MongoDB with client certificates**:

   After running provision_ssl.sh, you must use client certificates to connect:

   ```bash
   mongosh --host your-domain.com --port $MONGO_PORT --tls --tlsCAFile /etc/ssl/mongodb/certificate_authority.pem --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem -u admin -p your_password --authenticationDatabase admin
   ```

   Ensure the client certificate exists at `/etc/ssl/mongodb/client.pem`.

   **For GUI tools like Studio 3T**:
   
   You'll need to configure the connection to use:
   - TLS/SSL enabled
   - CA file: `/etc/ssl/mongodb/certificate_authority.pem`
   - Client certificate: Your generated client.pem file
   - Authentication: Username/Password with admin database

   **For application connections**:
   
   In your application code, you'll need to specify both the CA file and client certificate:
   
   ```
   mongodb://admin:password@your-domain.com:27017/?tls=true&tlsCAFile=/etc/ssl/mongodb/certificate_authority.pem&tlsCertificateKeyFile=/etc/ssl/mongodb/client.pem&authSource=admin
   ```

6. **Verify TLS is working**:

   The script will attempt to verify that MongoDB is running with TLS. You can also check manually, but remember you'll need to use your client certificate:

   ```bash
   mongosh --host your-domain.com --port $MONGO_PORT --tls --tlsCAFile /etc/ssl/mongodb/certificate_authority.pem --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem -u admin -p your_password --authenticationDatabase admin --eval "db.adminCommand({ getParameter: 1, tlsMode: 1 })"
   ```

   Replace `$MONGO_PORT` with the port you specified in config.json.

   You should see output indicating that `tlsMode` is set to `requireTLS`.

## Step 3: Set Up Monitoring

The monitoring script sets up email alerts and a monitoring endpoint for your MongoDB instance.

1. **Run the monitoring script**:

   ```bash
   ./monitoring.sh your-domain.com
   ```

   Parameter:
   - `your-domain.com`: Your server's domain name

2. **What the monitoring script does**:
   - Installs required dependencies (msmtp, nginx, fcgiwrap)
   - Configures email alerts via SMTP
   - Sets up health checks that run every 30 seconds
   - Creates a monitoring endpoint accessible via HTTP
   - Configures nginx to serve the monitoring endpoint
   - Sends alerts when MongoDB goes down AND when it comes back up

3. **Access the monitoring endpoint**:

   You can access the monitoring endpoint via HTTP at:
   ```
   http://your-domain.com/monitor?token=your_secure_monitor_token
   ```

   Replace `your_secure_monitor_token` with the value you set in `config.json`.
   
   Note: The monitoring endpoint is only available over HTTP, not HTTPS, as it uses a simple configuration that doesn't require SSL certificates.

4. **Email alerts**:

   The monitoring system will:
   - Check MongoDB status every 30 seconds
   - Send an alert email when MongoDB goes down
   - Send another alert email when MongoDB comes back up

   You can test this by temporarily stopping and starting MongoDB:

   ```bash
   # Stop MongoDB to trigger a DOWN alert
   sudo systemctl stop mongod
   
   # Wait a minute, then start MongoDB to trigger an UP alert
   sudo systemctl start mongod
   ```

## Managing Replica Sets

This deployment uses x509 certificate authentication for replica set members, providing enhanced security compared to the traditional keyFile authentication method.

1. **Set up secondary nodes**:

   On each secondary node, follow the same steps as above:
   
   ```bash
   # On secondary node
   ./bootstrap.sh secondary rs0 secondary-node-domain.com
   
   # Place your private CA certificates in the required locations
   sudo mkdir -p /etc/ssl/mongodb
   sudo cp /path/to/your/certificate.pem /etc/ssl/mongodb/certificate.pem
   sudo cp /path/to/your/ca_certificate.pem /etc/ssl/mongodb/certificate_authority.pem
   sudo cp /path/to/your/replicas.pem /etc/ssl/mongodb/replicas.pem
   sudo chmod 600 /etc/ssl/mongodb/certificate.pem
   sudo chmod 600 /etc/ssl/mongodb/certificate_authority.pem
   sudo chmod 600 /etc/ssl/mongodb/replicas.pem
   sudo chown mongodb:mongodb /etc/ssl/mongodb/certificate.pem
   sudo chown mongodb:mongodb /etc/ssl/mongodb/certificate_authority.pem
   sudo chown mongodb:mongodb /etc/ssl/mongodb/replicas.pem
   
   # Configure TLS and set up monitoring
   ./provision_ssl.sh
   ./monitoring.sh secondary-node-domain.com
   ```

   The `provision_ssl.sh` script will automatically get the domain name from your config.json file and use it to configure the replica set.
   
   **Note about x509 Authentication**: This deployment uses x509 certificate authentication for replica set members instead of the traditional keyFile method. The x509 certificates provide stronger security and are more flexible for certificate rotation. 
   
   The replica certificate should be placed at `/etc/ssl/mongodb/replicas.pem` on each node. This file must contain both the certificate and its private key in PEM format, similar to the server certificate. The certificate should be signed by the same CA as the server certificate.
   
   Example of generating a replica certificate:
   ```bash
   # Generate private key
   openssl genrsa -out replicas.key 2048
   
   # Generate CSR (Certificate Signing Request)
   openssl req -new -key replicas.key -out replicas.csr -subj "/CN=mongodb-replicas"
   
   # Sign with your CA
   openssl x509 -req -in replicas.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out replicas.crt -days 7300 -sha256
   
   # Combine certificate and key into a single PEM file
   cat replicas.crt replicas.key > replicas.pem
   ```

2. **Add secondary nodes to the replica set**:

   From the primary node, use the replica_sets.sh utility script:

   ```bash
   ./utils/replica_sets.sh add secondary-node-domain.com:$MONGO_PORT
   ```

   Replace `$MONGO_PORT` with the port you specified in config.json.

3. **Remove nodes from the replica set** (if needed):

   ```bash
   ./utils/replica_sets.sh remove secondary-node-domain.com:$MONGO_PORT
   ```

   Replace `$MONGO_PORT` with the port you specified in config.json.

## Connection Information

After setting up MongoDB, you can get the connection information in JSON format:

```bash
./connection_info.sh
```

This will output a JSON object containing:
- Username and password
- List of all hosts in the replica set with their roles
- SSL status
- Connection string for use in applications

Example output:
```json
{
  "username": "admin",
  "password": "your_secure_password",
  "hosts": [
    { "hostname": "mdb1.example.com", "port": "27017", "state": "primary" },
    { "hostname": "mdb2.example.com", "port": "27017", "state": "secondary" }
  ],
  "tls_enabled": true,
  "replica_set": "rs0",
  "connection_string": "mongodb://admin:your_secure_password@mdb1.example.com:27017,mdb2.example.com:27017/?tls=true&tlsCAFile=/etc/ssl/mongodb/certificate_authority.pem&tlsCertificateKeyFile=/etc/ssl/mongodb/client.pem&authSource=admin&replicaSet=rs0"
}
```

## Password Rotation

For security best practices, you should regularly rotate the MongoDB admin password. This needs to be done on the primary node and will automatically propagate to all secondary nodes in the replica set.

1. **Connect to the primary node**:

   ```bash
   mongosh --host your-domain.com --port $MONGO_PORT --tls --tlsCAFile /etc/ssl/mongodb/certificate_authority.pem --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem -u admin -p current_password --authenticationDatabase admin
   ```

   Replace `$MONGO_PORT` with the port you specified in config.json and `current_password` with your current password.

2. **Change the admin user's password**:

   ```javascript
   db.getSiblingDB("admin").changeUserPassword("admin", "new_secure_password")
   ```

   Replace `new_secure_password` with your new secure password.

3. **Update the config.json file**:

   After changing the password, update the `db_password` field in your config.json file:

   ```bash
   micro config.json
   ```

   This ensures that all scripts will continue to work with the new password.

4. **Verify the new password**:

   ```bash
   mongosh --host your-domain.com --port $MONGO_PORT --tls --tlsCAFile /etc/ssl/mongodb/certificate_authority.pem --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem -u admin -p new_secure_password --authenticationDatabase admin --eval "db.adminCommand('ping')"
   ```
   
   You should see a successful response with `{ ok: 1 }`.

5. **Password Rotation Schedule**:

   Consider implementing a regular password rotation schedule (e.g., every 90 days) as part of your security policy. You can use system cron jobs to remind you when it's time to rotate passwords.

## Backup and Restore

The bootstrap script sets up automatic backups to S3 for the primary node. You can also manage backups manually.

1. **List available backups**:

   ```bash
   ./utils/list_backups.sh
   ```

2. **Create a manual backup**:

   ```bash
   ./utils/create_backup.sh [prefix]
   ```

   The optional `prefix` parameter allows you to add a custom prefix to the backup filename (default is "manual").
   
   Example:
   ```bash
   ./utils/create_backup.sh pre-update
   ```
   
   This will create a backup with a filename like `pre-update-20250504-193245.gz`.

3. **Restore from a backup**:

   ```bash
   ./utils/restore_backup.sh backup-filename.gz
   ```

   Replace `backup-filename.gz` with the actual backup file name from the list.

## Troubleshooting

If you encounter issues during the setup process, here are some common troubleshooting steps:

1. **Check MongoDB logs**:

   ```bash
   sudo journalctl -u mongod --no-pager -n 100
   ```

2. **Verify MongoDB is running**:

   ```bash
   sudo systemctl status mongod
   ```

3. **Check SSL certificate files**:

   ```bash
   ls -la /etc/ssl/mongodb/
   ```

4. **Test MongoDB connection with TLS**:

   ```bash
   mongosh --host your-domain.com --port $MONGO_PORT --tls --tlsCAFile /etc/ssl/mongodb/certificate_authority.pem --tlsCertificateKeyFile /etc/ssl/mongodb/client.pem -u admin -p your_password --authenticationDatabase admin
   ```

   Replace `$MONGO_PORT` with the port you specified in config.json and `your-domain.com` with your actual domain name.

5. **Check nginx configuration**:

   ```bash
   sudo nginx -t
   sudo systemctl status nginx
   ```

6. **Verify monitoring endpoint**:

   ```bash
   curl -v "http://your-domain.com/monitor?token=your_secure_monitor_token"
   ```

## Scaling

Scaling is managed directly via your host. Before scaling, ALWAYS make sure to take a manual backup and confirm it:

```
./utils/create_backup.sh
```

This will take a manual snapshot and upload it to S3. You can pass an additional prefix like this: `./utils/create_backup.sh <prefix>` where `<prefix>` is something like `before_scale`.

After this, just use the manual scaling GUI on your host. If need be, once the server restarts, you can do a manual restore from the backup you took with:

```
./utils/restore_backup.sh <timestamp>
```

You can get the specific backup timestamp by running:

```
./utils/list_backups.sh
```

## Reset and Cleanup

If you need to reset your server and remove all installed components, you can use the reset script:

```bash
./utils/reset.sh
```

**WARNING**: This will permanently delete MongoDB, nginx, certbot, AWS CLI, fcgiwrap, and all configurations. Use with caution!

---

This deployment solution provides a secure, monitored MongoDB installation with TLS encryption and automatic backups. If you have any questions or issues, please open an issue on the GitHub repository.
