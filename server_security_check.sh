#!/bin/bash
set -euo pipefail


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

HOSTNAME=$(hostname)
DATE=$(date +"%Y-%m-%d %H:%M:%S")
DATE_FILE=$(date +"%Y-%m-%d")

LOG_DIR="$HOME/logs"
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

log() {
    echo "$1" | tee -a "$REPORT" >> "$LOG_FILE"
}

# === Start Report ===
echo "🔒 Security Check Report" | tee "$REPORT" > "$LOG_FILE"
log "Host: $HOSTNAME"
log "Date: $DATE"
log "Running as: $(whoami)"
log ""

# === Security Checks ===

## 1. Pending security updates
log "➡ Checking for pending security updates..."
if command -v apt-get &>/dev/null; then
    UPDATES=$(apt-get -s upgrade | grep -i security || true)
    if [ -n "$UPDATES" ]; then
        log "⚠️ Security updates available:"
        log "$UPDATES"
        set_status "WARNING"
    else
        log "✅ No pending security updates."
    fi
else
    log "⚠️ apt-get not found (cannot check updates)."
    set_status "WARNING"
fi
log ""

## 2. AWS Security Group check
log "➡ Checking AWS Security Groups for this instance..."



# === AWS Metadata (IMDSv2) ===
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)

if [ -n "$TOKEN" ]; then
    INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/instance-id || true)

    META_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/placement/region || true)

    REGION="${META_REGION:-$REGION}"
else
    log "⚠️ Could not obtain IMDSv2 token (not running on EC2?)."
    INSTANCE_ID=""
fi



if [ -n "$INSTANCE_ID" ]; then
    SG_IDS=$($AWS ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$REGION" \
        --query "Reservations[].Instances[].SecurityGroups[].GroupId" \
        --output text)

    if [ -z "$SG_IDS" ]; then
        log "⚠️ No Security Groups found for instance $INSTANCE_ID"
        set_status "WARNING"
    else
        log "Instance Security Groups: $SG_IDS"

        for sg in $SG_IDS; do
            RULES=$($AWS ec2 describe-security-groups \
                --group-ids "$sg" \
                --region "$REGION" \
                --query "SecurityGroups[].IpPermissions" \
                --output json)

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
    log "⚠️ Could not determine instance ID (not running in EC2?)."
    set_status "WARNING"
fi
log ""

## 3. SSH configuration
log "➡ Checking SSH configuration..."
if [ -f /etc/ssh/sshd_config ]; then
    if grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config; then
        log "❌ Root login via SSH is ENABLED!"
        set_status "CRITICAL"
    else
        log "✅ Root login disabled."
    fi

    if grep -q "^PasswordAuthentication yes" /etc/ssh/sshd_config; then
        log "⚠️ SSH password login enabled (consider using keys only)."
        set_status "WARNING"
    else
        log "✅ SSH password login disabled."
    fi
else
    log "⚠️ sshd_config not found."
    set_status "WARNING"
fi
log ""

## 4. World-writable files
log "➡ Checking for world-writable files..."
WW=$(find / -xdev -type f -perm -0002 2>/dev/null | head -n 20)
if [ -n "$WW" ]; then
    log "⚠️ World-writable files found (showing first 20):"
    log "$WW"
    set_status "WARNING"
else
    log "✅ No world-writable files found."
fi
log ""

## 5. UID 0 users
log "➡ Checking for multiple UID 0 users..."
UID0=$(awk -F: '($3 == 0) {print $1}' /etc/passwd)
if [ "$(echo "$UID0" | wc -l)" -gt 1 ]; then
    log "❌ Multiple UID 0 users found:"
    log "$UID0"
    set_status "CRITICAL"
else
    log "✅ Only root has UID 0."
fi
log ""



## 6. Listening services
log "➡ Checking listening network services..."
OPEN=$(ss -tulwn | awk '$5 ~ /0\.0\.0\.0|:::/{print}')

if [ -n "$OPEN" ]; then
    # Exclude common/expected ports (22, 80, 443)
    UNEXPECTED=$(echo "$OPEN" | awk '!($5 ~ /:22$|:80$|:443$/)')

    if [ -n "$UNEXPECTED" ]; then
        log "❌ Unexpected services listening on all interfaces:"
        log "$UNEXPECTED"
        set_status "WARNING"
    else
        log "✅ Only expected services (22/80/443) are listening on all interfaces."
    fi
else
    log "✅ No services are listening on all interfaces."
fi
log ""


# === Determine final subject ===
case "$STATUS" in
    OK)
        SUBJECT="✅ Security Check – $HOSTNAME ($DATE)"
        ;;
    WARNING)
        SUBJECT="⚠️ Security Check (Warnings) – $HOSTNAME ($DATE)"
        ;;
    CRITICAL)
        SUBJECT="❌ Security Check (CRITICAL) – $HOSTNAME ($DATE)"
        ;;
esac

# === Send Email ===
BODY=$(cat "$REPORT")

$AWS ses send-email \
  --region "$REGION" \
  --from "$EMAIL_FROM" \
  --destination "ToAddresses=$EMAIL_TO" \
  --message "Subject={Data='${SUBJECT}'},Body={Text={Data='${BODY}'}}"

if [ $? -eq 0 ]; then
    log "✅ Report emailed to $EMAIL_TO"
else
    log "❌ Failed to send report via SES"
fi

# === Cleanup ===
rm -f "$REPORT"

