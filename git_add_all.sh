#!/usr/bin/env bash
#
# /home/ubuntu/scripts/git_add_all.sh
# Safely run git add . without breaking production ownership.

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

# --- PERFORM GIT ADD ---
cd "$REPO_ROOT"
echo "➕ Running git add . ..."
git add .

echo "✅ git add . completed successfully."
exit 0
