#!/bin/bash
set -euo pipefail

# For Manual use:
# /home/ubuntu/fs_bak.sh prod-ergsy.com

# === Configuration ===
DATE_FOLDER=$(date +"%Y-%m-%d")      # For S3 folder (readable)
TODAY=$(date +"%Y%m%d")             # For filenames (no dashes)
TIME_NOW=$(date +"%H%M")            # For filenames (no colon)
TIMESTAMP="$TODAY-$TIME_NOW"        # Combined suffix

SOURCE_DIR="/var/www"
TMP_DIR="/home/ubuntu/fs-backups"   # moved out of /tmp for more space
LOG_DIR="/home/ubuntu/logs"
LOG_FILE="$LOG_DIR/${DATE_FOLDER}.fs.log"

S3_BUCKET="martok-bucket"
S3_PREFIX="fs-baks/$DATE_FOLDER"

EMAIL_FROM="patrick@powdermonkey.eu"
EMAIL_TO="patrick@powdermonkey.eu"
REGION="eu-west-2"

SUBJECT="✅ Martok File System Backup Report – $DATE_FOLDER"
EMAIL_BODY=""
ERRORS=()

# === Ensure directories exist ===
mkdir -p "$TMP_DIR" "$LOG_DIR"

# === Redirect all output to log file (tailable) ===
exec > >(tee -a "$LOG_FILE") 2>&1

# === Cleanup trap on script exit ===
cleanup() {
    echo "🧹 Cleaning up any leftover temporary files..."
    rm -rf "$TMP_DIR"/*
}
trap cleanup EXIT

# === Start backup ===
echo "📁 Starting file system backup on $DATE_FOLDER at $TIME_NOW"
EMAIL_BODY+="Martok File system backup started on $DATE_FOLDER at $TIME_NOW\n\n"

cd "$SOURCE_DIR" || {
    ERR="❌ Cannot access $SOURCE_DIR"
    echo "$ERR"
    ERRORS+=("$ERR")
}

# === Determine target directories ===
if [ $# -gt 0 ]; then
    # Manual mode: user specified a folder
    TARGET_DIR="$SOURCE_DIR/$1"
    if [ -d "$TARGET_DIR" ]; then
        DIRS_TO_BACKUP=("$TARGET_DIR")
    else
        echo "❌ Specified directory $TARGET_DIR does not exist."
        exit 1
    fi
else
    # Cron mode: all prod* dirs
    DIRS_TO_BACKUP=($SOURCE_DIR/prod*/)
fi

# === Process directories ===
for full_path in "${DIRS_TO_BACKUP[@]}"; do
    [ -d "$full_path" ] || continue

    folder_name=$(basename "$full_path")
    archive_name="${folder_name}-${TIMESTAMP}.tar.gz"
    archive_path="${TMP_DIR}/${archive_name}"
    snapshot_dir="${TMP_DIR}/${folder_name}-snapshot"

    echo "📋 Creating snapshot for $folder_name → $snapshot_dir"
    rsync -a --delete \
      --exclude='.git' \
      --exclude='web/sites/default/files/css' \
      --exclude='web/sites/default/files/js' \
      --exclude='web/sites/default/files/php' \
      "$full_path" "$snapshot_dir" || {
        ERR="❌ Rsync failed for $folder_name"
        echo "$ERR"
        ERRORS+=("$ERR")
        continue
    }

    echo "📦 Archiving snapshot $folder_name → $archive_path"
    tar -czf "$archive_path" -C "$TMP_DIR" "$(basename "$snapshot_dir")" || {
        ERR="❌ Failed to archive $folder_name"
        echo "$ERR"
        ERRORS+=("$ERR")
        rm -rf "$snapshot_dir"
        continue
    }

    echo "  Uploading to s3://$S3_BUCKET/$S3_PREFIX/$archive_name"
    /usr/local/bin/aws s3 cp "$archive_path" "s3://$S3_BUCKET/$S3_PREFIX/$archive_name" --region "$REGION" && {
        echo "✅ Upload successful. Cleaning up..."
        rm -f "$archive_path"
        rm -rf "$snapshot_dir"
    } || {
        ERR="❌ Upload failed for $archive_name"
        echo "$ERR"
        ERRORS+=("$ERR")
        rm -rf "$snapshot_dir"
    }
done

# === Compose email body ===
if [ ${#ERRORS[@]} -eq 0 ]; then
    EMAIL_BODY+="All file system backups completed and uploaded to:\n"
    EMAIL_BODY+="s3://$S3_BUCKET/$S3_PREFIX/\n"
else
    SUBJECT="❌ File System Backup FAILED – $DATE_FOLDER"
    EMAIL_BODY+="Some errors occurred during file system backup:\n\n"
    for e in "${ERRORS[@]}"; do
        EMAIL_BODY+="$e\n"
    done
    EMAIL_BODY+="\nSee log: $LOG_FILE\n"
fi

EMAIL_BODY+="\nScript completed at $(date +"%H:%M:%S")"

# === Send Email via SES ===
echo "📧 Sending email notification via AWS SES..."
/usr/local/bin/aws ses send-email \
  --region "$REGION" \
  --from "$EMAIL_FROM" \
  --destination "ToAddresses=$EMAIL_TO" \
  --message "Subject={Data='${SUBJECT}'},Body={Text={Data='${EMAIL_BODY}'}}"

if [ $? -eq 0 ]; then
    echo "✅ Email sent to $EMAIL_TO"
else
    echo "❌ Failed to send email via SES"
fi

