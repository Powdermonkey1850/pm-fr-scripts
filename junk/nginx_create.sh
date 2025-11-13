#!/bin/bash

# nginx_create.sh — Bootstrap a Drupal (7/10), WordPress, or Generic PHP site on Nginx (FastCGI + Certbot ready)
# Usage:
#   sudo ./nginx_create.sh example.com

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

# --- Choose CMS type ---
read -r -p "❓ Which CMS are you setting up? (D7/D10/WP/Generic) [D10]: " CMS_TYPE
CMS_TYPE="${CMS_TYPE:-D10}"
CMS_TYPE=$(echo "$CMS_TYPE" | tr '[:upper:]' '[:lower:]')  # normalize input to lowercase

if [[ "$CMS_TYPE" == "d10" || "$CMS_TYPE" == "drupal" ]]; then
    SITE_ROOT="/var/www/prod-$DOMAIN/web"
    FRONT_CONTROLLER='try_files $uri /index.php?$query_string;'
    CMS_BLOCK=$(cat <<'DRUPAL'
    # Allow Drupal to generate missing image style derivatives
    location ~* ^/sites/.*/files/styles/ {
        try_files $uri @rewrite;
    }

    # Allow Drupal to generate missing aggregated CSS/JS
    location ~* ^/sites/.*/files/(css|js)/ {
        try_files $uri @rewrite;
    }

    # Allow Drupal to serve public files and rewrite missing ones to index.php
    location ~* ^/sites/.*/files/ {
        try_files $uri /index.php?$query_string;
        access_log off;
        log_not_found off;
    }

    # Rewrite handler for Drupal
    location @rewrite {
        rewrite ^ /index.php?$query_string;
    }

    # Security: deny execution of PHP in user-uploaded files
    location ~* ^/sites/.*/files/.*\.php$ {
        deny all;
    }

    # Security: deny execution of PHP and sensitive files in core/vendor/etc
    location ~* ^/(core|vendor|modules|profiles|themes)/.*\.(engine|inc|install|make|module|profile|po|sh|sql|theme|tpl(\.php)?|xtmpl|php)$ {
        deny all;
    }

    # Security: deny hidden files (.git, .htaccess, etc.)
    location ~ (^|/)\. {
        deny all;
    }

    # Security: block composer files
    location ~* ^/composer\.(json|lock)$ {
        deny all;
    }

    # Cache static assets generally
    location ~* \.(?:ico|css|js|gif|jpe?g|png|woff2?|eot|ttf|svg|mp4|ogg|webm)$ {
        expires 6M;
        access_log off;
        log_not_found off;
    }
DRUPAL
)
    CACHE_BYPASS=$(cat <<'EOF'
    set $no_cache 0;
    if ($http_cookie ~* "S?SESS|_session") {
        set $no_cache 1;
    }
EOF
)

elif [[ "$CMS_TYPE" == "d7" ]]; then
    SITE_ROOT="/var/www/prod-$DOMAIN"
    FRONT_CONTROLLER='try_files $uri /index.php?$query_string;'
    CMS_BLOCK=$(cat <<'DRUPAL7'
    # Deny access to hidden and sensitive files
    location ~ (^|/)\. {
        deny all;
    }
    location ~* \.(engine|inc|install|make|module|profile|po|sh|.*sql|theme|tpl\.php)$ {
        deny all;
    }

    # Image styles: let Drupal generate missing derivatives
    location ~* ^/sites/.*/files/styles/ {
        try_files $uri @drupal;
    }

    # Private files must remain blocked
    location ~* ^/sites/.*/files/private/ {
        deny all;
    }

    # Cache static assets
    location ~* \.(?:ico|css|js|gif|jpe?g|png|woff2?|eot|ttf|svg|mp4|ogg|webm)$ {
        expires 6M;
        access_log off;
        log_not_found off;
    }

    # Fallback handler for Drupal
    location @drupal {
        rewrite ^ /index.php;
    }
DRUPAL7
)
    CACHE_BYPASS=$(cat <<'EOF'
    set $no_cache 0;
    if ($http_cookie ~* "S?SESS|_session") {
        set $no_cache 1;
    }
EOF
)

elif [[ "$CMS_TYPE" == "wp" ]]; then
    SITE_ROOT="/var/www/prod-$DOMAIN"
    FRONT_CONTROLLER='try_files $uri $uri/ /index.php?$args;'
    CMS_BLOCK=$(cat <<'WP'
    # Deny access to hidden files
    location ~ (^|/)\. {
        deny all;
    }

    # Cache static assets
    location ~* \.(?:ico|css|js|gif|jpe?g|png|woff2?|eot|ttf|svg)$ {
        expires 6M;
        access_log off;
        log_not_found off;
    }
WP
)
    CACHE_BYPASS=$(cat <<'EOF'
    set $no_cache 0;
    if ($http_cookie ~* "wordpress_logged_in_|wp-postpass_|wordpress_sec") {
        set $no_cache 1;
    }
EOF
)

elif [[ "$CMS_TYPE" == "generic" ]]; then
    SITE_ROOT="/var/www/prod-$DOMAIN"
    FRONT_CONTROLLER='try_files $uri /index.php?$query_string;'
    CMS_BLOCK=$(cat <<'GENERIC'
    # Generic PHP site config — deny hidden files
    location ~ (^|/)\. {
        deny all;
    }

    # Cache static assets (images, fonts, CSS, JS)
    location ~* \.(?:ico|css|js|gif|jpe?g|png|woff2?|eot|ttf|svg|mp4|ogg|webm)$ {
        expires 6M;
        access_log off;
        log_not_found off;
    }
GENERIC
)
    CACHE_BYPASS=$(cat <<'EOF'
    set $no_cache 0;
    # No CMS-specific session handling
EOF
)

else
    echo "❌ Unknown CMS type: $CMS_TYPE"
    exit 1
fi

# --- Ask PHP version ---
read -r -p "❓ Which PHP version do you want to use? (7.0/7.4/8.0/8.1/8.2/8.3) [8.3]: " PHP_VERSION
PHP_VERSION="${PHP_VERSION:-8.3}"
PHP_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"

# --- Paths and filenames ---
NGINX_CONF_NAME="prod-$DOMAIN.conf"
NGINX_CONF_PATH="/etc/nginx/sites-available/$NGINX_CONF_NAME"
NGINX_SYMLINK="/etc/nginx/sites-enabled/$NGINX_CONF_NAME"
ACCESS_LOG="/var/log/nginx/$DOMAIN.access.log"
ERROR_LOG="/var/log/nginx/$DOMAIN.error.log"

# --- Site directory check ---
if [ ! -d "$SITE_ROOT" ]; then
    echo "❌ Expected site root does not exist: $SITE_ROOT"
    echo "🛑 Aborting. Create the site directory before running this script."
    exit 1
fi

# --- Handle existing config ---
OVERWRITE=false

if [ -f "$NGINX_CONF_PATH" ] || [ -L "$NGINX_SYMLINK" ]; then
    echo "  Existing config detected:"
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

# --- Create FastCGI-caching NGINX config ---
echo "📝 Creating NGINX config: $NGINX_CONF_PATH"

cat > "$NGINX_CONF_PATH" <<EOF
##
# $NGINX_CONF_NAME - Minimal HTTP config with FastCGI for $DOMAIN ($CMS_TYPE)
##

server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;

    # Upload size limits (safe default: 64M)
    client_max_body_size 64M;

    root $SITE_ROOT;
    index index.php;

    access_log $ACCESS_LOG;
    error_log  $ERROR_LOG;

    location / {
        $FRONT_CONTROLLER
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_SOCKET;
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;

        # Enable FastCGI cache
        fastcgi_cache FASTCGI;
        fastcgi_cache_valid 200 301 302 30m;
        fastcgi_cache_valid 404 1m;

        # CMS-specific cache bypass
$CACHE_BYPASS

        fastcgi_cache_bypass \$no_cache;
        fastcgi_no_cache \$no_cache;

        add_header X-FastCGI-Cache \$upstream_cache_status;

        include fastcgi_params;
        fastcgi_read_timeout 300;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
    }

$CMS_BLOCK
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
echo "  SSL certificates not yet installed for $DOMAIN"
echo "👉 To issue Let's Encrypt SSL certificates, run the following command:"
echo ""
echo "   sudo certbot --nginx -d $DOMAIN -d www.$DOMAIN"
echo ""
echo "💡 This will update the config with full HTTPS support automatically."
echo ""
echo "✅ Site bootstrap (HTTP-only + FastCGI) complete for $DOMAIN"

