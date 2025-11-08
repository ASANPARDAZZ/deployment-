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
