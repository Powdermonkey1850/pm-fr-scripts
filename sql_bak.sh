#!/bin/bash
set -euo pipefail

# === Configuration ===
DATE_FOLDER=$(date +"%Y-%m-%d")      # For S3 folder (human-readable)
TODAY=$(date +"%Y%m%d")             # For filenames (no dashes)
TIME_NOW=$(date +"%H%M")            # For filenames (no colon)
TIMESTAMP="$TODAY-$TIME_NOW"        # Combined suffix

S3_BUCKET="martok-bucket"
S3_PREFIX="sql-baks/$DATE_FOLDER"
BACKUP_DIR="/tmp/sql-backups"
LOG_DIR="/home/ubuntu/logs"
LOG_FILE="$LOG_DIR/${DATE_FOLDER}.sql.log"
MY_CNF="/home/ubuntu/.my.cnf"

EMAIL_FROM="patrick@powdermonkey.eu"
EMAIL_TO="patrick@powdermonkey.eu"
REGION="eu-west-3"

SUBJECT="✅ Martok MariaDB Backup Report – $DATE_FOLDER"
EMAIL_BODY=""
ERRORS=()

# === Ensure directories exist ===
mkdir -p "$BACKUP_DIR" "$LOG_DIR"

# === Cleanup trap on exit ===
cleanup() {
    echo "🧹 Cleaning up temporary files..." | tee -a "$LOG_FILE"
    rm -rf "$BACKUP_DIR"/*
}
trap cleanup EXIT

# === Start Backup ===
echo "📦 Starting MariaDB backup at $TIMESTAMP..." | tee "$LOG_FILE"
EMAIL_BODY+="Martok MariaDB backup started at $TIMESTAMP\n\n"

# === Get list of user databases ===
databases=$(mysql --defaults-extra-file="$MY_CNF" -e "SHOW DATABASES;" \
  | grep -Ev "Database|information_schema|performance_schema|mysql|sys")

if [ -z "$databases" ]; then
    ERR="❌ No user databases found or connection failed."
    echo "$ERR" | tee -a "$LOG_FILE"
    EMAIL_BODY+="$ERR\n"
    SUBJECT="❌ MariaDB Backup FAILED – $DATE_FOLDER"
    ERRORS+=("$ERR")
else
    while IFS= read -r db; do
        SQL_NAME="${db}_${TIMESTAMP}.sql"
        TAR_NAME="${db}-${TIMESTAMP}.tar.gz"
        SQL_PATH="$BACKUP_DIR/$SQL_NAME"
        TAR_PATH="$BACKUP_DIR/$TAR_NAME"

        echo "📤 Dumping $db to $SQL_PATH" | tee -a "$LOG_FILE"
        if ! mysqldump --defaults-extra-file="$MY_CNF" --single-transaction --quick "$db" > "$SQL_PATH" 2>>"$LOG_FILE"; then
            ERR="❌ Failed to dump $db"
            echo "$ERR" | tee -a "$LOG_FILE"
            ERRORS+=("$ERR")
            continue
        fi

        echo "🗜️  Compressing $SQL_NAME to $TAR_NAME" | tee -a "$LOG_FILE"
        tar -czf "$TAR_PATH" -C "$BACKUP_DIR" "$SQL_NAME"
        rm -f "$SQL_PATH"

        # Verify archive
        if [ ! -s "$TAR_PATH" ]; then
            ERR="❌ Archive $TAR_NAME is empty or failed to create"
            echo "$ERR" | tee -a "$LOG_FILE"
            ERRORS+=("$ERR")
            continue
        elif ! gzip -t "$TAR_PATH" &>/dev/null; then
            ERR="❌ Archive $TAR_NAME is corrupt"
            echo "$ERR" | tee -a "$LOG_FILE"
            ERRORS+=("$ERR")
            continue
        fi

        echo "☁️ Uploading to s3://$S3_BUCKET/$S3_PREFIX/$TAR_NAME" | tee -a "$LOG_FILE"
        # Retry logic for S3 upload
        retries=0
        max_retries=3
        upload_success=0
        until aws s3 cp "$TAR_PATH" "s3://$S3_BUCKET/$S3_PREFIX/$TAR_NAME" --region "$REGION"; do
            retries=$((retries + 1))
            if [ $retries -ge $max_retries ]; then
                ERR="❌ Upload failed after $max_retries attempts for $TAR_NAME"
                echo "$ERR" | tee -a "$LOG_FILE"
                ERRORS+=("$ERR")
                break
            fi
            echo "🔁 Retry $retries for $TAR_NAME after 5 seconds..." | tee -a "$LOG_FILE"
            sleep 5
        done

        if [ $retries -lt $max_retries ]; then
            echo "✅ Upload successful. Deleting local archive." | tee -a "$LOG_FILE"
            rm -f "$TAR_PATH"
        fi

    done <<< "$databases"
fi

# === Final Summary ===
if [ ${#ERRORS[@]} -eq 0 ]; then
    EMAIL_BODY+="All databases backed up and uploaded to:\n"
    EMAIL_BODY+="s3://$S3_BUCKET/$S3_PREFIX/\n"
else
    SUBJECT="❌ MariaDB Backup FAILED – $DATE_FOLDER"
    EMAIL_BODY+="Some errors occurred during the backup:\n\n"
    for e in "${ERRORS[@]}"; do
        EMAIL_BODY+="$e\n"
    done
    EMAIL_BODY+="\nSee the full log at: $LOG_FILE\n"
fi

EMAIL_BODY+="\nBackup script completed at $(date +"%H:%M:%S")"

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

