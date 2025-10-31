#!/bin/bash
set -euo pipefail

# Ensure cron has the right environment
export HOME="/home/ubuntu"
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

AWS="/usr/local/bin/aws"
S3_BUCKET="martok-bucket"
REGION="eu-west-2"

TMP_DIR="/home/ubuntu/tmp/backup_essentials"
EMAIL_SCRIPT="/home/ubuntu/scripts/send-ses.sh"
LOGFILE="/home/ubuntu/tmp/backup_essentials.log"

mkdir -p "$TMP_DIR"

# Timestamp for folder naming
TIMESTAMP=$(date +"%Y%m%d-%H%M")
BASE_PREFIX="essentials/$TIMESTAMP"

{
	echo "📂 Starting backup → S3 prefix: $BASE_PREFIX"

# Helper function to upload
upload_file() {
	local FILE="$1"
	local PREFIX="$2"
	local BASENAME
	BASENAME=$(basename "$FILE")
	local S3_PATH="s3://$S3_BUCKET/$PREFIX/$BASENAME"

	echo "➡️  Uploading $FILE → $S3_PATH"
	$AWS s3 cp "$FILE" "$S3_PATH" --region "$REGION"
}

# Files to back up (map: file → subfolder)
declare -A FILES_TO_BACKUP=(
["/home/ubuntu/.ssh/config"]="ssh-config"
["/home/ubuntu/.zshrc"]="zshrc"
["/home/ubuntu/.vimrc"]="vimrc"
["/home/ubuntu/.gitconfig"]="gitconfig"
)

# Backup dotfiles
for FILE in "${!FILES_TO_BACKUP[@]}"; do
	if [ -f "$FILE" ]; then
		SUBFOLDER="${FILES_TO_BACKUP[$FILE]}"
		upload_file "$FILE" "$BASE_PREFIX/$SUBFOLDER"
	else
		echo "⚠️ Skipping missing file: $FILE"
	fi
done

# Backup crontabs
echo "📂 Backing up crontabs..."
UBUNTU_CRON="$TMP_DIR/ubuntu-crontab.txt"
ROOT_CRON="$TMP_DIR/root-crontab.txt"

crontab -l -u ubuntu > "$UBUNTU_CRON" 2>/dev/null || echo "# no crontab for ubuntu" > "$UBUNTU_CRON"
sudo crontab -l -u root > "$ROOT_CRON" 2>/dev/null || echo "# no crontab for root" > "$ROOT_CRON"

upload_file "$UBUNTU_CRON" "$BASE_PREFIX/crontabs"
upload_file "$ROOT_CRON" "$BASE_PREFIX/crontabs"

# Backup scripts individually
echo "📂 Backing up individual scripts..."
if [ -d "/home/ubuntu/scripts" ]; then
	for SCRIPT_FILE in /home/ubuntu/scripts/*.sh; do
		if [ -f "$SCRIPT_FILE" ]; then
			upload_file "$SCRIPT_FILE" "$BASE_PREFIX/scripts/individual"
		fi
	done
fi

# Tarball of scripts directory
echo "📦 Creating tarball of scripts..."
if [ -d "/home/ubuntu/scripts" ]; then
	TARFILE="$TMP_DIR/scripts-$TIMESTAMP.tar.gz"
	tar -czf "$TARFILE" -C /home/ubuntu scripts
	upload_file "$TARFILE" "$BASE_PREFIX/scripts/archive"
	rm -f "$TARFILE"
fi



# Backup Nginx configuration
echo "📂 Backing up Nginx configuration..."
NGINX_TAR="$TMP_DIR/nginx-$TIMESTAMP.tar.gz"

# Dynamically include relevant nginx directories if they exist
NGINX_FILES=()
[[ -f /etc/nginx/nginx.conf ]] && NGINX_FILES+=("/etc/nginx/nginx.conf")
[[ -f /etc/nginx/mime.types ]] && NGINX_FILES+=("/etc/nginx/mime.types")
[[ -d /etc/nginx/sites-available ]] && NGINX_FILES+=("/etc/nginx/sites-available")
[[ -d /etc/nginx/sites-enabled ]] && NGINX_FILES+=("/etc/nginx/sites-enabled")
[[ -d /etc/nginx/conf.d ]] && NGINX_FILES+=("/etc/nginx/conf.d")
[[ -d /etc/nginx/includes ]] && NGINX_FILES+=("/etc/nginx/includes")
[[ -d /etc/nginx/snippets ]] && NGINX_FILES+=("/etc/nginx/snippets")
[[ -d /etc/letsencrypt ]] && NGINX_FILES+=("/etc/letsencrypt")

if [ ${#NGINX_FILES[@]} -gt 0 ]; then
	echo "   Found ${#NGINX_FILES[@]} nginx configuration sources to archive"
	tar -czf "$NGINX_TAR" "${NGINX_FILES[@]}"
	upload_file "$NGINX_TAR" "$BASE_PREFIX/nginx"
	rm -f "$NGINX_TAR"
else
	echo "  ⚠️ No Nginx configuration files found — skipping."
fi





# Cleanup tmp dir
rm -rf "$TMP_DIR"

echo "✅ Essentials backup finished at $(date)"
} | tee -a "$LOGFILE"

# Send email notification with log
$EMAIL_SCRIPT "✅ Essentials Backup Complete" "patrick@powdermonkey.eu" "$LOGFILE"

# Remove log after sending
rm -f "$LOGFILE"

