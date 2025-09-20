#!/bin/bash
set -euo pipefail

# === Config ===
REGION="eu-west-2"
EMAIL_FROM="patrick@powdermonkey.eu"
EMAIL_TO="patrick@powdermonkey.eu"
SUBJECT="🔧 SES Test Email"
EMAIL_BODY="This is a test email sent using AWS SES from the backup script creds.\n\nTime: $(date)"

# === Send Email via SES ===
echo "📧 Sending SES test email..."
/usr/local/bin/aws ses send-email \
  --region "$REGION" \
  --from "$EMAIL_FROM" \
  --destination "ToAddresses=$EMAIL_TO" \
  --message "Subject={Data='${SUBJECT}'},Body={Text={Data='${EMAIL_BODY}'}}"

if [ $? -eq 0 ]; then
    echo "✅ Test email sent to $EMAIL_TO"
else
    echo "❌ Failed to send test email via SES"
fi


