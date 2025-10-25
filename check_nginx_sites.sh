#!/usr/bin/env bash
#
# check_nginx_sites.sh
# Tests HTTPS availability for all Nginx vhosts (including www variants)
# Skips certain domains and only sends mail at 04:00–05:00 if all pass.
#

set -uo pipefail

TMPDIR="/home/ubuntu/tmp"
EMAIL="patrick@powdermonkey.eu"
CONFIG_DIR="/etc/nginx/sites-enabled"
HOST=$(hostname)
DATE=$(date '+%Y-%m-%d %H:%M')
HOUR=$(date '+%H') # Server local time hour (00–23)
MIN=$(date '+%M')  # Add minute for 04:00–04:15 check
TMPFILE=$(mktemp "$TMPDIR/nginx_site_status_XXXXXX.txt")

# Domain to ignore (password-protected)
IGNORE_DOMAIN="monkeywiki.powdermonkey.eu"

mkdir -p "$TMPDIR"

{
    echo "📊 Nginx HTTPS Site Status Report - $DATE"
    echo "Host: $HOST"
    echo "---------------------------------------------"
    echo ""
} > "$TMPFILE"

failed_count=0

if [ ! -d "$CONFIG_DIR" ]; then
    echo "❌ Nginx config directory not found: $CONFIG_DIR" >> "$TMPFILE"
    /home/ubuntu/scripts/send-ses.sh "❌ Nginx Check Failed ($HOST)" "$EMAIL" "$TMPFILE"
    rm -f "$TMPFILE"
    exit 1
fi

check_https() {
    local d=$1
    curl -s -I -L -o /dev/null -w "%{http_code}" --max-time 5 "https://$d" || echo "ERR"
}

for conf in "$CONFIG_DIR"/*; do
    [ -f "$conf" ] || continue

    sitename=$(basename "$conf")
    server_names=$(grep -oP '(?<=server_name\s)[^;]*' "$conf" | tr -s ' ')

    echo "🔧 Checking site config: $sitename" >> "$TMPFILE"

    if [ -z "$server_names" ]; then
        echo "      No server_name found in $sitename" >> "$TMPFILE"
        echo "" >> "$TMPFILE"
        continue
    fi

    for domain in $server_names; do
        [[ "$domain" =~ ^(_|\*|~|localhost|127\.|::1) ]] && continue

        # Skip password-protected domain
        if [[ "$domain" == "$IGNORE_DOMAIN" || "$domain" == "www.$IGNORE_DOMAIN" ]]; then
            echo "      Skipping $domain (password-protected)" >> "$TMPFILE"
            continue
        fi

        # Derive alternate www/bare domain
        if [[ "$domain" =~ ^www\. ]]; then
            alt_domain="${domain#www.}"
        else
            alt_domain="www.$domain"
        fi

        code1=$(check_https "$domain")
        code2=$(check_https "$alt_domain")

        if [[ "$code1" =~ ^(200|301|302|403)$ || "$code2" =~ ^(200|301|302|403)$ ]]; then
            echo "   ✅ $domain (or $alt_domain) is UP (HTTPS $code1 / $code2)" >> "$TMPFILE"
        else
            echo "   ❌ $domain (and $alt_domain) are DOWN (HTTPS $code1 / $code2)" >> "$TMPFILE"
            ((failed_count++))
        fi
    done

    echo "" >> "$TMPFILE"
done

# Determine subject and email policy
if [ "$failed_count" -eq 0 ]; then
    SUBJECT_PREFIX="✅"
    SEND_MAIL=false
    # Send once daily between 04:00–05:00
    if [ "$HOUR" -eq 4 ] && [ "$MIN" -ge 0 ] && [ "$MIN" -lt 15 ]; then
        SEND_MAIL=true
    fi
else
    SUBJECT_PREFIX="❌"
    SEND_MAIL=true
fi

SUBJECT="$SUBJECT_PREFIX Nginx HTTPS Site Status - $HOST - $DATE"

if [ "$SEND_MAIL" = true ]; then
    /home/ubuntu/scripts/send-ses.sh "$SUBJECT" "$EMAIL" "$TMPFILE"
else
    echo "🕒 All sites passed. No email sent (outside 04:00–05:00 window)." >> "$TMPFILE"
fi

# Cleanup
rm -f "$TMPFILE"

