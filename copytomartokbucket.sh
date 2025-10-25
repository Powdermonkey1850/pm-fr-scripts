#!/bin/bash
set -euo pipefail

# === Configuration ===
S3_BUCKET="martok-bucket"
REGION="eu-west-2"
AWS="/usr/local/bin/aws"
S3_PREFIX="manual-uploads"

echo "📦 Welcome to Martok S3 uploader"

# === Ask for local file ===
read -rp "Enter the full path of the local file to upload: " LOCAL_FILE

if [ ! -f "$LOCAL_FILE" ]; then
    echo "❌ File not found: $LOCAL_FILE"
    exit 1
fi

# === Ask for destination folder ===
echo "Enter the destination folder within '$S3_BUCKET/$S3_PREFIX/' (leave empty for root):"
read -r SUBPATH

# Normalize input
SUBPATH=$(echo "$SUBPATH" | sed 's#^/*##; s#/*$##')

BASENAME=$(basename "$LOCAL_FILE")

# Build S3 destination path
if [ -n "$SUBPATH" ]; then
    S3_PATH="s3://$S3_BUCKET/$S3_PREFIX/$SUBPATH/$BASENAME"
else
    S3_PATH="s3://$S3_BUCKET/$S3_PREFIX/$BASENAME"
fi

echo "📤 Uploading '$LOCAL_FILE' → '$S3_PATH'"

# === Retry logic ===
retries=0
max_retries=3
until "$AWS" s3 cp "$LOCAL_FILE" "$S3_PATH" --region "$REGION"; do
    retries=$((retries + 1))
    if [ $retries -ge $max_retries ]; then
        echo "❌ Upload failed after $max_retries attempts"
        exit 1
    fi
    echo "🔁 Retry $retries after 5 seconds..."
    sleep 5
done

echo "✅ Upload successful!"

