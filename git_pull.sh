#!/usr/bin/env bash
#
# /home/ubuntu/scripts/git_pull.sh
# Safely pull updates and enforce production Drupal settings.

set -euo pipefail

DEBUG_SEP="────────────────────────────────────────"

echo "$DEBUG_SEP"
echo "🚀 git_pull.sh started at $(date)"
echo "   Running as user: $(whoami)"
echo "   Shell: $SHELL"
echo "   PWD: $(pwd)"
echo "$DEBUG_SEP"

# --- FIND GIT ROOT ---
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)

echo "🔍 Git root detection:"
echo "   REPO_ROOT='$REPO_ROOT'"

if [[ -z "$REPO_ROOT" ]]; then
  echo "❌ Not inside a Git repository - aborted at $(date)"
  exit 1
fi

echo "✅ Git repository root: $REPO_ROOT"

# Set once DRUPAL_ROOT is known; the EXIT trap uses it to recreate asset dirs
# even if the script exits early before detection.
DRUPAL_SITES_FILES=""

# --- GUARANTEE OWNERSHIP RESTORATION ---
restore_ownership() {
  echo "$DEBUG_SEP"
  echo "🔁 EXIT TRAP: restore_ownership() firing at $(date)"
  echo "   DRUPAL_SITES_FILES='$DRUPAL_SITES_FILES'"
  local files_dir="${DRUPAL_SITES_FILES:-$REPO_ROOT/web/sites/default/files}"
  echo "   Using files_dir='$files_dir'"
  mkdir -p "$files_dir/css" "$files_dir/js"
  echo "   mkdir -p css/ js/ done"
  sudo chown -R www-data:www-data "$REPO_ROOT"
  echo "   chown -R www-data:www-data $REPO_ROOT done"
  echo "   Final css/ stat: $(stat -c '%U:%G mode=%a' "$files_dir/css" 2>/dev/null || echo 'stat failed')"
  echo "   Final js/  stat: $(stat -c '%U:%G mode=%a' "$files_dir/js"  2>/dev/null || echo 'stat failed')"
  echo "🔁 EXIT TRAP complete"
  echo "$DEBUG_SEP"
}
trap restore_ownership EXIT

# --- CHANGE OWNERSHIP TO UBUNTU ---
echo "$DEBUG_SEP"
echo "🧩 Changing ownership to ubuntu..."
echo "   Before: $(stat -c '%U:%G' "$REPO_ROOT")"
sudo chown -R ubuntu:ubuntu "$REPO_ROOT"
echo "   After:  $(stat -c '%U:%G' "$REPO_ROOT")"

# --- PERFORM GIT PULL ---
echo "$DEBUG_SEP"
cd "$REPO_ROOT"
echo "   Fetching all remotes (including new branches)..."
git fetch --all --prune
echo "   Executing git pull..."
git pull --ff-only
echo "✅ Git pull completed successfully."
echo "   HEAD is now: $(git log -1 --oneline)"

# --- DETECT DRUPAL ROOT ---
echo "$DEBUG_SEP"
echo "🔎 Detecting Drupal root..."
echo "   Checking $REPO_ROOT/core/lib/Drupal.php ... $([ -f "$REPO_ROOT/core/lib/Drupal.php" ] && echo 'EXISTS' || echo 'not found')"
echo "   Checking $REPO_ROOT/web/core/lib/Drupal.php ... $([ -f "$REPO_ROOT/web/core/lib/Drupal.php" ] && echo 'EXISTS' || echo 'not found')"

DRUPAL_ROOT=""

if [[ -f "$REPO_ROOT/core/lib/Drupal.php" ]]; then
  DRUPAL_ROOT="$REPO_ROOT"
elif [[ -f "$REPO_ROOT/web/core/lib/Drupal.php" ]]; then
  DRUPAL_ROOT="$REPO_ROOT/web"
fi

if [[ -z "$DRUPAL_ROOT" ]]; then
  echo "   Not a Drupal site. Skipping Drupal tasks."
  exit 0
fi

echo "🧠 Drupal site detected at: $DRUPAL_ROOT"
DRUPAL_SITES_FILES="$DRUPAL_ROOT/sites/default/files"
echo "   DRUPAL_SITES_FILES='$DRUPAL_SITES_FILES'"
echo "   files/ exists: $([ -d "$DRUPAL_SITES_FILES" ] && echo 'YES' || echo 'NO')"
echo "   files/ stat:   $(stat -c '%U:%G mode=%a' "$DRUPAL_SITES_FILES" 2>/dev/null || echo 'stat failed')"
echo "   css/ exists:   $([ -d "$DRUPAL_SITES_FILES/css" ] && echo 'YES' || echo 'NO')"
echo "   js/  exists:   $([ -d "$DRUPAL_SITES_FILES/js"  ] && echo 'YES' || echo 'NO')"

# --- DRUSH ---
echo "$DEBUG_SEP"
DRUSH_BIN="$REPO_ROOT/vendor/drush/drush/drush"
echo "🔎 Drush check:"
echo "   DRUSH_BIN='$DRUSH_BIN'"
echo "   Exists:     $([ -f "$DRUSH_BIN" ] && echo 'YES' || echo 'NO')"
echo "   Executable: $([ -x "$DRUSH_BIN" ] && echo 'YES' || echo 'NO')"

if [[ ! -x "$DRUSH_BIN" ]]; then
  echo "   Drush binary not found or not executable. Skipping Drupal tasks."
  exit 0
fi

echo "   Drush version: $("$DRUSH_BIN" --version 2>/dev/null || echo 'version check failed')"

cd "$DRUPAL_ROOT"
echo "   Working dir now: $(pwd)"

echo "$DEBUG_SEP"
echo "🔎 Drush status dump:"
"$DRUSH_BIN" status 2>/dev/null || echo "   drush status failed"

# --- ENSURE BIGPIPE ENABLED ---
echo "$DEBUG_SEP"
echo "📦 Ensuring BigPipe is enabled..."
"$DRUSH_BIN" en big_pipe -y

# --- DISABLE THEME / TWIG DEVELOPMENT MODE ---
echo "$DEBUG_SEP"
echo "🛑 Disabling theme (Twig) development mode..."
echo "   Before — system.performance css.preprocess:"
"$DRUSH_BIN" config:get system.performance css.preprocess 2>/dev/null || echo "   config get failed"
echo "   Before — system.performance js.preprocess:"
"$DRUSH_BIN" config:get system.performance js.preprocess 2>/dev/null || echo "   config get failed"

"$DRUSH_BIN" theme:dev off

echo "   After — system.performance css.preprocess:"
"$DRUSH_BIN" config:get system.performance css.preprocess 2>/dev/null || echo "   config get failed"
echo "   After — system.performance js.preprocess:"
"$DRUSH_BIN" config:get system.performance js.preprocess 2>/dev/null || echo "   config get failed"

# --- ENFORCE BROWSER CACHE (1 DAY) ---
echo "$DEBUG_SEP"
echo "⏱️  Setting browser cache max-age to 1 day..."
echo "   Before: $("$DRUSH_BIN" config:get system.performance cache.page.max_age 2>/dev/null || echo 'get failed')"
"$DRUSH_BIN" config:set system.performance cache.page.max_age 86400 -y
echo "   After:  $("$DRUSH_BIN" config:get system.performance cache.page.max_age 2>/dev/null || echo 'get failed')"

# --- CACHE REBUILD ---
echo "$DEBUG_SEP"
echo "🧹 Running drush cr..."
echo "   css/ before cr: $([ -d "$DRUPAL_SITES_FILES/css" ] && echo "EXISTS ($(ls "$DRUPAL_SITES_FILES/css" | wc -l) files)" || echo 'MISSING')"
echo "   js/  before cr: $([ -d "$DRUPAL_SITES_FILES/js"  ] && echo "EXISTS ($(ls "$DRUPAL_SITES_FILES/js"  | wc -l) files)" || echo 'MISSING')"

"$DRUSH_BIN" cr

echo "   css/ after cr:  $([ -d "$DRUPAL_SITES_FILES/css" ] && echo "EXISTS ($(ls "$DRUPAL_SITES_FILES/css" | wc -l) files)" || echo 'MISSING')"
echo "   js/  after cr:  $([ -d "$DRUPAL_SITES_FILES/js"  ] && echo "EXISTS ($(ls "$DRUPAL_SITES_FILES/js"  | wc -l) files)" || echo 'MISSING')"

# --- RECREATE ASSET DIRS ---
echo "$DEBUG_SEP"
echo "📁 Recreating asset directories..."
mkdir -p "$DRUPAL_SITES_FILES/css" "$DRUPAL_SITES_FILES/js"
echo "   mkdir -p done"
sudo chown www-data:www-data "$DRUPAL_SITES_FILES/css" "$DRUPAL_SITES_FILES/js"
sudo chmod 775 "$DRUPAL_SITES_FILES/css" "$DRUPAL_SITES_FILES/js"
echo "   css/ → $(stat -c '%U:%G mode=%a' "$DRUPAL_SITES_FILES/css")"
echo "   js/  → $(stat -c '%U:%G mode=%a' "$DRUPAL_SITES_FILES/js")"
echo "   parent files/ → $(stat -c '%U:%G mode=%a' "$DRUPAL_SITES_FILES")"

echo "   Write test (sudo -u www-data):"
if sudo -u www-data touch "$DRUPAL_SITES_FILES/css/.write_test" 2>/dev/null; then
  echo "   ✅ www-data CAN write to css/"
  sudo -u www-data rm "$DRUPAL_SITES_FILES/css/.write_test"
else
  echo "   ❌ www-data CANNOT write to css/ — aggregation will fail"
fi

# --- FASTCGI CACHE CLEAR ---
echo "$DEBUG_SEP"
echo "🚀 Clearing FastCGI cache..."
/home/ubuntu/scripts/clear_fastcgi_cache.sh

# --- SITE WARMUP ---
echo "$DEBUG_SEP"
echo "🌐 Warming up site to regenerate aggregated assets..."

# Derive domain from conventional prod-{domain} directory naming.
# Falls back to sudo grep on nginx config (capital -R follows symlinks).
SITE_DOMAIN=$(basename "$REPO_ROOT" | sed 's/^prod-//')
echo "   Domain from directory name: '$SITE_DOMAIN'"

if [[ -z "$SITE_DOMAIN" || "$SITE_DOMAIN" == "$(basename "$REPO_ROOT")" ]]; then
  echo "   Directory name did not yield a domain — trying Nginx config..."
  SITE_DOMAIN=$(sudo grep -Rh 'server_name' /etc/nginx/sites-enabled/ 2>/dev/null \
    | awk '{print $2}' | tr -d ';' | grep '\.' | grep -v '^_' | head -1 || true)
  echo "   Domain from Nginx grep: '$SITE_DOMAIN'"
fi

if [[ -n "$SITE_DOMAIN" ]]; then
  echo "   Resolved SITE_DOMAIN='$SITE_DOMAIN'"
  echo "   Nginx listening on 443:"
  sudo ss -tlnp 'sport = :443' 2>/dev/null || echo "   (could not check port)"

  echo "   Sending warmup request: curl -k -H 'Host: $SITE_DOMAIN' https://127.0.0.1/"
  HTTP_CODE=$(curl -v -k -H "Host: $SITE_DOMAIN" "https://127.0.0.1/" \
    --max-time 30 -o /tmp/warmup_response.html -w "%{http_code}" \
    2>/tmp/warmup_curl_debug.txt || true)

  echo "   Warmup → HTTP $HTTP_CODE"
  echo "   Curl verbose output:"
  grep -E '^\*|^>|^<' /tmp/warmup_curl_debug.txt | head -40 || true

  if [[ "$HTTP_CODE" == "200" ]]; then
    echo "   ✅ Warmup succeeded"
    echo "   Response size: $(wc -c < /tmp/warmup_response.html 2>/dev/null || echo 'unknown') bytes"
  elif [[ "$HTTP_CODE" == "301" || "$HTTP_CODE" == "302" ]]; then
    LOCATION=$(grep -i '^< location:' /tmp/warmup_curl_debug.txt | head -1 || true)
    echo "   ↪️  Warmup got redirect ($LOCATION) — following with -L..."
    HTTP_CODE2=$(curl -s -k -L -H "Host: $SITE_DOMAIN" "https://127.0.0.1/" \
      --max-time 30 -o /tmp/warmup_response2.html -w "%{http_code}" 2>/dev/null || true)
    echo "   After redirect → HTTP $HTTP_CODE2"
    echo "   Response size: $(wc -c < /tmp/warmup_response2.html 2>/dev/null || echo 'unknown') bytes"
  else
    echo "   ⚠️  Warmup returned HTTP $HTTP_CODE — trying direct HTTPS to domain..."
    HTTP_CODE3=$(curl -s --max-time 30 -o /tmp/warmup_response3.html \
      -w "%{http_code}" "https://$SITE_DOMAIN/" 2>/dev/null || true)
    echo "   Direct request → HTTP $HTTP_CODE3"
  fi
else
  echo "   ❌ Could not determine site domain — warmup skipped."
fi

# --- CONFIRM AGGREGATED FILES ---
echo "$DEBUG_SEP"
echo "🔎 Checking aggregated files on disk..."
echo "   css/ exists: $([ -d "$DRUPAL_SITES_FILES/css" ] && echo 'YES' || echo 'NO')"
echo "   js/  exists: $([ -d "$DRUPAL_SITES_FILES/js"  ] && echo 'YES' || echo 'NO')"

CSS_COUNT=0
JS_COUNT=0
[[ -d "$DRUPAL_SITES_FILES/css" ]] && CSS_COUNT=$(find "$DRUPAL_SITES_FILES/css" -name "*.css" | wc -l)
[[ -d "$DRUPAL_SITES_FILES/js"  ]] && JS_COUNT=$(find  "$DRUPAL_SITES_FILES/js"  -name "*.js"  | wc -l)
echo "   Aggregated files: ${CSS_COUNT} CSS, ${JS_COUNT} JS"

if [[ "$CSS_COUNT" -gt 0 || "$JS_COUNT" -gt 0 ]]; then
  echo "   ✅ Aggregated assets present"
  echo "   CSS files:"
  find "$DRUPAL_SITES_FILES/css" -name "*.css" | head -5 | sed 's/^/      /'
  echo "   JS files:"
  find "$DRUPAL_SITES_FILES/js"  -name "*.js"  | head -5 | sed 's/^/      /'
else
  echo "   ❌ No aggregated files — aggregation did not run after warmup"
  echo "   Drupal watchdog (last 10 errors):"
  "$DRUSH_BIN" watchdog:show --count=10 --severity=Error 2>/dev/null || echo "   (watchdog check failed)"
fi

echo "$DEBUG_SEP"
echo "✅ Drupal production enforcement completed at $(date)"
exit 0

