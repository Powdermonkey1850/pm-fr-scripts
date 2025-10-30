#!/bin/bash
# ============================================================
# Server Resource Report (Martok Expert) — Status-Flag Version
# ============================================================

set -Eeuo pipefail

# --- Paths and constants ---
TMPDIR="/home/ubuntu/tmp"
REPORT="$TMPDIR/server_resource_report.txt"
DEBUGLOG="$TMPDIR/server_resource_debug.log"
SEND_SES="/home/ubuntu/scripts/send-ses.sh"

# --- Trap for fatal errors ---
trap 'echo "[FATAL] Script aborted at line $LINENO (exit code $?)" | tee -a "$DEBUGLOG" ; "$SEND_SES" "❌ Martok Server Report Failed" "patrick@powdermonkey.eu" "Failed at line $LINENO on $(hostname)"' ERR

# --- Ensure tmp dir exists ---
mkdir -p "$TMPDIR"
: > "$REPORT"
: > "$DEBUGLOG"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@" | tee -a "$REPORT" "$DEBUGLOG"; }
flush() { sync; sleep 0.2; }

log "📊 SERVER RESOURCE REPORT (Host: $(hostname))"
log "Date: $(date '+%Y-%m-%d %H:%M:%S')"
log "============================================================"
flush

# ============================================================
# 1) System Load
# ============================================================
LOAD1=$(/usr/bin/awk '{print $1}' /proc/loadavg)
log ""
log "➡ SYSTEM LOAD:"
/usr/bin/uptime | tee -a "$REPORT" "$DEBUGLOG" || true
flush

# ============================================================
# 2) CPU Usage
# ============================================================
log ""
log "➡ CPU USAGE (top 10 processes):"
/usr/bin/ps -eo pid,cmd,%cpu,%mem --sort=-%cpu | /usr/bin/head -n 11 | tee -a "$REPORT" "$DEBUGLOG" || true
flush

# Capture CPU idle for health check
CPU_IDLE=$(/usr/bin/top -bn1 | /usr/bin/awk '/Cpu/ {print $8}')

# ============================================================
# 3) Memory Usage
# ============================================================
log ""
log "➡ MEMORY USAGE:"
/usr/bin/free -h | tee -a "$REPORT" "$DEBUGLOG" || true

# Parse available memory (GiB)
MEM_AVAILABLE=$(free -g | awk '/Mem:/ {print $7}')

log ""
log "Top 10 processes by memory:"
/usr/bin/ps -eo pid,cmd,%mem,%cpu --sort=-%mem | /usr/bin/head -n 11 | tee -a "$REPORT" "$DEBUGLOG" || true
flush

# ============================================================
# 4) Disk Usage
# ============================================================
log ""
log "➡ DISK USAGE:"
/usr/bin/df -hT 2>/dev/null | tee -a "$REPORT" "$DEBUGLOG" || true
flush

# Get highest disk utilization (%)
DISK_MAX=$(df --output=pcent / | tail -1 | tr -dc '0-9')

# ============================================================
# 5) Network Connections
# ============================================================
log ""
log "➡ ACTIVE NETWORK CONNECTIONS (top 10 remote IPs):"
/usr/bin/ss -ntuH 2>/dev/null | /usr/bin/awk '{print $5}' | /usr/bin/cut -d: -f1 | \
/usr/bin/sort | /usr/bin/uniq -c | /usr/bin/sort -nr | /usr/bin/head -10 | \
/usr/bin/tee -a "$REPORT" "$DEBUGLOG" || true
flush

# ============================================================
# 6) Nginx Traffic Analysis
# ============================================================
log ""
log "➡ NGINX TRAFFIC BY SITE (last 10 minutes):"
TMPLOG="$TMPDIR/all_sites_access.log"
> "$TMPLOG"

for f in /var/log/nginx/*.access.log; do
  site=$(/usr/bin/basename "$f" .access.log)
  /usr/bin/awk -v s="$site" '{print s, $0}' "$f" >> "$TMPLOG" 2>>"$DEBUGLOG" || log "⚠️ Failed to read $f"
done

/usr/bin/awk -v d="$(date -d '10 minutes ago' '+%d/%b/%Y:%H:%M')" '$0 ~ d' "$TMPLOG" 2>>"$DEBUGLOG" | \
/usr/bin/awk '{print $1}' | /usr/bin/sort | /usr/bin/uniq -c | /usr/bin/sort -nr | /usr/bin/head -10 | \
/usr/bin/tee -a "$REPORT" "$DEBUGLOG" || true

log ""
log "➡ TOP 10 SOURCE IPS (all sites combined):"
/usr/bin/awk '{print $2}' "$TMPLOG" | /usr/bin/sort | /usr/bin/uniq -c | \
/usr/bin/sort -nr | /usr/bin/head -10 | /usr/bin/tee -a "$REPORT" "$DEBUGLOG" || true

rm -f "$TMPLOG" || log "⚠️ Could not remove $TMPLOG"
flush

# ============================================================
# 7) Health Check Logic & Status Flag
# ============================================================

# Defaults
STATUS="OK"
STATUS_ICON="✅"

# Limits for a t2.xlarge (4 vCPU, 16 GiB)
LOAD_LIMIT=4.0
CPU_IDLE_LIMIT=20.0
MEM_AVAILABLE_LIMIT=2      # GiB
DISK_USAGE_LIMIT=85        # percent

log ""
log "➡ HEALTH CHECK SUMMARY:"
log "Load (1min): $LOAD1 / Limit: $LOAD_LIMIT"
log "CPU idle: $CPU_IDLE% / Limit: >$CPU_IDLE_LIMIT%"
log "Mem available: ${MEM_AVAILABLE}Gi / Limit: >${MEM_AVAILABLE_LIMIT}Gi"
log "Max disk use: ${DISK_MAX}% / Limit: <${DISK_USAGE_LIMIT}%"
flush

FAIL=0
if (( $(echo "$LOAD1 > $LOAD_LIMIT" | /usr/bin/bc -l) )); then
  log "⚠️ LOAD above limit!"
  FAIL=1
fi
if (( $(echo "$CPU_IDLE < $CPU_IDLE_LIMIT" | /usr/bin/bc -l) )); then
  log "⚠️ CPU idle too low!"
  FAIL=1
fi
if (( MEM_AVAILABLE < MEM_AVAILABLE_LIMIT )); then
  log "⚠️ Memory available too low!"
  FAIL=1
fi
if (( DISK_MAX > DISK_USAGE_LIMIT )); then
  log "⚠️ Disk usage too high!"
  FAIL=1
fi

if (( FAIL == 1 )); then
  STATUS="WARNING"
  STATUS_ICON="❌"
fi

log "➡ SUMMARY STATUS: $STATUS"
flush

# ============================================================
# 8) EMAIL SECTION (conditional)
# ============================================================
SES_HELPER="/home/ubuntu/scripts/send-ses.sh"
EMAIL_TO="patrick@powdermonkey.eu"
EMAIL_SUBJECT="${STATUS_ICON} Server Resource Report — $(hostname)"
EMAIL_FILE="$REPORT"

# Determine if current time is between 05:00 and 05:20
HOUR=$(date +%H)
MINUTE=$(date +%M)
IN_MORNING_WINDOW=false

if [ "$HOUR" -eq 5 ] && [ "$MINUTE" -lt 15 ]; then
  IN_MORNING_WINDOW=true
fi

# Only send if there's an issue OR it's within 05:00–05:20
if [ "$STATUS" != "OK" ] || [ "$IN_MORNING_WINDOW" = true ]; then
  log ""
  log "➡ Sending final report email (Status=$STATUS, MorningWindow=$IN_MORNING_WINDOW)"
  if [ -x "$SES_HELPER" ]; then
    if "$SES_HELPER" "$EMAIL_SUBJECT" "$EMAIL_TO" "$EMAIL_FILE" >>"$DEBUGLOG" 2>&1; then
      log "✅ Email sent successfully"
    else
      RC=$?
      log "❌ Email send failed (exit code $RC)"
      "$SEND_SES" "❌ Server Resource Report Failed" "$EMAIL_TO" "Email step failed with exit code $RC on $(hostname)"
    fi
  else
    log "❌ SES helper not found or not executable: $SES_HELPER"
    "$SEND_SES" "❌ Server Resource Report Failed" "$EMAIL_TO" "SES helper missing or not executable on $(hostname)"
  fi
else
  log ""
  log "ℹ️  No issues detected and not within 05:00–05:20 — skipping email."
fi

flush
log ""
log "✅ Script completed successfully at $(date)"
exit 0

