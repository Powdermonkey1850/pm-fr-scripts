#!/bin/bash

# === Configuration ===
DATE_FOLDER=$(date +"%Y-%m-%d")      # For S3 folder (human-readable)
TODAY=$(date +"%Y%m%d")             # For filenames (no dashes)
TIME_NOW=$(date +"%H%M")            # For filenames (no colon)
TIMESTAMP="$TODAY-$TIME_NOW"        # Combined suffix
S3_BUCKET="pm-fr-bucket"
S3_PREFIX="sql-baks/$DATE_FOLDER"
BACKUP_DIR="/tmp/sql-backups"
LOG_DIR="/home/ubuntu/logs"
LOG_FILE="$LOG_DIR/${DATE_FOLDER}.sql.log"
MY_CNF="/home/ubuntu/.my.cnf"
EMAIL_FROM="patrick@powdermonkey.eu"
EMAIL_TO="patrick@powdermonkey.eu"
REGION="eu-west-3"
SUBJECT="✅ MariaDB Backup Report – $DATE_FOLDER"
EMAIL_BODY=""
ERRORS=()

# === Setup ===
mkdir -p "$BACKUP_DIR" "$LOG_DIR"

echo "📦 Starting MariaDB backup at $TIMESTAMP..." | tee "$LOG_FILE"
EMAIL_BODY+="MariaDB backup started at $TIMESTAMP\n\n"

# === Get list of databases ===
databases=$(mysql --defaults-extra-file="$MY_CNF" -e "SHOW DATABASES;" \
  | grep -Ev "Database|information_schema|performance_schema|mysql|sys")

if [ -z "$databases" ]; then
    ERR="❌ No user databases found or connection failed."
    echo "$ERR" | tee -a "$LOG_FILE"
    EMAIL_BODY+="$ERR\n"
    SUBJECT="❌ MariaDB Backup FAILED – $DATE_FOLDER"
    ERRORS+=("$ERR")
else
    # === Process each database ===
    while IFS= read -r db; do
        SQL_NAME="${db}_${TIMESTAMP}.sql"
        TAR_NAME="${db}-${TIMESTAMP}.tar.gz"
        SQL_PATH="$BACKUP_DIR/$SQL_NAME"
        TAR_PATH="$BACKUP_DIR/$TAR_NAME"

        echo "📤 Dumping $db to $SQL_PATH" | tee -a "$LOG_FILE"
        if ! mysqldump --defaults-extra-file="$MY_CNF" "$db" > "$SQL_PATH" 2>>"$LOG_FILE"; then
            ERR="❌ Failed to dump $db"
            echo "$ERR" | tee -a "$LOG_FILE"
            ERRORS+=("$ERR")
            continue
        fi

        echo "🗜️  Compressing $SQL_NAME to $TAR_NAME" | tee -a "$LOG_FILE"
        tar -czf "$TAR_PATH" -C "$BACKUP_DIR" "$SQL_NAME"
        rm -f "$SQL_PATH"

        if [ ! -s "$TAR_PATH" ]; then
            ERR="❌ Archive $TAR_NAME is empty or failed to create"
            echo "$ERR" | tee -a "$LOG_FILE"
            ERRORS+=("$ERR")
            continue
        fi

        echo "☁️  Uploading to s3://$S3_BUCKET/$S3_PREFIX/$TAR_NAME" | tee -a "$LOG_FILE"
        aws s3 cp "$TAR_PATH" "s3://$S3_BUCKET/$S3_PREFIX/$TAR_NAME" --region "$REGION"

        if [ $? -eq 0 ]; then
            echo "✅ Upload successful. Deleting local archive." | tee -a "$LOG_FILE"
            rm -f "$TAR_PATH"
        else
            ERR="❌ Upload failed for $TAR_NAME"
            echo "$ERR" | tee -a "$LOG_FILE"
            ERRORS+=("$ERR")
        fi
    done <<< "$databases"
fi

# === Final Summary ===
if [ ${#ERRORS[@]} -eq 0 ]; then
    EMAIL_BODY+="All databases backed up and uploaded to s3://$S3_BUCKET/$S3_PREFIX/\n"
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

