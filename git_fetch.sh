#!/usr/bin/env bash
#
# /home/ubuntu/scripts/git_fetch.sh
# Production-safe git fetch with ownership handoff

set -euo pipefail

# --- FIND GIT ROOT ---
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"

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

# --- TEMPORARILY TAKE OWNERSHIP ---
echo "🧩 Temporarily changing ownership to ubuntu..."
sudo chown -R ubuntu:ubuntu "$REPO_ROOT"

# --- GIT FETCH (AS UBUNTU) ---
cd "$REPO_ROOT"

echo "📡 Fetching from origin..."
git fetch origin

echo "✅ Git fetch completed successfully."
exit 0

