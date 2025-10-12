#!/bin/bash
# /home/ubuntu/scripts/server_security_check.sh
# Self-contained security audit + inline updates (notify-only)
# All binaries and script paths are hardcoded for root cron safety.

set -Eeuo pipefail
umask 027

# --- Standard PATH for cron (kept explicit anyway) ---
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

# --- Absolute paths to tools (for clarity and cron safety) ---
APT_GET="/usr/bin/apt-get"
CURL="/usr/bin/curl"
SS="/usr/sbin/ss"
GREP="/usr/bin/grep"
EGREP="/usr/bin/egrep"
AWK="/usr/bin/awk"
STAT="/usr/bin/stat"
FIND="/usr/bin/find"
PS="/usr/bin/ps"
TEE="/usr/bin/tee"
HEAD="/usr/bin/head"
SED="/usr/bin/sed"
WC="/usr/bin/wc"
SORT="/usr/bin/sort"
HOSTNAME_BIN="/bin/hostname"
DATE_BIN="/bin/date"
WHOAMI_BIN="/usr/bin/whoami"

# AWS CLI (only for SG checks, not for email)
AWS="/usr/local/bin/aws"

# --- Config (absolute paths) ---
HOSTNAME="$($HOSTNAME_BIN)"
DATE="$($DATE_BIN '+%Y-%m-%d %H:%M:%S')"
TMPDIR="/home/ubuntu/tmp"
REPORT="$TMPDIR/security_report.txt"
LOG_FILE="$TMPDIR/security_check.log"
EMAIL_TO="patrick@powdermonkey.eu"
EMAIL_FROM="security-check@$HOSTNAME"
REGION="eu-west-1"
SEND_SES="/home/ubuntu/scripts/send-ses.sh"

STATUS="OK"
REBOOT_REQUIRED="false"

# --- Ensure tmp dir exists ---
/bin/mkdir -p "$TMPDIR"

# --- Cleanup on exit (always remove temp files) ---
cleanup() {
  /bin/rm -f "$REPORT" "$LOG_FILE" 2>/dev/null || true
}
trap cleanup EXIT

# --- Require root ---
if [ "$EUID" -ne 0 ]; then
  echo "This script must run as root." >&2
  exit 3
fi

# --- Helper: status promotion ---
set_status() {
  case "$1" in
    CRITICAL) STATUS="CRITICAL" ;;
    WARNING)  [ "$STATUS" = "OK" ] && STATUS="WARNING" ;;
  esac
}

# --- Helper: log to report and logfile ---
log() {
  # allow multi-line input safely
  /usr/bin/printf "%s\n" "$1" | "$TEE" -a "$REPORT" >> "$LOG_FILE"
}

# --- Start report ---
: > "$REPORT"
: > "$LOG_FILE"
log "🔒 Security Check Report"
log "Host: $HOSTNAME"
log "Date: $DATE"
log "Running as: $($WHOAMI_BIN)"
log ""

# === 1) Pending security updates (inline updates, notify-only) ===
log "➡ Checking for pending security updates..."
if [ -x "$APT_GET" ]; then
  UPDATES=$("$APT_GET" -s upgrade 2>/dev/null | "$GREP" -i "^Inst" | "$GREP" -i security || true)
  if [ -n "$UPDATES" ]; then
    log "  Security updates available:"
    log "$UPDATES"
    set_status "WARNING"

    log "⚡ Applying security updates (notify-only, no auto-reboot)..."
    {
      echo "---- apt-get update ----"
      "$APT_GET" update
      echo

      echo "---- apt-get upgrade -y ----"
      "$APT_GET" upgrade -y
      echo

      echo "---- apt-get dist-upgrade -y ----"
      "$APT_GET" dist-upgrade -y
      echo

      echo "---- apt-get autoremove -y ----"
      "$APT_GET" autoremove -y
      echo
    } >> "$REPORT" 2>&1

    if [ -f /var/run/reboot-required ]; then
      REBOOT_REQUIRED="true"
      log "⚠️  Reboot required after updates."
    else
      log "✅ No reboot required."
    fi

    log "✅ Updates completed at $($DATE_BIN)"
  else
    log "✅ No pending security updates."
  fi
else
  log "  apt-get not found at $APT_GET (cannot check/apply updates)."
  set_status "WARNING"
fi
log ""

# === 2) AWS Security Group check (IMDSv2 + awscli) ===
log "➡ Checking AWS Security Groups for this instance..."
TOKEN=$("$CURL" -s -m 3 -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)

INSTANCE_ID=""
META_REGION=""
if [ -n "$TOKEN" ]; then
  INSTANCE_ID=$("$CURL" -s -m 3 -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-id || true)

  META_REGION=$("$CURL" -s -m 3 -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/placement/region || true)

  REGION="${META_REGION:-$REGION}"
else
  log "  Could not obtain IMDSv2 token (not running on EC2 or IMDS blocked?)."
fi

if [ -n "$INSTANCE_ID" ] && [ -x "$AWS" ]; then
  SG_IDS=$("$AWS" ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Reservations[].Instances[].SecurityGroups[].GroupId" \
    --output text 2>/dev/null || true)

  if [ -z "$SG_IDS" ]; then
    log "  No Security Groups found for instance $INSTANCE_ID"
    set_status "WARNING"
  else
    log "Instance Security Groups: $SG_IDS"

    for sg in $SG_IDS; do
      RULES=$("$AWS" ec2 describe-security-groups \
        --group-ids "$sg" \
        --region "$REGION" \
        --query "SecurityGroups[].IpPermissions" \
        --output json 2>/dev/null || true)

      if echo "$RULES" | "$GREP" -q '"FromPort": 22'; then
        if echo "$RULES" | "$GREP" -q '0.0.0.0/0'; then
          log "❌ SG $sg allows SSH (22/tcp) from 0.0.0.0/0 (worldwide)!"
          set_status "CRITICAL"
        else
          log "✅ SG $sg restricts SSH properly."
        fi
      fi

      if echo "$RULES" | "$GREP" -q '"FromPort": 3389'; then
        if echo "$RULES" | "$GREP" -q '0.0.0.0/0'; then
          log "❌ SG $sg allows RDP (3389/tcp) from 0.0.0.0/0!"
          set_status "CRITICAL"
        fi
      fi
    done
  fi
else
  if [ -z "$INSTANCE_ID" ]; then
    log "  Could not determine instance ID (not running in EC2?)."
  else
    log "  AWS CLI not found/executable at $AWS (skip SG checks)."
  fi
  set_status "WARNING"
fi
log ""

# === 3) SSH configuration ===
log "➡ Checking SSH configuration..."
if [ -f /etc/ssh/sshd_config ]; then
  if "$EGREP" -iq "^\s*PermitRootLogin\s+yes" /etc/ssh/sshd_config; then
    log "❌ Root login via SSH is ENABLED!"
    set_status "CRITICAL"
  else
    log "✅ Root login disabled."
  fi

  if "$EGREP" -iq "^\s*PasswordAuthentication\s+yes" /etc/ssh/sshd_config; then
    log "  SSH password login enabled (consider using keys only)."
    set_status "WARNING"
  else
    log "✅ SSH password login disabled."
  fi

  if "$EGREP" -iq "^\s*PermitEmptyPasswords\s+yes" /etc/ssh/sshd_config; then
    log "❌ SSH permits empty passwords!"
    set_status "CRITICAL"
  fi

  if "$EGREP" -iq "^\s*ChallengeResponseAuthentication\s+yes" /etc/ssh/sshd_config; then
    log "  Challenge-response auth enabled (verify configuration)."
    set_status "WARNING"
  fi
else
  log "  sshd_config not found."
  set_status "WARNING"
fi
log ""

# === 4) World-writable files (/ limited) ===
log "➡ Checking for world-writable files..."
WW=$("$FIND" / -xdev -not -path "/proc/*" -not -path "/sys/*" -not -path "/run/*" \
  -type f -perm -0002 2>/dev/null | "$HEAD" -n 20 || true)
if [ -n "$WW" ]; then
  log "  World-writable files found (first 20):"
  log "$WW"
  set_status "WARNING"
else
  log "✅ No world-writable files found."
fi

if [ -d /tmp ]; then
  STICKY=$("$STAT" -c '%A' /tmp 2>/dev/null || true)
  if [[ "$STICKY" != *t ]]; then
    log "❌ /tmp does not have sticky bit set!"
    set_status "CRITICAL"
  else
    log "✅ /tmp has sticky bit set."
  fi
fi
log ""

# === 5) UID 0 users ===
log "➡ Checking for multiple UID 0 users..."
UID0=$("$AWK" -F: '($3 == 0) {print $1}' /etc/passwd || true)
UID0_COUNT=$(printf "%s\n" "$UID0" | "$WC" -l)
if [ "$UID0_COUNT" -gt 1 ]; then
  log "❌ Multiple UID 0 users found:"
  log "$UID0"
  set_status "CRITICAL"
else
  log "✅ Only root has UID 0."
fi
log ""

# === 6) Listening services ===
log "➡ Checking listening network services..."
LISTEN_ALL=$("$SS" -H -tuln 2>/dev/null || true)
ADDRESSES=$(echo "$LISTEN_ALL" | "$AWK" '{print $5}')
OPEN=$(echo "$ADDRESSES" | "$GREP" -E "^(0\.0\.0\.0:|\[::\]:)" || true)

if [ -n "$OPEN" ]; then
  UNEXPECTED=$(echo "$OPEN" | "$GREP" -Ev ":(22|80|443)$" || true)
  if [ -n "$UNEXPECTED" ]; then
    log "❌ Services listening on all interfaces (check carefully):"
    log "$UNEXPECTED"
    set_status "WARNING"
  else
    log "✅ Only expected services (22/80/443) are listening on all interfaces."
  fi
else
  log "✅ No services are listening on all interfaces."
fi

if echo "$ADDRESSES" | "$GREP" -qE "^(0\.0\.0\.0:6081|\[::\]:6081)"; then
  log "❌ Varnish port 6081 is exposed on all interfaces!"
  set_status "CRITICAL"
elif echo "$ADDRESSES" | "$GREP" -q "^127\.0\.0\.1:6081$"; then
  log "✅ Varnish port 6081 is bound to localhost (safe)."
fi

if echo "$ADDRESSES" | "$GREP" -qE "^(0\.0\.0\.0:6082|\[::\]:6082)"; then
  log "❌ Varnish admin port 6082 is exposed! Restrict it to localhost only."
  set_status "CRITICAL"
elif echo "$ADDRESSES" | "$GREP" -q "^127\.0\.0\.1:6082$"; then
  log "✅ Varnish admin port 6082 is bound to localhost (safe)."
fi

if echo "$ADDRESSES" | "$GREP" -q "^127\.0\.0\.1:3306$"; then
  log "✅ MySQL (3306) is bound only to localhost (safe)."
fi

log ""
log "Listening sockets (short):"
log "$("$SS" -tulwn | "$HEAD" -n 50 | "$SED" 's/^/  /')"
log ""

# === 7) PHP 5.6 usage check ===
log "➡ Checking that no sites are using PHP 5.6..."
PHP56_SITES=$("$GREP" -R "php5\.6" /etc/nginx/sites-enabled/ 2>/dev/null | "$AWK" -F: '{print $1}' | "$SORT" -u || true)
if [ -n "$PHP56_SITES" ]; then
  log "❌ The following site configs are using PHP 5.6 (not allowed):"
  log "$PHP56_SITES"
  set_status "CRITICAL"
else
  log "✅ No sites are using PHP 5.6 in nginx configs."
fi

PHP56_RUNNING=$("$PS" -eo cmd | "$GREP" -E "php.?5\.6.*fpm" | "$GREP" -v grep || true)
if [ -n "$PHP56_RUNNING" ]; then
  log "❌ PHP 5.6-FPM process is running (should only exist for emergencies):"
  log "$PHP56_RUNNING"
  set_status "CRITICAL"
else
  log "✅ No PHP 5.6-FPM processes are running."
fi
log ""

# === Subject (with reboot hint) ===
case "$STATUS" in
  OK)       SUBJECT="✅ Security Check - $HOSTNAME ($DATE)" ;;
  WARNING)  SUBJECT="🟠 Security Check (Warnings) - $HOSTNAME ($DATE)" ;;
  CRITICAL) SUBJECT="❌ Security Check (CRITICAL) - $HOSTNAME ($DATE)" ;;
esac
if [ "$REBOOT_REQUIRED" = "true" ]; then
  SUBJECT="$SUBJECT — REBOOT REQUIRED"
  log "⚠️ REBOOT REQUIRED to complete updates."
  log ""
fi

# === Send Email via SES helper (absolute path) ===
if [ -x "$SEND_SES" ]; then
  "$SEND_SES" "$SUBJECT" "$EMAIL_TO" "$REPORT"
  if [ $? -eq 0 ]; then
    log "✅ Report emailed to $EMAIL_TO"
  else
    log "❌ Failed to send report via $SEND_SES"
    set_status "WARNING"
  fi
else
  log "❌ SES helper script not found/executable at $SEND_SES"
  set_status "WARNING"
fi

# === Exit code for monitoring ===
case "$STATUS" in
  OK) exit 0 ;;
  WARNING) exit 1 ;;
  CRITICAL) exit 2 ;;
esac

