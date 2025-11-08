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
