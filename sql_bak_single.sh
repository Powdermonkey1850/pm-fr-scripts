#!/bin/bash
set -euo pipefail

# === Configuration ===
SITES_DIR="/var/www"
TMP_DIR="/home/ubuntu/tmp"
BACKUP_DIR="/tmp/sql-backups"
S3_BUCKET="martok-bucket"
REGION="eu-west-2"
AWS="/usr/local/bin/aws"
EMAIL="patrick@powdermonkey.eu"

DATESTAMP=$(date +"%Y%m%d-%H%M")
LOG="/home/ubuntu/logs/site-db-backup-${DATESTAMP}.log"

mkdir -p "$TMP_DIR" "$BACKUP_DIR" "$(dirname "$LOG")"

# === Check for sudo ===
if [ "$EUID" -ne 0 ]; then
  echo "❌ This script must be run with sudo."
  echo "   Example: sudo /home/ubuntu/scripts/site_db_backup.sh"
  exit 1
fi

echo "=== Martok Site Database Backup Utility ==="
echo

# === Step 1: List available sites ===
sites=($(ls -d ${SITES_DIR}/prod-* 2>/dev/null))
if [ ${#sites[@]} -eq 0 ]; then
  echo "❌ No sites found in $SITES_DIR"
  exit 1
fi

echo "Available sites:"
for i in "${!sites[@]}"; do
  echo "[$((i+1))] ${sites[$i]##*/}"
done

echo
read -rp "Select a site number: " choice

if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#sites[@]}" ]; then
  echo "❌ Invalid selection"
  exit 1
fi

SITE_PATH="${sites[$((choice-1))]}"
SITE_NAME=$(basename "$SITE_PATH")
echo "➡ Selected: $SITE_NAME"

# === Step 2: Detect CMS type ===
if [ -f "$SITE_PATH/wp-config.php" ]; then
  CMS="wordpress"
elif [ -f "$SITE_PATH/sites/default/settings.php" ]; then
  CMS="drupal"
else
  echo "❌ Could not detect CMS (no wp-config.php or settings.php)"
  exit 1
fi

echo "🧩 Detected CMS: $CMS"

# === Step 3: Extract DB credentials ===
if [ "$CMS" = "wordpress" ]; then
  DB_NAME=$(grep DB_NAME "$SITE_PATH/wp-config.php" | awk -F"'" '{print $4}')
  DB_USER=$(grep DB_USER "$SITE_PATH/wp-config.php" | awk -F"'" '{print $4}')
  DB_PASS=$(grep DB_PASSWORD "$SITE_PATH/wp-config.php" | awk -F"'" '{print $4}')
  DB_HOST=$(grep DB_HOST "$SITE_PATH/wp-config.php" | awk -F"'" '{print $4}')
elif [ "$CMS" = "drupal" ]; then
  DB_NAME=$(grep -E "database' =>" "$SITE_PATH/sites/default/settings.php" | awk -F"'" '{print $4}' | head -1)
  DB_USER=$(grep -E "username' =>" "$SITE_PATH/sites/default/settings.php" | awk -F"'" '{print $4}' | head -1)
  DB_PASS=$(grep -E "password' =>" "$SITE_PATH/sites/default/settings.php" | awk -F"'" '{print $4}' | head -1)
  DB_HOST=$(grep -E "host' =>" "$SITE_PATH/sites/default/settings.php" | awk -F"'" '{print $4}' | head -1)
fi

if [ -z "${DB_NAME:-}" ] || [ -z "${DB_USER:-}" ]; then
  echo "❌ Failed to extract DB credentials"
  exit 1
fi

echo "🔑 DB: $DB_NAME on $DB_HOST (user: $DB_USER)"

# === Step 4: Perform Backup ===
SQL_FILE="${TMP_DIR}/${SITE_NAME}_${DATESTAMP}.sql"
TAR_FILE="${BACKUP_DIR}/${SITE_NAME}_${DATESTAMP}.tar.gz"
S3_PATH="s3://${S3_BUCKET}/sql-baks/${SITE_NAME}_${DATESTAMP}.tar.gz"

echo "📦 Dumping database..."
mysqldump -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" --single-transaction --quick "$DB_NAME" > "$SQL_FILE"

echo "🗜️ Compressing..."
tar -czf "$TAR_FILE" -C "$TMP_DIR" "$(basename "$SQL_FILE")"
rm -f "$SQL_FILE"

echo "☁️ Uploading to $S3_PATH..."
if "$AWS" s3 cp "$TAR_FILE" "$S3_PATH" --region "$REGION"; then
  rm -f "$TAR_FILE"
  /home/ubuntu/scripts/send-ses.sh "✅ DB Backup OK – $SITE_NAME" "$EMAIL" \
    "Database $DB_NAME from $SITE_NAME uploaded to $S3_PATH at $(date)"
  echo "✅ Backup completed successfully."
else
  /home/ubuntu/scripts/send-ses.sh "❌ DB Backup FAILED – $SITE_NAME" "$EMAIL" \
    "Backup failed for $SITE_NAME at $(date)"
  echo "❌ Upload failed. Check logs."
  exit 1
fi

# === Cleanup ===
rm -f "$TMP_DIR"/*.sql "$TMP_DIR"/*.tar.gz 2>/dev/null || true

# === Summary ===
echo
echo "✅ Backup Summary:"
echo "  Site:       $SITE_NAME"
echo "  CMS:        $CMS"
echo "  S3 Path:    $S3_PATH"
echo "  Timestamp:  $DATESTAMP"
echo "  Log File:   $LOG"
echo
echo "Done."

