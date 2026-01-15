#!/bin/bash
# Zero out large Drupal debug file
# Cron-safe, permission-safe

FILE="/tmp/drupal_debug.txt"
TMP_DIR="/home/ubuntu/tmp"
LOG="$TMP_DIR/zero_drupal_debug.log"

# Ensure tmp + log exist with safe perms
mkdir -p "$TMP_DIR"
touch "$LOG"
chown root:root "$LOG"
chmod 644 "$LOG"

if [ -f "$FILE" ]; then
    /usr/bin/sudo -u www-data /usr/bin/truncate -s 0 "$FILE"

    if [ $? -eq 0 ]; then
        echo "$(date) - Truncated $FILE" >> "$LOG"

        /home/ubuntu/scripts/send-ses.sh \
            "🧹 Drupal debug file truncated" \
            "patrick@powdermonkey.eu" \
            "$FILE was zeroed at $(date)"
    else
        echo "$(date) - FAILED to truncate $FILE" >> "$LOG"

        /home/ubuntu/scripts/send-ses.sh \
            "❌ Drupal debug truncate failed" \
            "patrick@powdermonkey.eu" \
            "Permission error truncating $FILE at $(date)"
    fi
else
    echo "$(date) - File not found: $FILE" >> "$LOG"

    /home/ubuntu/scripts/send-ses.sh \
        "⚠️ Drupal debug file missing" \
        "patrick@powdermonkey.eu" \
        "$FILE not found at $(date)"
fi

# Rotate log if >1MB
if [ "$(/usr/bin/stat -c%s "$LOG")" -gt 1048576 ]; then
    : > "$LOG"
fi

