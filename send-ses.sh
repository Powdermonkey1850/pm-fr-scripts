#!/bin/bash
set -euo pipefail

# === Config ===
REGION="eu-west-2"
EMAIL_FROM="patrick@powdermonkey.eu"

# === Args ===
SUBJECT="$1"       # Include ✅ for success, ❌ for failure
EMAIL_TO="$2"      # Comma-separated if multiple
BODY_ARG="${3:-}"  # Either inline text or file path

# === Body handling ===
if [ -n "$BODY_ARG" ] && [ -f "$BODY_ARG" ]; then
    EMAIL_BODY=$(cat "$BODY_ARG")
else
    EMAIL_BODY="$BODY_ARG"
fi

# === Send ===
echo "📧 Sending SES email: $SUBJECT"
/usr/local/bin/aws ses send-email \
  --region "$REGION" \
  --from "$EMAIL_FROM" \
  --destination "ToAddresses=$EMAIL_TO" \
  --message "Subject={Data='${SUBJECT}'},Body={Text={Data='${EMAIL_BODY}'}}"

if [ $? -eq 0 ]; then
    echo "✅ SES email sent to $EMAIL_TO"
else
    echo "❌ Failed to send SES email"
    exit 1
fi

