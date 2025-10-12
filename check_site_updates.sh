#!/usr/bin/env bash
#
# WordPress Auto-Update + HTTP health-check + SES mail (uses working wrapper)
# Path: /home/ubuntu/scripts/check_site_updates.sh
#

set -euo pipefail
shopt -s nullglob

# --- Single-instance lock ---
LOCKFILE="/tmp/wp_auto_update.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "$(date '+%F %T') | Another instance is already running, exiting." >> /home/ubuntu/tmp/wp_cron.log
  exit 1
fi

# --- Config/paths ---
TMPDIR="/home/ubuntu/tmp"
DBDIR="/home/ubuntu/backups/wp-dbs"
TMPLOG="$TMPDIR/wp_update_$(date +%F_%H%M).log"
EMAIL="patrick@powdermonkey.eu"
SEND_SES="/home/ubuntu/scripts/send-ses.sh"
WPCLI="/usr/local/bin/wp"   # adjust if needed (check with: which wp)

mkdir -p "$TMPDIR" "$DBDIR"

# --- Logger ---
log() { echo -e "$(date '+%F %T') | $*" | tee -a "$TMPLOG"; }

# Do NOT delete TMPLOG before emails are sent
trap 'rm -f "$TMPLOG"' EXIT

log "⚙️  Starting WordPress Auto-Update Run"
log "=============================================="
log ""

abort_run=false

# --- Robust HTTP checker (no subshells, no grep/awk parsing issues) ---
test_url() {
  local url="$1"
  # GET request; follow redirects; quiet output; code only; sane timeouts; retry once
  local code
  code=$(curl -sSL --connect-timeout 5 --max-time 15 --retry 1 --retry-delay 1 \
                -o /dev/null -w "%{http_code}" "$url" || true)
  echo "$code"
}

for sitepath in /var/www/prod-*; do
  [[ -d "$sitepath" ]] || continue

  if [[ "$abort_run" == true ]]; then
    log "⏭️  Skipping remaining sites due to previous failure."
    break
  fi

  sitename=$(basename "$sitepath")
  cd "$sitepath" || continue

  if [[ -f "$sitepath/wp-config.php" ]]; then
    log "➡️  Updating $sitename ..."
    domain=${sitename#prod-}

    # Versions
    oldver=$(sudo -u www-data "$WPCLI" core version --path="$sitepath" 2>/dev/null || true)
    log "  • Current WP version: ${oldver:-unknown}"

    # --- DB backup (30s cap) ---
    DBFILE="$DBDIR/${sitename}_db_$(date +%F_%H%M).sql"
    dbuser=$(grep -m1 "DB_USER" "$sitepath/wp-config.php" | cut -d"'" -f4 || true)
    dbpass=$(grep -m1 "DB_PASSWORD" "$sitepath/wp-config.php" | cut -d"'" -f4 || true)
    dbname=$(grep -m1 "DB_NAME" "$sitepath/wp-config.php" | cut -d"'" -f4 || true)
    if [[ -n "${dbuser:-}" && -n "${dbpass:-}" && -n "${dbname:-}" ]]; then
      log "  • Backing up DB '$dbname' ..."
      timeout 30s mysqldump -u"$dbuser" -p"$dbpass" "$dbname" > "$DBFILE" 2>>"$TMPLOG" || log "  ⚠️  DB backup timed out or failed."
    else
      log "  ⚠️  Could not read DB credentials from wp-config.php; skipping DB backup."
    fi

    # --- Updates ---
    log "  • Updating core..."
    sudo -u www-data "$WPCLI" core update --path="$sitepath" 2>&1 | tee -a "$TMPLOG"

log "  • Checking plugins with updates available..."

# Manage these externally (skip in wp-cli)
SKIP_PLUGINS=("beehive-analytics" "postmark-approved-wordpress-plugin")

# Get list of slugs that report updates available
mapfile -t PLUGINS_TO_UPDATE < <(sudo -u www-data "$WPCLI" plugin list \
  --update=available --field=name --path="$sitepath" 2>/dev/null || true)

if [[ ${#PLUGINS_TO_UPDATE[@]} -eq 0 ]]; then
  log "  • No plugin updates available."
else
  for slug in "${PLUGINS_TO_UPDATE[@]}"; do
    # Skip known premium/externally managed plugins
    if printf '%s\0' "${SKIP_PLUGINS[@]}" | grep -Fzxq "$slug"; then
      log "  • Skipping $slug (managed externally)"
      continue
    fi
    log "  • Updating plugin: $slug ..."
    # Try update; if it fails (e.g., package not available), log and continue
    if ! sudo -u www-data "$WPCLI" plugin update "$slug" --path="$sitepath" 2>&1 | tee -a "$TMPLOG"; then
      log "  ⚠️  Plugin $slug update failed or not available (continuing)"
    fi
  done
fi

    log "  • Updating themes..."
    sudo -u www-data "$WPCLI" theme update --all --path="$sitepath" 2>&1 | tee -a "$TMPLOG"

    # Optional cache clear (WP Rocket)
    if sudo -u www-data "$WPCLI" plugin is-active wp-rocket --path="$sitepath" >/dev/null 2>&1; then
      log "  • Clearing cache (WP Rocket)..."
      sudo -u www-data "$WPCLI" rocket clean --path="$sitepath" 2>&1 | tee -a "$TMPLOG"
    fi

    newver=$(sudo -u www-data "$WPCLI" core version --path="$sitepath" 2>/dev/null || true)
    log "  ✅ Core version: ${oldver:-unknown} → ${newver:-unknown}"

    # --- HTTP health-check (non-www + www) ---
    log "  🌐 Checking site availability..."
    http_main=$(test_url "https://$domain")
    http_www=$(test_url "https://www.$domain")
    log "    → https://$domain        returned HTTP ${http_main:-N/A}"
    log "    → https://www.$domain    returned HTTP ${http_www:-N/A}"

    if [[ "$http_main" == "200" || "$http_www" == "200" ]]; then
      log "  ✅ Site responded OK (one variant reachable)"
    else
      log "  ❌ Site check FAILED (both variants unreachable)"
      log "🚨 Aborting update process due to failure."
      log "❗ Remaining sites skipped for safety."
      log "📍 Stopped at: $sitename"

      SUBJECT="❌ WP Auto-Update Aborted – $domain Failed"
      "$SEND_SES" "$SUBJECT" "$EMAIL" "$TMPLOG"
      abort_run=true
      break
    fi

    # Retention: keep DB dumps 7 days
    find "$DBDIR" -type f -name "*.sql" -mtime +7 -delete
    log ""

  else
    log "ℹ️  $sitename is not WordPress. Skipping."
  fi
done

log "=============================================="
if [[ "$abort_run" == true ]]; then
  log "⚠️  Update process aborted due to failure."
  SUBJECT="⚠️ WP Auto-Update Aborted (Partial Run)"
else
  log "✅ All WordPress sites updated successfully."
  SUBJECT="📋 WP Auto-Update Summary"
fi

log "📧 Sending summary email..."
"$SEND_SES" "$SUBJECT" "$EMAIL" "$TMPLOG"
log "✅ Finished at $(date)"

