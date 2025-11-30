#!/usr/bin/env bash
#
# Clear Nginx FastCGI Cache (Martok Server)
# Path: /home/ubuntu/scripts/clear_fastcgi_cache.sh

set -euo pipefail

# Auto-elevate to root if not already root
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

CACHE_DIR="/var/cache/nginx"
TMP_DIR="/home/ubuntu/tmp"
LOG_FILE="${TMP_DIR}/fastcgi_cache_clear_$$.log"

mkdir -p "$TMP_DIR"

echo "=== FastCGI Cache Clear Script Started ==="
echo "Cache directory: ${CACHE_DIR}"

echo "Timestamp: $(date)" >> "$LOG_FILE"
echo "Cache directory: ${CACHE_DIR}" >> "$LOG_FILE"

# Check cache directory
if [ ! -d "$CACHE_DIR" ]; then
    echo "❌ ERROR: Cache directory does not exist: ${CACHE_DIR}"
    rm -f "$LOG_FILE"
    exit 1
fi

echo "Clearing FastCGI cache (zero-downtime)..."
echo "Clearing FastCGI cache..." >> "$LOG_FILE"

# Zero-downtime delete
find "$CACHE_DIR" -type f -delete

echo "Reloading Nginx..."
echo "Reloading Nginx..." >> "$LOG_FILE"

/usr/bin/sudo /bin/systemctl reload nginx

echo "✅ FastCGI cache cleared successfully."
echo "Finished at: $(date)" >> "$LOG_FILE"

# Cleanup
rm -f "$LOG_FILE"

exit 0

