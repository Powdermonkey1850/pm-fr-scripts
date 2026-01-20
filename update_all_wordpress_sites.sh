#!/bin/bash

set -u  # allow per-site failures

WWW_ROOT="/var/www"
WP_CLI="/usr/local/bin/wp"
SUDOW="/usr/bin/sudo -u www-data"
TMP_DIR="/home/ubuntu/tmp"

AWS_CLI="/usr/bin/aws"
SES_FROM="patrick@powdermonkey.eu"
SES_TO="patrick@powdermonkey.eu"
SES_REGION="eu-west-1"

START_TIME="$(date)"
HOSTNAME="$(hostname)"
REPORT_FILE="$TMP_DIR/wp_update_report_$(date +%Y%m%d_%H%M%S).txt"

mkdir -p "$TMP_DIR"

# Detect interactive shell (manual run) vs cron
if [ -t 1 ]; then
    exec > >(tee -a "$REPORT_FILE") 2>&1
else
    exec >> "$REPORT_FILE" 2>&1
fi

echo "=================================================="
echo "WordPress Bulk Update Report"
echo "Host: $HOSTNAME"
echo "Started: $START_TIME"
echo "Running as user: $(whoami)"
echo "=================================================="
echo

for SITE in "$WWW_ROOT"/prod-*; do
    [ -d "$SITE" ] || continue

    echo "--------------------------------------------------"
    echo "Site: $SITE"
    echo "Time: $(date)"
    echo

    # WordPress detection
    if [ ! -f "$SITE/wp-config.php" ] || [ ! -d "$SITE/wp-content" ]; then
        echo "Not a WordPress site – skipped."
        echo
        continue
    fi

    if ! $SUDOW $WP_CLI --path="$SITE" core is-installed; then
        echo "WP-CLI reports WordPress not installed – skipped."
        echo
        continue
    fi

    echo "Updating WordPress core..."
    if ! $SUDOW $WP_CLI --path="$SITE" core update; then
        echo "❌ Core update FAILED"
    fi
    echo

    echo "Updating plugins..."
    if ! $SUDOW $WP_CLI --path="$SITE" plugin update --all; then
        echo "❌ Plugin update FAILED"
    fi
    echo

    echo "Updating themes..."
    if ! $SUDOW $WP_CLI --path="$SITE" theme update --all; then
        echo "❌ Theme update FAILED"
    fi
    echo

    echo "✔ Finished site: $SITE"
    echo
done

END_TIME="$(date)"

echo "=================================================="
echo "Finished: $END_TIME"
echo "=================================================="

# ---------- Send SES email directly ----------
SUBJECT="📊 WordPress Update Report on $HOSTNAME"
BODY_TEXT="$(cat "$REPORT_FILE")"

$AWS_CLI ses send-email \
    --region "$SES_REGION" \
    --from "$SES_FROM" \
    --destination "ToAddresses=$SES_TO" \
    --message "Subject={Data=$SUBJECT},Body={Text={Data=$BODY_TEXT}}"

# Cleanup
rm -f "$REPORT_FILE"

