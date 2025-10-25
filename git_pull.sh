#!/usr/bin/env bash
#
# /home/ubuntu/scripts/git_pull.sh
# Safely pull updates from remote Git repository when web files are owned by www-data.
# Temporarily chowns the repo to ubuntu, performs git pull, then restores www-data ownership.

set -euo pipefail

# --- FIND GIT ROOT ---
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)

if [[ -z "$REPO_ROOT" ]]; then
    echo "❌ Not inside a Git repository - aborted at $(date)"
    exit 1
fi

echo "🔍 Git repository root: $REPO_ROOT"

# --- CHANGE OWNERSHIP TO UBUNTU ---
echo "🧩 Changing ownership to ubuntu..."
sudo chown -R ubuntu:ubuntu "$REPO_ROOT"

# --- PERFORM GIT PULL ---
cd "$REPO_ROOT"
echo "⬇️  Executing git pull..."
if git pull --ff-only; then
    echo "✅ Git pull completed successfully."
else
    echo "❌ Git pull failed!"
    echo "🔁 Restoring www-data ownership..."
    sudo chown -R www-data:www-data "$REPO_ROOT"
    exit 1
fi

# --- RESTORE OWNERSHIP ---
echo "🔁 Restoring ownership to www-data..."
sudo chown -R www-data:www-data "$REPO_ROOT"

echo "✅ Ownership restored and pull completed successfully."
exit 0

