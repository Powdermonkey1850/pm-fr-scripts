#!/bin/bash
# =========================================
# WordPress Database Backup Script
# =========================================
# DB Name: yif2025
# DB User: yif2025
# Creates a gzipped SQL dump and archives it as a .tar.gz
# Keeps backups for 72 hours (3 days)
# Logs all operations
# =========================================

# --- CONFIG ---
DB_NAME="yif2025"
DB_USER="yif2025"
DB_PASS="Rooklinkertook555!"
DB_HOST="localhost"

BACKUP_DIR="/home/ubuntu/backups/dev_baks"
LOG_FILE="$BACKUP_DIR/backup.log"
DATE=$(date +'%Y-%m-%d_%H-%M-%S')
SQL_FILE="${DB_NAME}_${DATE}.sql"
TAR_FILE="${DB_NAME}_${DATE}.tar.gz"

# --- PREP ---
mkdir -p "$BACKUP_DIR"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Starting backup..." >> "$LOG_FILE"

# --- BACKUP DATABASE ---
if mysqldump -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" > "$BACKUP_DIR/$SQL_FILE" 2>>"$LOG_FILE"; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] SQL dump created: $SQL_FILE" >> "$LOG_FILE"
else
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: Database dump failed!" >> "$LOG_FILE"
    exit 1
fi

# --- CREATE TAR.GZ ARCHIVE ---
cd "$BACKUP_DIR" || exit
if tar -czf "$TAR_FILE" "$SQL_FILE" 2>>"$LOG_FILE"; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Archive created: $TAR_FILE" >> "$LOG_FILE"
    rm -f "$SQL_FILE"
else
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: Archive creation failed!" >> "$LOG_FILE"
fi

# --- CLEANUP OLD BACKUPS (older than 72 hours = 4320 minutes) ---
find "$BACKUP_DIR" -type f -name "*.tar.gz" -mmin +4320 -delete
echo "[$(date +'%Y-%m-%d %H:%M:%S')] Removed backups older than 72 hours." >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

