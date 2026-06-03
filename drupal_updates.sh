#!/bin/bash

BASE_DIR="/var/www"

AWS_REGION="eu-west-2"
MAIL_FROM="server@your-verified-domain.com"
MAIL_TO="patrick@powdermonkey.eu"

export COMPOSER_ALLOW_SUPERUSER=1

RUN_ID="$(date '+%Y%m%d-%H%M%S')"
TMP_DIR="/tmp/drupal-auto-update-$RUN_ID"
REPORT_FILE="$TMP_DIR/report.txt"
SES_JSON="$TMP_DIR/ses.json"

mkdir -p "$TMP_DIR"

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

TOTAL=0
SUCCESS=0
FAILED=0
SKIPPED=0
FAILURES=()
DETAILS=()

log() {
  local line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$line"
  DETAILS+=("$line")
}

run_cmd() {
  local description="$1"
  shift

  log "RUN: $description"

  local output
  output="$("$@" 2>&1)"
  local exit_code=$?

  DETAILS+=("$output")

  if [ "$exit_code" -eq 0 ]; then
    log "OK: $description"
  else
    log "FAIL: $description exit code $exit_code"
  fi

  return "$exit_code"
}

find_composer_root() {
  local start="$1"
  local current="$start"

  while [ "$current" != "/" ]; do
    if [ -f "$current/composer.json" ]; then
      echo "$current"
      return 0
    fi

    current="$(dirname "$current")"
  done

  return 1
}

fix_drush_permissions() {
  local root="$1"

  local paths=(
    "$root/vendor/drush/drush/drush"
    "$root/vendor/drush/drush/drush.php"
    "$root/vendor/bin/drush"
    "$root/vendor/bin/drush.php"
  )

  for path in "${paths[@]}"; do
    if [ -f "$path" ]; then
      $SUDO chmod +x "$path" 2>&1
      log "Drush executable fixed: $path"
    fi
  done
}

send_report_email() {
  local subject="$1"

  python3 - "$MAIL_FROM" "$MAIL_TO" "$subject" "$REPORT_FILE" "$SES_JSON" <<'PY'
import json
import sys
from pathlib import Path

mail_from, mail_to, subject, report_file, output_file = sys.argv[1:]

body = Path(report_file).read_text(errors="replace")

payload = {
    "FromEmailAddress": mail_from,
    "Destination": {
        "ToAddresses": [mail_to]
    },
    "Content": {
        "Simple": {
            "Subject": {
                "Data": subject,
                "Charset": "UTF-8"
            },
            "Body": {
                "Text": {
                    "Data": body,
                    "Charset": "UTF-8"
                }
            }
        }
    }
}

Path(output_file).write_text(json.dumps(payload, indent=2))
PY

  aws sesv2 send-email \
    --region "$AWS_REGION" \
    --cli-input-json "file://$SES_JSON"
}

update_site() {
  local drupal_php="$1"
  local drupal_root="${drupal_php%/core/lib/Drupal.php}"
  local composer_root
  local site
  local version
  local drush

  composer_root="$(find_composer_root "$drupal_root")"

  if [ -z "$composer_root" ] || [ ! -f "$composer_root/composer.json" ]; then
    log "SKIP: No composer.json found above $drupal_root"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi

  site="$(basename "$composer_root")"
  drush="$composer_root/vendor/drush/drush/drush"

  TOTAL=$((TOTAL + 1))

  version="$($SUDO grep "const VERSION" "$drupal_php" | sed -E "s/.*'([^']+)'.*/\1/")"

  log "========================================"
  log "SITE: $site"
  log "DRUPAL ROOT: $drupal_root"
  log "COMPOSER ROOT: $composer_root"
  log "VERSION: Drupal $version"
  log "DRUSH: $drush"
  log "----------------------------------------"

  cd "$composer_root" || {
    log "FAILED: Cannot cd into $composer_root"
    FAILURES+=("$site - cannot cd into composer root")
    FAILED=$((FAILED + 1))
    return 1
  }

  if ! run_cmd "$site composer update" $SUDO -E composer update; then
    FAILURES+=("$site - composer update failed")
    FAILED=$((FAILED + 1))
    return 1
  fi

  fix_drush_permissions "$composer_root"

  if [ ! -f "$drush" ]; then
    log "FAILED: Drush not found at $drush"
    FAILURES+=("$site - Drush not found")
    FAILED=$((FAILED + 1))
    return 1
  fi

  if ! run_cmd "$site drush updatedb" $SUDO -E ./vendor/drush/drush/drush updatedb -y; then
    FAILURES+=("$site - drush updatedb failed")
    FAILED=$((FAILED + 1))
    return 1
  fi

  if ! run_cmd "$site drush cache rebuild" $SUDO -E ./vendor/drush/drush/drush cr; then
    FAILURES+=("$site - drush cr failed")
    FAILED=$((FAILED + 1))
    return 1
  fi

  log "DONE: $site"
  SUCCESS=$((SUCCESS + 1))
  return 0
}

log "Starting Drupal auto-update run"
log "Base directory: $BASE_DIR"
log "Run ID: $RUN_ID"

while IFS= read -r drupal_php; do
  update_site "$drupal_php"
done < <($SUDO find "$BASE_DIR" -type f -path '*/core/lib/Drupal.php' 2>/dev/null)

{
  echo "Drupal update report"
  echo "===================="
  echo
  echo "Run ID: $RUN_ID"
  echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Server: $(hostname -f 2>/dev/null || hostname)"
  echo
  echo "Total Drupal sites processed: $TOTAL"
  echo "Successful: $SUCCESS"
  echo "Failed: $FAILED"
  echo "Skipped: $SKIPPED"
  echo

  if [ "$FAILED" -gt 0 ]; then
    echo "Failures:"
    for failure in "${FAILURES[@]}"; do
      echo "- $failure"
    done
    echo
  else
    echo "No failures detected."
    echo
  fi

  echo "Details:"
  echo "========"
  printf '%s\n' "${DETAILS[@]}"
} > "$REPORT_FILE"

if [ "$FAILED" -gt 0 ]; then
  SUBJECT="Drupal updates FAILED on $(hostname)"
else
  SUBJECT="Drupal updates OK on $(hostname)"
fi

if send_report_email "$SUBJECT"; then
  echo "Email report sent to $MAIL_TO"
else
  echo "FAILED: Could not send email report via AWS SES"
fi

rm -rf "$TMP_DIR"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi

exit 0
