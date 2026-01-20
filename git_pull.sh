#!/usr/bin/env bash
#
# /home/ubuntu/scripts/git_pull.sh
# Safely pull updates and run Drupal maintenance tasks.

set -euo pipefail

# --- FIND GIT ROOT ---
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)

if [[ -z "$REPO_ROOT" ]]; then
  echo "❌ Not inside a Git repository - aborted at $(date)"
  exit 1
fi

echo "🔍 Git repository root: $REPO_ROOT"

# --- GUARANTEE OWNERSHIP RESTORATION ---
restore_ownership() {
  echo "🔁 Restoring ownership to www-data..."
  sudo chown -R www-data:www-data "$REPO_ROOT"
}
trap restore_ownership EXIT

# --- CHANGE OWNERSHIP TO UBUNTU ---
echo "🧩 Changing ownership to ubuntu..."
sudo chown -R ubuntu:ubuntu "$REPO_ROOT"

# --- PERFORM GIT PULL ---
cd "$REPO_ROOT"
echo "⬇️  Executing git pull..."
git pull --ff-only
echo "✅ Git pull completed successfully."

# --- DETECT DRUPAL ROOT ---
DRUPAL_ROOT=""

if [[ -f "$REPO_ROOT/core/lib/Drupal.php" ]]; then
  DRUPAL_ROOT="$REPO_ROOT"
elif [[ -f "$REPO_ROOT/web/core/lib/Drupal.php" ]]; then
  DRUPAL_ROOT="$REPO_ROOT/web"
fi

if [[ -z "$DRUPAL_ROOT" ]]; then
  echo "ℹ️  Not a Drupal site. Skipping Drupal tasks."
  exit 0
fi

echo "🧠 Drupal site detected at: $DRUPAL_ROOT"

# --- RUN DRUSH CACHE REBUILD ---
DRUSH_BIN="$REPO_ROOT/vendor/drush/drush/drush"

if [[ ! -x "$DRUSH_BIN" ]]; then
  echo "⚠️  Drush binary not found. Skipping Drupal tasks."
  exit 0
fi

echo "🧹 Running drush cr..."
cd "$DRUPAL_ROOT"
"$DRUSH_BIN" cr

# --- RUN FASTCGI CACHE CLEAR ---
echo "🚀 Clearing FastCGI cache..."
/home/ubuntu/scripts/clear_fastcgi_cache.sh


echo "✅ Drupal maintenance tasks completed successfully."
exit 0

