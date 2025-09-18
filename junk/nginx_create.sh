#!/bin/bash

# nginx_create.sh — Bootstrap a Drupal site on Nginx (HTTP-only config for Certbot)
# Usage:
#   sudo ./nginx_create.sh <domain>
# Example:
#   sudo ./nginx_create.sh pmergsy.powdermonkey.eu

set -euo pipefail

# --- Root check ---
if [ "$EUID" -ne 0 ]; then
    echo "❌ This script must be run as root. Use: sudo $0 <domain>"
    exit 1
fi

# --- Parse arguments ---
if [ $# -lt 1 ]; then
    echo "❌ Usage: $0 <domain>"
    exit 1
fi

DOMAIN="$1"

# --- Paths and filenames ---
NGINX_CONF_NAME="prod-$DOMAIN.conf"
NGINX_CONF_PATH="/etc/nginx/sites-available/$NGINX_CONF_NAME"
NGINX_SYMLINK="/etc/nginx/sites-enabled/$NGINX_CONF_NAME"
SITE_ROOT="/var/www/prod-$DOMAIN"
ACCESS_LOG="/var/log/nginx/$DOMAIN.access.log"
ERROR_LOG="/var/log/nginx/$DOMAIN.error.log"
PHP_SOCKET="/run/php/php8.3-fpm.sock"

# --- Site directory check ---
if [ ! -d "$SITE_ROOT" ]; then
    echo "❌ Expected site root does not exist: $SITE_ROOT"
    echo "🛑 Aborting. Create the site directory before running this script."
    exit 1
fi

# --- Handle existing config ---
OVERWRITE=false

if [ -f "$NGINX_CONF_PATH" ] || [ -L "$NGINX_SYMLINK" ]; then
    echo "⚠️ Existing config detected:"
    [ -f "$NGINX_CONF_PATH" ] && echo "   - Config file exists: $NGINX_CONF_PATH"
    [ -L "$NGINX_SYMLINK" ] && echo "   - Symlink exists:     $NGINX_SYMLINK"

    read -r -p "❓ Overwrite existing config and symlink? [Y/n]: " CONFIRM
    CONFIRM="${CONFIRM:-Y}"

    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "✅ Overwriting..."
        OVERWRITE=true
    else
        echo "🚫 Aborted by user."
        exit 0
    fi
fi

# --- Remove existing config/symlink if overwriting ---
if $OVERWRITE; then
    [ -f "$NGINX_CONF_PATH" ] && rm -f "$NGINX_CONF_PATH"
    [ -L "$NGINX_SYMLINK" ] && rm -f "$NGINX_SYMLINK"
fi

# --- Create minimal HTTP-only NGINX config ---
echo "📝 Creating NGINX config: $NGINX_CONF_PATH"

cat > "$NGINX_CONF_PATH" <<EOF
##
# $NGINX_CONF_NAME - Minimal HTTP-only config for $DOMAIN
# Used for initial Certbot verification
##

server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;

    root $SITE_ROOT/web;
    index index.php;

    access_log $ACCESS_LOG;
    error_log  $ERROR_LOG;

    location / {
        try_files \$uri /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_SOCKET;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ (^|/)\. {
        deny all;
    }
}
EOF

# --- Create symlink ---
echo "🔗 Enabling site with symlink..."
ln -s "$NGINX_CONF_PATH" "$NGINX_SYMLINK"

# --- Test and reload NGINX ---
echo "🔍 Testing NGINX configuration..."
if nginx -t; then
    echo "✅ NGINX config is valid."
    echo "🔄 Reloading NGINX..."
    systemctl reload nginx
    echo "✅ NGINX reloaded successfully."
else
    echo "❌ NGINX configuration failed. Please review the config."
    exit 1
fi

# --- Final Certbot instruction ---
echo ""
echo "⚠️ SSL certificates not yet installed for $DOMAIN"
echo "👉 To issue Let's Encrypt SSL certificates, run the following command:"
echo ""
echo "   sudo certbot --nginx -d $DOMAIN -d www.$DOMAIN"
echo ""
echo "💡 This will update the config with full HTTPS support automatically."
echo ""
echo "✅ Site bootstrap (HTTP-only) complete for $DOMAIN"

