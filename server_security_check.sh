#!/bin/bash
# Server security check script
# - Does not exit mid-flow on most failures (so email always sent)
# - Flags services listening on all interfaces, but whitelists 22/80/443
# - Keeps consistent logs
# - Sends report via AWS SES (if aws CLI available)
#
# Usage: run as root (intended for root crontab)

set -uo pipefail   # NOTE: removed -e so script won't exit on first failure
IFS=$'\n\t'

# === Ensure script is run as root ===
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ This script must be run as root. Try again with: sudo $0"
    exit 1
fi

# === Configuration ===
REGION="eu-west-2"   # fallback region (will auto-detect from metadata)
EMAIL_FROM="patrick@powdermonkey.eu"
EMAIL_TO="patrick@powdermonkey.eu"
AWS="/usr/local/bin/aws"

HOSTNAME=$(hostname -f 2>/dev/null || hostname)
DATE=$(date +"%Y-%m-%d %H:%M:%S")
DATE_FILE=$(date +"%Y-%m-%d")

LOG_DIR="${HOME:-/root}/logs"
mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/security-$DATE_FILE.log"
REPORT="/tmp/security-check-$$.txt"
STATUS="OK"   # OK, WARNING, CRITICAL

# === Helpers ===
set_status() {
    local level="$1"
    case "$level" in
        CRITICAL)
            STATUS="CRITICAL"
            ;;
        WARNING)
            [ "$STATUS" = "OK" ] && STATUS="WARNING"
            ;;
    esac
}

# log: append to both report and log file
log() {
    # allow multi-line input safely
    printf "%s\n" "$1" | tee -a "$REPORT" >> "$LOG_FILE"
}

# safe_cmd: run a command but never allow non-zero to kill the script
# captures stdout/stderr and returns exit code
safe_cmd() {
    # Usage: out=$(safe_cmd command args...)
    "$@" 2>&1
    return $?
}

# === Start Report ===
: > "$REPORT"
log "🔒 Security Check Report"
log "Host: $HOSTNAME"
log "Date: $DATE"
log "Running as: $(whoami)"
log ""

# === Security Checks ===

## 1. Pending security updates
log "➡ Checking for pending security updates..."
if command -v apt-get &>/dev/null; then
    UPDATES=$(apt-get -s upgrade 2>/dev/null | grep -i "^Inst" | grep -i security || true)
    if [ -n "$UPDATES" ]; then
        log "  Security updates available:"
        log "$UPDATES"
        set_status "WARNING"
    else
        log "✅ No pending security updates."
    fi
else
    log "  apt-get not found (cannot check updates)."
    set_status "WARNING"
fi
log ""

## 2. AWS Security Group check
log "➡ Checking AWS Security Groups for this instance..."

TOKEN=$(curl -s -m 3 -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)

INSTANCE_ID=""
META_REGION=""
if [ -n "$TOKEN" ]; then
    INSTANCE_ID=$(curl -s -m 3 -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/instance-id || true)

    META_REGION=$(curl -s -m 3 -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/placement/region || true)

    REGION="${META_REGION:-$REGION}"
else
    log "  Could not obtain IMDSv2 token (not running on EC2 or IMDS blocked?)."
fi

if [ -n "$INSTANCE_ID" ] && [ -x "$AWS" ]; then
    SG_IDS=$($AWS ec2 describe-instances \
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
            RULES=$($AWS ec2 describe-security-groups \
                --group-ids "$sg" \
                --region "$REGION" \
                --query "SecurityGroups[].IpPermissions" \
                --output json 2>/dev/null || true)

            if echo "$RULES" | grep -q '"FromPort": 22'; then
                if echo "$RULES" | grep -q '0.0.0.0/0'; then
                    log "❌ SG $sg allows SSH (22/tcp) from 0.0.0.0/0 (worldwide)!"
                    set_status "CRITICAL"
                else
                    log "✅ SG $sg restricts SSH properly."
                fi
            fi

            if echo "$RULES" | grep -q '"FromPort": 3389'; then
                if echo "$RULES" | grep -q '0.0.0.0/0'; then
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
        log "  AWS CLI not found at $AWS (skip SG checks)."
    fi
    set_status "WARNING"
fi
log ""

## 3. SSH configuration
log "➡ Checking SSH configuration..."
if [ -f /etc/ssh/sshd_config ]; then
    if grep -Eiq "^\s*PermitRootLogin\s+yes" /etc/ssh/sshd_config; then
        log "❌ Root login via SSH is ENABLED!"
        set_status "CRITICAL"
    else
        log "✅ Root login disabled."
    fi

    if grep -Eiq "^\s*PasswordAuthentication\s+yes" /etc/ssh/sshd_config; then
        log "  SSH password login enabled (consider using keys only)."
        set_status "WARNING"
    else
        log "✅ SSH password login disabled."
    fi

    if grep -Eiq "^\s*PermitEmptyPasswords\s+yes" /etc/ssh/sshd_config; then
        log "❌ SSH permits empty passwords!"
        set_status "CRITICAL"
    fi

    if grep -Eiq "^\s*ChallengeResponseAuthentication\s+yes" /etc/ssh/sshd_config; then
        log "  Challenge-response auth enabled (PAM/other) — verify configuration."
        set_status "WARNING"
    fi
else
    log "  sshd_config not found."
    set_status "WARNING"
fi
log ""

## 4. World-writable files
log "➡ Checking for world-writable files..."
WW=$(find / -xdev -not -path "/proc/*" -not -path "/sys/*" -not -path "/run/*" -type f -perm -0002 2>/dev/null | head -n 20 || true)
if [ -n "$WW" ]; then
    log "  World-writable files found (showing first 20):"
    log "$WW"
    set_status "WARNING"
else
    log "✅ No world-writable files found."
fi

if [ -d /tmp ]; then
    STICKY=$(stat -c '%A' /tmp 2>/dev/null || true)
    if [[ "$STICKY" != *t ]]; then
        log "❌ /tmp does not appear to have the sticky bit set!"
        set_status "CRITICAL"
    else
        log "✅ /tmp has sticky bit set."
    fi
fi
log ""

## 5. UID 0 users
log "➡ Checking for multiple UID 0 users..."
UID0=$(awk -F: '($3 == 0) {print $1}' /etc/passwd || true)
UID0_COUNT=0
if [ -n "$UID0" ]; then
    UID0_COUNT=$(printf "%s\n" "$UID0" | wc -l)
fi

if [ "$UID0_COUNT" -gt 1 ]; then
    log "❌ Multiple UID 0 users found:"
    log "$UID0"
    set_status "CRITICAL"
else
    log "✅ Only root has UID 0."
fi
log ""

## 6. Listening services (robust parsing with ss -H)
log "➡ Checking listening network services..."
LISTEN_ALL=$(ss -H -tuln 2>/dev/null || true)
ADDRESSES=$(echo "$LISTEN_ALL" | awk '{print $5}')
OPEN=$(echo "$ADDRESSES" | grep -E "^(0\.0\.0\.0:|\[::\]:)" || true)

if [ -n "$OPEN" ]; then
    UNEXPECTED=$(echo "$OPEN" | grep -Ev ":(22|80|443)$" || true)
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

if echo "$ADDRESSES" | grep -qE "^(0\.0\.0\.0:6081|\[::\]:6081)"; then
    log "❌ Varnish port 6081 is exposed on all interfaces!"
    set_status "CRITICAL"
elif echo "$ADDRESSES" | grep -q "^127\.0\.0\.1:6081$"; then
    log "✅ Varnish port 6081 is bound to localhost (safe)."
fi

if echo "$ADDRESSES" | grep -qE "^(0\.0\.0\.0:6082|\[::\]:6082)"; then
    log "❌ Varnish admin port 6082 is exposed! Restrict it to localhost only."
    set_status "CRITICAL"
elif echo "$ADDRESSES" | grep -q "^127\.0\.0\.1:6082$"; then
    log "✅ Varnish admin port 6082 is bound to localhost (safe)."
fi

if echo "$ADDRESSES" | grep -q "^127\.0\.0\.1:3306$"; then
    log "✅ MySQL (3306) is bound only to localhost (safe)."
fi

log ""
log "Listening sockets (short):"
log "$(ss -tulwn | head -n 50 | sed 's/^/  /')"
log ""

MYSQL_LOCAL=$(echo "$ADDRESSES" | grep -E "^127\.0\.0\.1:3306$" || true)
if [ -n "$MYSQL_LOCAL" ]; then
    log "✅ MySQL (3306) is bound only to localhost (safe)."
fi

## 7. PHP 5.6 usage check
log "➡ Checking that no sites are using PHP 5.6..."

PHP56_SITES=$(grep -R "php5\.6" /etc/nginx/sites-enabled/ 2>/dev/null | awk -F: '{print $1}' | sort -u || true)
if [ -n "$PHP56_SITES" ]; then
    log "❌ The following site configs are using PHP 5.6 (not allowed):"
    log "$PHP56_SITES"
    set_status "CRITICAL"
else
    log "✅ No sites are using PHP 5.6 in nginx configs."
fi

PHP56_RUNNING=$(ps -eo cmd | grep -E "php.?5\.6.*fpm" | grep -v grep || true)
if [ -n "$PHP56_RUNNING" ]; then
    log "❌ PHP 5.6-FPM process is running (should only exist for emergencies):"
    log "$PHP56_RUNNING"
    set_status "CRITICAL"
else
    log "✅ No PHP 5.6-FPM processes are running."
fi
log ""

# === Determine final subject ===
case "$STATUS" in
    OK)
        SUBJECT="✅ Security Check - $HOSTNAME ($DATE)"
        ;;
    WARNING)
        SUBJECT="🟠 Security Check (Warnings) - $HOSTNAME ($DATE)"
        ;;
    CRITICAL)
        SUBJECT="❌ Security Check (CRITICAL) - $HOSTNAME ($DATE)"
        ;;
esac

# === Send Email ===
BODY=$(cat "$REPORT" || true)
if [ -x "$AWS" ]; then
    set +e
    $AWS ses send-email \
      --region "$REGION" \
      --from "$EMAIL_FROM" \
      --destination "ToAddresses=$EMAIL_TO" \
      --message "Subject={Data='${SUBJECT//\'/\'\\\'\'}'},Body={Text={Data='${BODY//\'/\'\\\'\'}'}}" \
      >/dev/null 2>&1
    SES_STATUS=$?
    set -e +o pipefail || true
    if [ "$SES_STATUS" -eq 0 ]; then
        log "✅ Report emailed to $EMAIL_TO"
    else
        log "❌ Failed to send report via SES (aws CLI exit code: $SES_STATUS)"
        set_status "WARNING"
    fi
else
    log "  AWS CLI not executable at $AWS — skipping SES email. Report will remain on host."
    set_status "WARNING"
fi

# === Cleanup ===
rm -f "$REPORT" || true

case "$STATUS" in
    OK) exit 0 ;;
    WARNING) exit 1 ;;
    CRITICAL) exit 2 ;;
esac

