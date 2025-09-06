#!/bin/bash

# === Configuration ===
DATE_FOLDER=$(date +"%Y-%m-%d")      # For S3 folder (readable)
TODAY=$(date +"%Y%m%d")             # For filenames (no dashes)
TIME_NOW=$(date +"%H%M")            # For filenames (no colon)
TIMESTAMP="$TODAY-$TIME_NOW"        # Combined suffix

SOURCE_DIR="/var/www"
TMP_DIR="/tmp/fs-backups"
LOG_DIR="/home/ubuntu/logs"
LOG_FILE="$LOG_DIR/${DATE_FOLDER}.fs.log"

S3_BUCKET="pm-fr-bucket"
S3_PREFIX="fs-baks/$DATE_FOLDER"

EMAIL_FROM="patrick@powdermonkey.eu"
EMAIL_TO="patrick@powdermonkey.eu"
REGION="eu-west-3"

SUBJECT="✅ File System Backup Report – $DATE_FOLDER"
EMAIL_BODY=""
ERRORS=()

# === Ensure directories exist ===
mkdir -p "$TMP_DIR" "$LOG_DIR"

# === Start backup ===
echo "📁 Starting file system backup on $DATE_FOLDER at $TIME_NOW" | tee "$LOG_FILE"
EMAIL_BODY+="File system backup started on $DATE_FOLDER at $TIME_NOW\n\n"

cd "$SOURCE_DIR" || {
    ERR="❌ Cannot access $SOURCE_DIR"
    echo "$ERR" | tee -a "$LOG_FILE"
    ERRORS+=("$ERR")
}

# === Process each prod* directory ===
for full_path in "$SOURCE_DIR"/prod*/; do
    [ -d "$full_path" ] || continue

    folder_name=$(basename "$full_path")
    archive_name="${folder_name}-${TIMESTAMP}.tar.gz"
    archive_path="${TMP_DIR}/${archive_name}"

    echo "📦 Archiving $folder_name → $archive_path" | tee -a "$LOG_FILE"
    tar -czf "$archive_path" "$folder_name"

    if [ $? -ne 0 ]; then
        ERR="❌ Failed to archive $folder_name"
        echo "$ERR" | tee -a "$LOG_FILE"
        ERRORS+=("$ERR")
        continue
    fi

    echo "☁️  Uploading to s3://$S3_BUCKET/$S3_PREFIX/$archive_name" | tee -a "$LOG_FILE"
    aws s3 cp "$archive_path" "s3://$S3_BUCKET/$S3_PREFIX/$archive_name" --region "$REGION"

    if [ $? -eq 0 ]; then
        echo "✅ Upload successful. Deleting local archive." | tee -a "$LOG_FILE"
        rm -f "$archive_path"
    else
        ERR="❌ Upload failed for $archive_name"
        echo "$ERR" | tee -a "$LOG_FILE"
        ERRORS+=("$ERR")
    fi
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
echo "📧 Sending email notification via AWS SES..." | tee -a "$LOG_FILE"
aws ses send-email \
  --region "$REGION" \
  --from "$EMAIL_FROM" \
  --destination "ToAddresses=$EMAIL_TO" \
  --message "Subject={Data='${SUBJECT}'},Body={Text={Data='${EMAIL_BODY}'}}"

if [ $? -eq 0 ]; then
    echo "✅ Email sent to $EMAIL_TO" | tee -a "$LOG_FILE"
else
    echo "❌ Failed to send email via SES" | tee -a "$LOG_FILE"
fi

