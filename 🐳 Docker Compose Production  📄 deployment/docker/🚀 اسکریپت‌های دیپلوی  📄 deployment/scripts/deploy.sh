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
