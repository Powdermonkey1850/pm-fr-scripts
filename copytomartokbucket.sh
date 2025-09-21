#!/bin/bash
set -euo pipefail

# === Configuration ===
S3_BUCKET="martok-bucket"
REGION="eu-west-2"
AWS="/usr/local/bin/aws"

S3_PREFIX="manual-uploads"

# === Check args ===
if [ $# -ne 1 ]; then
    echo "Usage: $0 /path/to/local/file"
    exit 1
fi

LOCAL_FILE="$1"

if [ ! -f "$LOCAL_FILE" ]; then
    echo "❌ File not found: $LOCAL_FILE"
    exit 1
fi

BASENAME=$(basename "$LOCAL_FILE")
S3_PATH="s3://$S3_BUCKET/$S3_PREFIX/$BASENAME"

echo "📤 Uploading $LOCAL_FILE → $S3_PATH"

# Retry logic
retries=0
max_retries=3
until "$AWS" s3 cp "$LOCAL_FILE" "$S3_PATH" --region "$REGION"; do
    retries=$((retries + 1))
    if [ $retries -ge $max_retries ]; then
        echo "❌ Upload failed after $max_retries attempts"
        exit 1
    fi
    echo "🔁 Retry $retries after 5s..."
    sleep 5
done

echo "✅ Upload successful!"

