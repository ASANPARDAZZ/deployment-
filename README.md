https://github.com/ASANPARDAZZ/deployment-.git🌐 کانفیگ Nginx و SSL + دیپلوی روی سرور

📋 ساختار کامل دیپلوی

🗂️ ساختار فایل‌های دیپلوی

```
deployment/
├── 📁 nginx/
│   ├── nginx.conf
│   ├── ssl.conf
│   ├── security-headers.conf
│   └── sites-available/
│       ├── apz-bridge.conf
│       ├── apz-explorer.conf
│       └── apz-api.conf
├── 📁 ssl/
│   ├── generate-certs.sh
│   ├── renew-certs.sh
│   └── dhparam.pem
├── 📁 scripts/
│   ├── deploy.sh
│   ├── setup-server.sh
│   ├── backup-database.sh
│   └── monitoring-setup.sh
├── 📁 systemd/
│   ├── apz-bridge.service
│   ├── apz-relayer.service
│   └── apz-indexer.service
├── 📁 docker/
│   ├── docker-compose.prod.yml
│   └── .env.production
├── 📁 monitoring/
│   ├── nginx-metrics.conf
│   └── nginx-status.conf
└── README_DEPLOYMENT.md
```

🔧 کانفیگ Nginx

📄 deployment/nginx/nginx.conf

```nginx
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
    multi_accept on;
    use epoll;
}

http {
    # Basic Settings
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    # MIME Types
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Logging Settings
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for" '
                    'rt=$request_time uct="$upstream_connect_time" '
                    'uht="$upstream_header_time" urt="$upstream_response_time"';

    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;

    # Rate Limiting
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=auth:10m rate=5r/m;

    # Gzip Settings
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        application/atom+xml
        application/javascript
        application/json
        application/ld+json
        application/manifest+json
        application/rss+xml
        application/vnd.geo+json
        application/vnd.ms-fontobject
        application/x-font-ttf
        application/x-web-app-manifest+json
        application/xhtml+xml
        application/xml
        font/opentype
        image/bmp
        image/svg+xml
        image/x-icon
        text/cache-manifest
        text/css
        text/plain
        text/vcard
        text/vnd.rim.location.xloc
        text/vtt
        text/x-component
        text/x-cross-domain-policy;

    # Security Headers
    include /etc/nginx/conf.d/security-headers.conf;

    # SSL Settings
    include /etc/nginx/conf.d/ssl.conf;

    # Virtual Host Configs
    include /etc/nginx/sites-enabled/*;
}
```

📄 deployment/nginx/sites-available/apz-bridge.conf

```nginx
# APZ Bridge Main Configuration
upstream apz_bridge_backend {
    server 127.0.0.1:3000;
    server 127.0.0.1:3001 backup;
    keepalive 32;
}

upstream apz_bridge_api {
    server 127.0.0.1:8080;
    server 127.0.0.1:8081 backup;
    keepalive 32;
}

# HTTP to HTTPS Redirect
server {
    listen 80;
    listen [::]:80;
    server_name bridge.apzchain.org www.bridge.apzchain.org;
    
    # Security Headers even for HTTP
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    
    # Redirect to HTTPS
    return 301 https://$server_name$request_uri;
}

# Main HTTPS Server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name bridge.apzchain.org www.bridge.apzchain.org;

    # SSL Configuration
    ssl_certificate /etc/letsencrypt/live/bridge.apzchain.org/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/bridge.apzchain.org/privkey.pem;
    include /etc/nginx/conf.d/ssl.conf;

    # Root directory for frontend
    root /var/www/apz-bridge/frontend/dist;
    index index.html;

    # Frontend Application
    location / {
        try_files $uri $uri/ /index.html;
        
        # Cache static assets
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
            expires 1y;
            add_header Cache-Control "public, immutable";
            add_header Vary "Accept-Encoding";
        }
        
        # Security headers for HTML
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    }

    # API Proxy
    location /api/ {
        limit_req zone=api burst=20 nodelay;
        
        proxy_pass http://apz_bridge_api;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
        
        # Timeout settings
        proxy_connect_timeout 30s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
        
        # Buffer settings
        proxy_buffering on;
        proxy_buffer_size 4k;
        proxy_buffers 8 4k;
        
        # CORS headers
        add_header Access-Control-Allow-Origin "https://bridge.apzchain.org" always;
        add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Authorization, Content-Type, X-Requested-With" always;
        
        if ($request_method = OPTIONS) {
            return 204;
        }
    }

    # WebSocket for real-time updates
    location /ws/ {
        proxy_pass http://apz_bridge_api;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # Metrics and Health Checks
    location /health {
        access_log off;
        proxy_pass http://apz_bridge_api/health;
        proxy_set_header Host $host;
    }

    location /metrics {
        limit_req zone=api burst=5 nodelay;
        proxy_pass http://apz_bridge_api/metrics;
        proxy_set_header Host $host;
    }

    # Security - Block sensitive files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    location ~ /(README.md|Dockerfile|\.env) {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Error pages
    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
    
    location = /50x.html {
        root /usr/share/nginx/html;
    }
}

# Subdomain for documentation
server {
    listen 443 ssl http2;
    server_name docs.bridge.apzchain.org;

    ssl_certificate /etc/letsencrypt/live/bridge.apzchain.org/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/bridge.apzchain.org/privkey.pem;
    include /etc/nginx/conf.d/ssl.conf;

    root /var/www/apz-bridge/docs;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

📄 deployment/nginx/conf.d/ssl.conf

```nginx
# SSL Security Configuration
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
ssl_prefer_server_ciphers off;

ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;

# OCSP Stapling
ssl_stapling on;
ssl_stapling_verify on;
resolver 8.8.8.8 1.1.1.1 valid=300s;
resolver_timeout 5s;

# DH Parameters
ssl_dhparam /etc/nginx/ssl/dhparam.pem;

# HSTS (63072000 seconds = 2 years)
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
```

📄 deployment/nginx/conf.d/security-headers.conf

```nginx
# Security Headers Configuration
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data: https:; connect-src 'self' https://rpc.apzchain.org wss://bridge.apzchain.org; frame-ancestors 'none';" always;
add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

# Block common attacks
if ($http_user_agent ~* (wget|curl|httrack|nikto|sqlmap)) {
    return 403;
}

# Block spam referrers
if ($http_referer ~* (babes|click|diamond|forsale|girl|jewelry|love|nudit|organic|poker|porn|poweroversoftware|sex|teen|video|webcam|zippo)) {
    return 403;
}
```

🔐 SSL Certificate Setup

📄 deployment/ssl/generate-certs.sh

```bash
#!/bin/bash

# APZ Bridge SSL Certificate Setup Script
set -e

DOMAINS=("bridge.apzchain.org" "www.bridge.apzchain.org" "docs.bridge.apzchain.org")
EMAIL="admin@apzchain.org"
SSL_DIR="/etc/letsencrypt/live/bridge.apzchain.org"

echo "🔐 Setting up SSL certificates for APZ Bridge..."

# Install Certbot if not exists
if ! command -v certbot &> /dev/null; then
    echo "Installing Certbot..."
    apt update
    apt install -y certbot python3-certbot-nginx
fi

# Create SSL directory
mkdir -p /etc/nginx/ssl
mkdir -p /etc/letsencrypt/live/bridge.apzchain.org

# Generate DH parameters if not exists
if [ ! -f /etc/nginx/ssl/dhparam.pem ]; then
    echo "Generating DH parameters (this may take a while)..."
    openssl dhparam -out /etc/nginx/ssl/dhparam.pem 2048
fi

# Stop nginx temporarily
systemctl stop nginx

# Obtain SSL certificate
echo "Requesting SSL certificate from Let's Encrypt..."
certbot certonly --standalone \
    --non-interactive \
    --agree-tos \
    --email "$EMAIL" \
    --domains "${DOMAINS[*]}" \
    --pre-hook "systemctl stop nginx" \
    --post-hook "systemctl start nginx"

# Set proper permissions
chmod 755 /etc/letsencrypt/live
chmod 755 /etc/letsencrypt/archive
chmod 644 /etc/letsencrypt/live/bridge.apzchain.org/fullchain.pem
chmod 644 /etc/letsencrypt/live/bridge.apzchain.org/privkey.pem

# Create certificate renewal hook
cat > /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh << 'EOF'
#!/bin/bash
echo "Reloading nginx after certificate renewal..."
systemctl reload nginx
EOF

chmod +x /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh

# Test renewal
echo "Testing certificate renewal..."
certbot renew --dry-run

# Start nginx
systemctl start nginx

echo "✅ SSL certificates setup completed!"
echo "📧 Certificate location: $SSL_DIR"
echo "🔄 Auto-renewal is configured"
```

📄 deployment/ssl/renew-certs.sh

```bash
#!/bin/bash

# SSL Certificate Auto-Renewal Script
set -e

echo "🔄 Checking for SSL certificate renewal..."

# Renew certificates
certbot renew --quiet --post-hook "systemctl reload nginx"

# Log renewal
if [ $? -eq 0 ]; then
    echo "$(date): SSL certificates renewed successfully" >> /var/log/ssl-renewal.log
else
    echo "$(date): SSL certificate renewal failed" >> /var/log/ssl-renewal.log
    # Send alert (you can integrate with your alerting system)
    curl -X POST -H 'Content-type: application/json' \
    --data '{"text":"SSL certificate renewal failed for APZ Bridge"}' \
    $SLACK_WEBHOOK_URL
fi
```

🐳 Docker Compose Production

📄 deployment/docker/docker-compose.prod.yml

```yaml
version: '3.8'

services:
  # Frontend
  frontend:
    image: apzbridge/frontend:${FRONTEND_VERSION:-latest}
    build:
      context: ../frontend
      dockerfile: Dockerfile.prod
    environment:
      - NODE_ENV=production
      - VUE_APP_API_URL=https://bridge.apzchain.org/api
      - VUE_APP_WS_URL=wss://bridge.apzchain.org/ws
    volumes:
      - /var/www/apz-bridge/frontend:/app/dist
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000"]
      interval: 30s
      timeout: 10s
      retries: 3

  # Backend API
  api:
    image: apzbridge/api:${API_VERSION:-latest}
    build:
      context: ../backend
      dockerfile: Dockerfile.prod
    environment:
      - NODE_ENV=production
      - DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@postgres:5432/apz_bridge
      - REDIS_URL=redis://redis:6379
      - KAFKA_BROKERS=kafka:9092
      - JWT_SECRET=${JWT_SECRET}
      - RPC_URL_APZ=${RPC_URL_APZ}
      - RPC_URL_ETH=${RPC_URL_ETH}
    ports:
      - "127.0.0.1:8080:8080"
      - "127.0.0.1:8081:8081"
    depends_on:
      - postgres
      - redis
      - kafka
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  # Relayers
  apz-relayer:
    image: apzbridge/relayer:${RELAYER_VERSION:-latest}
    environment:
      - NODE_ENV=production
      - CHAIN=apz
      - RPC_URL=${RPC_URL_APZ}
      - BRIDGE_ADDRESS=${BRIDGE_ADDRESS_APZ}
      - PRIVATE_KEY=${RELAYER_PRIVATE_KEY_APZ}
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "node", "healthcheck.js"]
      interval: 30s
      timeout: 10s
      retries: 3

  eth-relayer:
    image: apzbridge/relayer:${RELAYER_VERSION:-latest}
    environment:
      - NODE_ENV=production
      - CHAIN=ethereum
      - RPC_URL=${RPC_URL_ETH}
      - BRIDGE_ADDRESS=${BRIDGE_ADDRESS_ETH}
      - PRIVATE_KEY=${RELAYER_PRIVATE_KEY_ETH}
    restart: unless-stopped

  # Database
  postgres:
    image: postgres:14
    environment:
      - POSTGRES_DB=apz_bridge
      - POSTGRES_USER=${DB_USER}
      - POSTGRES_PASSWORD=${DB_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./database/init:/docker-entrypoint-initdb.d
    command: >
      postgres
      -c shared_preload_libraries=pg_stat_statements
      -c pg_stat_statements.track=all
      -c max_connections=200
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER}"]
      interval: 30s
      timeout: 10s
      retries: 3

  # Redis
  redis:
    image: redis:7-alpine
    command: redis-server --appendonly yes --requirepass ${REDIS_PASSWORD}
    volumes:
      - redis_data:/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 30s
      timeout: 3s
      retries: 3

  # Kafka Cluster
  zookeeper:
    image: confluentinc/cp-zookeeper:7.3.0
    environment:
      ZOOKEEPER_CLIENT_PORT: 2181
      ZOOKEEPER_TICK_TIME: 2000
    restart: unless-stopped

  kafka:
    image: confluentinc/cp-kafka:7.3.0
    depends_on:
      - zookeeper
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka:9092
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_NUM_PARTITIONS: 3
    restart: unless-stopped

  # Monitoring
  prometheus:
    image: prom/prometheus:latest
    volumes:
      - prometheus_data:/prometheus
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
      - '--storage.tsdb.retention.time=200h'
      - '--web.enable-lifecycle'
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
    volumes:
      - grafana_data:/var/lib/grafana
    restart: unless-stopped

volumes:
  postgres_data:
  redis_data:
  prometheus_data:
  grafana_data:

networks:
  default:
    name: apz-bridge-network
```

🚀 اسکریپت‌های دیپلوی

📄 deployment/scripts/deploy.sh

```bash
#!/bin/bash

# APZ Bridge Deployment Script
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
PROJECT_NAME="apz-bridge"
DEPLOY_DIR="/var/www/$PROJECT_NAME"
BACKUP_DIR="/var/backups/$PROJECT_NAME"
LOG_FILE="/var/log/$PROJECT_NAME-deploy.log"

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}" | tee -a $LOG_FILE
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}" | tee -a $LOG_FILE
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" | tee -a $LOG_FILE
    exit 1
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    error "Please run as root"
fi

# Create directories
create_directories() {
    log "Creating deployment directories..."
    mkdir -p $DEPLOY_DIR/{frontend,backend,ssl,logs,backups}
    mkdir -p $BACKUP_DIR
    chown -R www-data:www-data $DEPLOY_DIR
    chmod -R 755 $DEPLOY_DIR
}

# Backup current deployment
backup_current() {
    log "Backing up current deployment..."
    
    if [ -d "$DEPLOY_DIR/backend" ]; then
        BACKUP_FILE="$BACKUP_DIR/backup-$(date +%Y%m%d-%H%M%S).tar.gz"
        tar -czf $BACKUP_FILE -C $DEPLOY_DIR . 2>/dev/null || warn "Backup creation had some issues"
        log "Backup created: $BACKUP_FILE"
    else
        warn "No existing deployment found for backup"
    fi
}

# Pull latest code
pull_latest_code() {
    log "Pulling latest code..."
    
    cd /opt/$PROJECT_NAME
    
    # Pull from git
    git fetch origin
    git reset --hard origin/main
    
    # Update submodules if any
    if [ -f .gitmodules ]; then
        git submodule update --init --recursive
    fi
    
    log "Code updated to latest version: $(git rev-parse --short HEAD)"
}

# Build Docker images
build_images() {
    log "Building Docker images..."
    
    cd /opt/$PROJECT_NAME
    
    # Build frontend
    log "Building frontend image..."
    docker build -t apzbridge/frontend:latest -f frontend/Dockerfile.prod frontend/
    
    # Build backend
    log "Building backend image..."
    docker build -t apzbridge/api:latest -f backend/Dockerfile.prod backend/
    
    # Build relayers
    log "Building relayer images..."
    docker build -t apzbridge/relayer:latest -f relayers/Dockerfile.prod relayers/
    
    log "All images built successfully"
}

# Run database migrations
run_migrations() {
    log "Running database migrations..."
    
    cd /opt/$PROJECT_NAME/deployment/docker
    
    docker-compose -f docker-compose.prod.yml run --rm api \
        npx sequelize-cli db:migrate
    
    log "Database migrations completed"
}

# Deploy services
deploy_services() {
    log "Deploying services..."
    
    cd /opt/$PROJECT_NAME/deployment/docker
    
    # Stop existing services
    log "Stopping existing services..."
    docker-compose -f docker-compose.prod.yml down
    
    # Start new services
    log "Starting new services..."
    docker-compose -f docker-compose.prod.yml up -d
    
    # Wait for services to be healthy
    log "Waiting for services to be healthy..."
    sleep 30
    
    # Check service health
    check_services_health
}

# Check services health
check_services_health() {
    log "Checking services health..."
    
    SERVICES=(
        "api:8080/health"
        "frontend:3000"
        "apz-relayer:3002/health"
        "postgres:5432"
        "redis:6379"
    )
    
    ALL_HEALTHY=true
    
    for service in "${SERVICES[@]}"; do
        IFS=':' read -r service_name port <<< "$service"
        
        if curl -f "http://localhost:${port%%/*}" > /dev/null 2>&1; then
            log "✅ $service_name is healthy"
        else
            error "❌ $service_name is not healthy"
            ALL_HEALTHY=false
        fi
    done
    
    if [ "$ALL_HEALTHY" = true ]; then
        log "🎉 All services are healthy!"
    else
        error "Some services are not healthy. Check logs for details."
    fi
}

# Update nginx configuration
update_nginx() {
    log "Updating nginx configuration..."
    
    # Copy nginx configs
    cp /opt/$PROJECT_NAME/deployment/nginx/* /etc/nginx/ -r
    cp /opt/$PROJECT_NAME/deployment/nginx/sites-available/* /etc/nginx/sites-available/
    
    # Enable sites
    ln -sf /etc/nginx/sites-available/apz-bridge.conf /etc/nginx/sites-enabled/
    
    # Test nginx configuration
    if nginx -t; then
        log "✅ nginx configuration test passed"
        systemctl reload nginx
        log "nginx reloaded successfully"
    else
        error "nginx configuration test failed"
    fi
}

# Setup SSL certificates
setup_ssl() {
    log "Setting up SSL certificates..."
    
    if [ ! -f "/etc/letsencrypt/live/bridge.apzchain.org/fullchain.pem" ]; then
        warn "SSL certificates not found. Running initial setup..."
        /opt/$PROJECT_NAME/deployment/ssl/generate-certs.sh
    else
        log "SSL certificates already exist. Skipping initial setup."
    fi
}

# Setup cron jobs
setup_cron() {
    log "Setting up cron jobs..."
    
    # SSL certificate auto-renewal
    (crontab -l 2>/dev/null; echo "0 12 * * * /opt/$PROJECT_NAME/deployment/ssl/renew-certs.sh >> /var/log/ssl-renewal.log 2>&1") | crontab -
    
    # Database backups
    (crontab -l 2>/dev/null; echo "0 2 * * * /opt/$PROJECT_NAME/deployment/scripts/backup-database.sh >> /var/log/db-backup.log 2>&1") | crontab -
    
    # Log rotation
    (crontab -l 2>/dev/null; echo "0 0 * * * /usr/sbin/logrotate /etc/logrotate.d/apz-bridge") | crontab -
    
    log "Cron jobs setup completed"
}

# Main deployment function
main() {
    log "🚀 Starting APZ Bridge deployment..."
    
    case "${1:-}" in
        "setup")
            create_directories
            setup_ssl
            setup_cron
            ;;
        "deploy")
            backup_current
            pull_latest_code
            build_images
            run_migrations
            deploy_services
            update_nginx
            ;;
        "rollback")
            rollback_deployment
            ;;
        *)
            echo "Usage: $0 {setup|deploy|rollback}"
            exit 1
            ;;
    esac
    
    log "🎉 Deployment completed successfully!"
}

# Rollback function
rollback_deployment() {
    log "Initiating rollback..."
    
    # Find latest backup
    LATEST_BACKUP=$(ls -t $BACKUP_DIR/*.tar.gz 2>/dev/null | head -1)
    
    if [ -z "$LATEST_BACKUP" ]; then
        error "No backup found for rollback"
    fi
    
    log "Rolling back to: $LATEST_BACKUP"
    
    # Stop services
    cd /opt/$PROJECT_NAME/deployment/docker
    docker-compose -f docker-compose.prod.yml down
    
    # Restore backup
    tar -xzf $LATEST_BACKUP -C $DEPLOY_DIR
    
    # Start services
    docker-compose -f docker-compose.prod.yml up -d
    
    log "Rollback completed successfully"
}

# Run main function
main "$@"
```

📄 deployment/scripts/setup-server.sh

```bash
#!/bin/bash

# Server Setup Script for APZ Bridge
set -e

echo "🛠️ Setting up server for APZ Bridge..."

# Update system
apt update && apt upgrade -y

# Install required packages
apt install -y \
    curl \
    wget \
    git \
    htop \
    nginx \
    certbot \
    python3-certbot-nginx \
    postgresql \
    postgresql-contrib \
    docker.io \
    docker-compose \
    fail2ban \
    ufw \
    logrotate

# Setup firewall
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow http
ufw allow https
ufw enable

# Setup Docker without sudo
usermod -aG docker $USER

# Create application user
useradd -m -s /bin/bash apzbridge || true
usermod -aG docker apzbridge

# Create directories
mkdir -p /var/www/apz-bridge
mkdir -p /var/backups/apz-bridge
mkdir -p /var/log/apz-bridge
mkdir -p /opt/apz-bridge

# Set permissions
chown -R apzbridge:apzbridge /var/www/apz-bridge
chown -R apzbridge:apzbridge /opt/apz-bridge

# Setup logrotate
cat > /etc/logrotate.d/apz-bridge << EOF
/var/log/apz-bridge/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    copytruncate
}
EOF

echo "✅ Server setup completed!"
echo "📝 Next steps:"
echo "1. Clone your repository to /opt/apz-bridge"
echo "2. Run: ./deployment/scripts/deploy.sh setup"
echo "3. Run: ./deployment/scripts/deploy.sh deploy"
```

🔧 Systemd Services

📄 deployment/systemd/apz-bridge.service

```ini
[Unit]
Description=APZ Bridge Application
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/apz-bridge/deployment/docker
ExecStart=/usr/bin/docker-compose -f docker-compose.prod.yml up -d
ExecStop=/usr/bin/docker-compose -f docker-compose.prod.yml down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
```

📊 Monitoring Configuration

📄 deployment/monitoring/nginx-metrics.conf

```nginx
# Nginx Metrics for Prometheus
server {
    listen 8080;
    server_name 127.0.0.1;

    location /nginx-status {
        stub_status on;
        access_log off;
        allow 127.0.0.1;
        deny all;
    }

    location /metrics {
        proxy_pass http://prometheus:9090;
        access_log off;
        allow 127.0.0.1;
        deny all;
    }
}
```

📚 راهنمای دیپلوی

📄 deployment/README_DEPLOYMENT.md

```markdown
# 🚀 APZ Bridge Deployment Guide

## Prerequisites
- Ubuntu 20.04/22.04 LTS
- 4GB+ RAM, 2+ CPU cores, 50GB+ storage
- Domain name (bridge.apzchain.org)

## Quick Deployment

1. **Server Setup**
```bash
chmod +x deployment/scripts/setup-server.sh
./deployment/scripts/setup-server.sh
```

1. Initial Setup

```bash
chmod +x deployment/scripts/deploy.sh
./deployment/scripts/deploy.sh setup
```

1. Deploy Application

```bash
./deployment/scripts/deploy.sh deploy
```

Environment Variables

Create .env.production:

```bash
# Database
DB_USER=apzbridge
DB_PASSWORD=your_secure_password

# Redis
REDIS_PASSWORD=your_redis_password

# JWT
JWT_SECRET=your_jwt_secret

# RPC URLs
RPC_URL_APZ=https://rpc.apzchain.org
RPC_URL_ETH=https://mainnet.infura.io/v3/your_infura_key

# Relayer Private Keys
RELAYER_PRIVATE_KEY_APZ=your_apz_private_key
RELAYER_PRIVATE_KEY_ETH=your_eth_private_key
```

Monitoring

· Grafana: https://bridge.apzchain.org:3000
· Prometheus: https://bridge.apzchain.org:9090
· Nginx Status: http://localhost:8080/nginx-status

Backup & Recovery

Manual backup:

```bash
./deployment/scripts/backup-database.sh
```

Rollback:

```bash
./deployment/scripts/deploy.sh rollback
```

Security Checklist

· Firewall configured
· SSL certificates installed
· Database passwords secure
· Private keys protected
· Regular backups enabled
· Monitoring active
· Log rotation configured

```

---

این ساختار کامل دیپلوی، تمام نیازهای استقرار حرفه‌ای پل APZ را پوشش می‌دهد و امکان مدیریت آسان، مانیتورینگ پیشرفته و بازیابی سریع را فراهم می‌کند. 🎯# deployment-
