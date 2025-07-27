#!/bin/bash

# Fleet Management App - Ubuntu 24 VPS Auto-Deployment Script
# Run as root: chmod +x deploy-ubuntu-24.sh && ./deploy-ubuntu-24.sh

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
APP_USER="ltsfuel"
APP_DIR="/home/${APP_USER}/ltsfuel-app"
DB_NAME="ltsfuel_db"
DB_USER="ltsfueluser"
DB_PASS="LtsFuel2025!"
NODE_VERSION="20"

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    print_error "Please run this script as root (use sudo)"
    exit 1
fi

print_status "Starting Fleet Management App deployment on Ubuntu 24..."

# Step 1: Update system
print_status "Updating system packages..."
apt update && apt upgrade -y
print_success "System updated"

# Step 2: Install essential tools
print_status "Installing essential tools..."
apt install -y curl wget git nano htop unzip software-properties-common
print_success "Essential tools installed"

# Step 3: Install Node.js 20
print_status "Installing Node.js ${NODE_VERSION}..."
if ! command_exists node; then
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
    apt install -y nodejs
    print_success "Node.js installed: $(node --version)"
else
    print_success "Node.js already installed: $(node --version)"
fi

# Step 4: Install PostgreSQL
print_status "Installing PostgreSQL..."
if ! command_exists psql; then
    apt install -y postgresql postgresql-contrib
    systemctl start postgresql
    systemctl enable postgresql
    print_success "PostgreSQL installed and started"
else
    print_success "PostgreSQL already installed"
fi

# Step 5: Configure PostgreSQL
print_status "Configuring PostgreSQL database..."
sudo -u postgres psql -c "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || {
    sudo -u postgres createdb ${DB_NAME}
    sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH ENCRYPTED PASSWORD '${DB_PASS}';"
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};"
    sudo -u postgres psql -c "ALTER USER ${DB_USER} CREATEDB;"
    print_success "Database and user created"
}

# Configure pg_hba.conf for local connections
print_status "Configuring PostgreSQL authentication..."
PG_VERSION=$(ls /etc/postgresql/)
PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
if ! grep -q "local.*${DB_USER}.*md5" ${PG_HBA}; then
    echo "local   all             ${DB_USER}                             md5" >> ${PG_HBA}
    systemctl restart postgresql
    print_success "PostgreSQL authentication configured"
fi

# Step 6: Install Nginx
print_status "Installing Nginx..."
if ! command_exists nginx; then
    apt install -y nginx
    systemctl start nginx
    systemctl enable nginx
    print_success "Nginx installed and started"
else
    print_success "Nginx already installed"
fi

# Step 7: Install PM2
print_status "Installing PM2 process manager..."
if ! command_exists pm2; then
    npm install -g pm2
    print_success "PM2 installed"
else
    print_success "PM2 already installed"
fi

# Step 8: Create application user
print_status "Creating application user: ${APP_USER}..."
if ! id "${APP_USER}" &>/dev/null; then
    adduser --disabled-password --gecos "" ${APP_USER}
    usermod -aG sudo ${APP_USER}
    print_success "User ${APP_USER} created"
else
    print_success "User ${APP_USER} already exists"
fi

# Step 9: Create directory structure
print_status "Creating directory structure..."
sudo -u ${APP_USER} mkdir -p ${APP_DIR}
sudo -u ${APP_USER} mkdir -p /home/${APP_USER}/logs
sudo -u ${APP_USER} mkdir -p /home/${APP_USER}/backups
sudo -u ${APP_USER} mkdir -p /home/${APP_USER}/app-backups
print_success "Directory structure created"

# Step 10: Configure firewall
print_status "Configuring firewall..."
if command_exists ufw; then
    ufw --force enable
    ufw allow ssh
    ufw allow 'Nginx Full'
    print_success "Firewall configured"
fi

# Step 11: Create environment file template
print_status "Creating environment configuration template..."
cat > ${APP_DIR}/.env << EOF
# Database Configuration
DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}

# Application Settings
NODE_ENV=production
PORT=3000

# Session Secret (CHANGE THIS IN PRODUCTION!)
SESSION_SECRET=change-this-to-a-random-secret-key-in-production

# Email Configuration (optional)
SMTP_HOST=
SMTP_PORT=587
SMTP_USER=
SMTP_PASS=
EOF
chown ${APP_USER}:${APP_USER} ${APP_DIR}/.env
print_success "Environment file created"

# Step 12: Create PM2 ecosystem file
print_status "Creating PM2 configuration..."
cat > ${APP_DIR}/ecosystem.config.js << 'EOF'
module.exports = {
  apps: [{
    name: 'ltsfuel-app',
    script: 'dist/index.js',
    cwd: '/home/ltsfuel/ltsfuel-app',
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '1G',
    env: {
      NODE_ENV: 'production',
      PORT: 3000
    },
    error_file: '/home/ltsfuel/logs/app-error.log',
    out_file: '/home/ltsfuel/logs/app-out.log',
    log_file: '/home/ltsfuel/logs/app-combined.log'
  }]
};
EOF
chown ${APP_USER}:${APP_USER} ${APP_DIR}/ecosystem.config.js
print_success "PM2 configuration created"

# Step 13: Create Nginx configuration
print_status "Creating Nginx configuration..."
cat > /etc/nginx/sites-available/ltsfuel << 'EOF'
server {
    listen 80;
    server_name _;  # Replace with your domain

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;

    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
        proxy_redirect off;
        
        # Timeout settings
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    # Static files caching
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        proxy_pass http://localhost:3000;
        proxy_set_header Host $host;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # File upload size limit
    client_max_body_size 10M;
}
EOF

# Enable site and remove default
ln -sf /etc/nginx/sites-available/ltsfuel /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx
print_success "Nginx configured and restarted"

# Step 14: Create backup script
print_status "Creating database backup script..."
cat > /home/${APP_USER}/backup-db.sh << EOF
#!/bin/bash

# Database backup script
BACKUP_DIR="/home/${APP_USER}/backups"
DATE=\$(date +%Y%m%d_%H%M%S)
DB_NAME="${DB_NAME}"
DB_USER="${DB_USER}"

# Create backup
pg_dump -h localhost -U \$DB_USER -d \$DB_NAME > \$BACKUP_DIR/ltsfuel_backup_\$DATE.sql

# Keep only last 7 days of backups
find \$BACKUP_DIR -name "ltsfuel_backup_*.sql" -mtime +7 -delete

echo "Database backup completed: ltsfuel_backup_\$DATE.sql"
EOF

chmod +x /home/${APP_USER}/backup-db.sh
chown ${APP_USER}:${APP_USER} /home/${APP_USER}/backup-db.sh
print_success "Backup script created"

# Step 15: Create system status script
print_status "Creating system status script..."
cat > /home/${APP_USER}/system-status.sh << 'EOF'
#!/bin/bash

echo "=== LTS Fuel App System Status ==="
echo "Date: $(date)"
echo ""

echo "=== Application Status ==="
su - ltsfuel -c "pm2 status"
echo ""

echo "=== Disk Usage ==="
df -h
echo ""

echo "=== Memory Usage ==="
free -h
echo ""

echo "=== Database Status ==="
systemctl status postgresql --no-pager -l
echo ""

echo "=== Nginx Status ==="
systemctl status nginx --no-pager -l
echo ""
EOF

chmod +x /home/${APP_USER}/system-status.sh
chown ${APP_USER}:${APP_USER} /home/${APP_USER}/system-status.sh
print_success "System status script created"

# Step 16: Create update script
print_status "Creating application update script..."
cat > /home/${APP_USER}/update-app.sh << EOF
#!/bin/bash

APP_DIR="${APP_DIR}"
BACKUP_DIR="/home/${APP_USER}/app-backups"
DATE=\$(date +%Y%m%d_%H%M%S)

echo "Starting application update..."

# Create backup directory
mkdir -p \$BACKUP_DIR

# Backup current application
cp -r \$APP_DIR \$BACKUP_DIR/ltsfuel-app-backup-\$DATE

# Navigate to app directory
cd \$APP_DIR

# Install dependencies
npm ci --production

# Build application
npm run build

# Restart application
pm2 restart ltsfuel-app

echo "Application update completed!"
echo "Backup saved to: \$BACKUP_DIR/ltsfuel-app-backup-\$DATE"
EOF

chmod +x /home/${APP_USER}/update-app.sh
chown ${APP_USER}:${APP_USER} /home/${APP_USER}/update-app.sh
print_success "Update script created"

# Step 17: Setup log rotation
print_status "Setting up log rotation..."
cat > /etc/logrotate.d/ltsfuel << EOF
/home/${APP_USER}/logs/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 ${APP_USER} ${APP_USER}
    postrotate
        /usr/bin/pm2 reloadLogs
    endscript
}
EOF
print_success "Log rotation configured"

# Step 18: Install and configure Fail2Ban
print_status "Installing Fail2Ban..."
if ! command_exists fail2ban-server; then
    apt install -y fail2ban
    
    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log

[nginx-http-auth]
enabled = true
filter = nginx-http-auth
port = http,https
logpath = /var/log/nginx/error.log

[nginx-limit-req]
enabled = true
filter = nginx-limit-req
port = http,https
logpath = /var/log/nginx/error.log
EOF

    systemctl start fail2ban
    systemctl enable fail2ban
    print_success "Fail2Ban installed and configured"
else
    print_success "Fail2Ban already installed"
fi

# Step 19: Display completion message
print_success "Base deployment completed successfully!"
echo ""
print_warning "NEXT STEPS:"
echo "1. Upload your application files to: ${APP_DIR}"
echo "2. Run the following commands to start your app:"
echo "   cd ${APP_DIR}"
echo "   npm install"
echo "   npm run build"
echo "   sudo -u ${APP_USER} pm2 start ecosystem.config.js"
echo "   sudo -u ${APP_USER} pm2 save"
echo "   sudo -u ${APP_USER} pm2 startup"
echo ""
print_warning "SECURITY:"
echo "1. Change the SESSION_SECRET in ${APP_DIR}/.env"
echo "2. Update the server_name in /etc/nginx/sites-available/ltsfuel"
echo "3. Set up SSL certificate with: certbot --nginx -d your-domain.com"
echo "4. Change default application passwords after first login"
echo ""
print_warning "MONITORING:"
echo "- Check status: /home/${APP_USER}/system-status.sh"
echo "- View logs: sudo -u ${APP_USER} pm2 logs"
echo "- Application URL: http://$(curl -s ifconfig.me || hostname -I | awk '{print $1}')"
echo ""
print_success "Deployment automation completed!"