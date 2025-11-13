#!/bin/bash
# =========================================
# WordPress Database Backup Script (collabdgtl)
# =========================================
# DB Name: collabdgtl
# DB User: collabdgtl
# Creates a gzipped SQL dump (in /home/ubuntu/tmp) and archives it to /home/ubuntu/backups/collabdgtl_baks
# Keeps backups for 72 hours (3 days)
# Logs all operations to backup.log
# Sends SES notifications on success/failure
# =========================================

set -euo pipefail

# --- CONFIG ---
DB_NAME="collabdgtl"
DB_USER="collabdgtl"
DB_PASS="Trinkerlocknift5541!"
DB_HOST="localhost"

BACKUP_DIR="/home/ubuntu/backups/collabdgtl_baks"
TMP_DIR="/home/ubuntu/tmp"
LOG_FILE="$BACKUP_DIR/backup.log"
DATE="$(date +'%Y-%m-%d_%H-%M-%S')"
SQL_FILE="${DB_NAME}_${DATE}.sql"
TAR_FILE="${DB_NAME}_${DATE}.tar.gz"
SQL_TMP="$TMP_DIR/$SQL_FILE"

SEND_SES="/home/ubuntu/scripts/send-ses.sh"
ALERT_TO="patrick@powdermonkey.eu"

# --- FUNCTIONS ---
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

cleanup_tmp() { rm -f "$SQL_TMP" 2>/dev/null || true; }

on_error() {
  local msg="ERROR: Backup failed. Check log: $LOG_FILE"
  log "$msg"
  cleanup_tmp
  "$SEND_SES" "❌ DB Backup Failed (collabdgtl)" "$ALERT_TO" "Error at $(date). $msg"
  exit 1
}
trap on_error ERR

# --- PREP ---
mkdir -p "$BACKUP_DIR" "$TMP_DIR"
log "Starting backup..."

# --- BACKUP DATABASE (dump to TMP) ---
if mysqldump -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" > "$SQL_TMP" 2>>"$LOG_FILE"; then
  log "SQL dump created: $SQL_FILE (in $TMP_DIR)"
else
  log "ERROR: Database dump failed!"
  exit 1
fi

# --- CREATE TAR.GZ ARCHIVE IN BACKUP_DIR ---
if tar -C "$TMP_DIR" -czf "$BACKUP_DIR/$TAR_FILE" "$SQL_FILE" 2>>"$LOG_FILE"; then
  log "Archive created: $TAR_FILE"
  cleanup_tmp
  log "Temp SQL removed"
else
  log "ERROR: Archive creation failed!"
  exit 1
fi

# --- CLEANUP OLD BACKUPS (older than 72 hours = 4320 minutes) ---
find "$BACKUP_DIR" -type f -name "*.tar.gz" -mmin +4320 -print -delete >> "$LOG_FILE" 2>&1
log "Removed backups older than 72 hours."

# --- NOTIFY SUCCESS ---
# "$SEND_SES" "✅ DB Backup OK (collabdgtl)" "$ALERT_TO" "Finished at $(date)
# Archive: $BACKUP_DIR/$TAR_FILE"

log "Backup finished."
echo "" >> "$LOG_FILE"

