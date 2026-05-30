#!/usr/bin/env bash
#
# /home/ubuntu/scripts/git_add_commit_push.sh
# Safely run git add, commit, and push without breaking production ownership.

set -euo pipefail

# --- FIND GIT ROOT ---
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)

if [[ -z "$REPO_ROOT" ]]; then
  echo "❌ Not inside a Git repository - aborted at $(date)"
  exit 1
fi

# --- COMMIT MESSAGE ---
DEFAULT_MESSAGE="ups from live"

read -r -p "Optional commit message addition, or press Enter for none: " USER_MESSAGE

if [[ -n "$USER_MESSAGE" ]]; then
  COMMIT_MESSAGE="$DEFAULT_MESSAGE - $USER_MESSAGE"
else
  COMMIT_MESSAGE="$DEFAULT_MESSAGE"
fi

echo "🔍 Git repository root: $REPO_ROOT"
echo "📝 Commit message: $COMMIT_MESSAGE"

# --- GUARANTEE OWNERSHIP RESTORATION ---
restore_ownership() {
  echo "🔁 Restoring ownership to www-data..."
  sudo chown -R www-data:www-data "$REPO_ROOT"
}
trap restore_ownership EXIT

# --- CHANGE OWNERSHIP TO UBUNTU FIRST ---
echo "🧩 Changing ownership to ubuntu..."
sudo chown -R ubuntu:ubuntu "$REPO_ROOT"

cd "$REPO_ROOT"

# --- GIT ADD ---
echo "➕ Running git add . ..."
git add .

# --- GIT COMMIT ---
if git diff --cached --quiet; then
  echo "ℹ️ No staged changes to commit."
else
  echo "📦 Running git commit..."
  git commit -m "$COMMIT_MESSAGE"
fi

# --- GIT PUSH ---
echo "🚀 Running git push..."
git push

echo "✅ Git add, commit, and push completed successfully."
exit 0
