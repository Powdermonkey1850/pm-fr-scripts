#!/bin/bash
# ============================================================
# fix_wp_cron.sh — Auto-manage system cron entries for all WP sites
# Layout: /var/www/prod-<site>/{wp-config.php, wp-cron.php}
# - Finds all WP installs
# - Ensures DISABLE_WP_CRON is set
# - (Re)writes a merged WP Cron block into ROOT crontab (no overwrite)
# - Backs up existing crontab every run
# - Uses absolute paths (cron won't expand aliases)
# ============================================================

set -euo pipefail

TMPDIR="/home/ubuntu/tmp"
mkdir -p "$TMPDIR"

TMPFILE="$TMPDIR/wp_cron_tasks.txt"
REPORT="$TMPDIR/wp_cron_report.txt"
CURCRON="$TMPDIR/crontab.current"
BACKUP="/home/ubuntu/tmp/root-crontab.backup.$(date +%F_%H%M%S)"

SEND_SES="/home/ubuntu/scripts/send-ses.sh"
EMAIL_TO="patrick@powdermonkey.eu"

# Clean temp files on exit
cleanup() {
  rm -f "$TMPFILE" "$CURCRON"
}
trap cleanup EXIT

: > "$TMPFILE"
: > "$REPORT"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@" | tee -a "$REPORT"
}

log "🧩 Starting WordPress cron fix script (safe merge mode)"

# Gather wp-config.php files (flat prod-* layout; up to 4 levels just in case)
mapfile -t WP_CONFIGS < <(find /var/www -maxdepth 4 -type f -name wp-config.php 2>/dev/null)

if [ ${#WP_CONFIGS[@]} -eq 0 ]; then
  log "❌ No wp-config.php files found under /var/www"
fi

added=0
skipped=0

for cfg in "${WP_CONFIGS[@]}"; do
  [ -f "$cfg" ] || continue

  site_dir="$(dirname "$cfg")"
  site_name="$(basename "$site_dir")"

  # Skip Drupal (has core/lib/Drupal dir)
  if [ -d "$site_dir/core/lib/Drupal" ]; then
    log "⚙️  Skipping Drupal site: $cfg"
    ((skipped++)) || true
    continue
  fi

  log "🔍 Found WordPress site: $site_name ($cfg)"

  # Ensure DISABLE_WP_CRON present
  if grep -q "DISABLE_WP_CRON" "$cfg"; then
    log "   ➡ wp-cron already disabled"
  else
    log "   ➕ Adding DISABLE_WP_CRON constant"
    # Try insert before the standard comment; fallback to append
    if ! sudo sed -i "/That's all, stop editing/i define('DISABLE_WP_CRON', true);" "$cfg"; then
      echo "define('DISABLE_WP_CRON', true);" | sudo tee -a "$cfg" >/dev/null
    fi
  fi

  # Cron file expected alongside wp-config.php (your layout confirms this)
  wp_cron_path="$site_dir/wp-cron.php"
  if [ -f "$wp_cron_path" ]; then
    # IMPORTANT: use absolute sudo path; cron won't expand aliases
    echo "*/30 * * * * /usr/bin/sudo -u www-data /usr/bin/php $wp_cron_path > /dev/null 2>&1" >> "$TMPFILE"
    log "   ✅ Queued cron line for $site_name ($wp_cron_path)"
    ((added++)) || true
  else
    log "   ⚠️  wp-cron.php not found in $site_dir — skipped"
    ((skipped++)) || true
  fi
done

log "📋 Prepared cron lines:"
if [ -s "$TMPFILE" ]; then
  sort -u -o "$TMPFILE" "$TMPFILE"
  cat "$TMPFILE" | tee -a "$REPORT"
else
  log "❌ No cron jobs were generated — aborting before crontab write"
  if [ -x "$SEND_SES" ]; then
    "$SEND_SES" "❌ WP Cron Fix Failed" "$EMAIL_TO" "$REPORT"
  fi
  exit 1
fi

# -------- SAFE MERGE INTO ROOT CRONTAB (never overwrite other jobs) --------
log "📦 Backing up current root crontab to: $BACKUP"
sudo crontab -u root -l > "$BACKUP" 2>/dev/null || true

log "🧮 Merging WP Cron block into root crontab"
sudo crontab -u root -l > "$CURCRON" 2>/dev/null || true
# Remove any existing block we manage
sed -i '/# WP Cron Fixes/,/# End WP Cron Fixes/d' "$CURCRON"
# Append fresh block with blank lines above & below
{
  echo ""
  echo "# WP Cron Fixes"
  cat "$TMPFILE"
  echo "# End WP Cron Fixes"
  echo ""
} >> "$CURCRON"

# Apply via stdin to avoid file/permission quirks
cat "$CURCRON" | sudo /usr/bin/crontab -u root -
log "✅ WP Cron block written to root crontab (merged, non-destructive)"

total=$(wc -l < "$TMPFILE" | awk '{print $1}')
log "📊 Summary: sites found=$((${#WP_CONFIGS[@]})), cron lines written=$total, skipped=$skipped"

# Email report (file body)
if [ -x "$SEND_SES" ]; then
  "$SEND_SES" "✅ WP Cron Fix Applied ($total jobs)" "$EMAIL_TO" "$REPORT"
fi

log "🎯 Completed at $(date)"
exit 0

