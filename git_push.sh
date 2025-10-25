#!/usr/bin/env bash
#
# /home/ubuntu/scripts/git_push.sh
# Safely push changes to remote Git repository when web files are owned by www-data.
# Temporarily changes ownership to ubuntu, performs git push, then restores www-data ownership.

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

# --- PERFORM GIT PUSH ---
cd "$REPO_ROOT"
echo "🚀 Executing git push..."
if git push; then
    echo "✅ Git push completed successfully."
else
    echo "❌ Git push failed!"
    echo "🔁 Restoring ownership to www-data..."
    sudo chown -R www-data:www-data "$REPO_ROOT"
    exit 1
fi

# --- RESTORE OWNERSHIP ---
echo "🔁 Restoring ownership to www-data..."
sudo chown -R www-data:www-data "$REPO_ROOT"

echo "✅ Ownership restored. Push operation complete."
exit 0

